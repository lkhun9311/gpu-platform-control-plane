module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.24.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # The API server is reachable from inside the VPC always, and from the internet only if someone names the
  # addresses.
  #
  # The private endpoint is what lets the workers -- which no longer have public addresses -- talk to the API
  # without leaving the VPC. It is not optional once the nodes are private.
  #
  # The public half is derived rather than set: an empty api_public_access_cidrs turns it off entirely, and a
  # non-empty one restricts it to those addresses. variables.tf rejects 0.0.0.0/0 outright, which is what the
  # module default used to be and what this cluster ran with until it was measured against the threat model
  # in docs/09. Reaching the endpoint is not the same as authenticating to it -- IAM and RBAC still stand --
  # but an endpoint the whole internet can reach is one a leaked credential can be used from anywhere, and
  # narrowing it costs nothing.
  #
  # Note what the default of [] implies for tooling: `terraform apply` here only calls AWS APIs and works
  # fine, but infra/aws/argo-bootstrap drives the Kubernetes API through the helm and kubernetes providers
  # and cannot run from outside the VPC. Its README says how.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = length(var.api_public_access_cidrs) > 0
  cluster_endpoint_public_access_cidrs = var.api_public_access_cidrs

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

  vpc_id = module.vpc.vpc_id

  # Private subnets: both the control-plane ENIs and every node group live here. The public subnets hold the
  # NAT gateway and nothing else.
  subnet_ids = module.vpc.private_subnets

  # EKS access entries are the auth path; the CI apply role entry is added in iam.tf.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # SSM Session Manager, which is what replaces the bastion host rather than supplementing it.
  #
  # A private node with no public address still has to be reachable when a session goes wrong -- the usual
  # answer is a bastion in the public subnet, which is a permanently billed instance whose whole job is to
  # hold an open SSH port. Session Manager needs no inbound port at all: the agent (already in AL2023) dials
  # out through the NAT gateway, and access is an IAM decision that CloudTrail records.
  #
  # This is the one policy attachment that buys a control the security groups cannot.
  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  eks_managed_node_groups = {
    cpu = {
      # Pin the node group to the first AZ to avoid cross-AZ workload traffic. It is also the zone holding
      # the single NAT gateway, so this group's egress stays in-zone.
      subnet_ids     = [module.vpc.private_subnets[0]]
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
      subnet_ids     = local.gpu_subnets
      instance_types = [var.gpu_node_instance_type]
      # On-Demand rather than Spot. A reclaimed Spot node mid-run does not fail the experiment cleanly -- it
      # ends the observation and leaves the run indistinguishable from one whose worker died, which is a
      # class of refusal the lab already has and does not need a second cause for. The session is measured in
      # hours, so the premium is small against the cost of an unusable run.
      # On-Demand, and the reason is measurement rather than cost -- which is the opposite of where this
      # started.
      #
      # The first version of this comment said a reclaimed Spot node "does not fail the experiment cleanly"
      # and leaves the run indistinguishable from one whose worker died. That argument does not survive
      # contact with this repository: telling those apart is exactly what the validity gates and the refusal
      # register were built for, and a vanished node is one of the easiest things they catch.
      #
      # The argument that does survive is narrower and only applies HERE. queuelab measures preemption. A
      # Spot reclamation is a two-minute warning followed by a cordon and drain, and a drain EVICTS the
      # victim Pod -- which truncates the victim's work window (PodReady -> AttemptStopped) that the held
      # time is computed over. A truncated window reports a SHORTER hold, which flatters the headline. It is
      # not that the run would break; it is that it might quietly read better.
      #
      # A bias toward the result you want is the one failure mode this study cannot afford, and $2.75/hour is
      # not enough to buy it. The M5-b and M5-c groups measure admission under KV pressure, where an
      # interruption aborts without biasing, and they run on Spot for that reason.
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
      subnet_ids     = local.gpu_single_subnets
      instance_types = [var.gpu_single_node_instance_type]

      # Spot, because what this group measures is not harmed by being interrupted.
      #
      # M5-b compares four admission arms against one engine under KV pressure. An interruption ends the arm;
      # it does not bias it, and a run that ends without records is refused rather than reported. That is the
      # difference from the queuelab group above, where a drain-induced eviction shortens the very window the
      # headline is computed over.
      #
      # The discount is not marginal. On 2026-08-27 the Seoul spot history for g5.xlarge was $0.357 (2d),
      # $0.403 (2c) and $0.424 (2a) against an On-Demand $1.237 -- 66 to 71 percent off. Even assuming every
      # session is interrupted once and half the work is redone, the expected cost is well under half of
      # On-Demand.
      #
      # What this buys is not a smaller bill so much as more runs for the same money, and the study's weakest
      # axis is repetition count: two reviews scored its statistical power at 30 percent and said the
      # sequence itself encoded the limit. Spot converts the same budget into REPS.
      capacity_type = "SPOT"
      min_size      = 0
      max_size      = 1
      desired_size  = 0

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

    # The sharing node group, and it deliberately does NOT carry the observer label.
    #
    # M5-c puts two engines on one card through time-slicing, and under time-slicing a busy SM belongs to no
    # single Pod: DCGM cannot attribute it, and queuelab's exclusivity clause refuses to. Giving this node
    # platform.lkhun9311.github.io/gpu would schedule the exclusive device plugin and the observer here, and
    # two plugins registering nvidia.com/gpu against one kubelet socket is not something worth debugging on a
    # rented card. The label split is the mechanism; the comment is only the reason.
    #
    # An A10G rather than a T4, decided by arithmetic before renting anything: two Qwen2.5-3B engines leave
    # 10 MiB of KV each on a T4, which is 284 tokens against a 7,695-token contender prompt.
    # internal/bench.SharingPlan refuses that plan. g5.xlarge is four vCPU, the same as g4dn.xlarge, so the
    # granted G-family quota covers it.
    #
    # max_size 1 is what makes co-location certain. Two engines on two nodes are not sharing a card, and
    # nothing downstream could tell that apart from a sharing result.
    gpu_shared = {
      subnet_ids     = local.gpu_shared_subnets
      instance_types = [var.gpu_shared_node_instance_type]

      # Spot, for the same reason as gpu_single: the sharing matrix measures what two engines do to each
      # other's latency on one card, and an interruption ends a cell rather than skewing it. A cell that did
      # not finish leaves no record, and a matrix missing a cell is refused at comparison rather than
      # averaged over.
      capacity_type = "SPOT"
      min_size      = 0
      max_size      = 1
      desired_size  = 0

      ami_type = "AL2023_x86_64_NVIDIA"

      labels = {
        "platform.lkhun9311.github.io/gpu-sharing" = "true"
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