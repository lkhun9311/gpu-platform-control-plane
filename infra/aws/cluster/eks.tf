module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.24.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Public endpoint: demo-only threat model, documented in docs/09.
  cluster_endpoint_public_access = true

  # Terraform owns the cluster-lifecycle add-ons.
  #
  # Argo CD never touches these.
  #
  # Versions are pinned to the AWS defaults for EKS 1.31.
  #
  # Re-verify them against aws eks describe-addon-versions before provisioning, since AWS revises eksbuild numbers over time.
  cluster_addons = {
    coredns = {
      addon_version = "v1.11.3-eksbuild.1"
    }
    kube-proxy = {
      addon_version = "v1.31.0-eksbuild.5"
    }
    vpc-cni = {
      addon_version = "v1.18.3-eksbuild.3"
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  # EKS access entries are the auth path; the CI apply role entry is added in iam.tf.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    cpu = {
      # Pin the node group to the first AZ to avoid cross-AZ workload traffic.
      subnet_ids     = [module.vpc.public_subnets[0]]
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 2
      desired_size   = 1

      # IMDSv2 required, single hop: blocks IMDS from pod-network containers.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }

    # The GPU node group is added in M5-b: desired=0, On-Demand g5.xlarge,
    # taint nvidia.com/gpu=present:NoSchedule, pinned to public_subnets[0].
  }

  tags = var.tags
}
