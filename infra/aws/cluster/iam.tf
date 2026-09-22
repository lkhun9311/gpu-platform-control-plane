# The CI apply role is resolved from its name rather than passed in as an ARN.
#
# See the comment on var.ci_apply_role_name: the ARN form was never supplied by any caller, so the access
# entry below counted to zero on every plan ever produced here. A lookup cannot be forgotten.
data "aws_iam_role" "ci_apply" {
  count = var.ci_apply_role_name == "" ? 0 : 1
  name  = var.ci_apply_role_name
}

# The CI apply role needs kubectl to run pre-destroy teardown in a later increment.
#
# Without this access entry, destroy.yml cannot delete Argo apps in order.
#
# The entry is created only when the role ARN is supplied, so validate and plan work before bootstrap exists.
resource "aws_eks_access_entry" "ci_apply" {
  count         = var.ci_apply_role_name == "" ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.ci_apply[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_apply_admin" {
  count         = var.ci_apply_role_name == "" ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.ci_apply[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  # AWS requires the access entry to exist before a policy association references its principal.
  #
  # The two resources share no attribute, so this explicit dependency is what orders them.
  depends_on = [aws_eks_access_entry.ci_apply]
}

# The EBS CSI driver's role, assumed through IRSA rather than carried on the node role.
#
# `enable_irsa` is not set on the module and its default is true (v20.24.0 variables.tf:401), so the OIDC
# provider exists and `module.eks.oidc_provider_arn` is the trust anchor. If that default ever changes, this
# role's trust policy stops resolving and the addon fails to assume it -- a loud failure rather than a quiet
# one, which is why it is referenced rather than duplicated.
#
# The registry submodule that normally builds this (iam-role-for-service-accounts-eks) is deliberately not
# used: `make infra-validate` runs `terraform init -backend=false` in CI, and every module it has to fetch is
# a network dependency in a check that is otherwise offline.
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # Both conditions are required. Without the `sub` bound to this exact service account, any pod in the
    # cluster with a projected token could assume this role and delete any volume in the account.
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
