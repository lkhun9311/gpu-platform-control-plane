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
  # One A10G, which is the smallest thing that is a real card rather than a fraction of one. The lab's claims
  # are about a device being held and released, not about how fast it computes, so a larger instance would buy
  # nothing the experiment reads and would bill for it by the hour.
  default = "g5.xlarge"
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
