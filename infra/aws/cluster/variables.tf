variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "gpu-platform"
}

variable "cluster_version" {
  description = "Pinned EKS Kubernetes version. Clusters are recreated, never upgraded."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "Instance type for the CPU managed node group."
  type        = string
  default     = "t3.large"
}

variable "gpu_shared_node_instance_type" {
  description = "Instance type for the sharing node group M5-c runs its matrix on."
  type        = string
  # ONE A10G, and 24 GB is the requirement rather than a preference.
  #
  # The matrix puts two Qwen2.5-3B engines on one card. Time-slicing does not partition memory, so each gets
  # half: on a T4 that leaves 10 MiB of KV per engine -- 284 tokens against a 7,695-token contender prompt --
  # and internal/bench.SharingPlan refuses it. An A10G leaves 3.6 GiB each.
  #
  # Four vCPU, the same as g4dn.xlarge, so the 8 vCPU granted for ap-northeast-2 on 2026-08-24 covers it:
  # M5-c is not blocked on the support case either.
  default = "g5.xlarge"
}

variable "gpu_single_node_instance_type" {
  description = "Instance type for the one-card GPU node group that M5-b runs on."
  type        = string
  # ONE T4, and one is the requirement rather than a saving.
  #
  # config/vllm/deployment.yaml pins replicas = 1 because the KV-aware arm scrapes one /metrics endpoint and
  # admits against what it reads; a second engine is a second cache it would be reacting to the wrong one of.
  # So the experiment has no use for a second card, and g4dn.xlarge is the smallest shape that carries one.
  #
  # It is also the only GPU shape this account can currently start. The Seoul G quota was granted at 8 vCPU
  # on 2026-08-24 against a request for 96, and the 48-vCPU queuelab group does not fit in that; 4 does.
  default = "g4dn.xlarge"
}

variable "gpu_node_instance_type" {
  description = "Instance type for the GPU managed node group, which runs at desired_size 0 until a session."
  type        = string
  # FOUR T4s, and the count is the requirement rather than a preference.
  #
  # The protocol needs TWO devices on ONE node at the same time: the trace runs a1 inside the tenant's quota
  # and a2-borrow beyond it concurrently, and the lab pins both to a single worker it holds exclusively. Every
  # recorded run carries requiredGPU 2 against allocatable 2, and qualifyWorker refuses a node that cannot
  # meet it.
  #
  # This was g5.xlarge, which has ONE A10G. A review caught it before any money was spent: the node group
  # would have provisioned, the first run would have been refused at qualification for a node too small to
  # measure on, and the bill would already have started. Nothing in terraform can check a Kubernetes-side
  # requirement, so it is written here where the number is chosen.
  #
  # g4dn.12xlarge is the cheapest instance carrying more than one GPU that DCGM supports properly -- Turing,
  # four T4s.
  #
  # This comment used to say "the two spare cards cost nothing the experiment reads". That was asserted
  # without measuring and it was false. The study's headline is the owner's wait, and the records show what
  # produces it: Kueue admits the owner within 0.1 s of the preemption decision, and the owner's Pod then
  # becomes Ready one to two seconds after the VICTIM'S terminal phase -- it is waiting for a card. Two idle
  # cards would absorb it at admission in both arms and the 29-second difference would collapse below the
  # floor, with every other figure in the record looking exactly as it does now.
  #
  # The spare cards are therefore excluded rather than tolerated. The first attempt at that was a
  # NVIDIA_VISIBLE_DEVICES setting on the device plugin, which two reviews then established almost certainly
  # does not restrict what the plugin advertises -- see the comment beside it in
  # config/nvidia-device-plugin/daemonset.yaml. The exclusion the run actually relies on is its own: the
  # qualification refuses a node advertising more devices than the protocol needs, and the run occupies the
  # surplus itself so that what it measures is a node with exactly the scarcity the contrast depends on.
  #
  # Anything with two or more well-supported devices works, because the surplus is taken away by the harness
  # rather than trusted to be harmless or trusted to a manifest nobody can check without hardware.
  default = "g4dn.12xlarge"
}

variable "tags" {
  description = "Owner and TTL tags applied to every resource."
  type        = map(string)
  default = {
    project = "gpu-platform-control-plane"
    owner   = "lkhun9311"
    ttl     = "ephemeral"
  }
}

variable "ci_apply_role_arn" {
  description = "ARN of the CI apply role (bootstrap output) granted cluster admin via an access entry."
  type        = string
  default     = ""
}
