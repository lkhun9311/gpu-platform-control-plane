# Where each GPU node group can actually run, rather than wherever subnet zero happens to be.
#
# Every node group pinned to module.vpc.public_subnets[0], which is the first of the two AZs the VPC was
# built in. That worked by luck and would have kept working until it did not: in ap-northeast-2 the
# availability zones come back a, b, c, d, so subnet zero is 2a, and g5 is offered in 2a, 2c and 2d --
# but NOT in 2b. Lose 2a from the available list for any reason and the slice becomes [2b, 2c], subnet zero
# becomes 2b, and the A10G groups have nowhere to run.
#
# The failure would not have surfaced at apply. Every GPU group runs at desired_size 0, so terraform builds
# the group and launches nothing; the InsufficientInstanceCapacity or unsupported-type error arrives when a
# session scales up, on a cluster that has looked healthy for hours. This is the same shape as the region
# defaulting to us-east-1, and it is worth solving the same way: derive the placement instead of assuming it.

data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.gpu_node_instance_type]
  }
  filter {
    name   = "location"
    values = local.azs
  }
}

data "aws_ec2_instance_type_offerings" "gpu_single" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.gpu_single_node_instance_type]
  }
  filter {
    name   = "location"
    values = local.azs
  }
}

data "aws_ec2_instance_type_offerings" "gpu_shared" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.gpu_shared_node_instance_type]
  }
  filter {
    name   = "location"
    values = local.azs
  }
}

locals {
  # The VPC module builds one private subnet per AZ, in order, so this pairs them. Node groups live in the
  # private tier now; the public subnets hold the NAT gateway and no instances.
  az_subnet = zipmap(local.azs, module.vpc.private_subnets)

  # Subnets whose zone actually offers the type. Ordered by local.azs so the choice is deterministic
  # rather than dependent on the order AWS happened to return offerings in.
  gpu_subnets        = [for az in local.azs : local.az_subnet[az] if contains(data.aws_ec2_instance_type_offerings.gpu.locations, az)]
  gpu_single_subnets = [for az in local.azs : local.az_subnet[az] if contains(data.aws_ec2_instance_type_offerings.gpu_single.locations, az)]
  gpu_shared_subnets = [for az in local.azs : local.az_subnet[az] if contains(data.aws_ec2_instance_type_offerings.gpu_shared.locations, az)]
}

# A hard stop at plan time, because the alternative is a soft stop at session time.
#
# terraform_data carries no infrastructure; it exists so these preconditions have somewhere to live. A
# `check` block would only warn, and a warning is exactly what nobody reads before scaling a node group up.
resource "terraform_data" "gpu_placement" {
  input = {
    gpu        = join(",", local.gpu_subnets)
    gpu_single = join(",", local.gpu_single_subnets)
    gpu_shared = join(",", local.gpu_shared_subnets)
  }

  lifecycle {
    precondition {
      condition     = length(local.gpu_subnets) > 0
      error_message = "No subnet in this VPC is in a zone that offers ${var.gpu_node_instance_type}. queuelab needs two devices on one node and this is the only family size that provides them; either widen local.azs or move the region."
    }
    precondition {
      condition     = length(local.gpu_single_subnets) > 0
      error_message = "No subnet in this VPC is in a zone that offers ${var.gpu_single_node_instance_type}. M5-b's sizing in hack/m5b-vllm-sizing.md is derived for that card and does not transfer to another."
    }
    precondition {
      condition     = length(local.gpu_shared_subnets) > 0
      error_message = "No subnet in this VPC is in a zone that offers ${var.gpu_shared_node_instance_type}. M5-c puts two engines on one card and internal/bench.SharingPlan refuses that plan on anything smaller."
    }
  }
}
