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
  # four T4s. The two spare cards cost nothing the experiment reads; what would cost is a node the run cannot
  # qualify. Anything with two or more well-supported devices works.
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
