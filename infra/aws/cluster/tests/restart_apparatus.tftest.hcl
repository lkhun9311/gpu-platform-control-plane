# The distributed restart session's infrastructure, checked at plan time without AWS: the EFS volume that efs_enabled
# builds or leaves out, the three-worker gpu group, and the quota precondition that still holds three of a type the
# account cannot run.
#
# The provider is mocked and both modules are replaced by fixed outputs, as in gpu_zone.tftest.hcl, whose offerings
# these copy: g4dn.12xlarge in 2a, 2b and 2c, g5 in 2a, 2c and 2d.
# The quota is the 128 vCPU granted on 2026-11-01 (service-quotas, read-only, profile gpu-lab), and g5.xlarge is
# 4 vCPU (describe-instance-types, same day); both are fixtures here, not readings.

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
    values = { value = 128 }
  }
  override_data {
    target = data.aws_servicequotas_service_quota.gpu_spot
    values = { value = 8 }
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = { default_vcpus = 4 }
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu_single
    values = { default_vcpus = 4 }
  }
  override_data {
    target = data.aws_ec2_instance_type.gpu_shared
    values = { default_vcpus = 4 }
  }
  override_data {
    target = data.aws_iam_policy_document.ebs_csi_assume
    values = { json = "{}" }
  }
  override_data {
    target = data.aws_iam_policy_document.efs_csi_assume
    values = { json = "{}" }
  }
  override_data {
    target = data.aws_iam_role.ci_apply
    values = { arn = "arn:aws:iam::000000000000:role/test-ci-apply" }
  }
  # The provider checks ARN shape at plan even under a mock, and the role's ARN reaches the addon entry.
  override_resource {
    target = aws_iam_role.efs_csi
    values = { arn = "arn:aws:iam::000000000000:role/test-efs-csi" }
  }
  # Known at plan, so an assertion can say which file system and which security group a reference names.
  override_resource {
    target          = aws_efs_file_system.shared
    override_during = plan
    values          = { id = "fs-test" }
  }
  override_resource {
    target          = aws_security_group.efs
    override_during = plan
    values          = { id = "sg-efs" }
  }
}

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
    node_security_group_id             = "sg-nodes"
  }
}

# The session's own variables: g5.xlarge in the gpu group, three of them, pinned to 2a.
variables {
  gpu_node_instance_type = "g5.xlarge"
  gpu_max_nodes          = 3
  gpu_availability_zone  = "ap-northeast-2a"
}

run "efs_is_absent_unless_asked_for" {
  command = plan

  variables {
    gpu_max_nodes         = 1
    gpu_availability_zone = ""
  }

  assert {
    condition     = length(aws_efs_file_system.shared) == 0 && length(aws_efs_mount_target.shared) == 0
    error_message = "With efs_enabled unset no file system or mount target may be planned."
  }

  assert {
    condition     = length(aws_security_group.efs) == 0 && length(aws_iam_role.efs_csi) == 0
    error_message = "With efs_enabled unset neither the NFS security group nor the CSI role may be planned."
  }

  assert {
    condition     = length(local.efs_addon) == 0
    error_message = "With efs_enabled unset the EFS CSI addon must not join the cluster's addons, got ${jsonencode(keys(local.efs_addon))}."
  }
}

run "efs_with_one_mount_target_in_the_pinned_zone" {
  command = plan

  variables {
    efs_enabled = true
  }

  assert {
    condition     = length(aws_efs_file_system.shared) == 1 && aws_efs_file_system.shared[0].encrypted == true
    error_message = "efs_enabled must plan exactly one encrypted file system."
  }

  assert {
    condition     = aws_efs_file_system.shared[0].throughput_mode == "bursting"
    error_message = "The file system must burst rather than bill each byte written, got ${aws_efs_file_system.shared[0].throughput_mode}."
  }

  assert {
    condition     = length(aws_efs_mount_target.shared) == 1 && aws_efs_mount_target.shared[0].subnet_id == "subnet-2a"
    error_message = "A pin to 2a must give exactly one mount target, in 2a's private subnet."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.efs_nfs_from_nodes[0].from_port == 2049
      && aws_vpc_security_group_ingress_rule.efs_nfs_from_nodes[0].to_port == 2049
      && aws_vpc_security_group_ingress_rule.efs_nfs_from_nodes[0].ip_protocol == "tcp"
      && aws_vpc_security_group_ingress_rule.efs_nfs_from_nodes[0].referenced_security_group_id == "sg-nodes"
    )
    error_message = "The mount targets must admit TCP 2049 from the node security group and from nothing broader."
  }

  assert {
    condition     = tolist(aws_efs_mount_target.shared[0].security_groups) == tolist([aws_security_group.efs[0].id])
    error_message = "The mount target must carry the NFS security group and only it."
  }

  assert {
    condition     = local.efs_addon["aws-efs-csi-driver"].addon_version == "v3.5.3-eksbuild.1"
    error_message = "efs_enabled must add the pinned EFS CSI addon to the cluster's addons."
  }

  assert {
    condition     = output.efs_file_system_id == aws_efs_file_system.shared[0].id
    error_message = "The output the session renders its volume from must name the planned file system."
  }
}

run "efs_refused_without_a_zone_pin" {
  command = plan

  variables {
    efs_enabled           = true
    gpu_availability_zone = ""
  }

  expect_failures = [aws_efs_file_system.shared]
}

run "three_workers_of_g5_xlarge_fit_the_quota" {
  command = plan

  assert {
    condition     = local.gpu_group_vcpus["gpu"] == 12 && local.gpu_on_demand_needed <= 128
    error_message = "Three g5.xlarge are 12 vCPU and must pass the On-Demand quota of 128, got ${local.gpu_group_vcpus["gpu"]}."
  }
}

# Three of the queuelab type ask 144 vCPU, and the precondition must still refuse them against 128.
run "three_workers_of_g4dn_12xlarge_are_refused" {
  command = plan

  variables {
    gpu_node_instance_type = "g4dn.12xlarge"
  }

  override_data {
    target = data.aws_ec2_instance_type.gpu
    values = { default_vcpus = 48 }
  }

  expect_failures = [terraform_data.gpu_quota]
}

run "four_workers_are_refused" {
  command = plan

  variables {
    gpu_max_nodes = 4
  }

  expect_failures = [var.gpu_max_nodes]
}
