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

    # The GPU node group the device-work observer and the real device plugin need.
    #
    # desired_size = 0 is the important number and it is not a placeholder: a GPU instance is charged by the
    # hour whether or not anything is scheduled on it, and this repository's whole cost discipline is that
    # nothing bills while nobody is running an experiment. Scaling it up is a deliberate act at the start of
    # a session and back to 0 at the end. min_size = 0 is what makes that possible.
    #
    # max_size is a CAPABILITY and desired_size is the cost control, and conflating the two cost this study
    # an axis. The cap was 1, which saved nothing -- nothing bills at desired_size = 0 either way -- and made
    # the node comparison the preregistration promises impossible to run: `-compare -mode node` refuses a
    # record set in which nothing varies, so a session on one node cannot deliver that half however it is
    # invoked. It is 2 so the choice is the operator's at session time rather than made here by a number
    # nobody argued for.
    #
    # Scaling to 2 doubles the burn for as long as both are up, and the node axis is the only thing it buys.
    # hack/gpu-session-preregistration.md says what the session delivers with one node and what it does not.
    gpu = {
      subnet_ids     = [module.vpc.public_subnets[0]]
      instance_types = [var.gpu_node_instance_type]
      # On-Demand rather than Spot. A reclaimed Spot node mid-run does not fail the experiment cleanly -- it
      # ends the observation and leaves the run indistinguishable from one whose worker died, which is a
      # class of refusal the lab already has and does not need a second cause for. The session is measured in
      # hours, so the premium is small against the cost of an unusable run.
      capacity_type = "ON_DEMAND"
      min_size      = 0
      max_size      = 2
      desired_size  = 0

      # The AMI with the NVIDIA driver already in it. Without this the device plugin has nothing to talk to
      # and the node advertises no capacity, which reads downstream as "no GPU nodes" rather than as "the
      # driver is missing".
      ami_type = "AL2023_x86_64_NVIDIA"

      # The taint keeps ordinary workloads off the expensive node; the label is what the DCGM exporter and
      # the device plugin select on.
      #
      # The label is this repository's own rather than nvidia.com/gpu.present, which is produced by NVIDIA's
      # GPU Feature Discovery -- not deployed here. Selecting on a label nothing sets leaves the observer
      # unschedulable and silently absent, and a run then reports "no device observer ran" without anything
      # saying why. config/dcgm-exporter/daemonset.yaml selects on this one.
      labels = {
        "platform.lkhun9311.github.io/gpu" = "true"
      }
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "present"
          effect = "NO_SCHEDULE"
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }

    # A second GPU group, one card wide, because the two experiments need different machines and the quota
    # only allows one of them.
    #
    # queuelab needs TWO devices on ONE node, and the G family has no two-GPU instance: the sizes run
    # 1, 1, 1, 1, then jump to 4 at g4dn.12xlarge, which is 48 vCPU. M5-b needs exactly one card, and its
    # engine Deployment asserts replicas = 1 for the single-KV-pool reason. Putting M5-b on the 12xlarge
    # works and wastes three cards' worth of hourly charge; more importantly, on 2026-08-24 the Seoul
    # account's "Running On-Demand G and VT instances" quota was granted at 8 vCPU against a request for 96,
    # so the 48-vCPU group cannot start at all and this 4-vCPU one can. The M5-b run is not blocked on a
    # support case.
    #
    # Same desired_size = 0 discipline, same taint and label, so the observer and device plugin need no
    # special case. max_size is 1 rather than 2: a second node here buys nothing, because the arms are
    # compared against one engine and a second KV pool is the one thing config/vllm forbids.
    gpu_single = {
      subnet_ids     = [module.vpc.public_subnets[0]]
      instance_types = [var.gpu_single_node_instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = 0
      max_size       = 1
      desired_size   = 0

      ami_type = "AL2023_x86_64_NVIDIA"

      labels = {
        "platform.lkhun9311.github.io/gpu" = "true"
      }
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "present"
          effect = "NO_SCHEDULE"
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  tags = var.tags
}
