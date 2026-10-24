# The gpu group's zone pin, checked at plan time without AWS.
#
# The provider is mocked and both modules are replaced by fixed outputs, so the only logic that runs is this
# root's: the zone union in vpc.tf, the subnet filter and its precondition in placement.tf.
# The offerings below are ap-northeast-2's as placement.tf and vpc.tf describe them: g4dn.12xlarge in 2a,
# 2b and 2c, and g5 in 2a, 2c and 2d. They are fixtures, not a reading of the region.

mock_provider "aws" {
  override_data {
    target = data.aws_ec2_instance_type_offerings.gpu
    values = { locations = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"] }
  }
  override_data {
    target = data.aws_ec2_instance_type_offerings.gpu_single
    values = { locations = ["ap-northeast-2a", "ap-northeast-2c", "ap-northeast-2d"] }
  }
  override_data {
    target = data.aws_ec2_instance_type_offerings.gpu_shared
    values = { locations = ["ap-northeast-2a", "ap-northeast-2c", "ap-northeast-2d"] }
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c", "ap-northeast-2d"] }
  }
  override_data {
    target = data.aws_servicequotas_service_quota.gpu_on_demand
    values = { value = 52 }
  }
  override_data {
    target = data.aws_servicequotas_service_quota.gpu_spot
    values = { value = 8 }
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = { default_vcpus = 48 }
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu_single
    values = { default_vcpus = 4 }
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu_shared
    values = { default_vcpus = 8 }
  }
  override_data {
    target = data.aws_iam_policy_document.ebs_csi_assume
    values = { json = "{}" }
  }
  # The provider validates ARN shape at plan even under a mock, and a generated string is not one.
  override_data {
    target = data.aws_iam_role.ci_apply
    values = { arn = "arn:aws:iam::000000000000:role/test-ci-apply" }
  }
}

# The private subnet IDs name their zone, so an assertion can say which zone a subnet is without a lookup.
# local.azs is the sorted union, 2a, 2b, 2c, 2d, and the VPC module pairs one private subnet with each.
override_module {
  target = module.vpc
  outputs = {
    vpc_id                  = "vpc-test"
    private_subnets         = ["subnet-2a", "subnet-2b", "subnet-2c", "subnet-2d"]
    public_subnets          = ["subnet-pub-2a", "subnet-pub-2b", "subnet-pub-2c", "subnet-pub-2d"]
    private_route_table_ids = ["rtb-test"]
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster_name                       = "gpu-platform"
    cluster_endpoint                   = "https://example.invalid"
    cluster_certificate_authority_data = "dGVzdA=="
    oidc_provider                      = "oidc.example.invalid/id/TEST"
    oidc_provider_arn                  = "arn:aws:iam::000000000000:oidc-provider/oidc.example.invalid/id/TEST"
  }
}

# Every comparison converts both sides to a list, because Terraform's == is false between a list and a tuple
# holding the same strings, and which of the two a local is depends on how it is written, not on its value.

run "unpinned_keeps_every_zone_that_offers_the_type" {
  command = plan

  assert {
    condition     = tolist(local.gpu_subnets) == tolist(["subnet-2a", "subnet-2b", "subnet-2c"])
    error_message = "With no pin the gpu group must keep every VPC zone offering its type, got ${jsonencode(local.gpu_subnets)}."
  }
}

run "pinned_to_one_offered_zone" {
  command = plan

  variables {
    gpu_availability_zone = "ap-northeast-2a"
  }

  assert {
    condition     = tolist(local.gpu_subnets) == tolist(["subnet-2a"])
    error_message = "A pin to 2a must leave exactly 2a's private subnet, got ${jsonencode(local.gpu_subnets)}."
  }

  # The pin narrows the gpu group alone; the single-card groups and the VPC's zones are untouched.
  assert {
    condition     = tolist(local.gpu_single_subnets) == tolist(["subnet-2a", "subnet-2c", "subnet-2d"])
    error_message = "The pin must not change the single-card group's subnets, got ${jsonencode(local.gpu_single_subnets)}."
  }

  assert {
    condition     = tolist(local.azs) == tolist(["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c", "ap-northeast-2d"])
    error_message = "The pin must not change the VPC's zones, got ${jsonencode(local.azs)}."
  }
}

# 2d is in the VPC, because the A10G groups need it, but g4dn.12xlarge is not offered there.
run "pinned_to_a_vpc_zone_the_type_is_not_offered_in" {
  command = plan

  variables {
    gpu_availability_zone = "ap-northeast-2d"
  }

  expect_failures = [terraform_data.gpu_placement]
}

run "pinned_to_a_zone_outside_the_vpc" {
  command = plan

  variables {
    gpu_availability_zone = "ap-northeast-2z"
  }

  expect_failures = [terraform_data.gpu_placement]
}

run "a_value_that_is_not_a_zone_name" {
  command = plan

  variables {
    gpu_availability_zone = "2a"
  }

  expect_failures = [var.gpu_availability_zone]
}
