# The shared volume of the distributed restart session, built only when var.efs_enabled asks for it.
#
# A restartable distributed MLTrainingJob starts every rank again, possibly on another node, and the ranks must read
# what all of them wrote before the fault (docs/superpowers/specs/2026-11-01-distributed-restart-design.md).
# EBS, the only volume this cluster had, attaches to one node at a time, so it cannot be that volume.
#
# Everything here counts on var.efs_enabled, so a session that does not ask plans the resources it always planned.
# The Kubernetes side, a PersistentVolume naming this file system and a ReadWriteMany claim bound to it, is rendered
# by the session from the efs_file_system_id output, because this root drives no Kubernetes provider.

locals {
  efs_count = var.efs_enabled ? 1 : 0
}

resource "aws_efs_file_system" "shared" {
  count          = local.efs_count
  creation_token = "${var.cluster_name}-restart"
  encrypted      = true

  # Bursting rather than Elastic, because Elastic bills every byte written ($0.07 per GB in ap-northeast-2, Price List
  # API, 2026-11-01) and the session writes a checkpoint after every step on every rank.
  # A new file system starts with a burst credit balance, and the session's checkpoints are far smaller than it.
  throughput_mode  = "bursting"
  performance_mode = "generalPurpose"

  tags = merge(var.tags, { Name = "${var.cluster_name}-restart" })

  lifecycle {
    # The mount targets follow the gpu group's subnets, so an unpinned group would put ranks, and mount targets, in
    # several zones, and the session's figures would then include cross-zone NFS that its registration rules out.
    precondition {
      condition     = var.gpu_availability_zone != ""
      error_message = "efs_enabled needs gpu_availability_zone: the restart session's ranks, spare and mount target share one zone, and an unpinned gpu group could spread them across several."
    }
  }
}

# The mount targets admit NFS from the nodes and nothing else.
resource "aws_security_group" "efs" {
  count       = local.efs_count
  name        = "${var.cluster_name}-efs"
  description = "NFS from the EKS nodes to the restart session's EFS mount targets"
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-efs" })
}

# From the module's node security group, which every managed node group carries, rather than from the VPC CIDR, so a
# load balancer or an endpoint in the same VPC cannot reach the file system.
resource "aws_vpc_security_group_ingress_rule" "efs_nfs_from_nodes" {
  count                        = local.efs_count
  security_group_id            = aws_security_group.efs[0].id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  description                  = "NFS from the EKS node security group"
}

# One mount target per subnet the gpu group may use, which the zone pin makes exactly one.
#
# count rather than for_each, because the subnet IDs are unknown until the VPC exists, and for_each refuses unknown
# keys at plan; the number of subnets is known, since it comes from the zone filter in placement.tf.
resource "aws_efs_mount_target" "shared" {
  count           = var.efs_enabled ? length(local.gpu_subnets) : 0
  file_system_id  = aws_efs_file_system.shared[0].id
  subnet_id       = local.gpu_subnets[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

# The EFS CSI controller's role, through IRSA, as the EBS CSI driver's is built in iam.tf and for the same reasons.
#
# The session provisions its volume statically, so the controller creates no access point and the node plugin mounts
# without IAM; the role exists so the addon starts healthy rather than crash-looping on a missing credential, and so a
# later dynamically provisioned claim does not need a second apply.
data "aws_iam_policy_document" "efs_csi_assume" {
  count = local.efs_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # Bound to the controller's service account alone, so no other Pod's projected token can assume it.
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  count              = local.efs_count
  name               = "${var.cluster_name}-efs-csi"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume[0].json
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = local.efs_count
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

locals {
  # The addon entry eks.tf merges into the module's cluster_addons, empty when the volume is off.
  #
  # Pinned to the default AWS lists for Kubernetes 1.35, read on 2026-11-01:
  #   aws eks describe-addon-versions --addon-name aws-efs-csi-driver --kubernetes-version 1.35 --region ap-northeast-2
  # It moves with var.cluster_version like the other pinned addons.
  # one() rather than an index, because the entry is built before the filter drops it, and [0] of an empty list fails.
  efs_addon = {
    for name, addon in {
      aws-efs-csi-driver = {
        addon_version            = "v3.5.3-eksbuild.1"
        service_account_role_arn = one(aws_iam_role.efs_csi[*].arn)
      }
    } : name => addon if var.efs_enabled
  }
}
