data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The zones are derived from what the GPU types are actually offered in, not from the first three the API
  # returns.
  #
  # slice(names, 0, 3) gave 2a, 2b, 2c. In ap-northeast-2 that is exactly wrong for this workload: g5 is
  # offered in 2a, 2c and 2d, so the slice DROPPED 2d -- a zone that can run the A10G groups, and the one
  # with the cheapest spot price -- while KEEPING 2b, which cannot run g5 at all. Two of the three zones the
  # single-card groups could use, and one that is dead weight for them.
  #
  # It was not wrong in a way anything would report. Both A10G groups still had two homes, so the placement
  # preconditions passed and the only symptom would have been an InsufficientInstanceCapacity in a session,
  # with a usable zone sitting outside the VPC.
  #
  # The union is used rather than an intersection because the groups do not need the same zones: queuelab's
  # g4dn.12xlarge runs in 2a/2b/2c and the A10G groups in 2a/2c/2d, so an intersection would discard 2b and
  # 2d and hand each group a smaller pool than it has. placement.tf is what assigns each group its own subset.
  gpu_zones = sort(distinct(concat(
    tolist(data.aws_ec2_instance_type_offerings.gpu.locations),
    tolist(data.aws_ec2_instance_type_offerings.gpu_single.locations),
    tolist(data.aws_ec2_instance_type_offerings.gpu_shared.locations),
  )))

  # EKS CreateCluster rejects fewer than two AZs, so a region that offered the GPU types in one zone would
  # need padding from the general list. Refusing instead would be wrong -- the CPU node group and the control
  # plane do not care about G capacity -- so the general zones fill the gap, deterministically ordered.
  azs = length(local.gpu_zones) >= 2 ? local.gpu_zones : distinct(concat(local.gpu_zones, slice(data.aws_availability_zones.available.names, 0, 2)))

  # The purchasing option per GPU node group, declared once. eks.tf sets capacity_type from this map and
  # placement.tf derives the quota preconditions from the same values, so a group cannot be switched to SPOT
  # without the Spot quota check becoming load-bearing in the same edit.
  gpu_capacity = {
    gpu        = "ON_DEMAND"
    gpu_single = "ON_DEMAND"
    gpu_shared = "ON_DEMAND"
  }

  # Two /20 tiers, indexed off the same list so they cannot drift in length. placement.tf zips local.azs
  # against the private subnets and a mismatch is a value-level error that `validate` accepts and only `plan`
  # catches -- deriving both from one list is what removes that class of mistake rather than documenting it.
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + length(local.azs))]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = local.azs

  # Two tiers, and the split is the point rather than a formality.
  #
  # Every node used to sit in a public subnet with map_public_ip_on_launch, which meant each worker carried a
  # routable address and the security group was the only thing between the internet and a kubelet. That is a
  # defensible choice for a cluster that lives for four hours, and it was labelled demo-only -- but it is
  # defensible on cost grounds alone, and once the cost is measured (below) the grounds do not hold.
  #
  # Public subnets keep two jobs and no nodes: they host the NAT gateway, and they are tagged for ELB so an
  # ingress load balancer has somewhere to land if one is ever wanted. See docs/09 for why the benchmark
  # forbids putting one in front of the engine.
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # ONE NAT gateway for all three private subnets, not one per AZ.
  #
  # Per-AZ NAT is the production answer: it keeps an AZ failure inside that AZ. This cluster is scaled to
  # zero except during a session measured in hours, and a NAT outage during one costs a re-run rather than an
  # incident -- so the AZ-isolation the second and third gateway buy is worth less here than the hourly rate.
  #
  # The price of the single gateway is honest and small: workers in the other two zones egress cross-AZ, at
  # $0.01/GB each way on top of NAT processing. Image pulls are the bulk of that traffic and the S3 gateway
  # endpoint below takes them off this path entirely.
  enable_nat_gateway = true
  single_nat_gateway = true

  # No public IPs anywhere. A node reaches ECR and the internet through the NAT gateway, and reaches the EKS
  # API over the cluster's private endpoint (eks.tf) without leaving the VPC.
  map_public_ip_on_launch = false
  enable_dns_hostnames    = true
  enable_dns_support      = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}

# The S3 gateway endpoint is free, so it stays -- but the reason first written beside it was wrong.
#
# The claim was: ECR stores image layers in S3, so a node pulling the multi-GB vLLM image sends that traffic
# through this endpoint instead of the NAT, and the endpoint therefore removes most of the session's NAT data
# charge.
#
# The premise does not hold for this cluster's images. The three big pulls are not in ECR:
#
#   vllm/vllm-openai@sha256:0a51ea5b...          Docker Hub
#   nvcr.io/nvidia/k8s-device-plugin:v0.16.2     NVIDIA NGC
#   nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-...   NVIDIA NGC
#
# ECR holds only the operator and gateway images, which are Go binaries in the tens of megabytes. So the
# bytes that dominate a fresh node's pull go over the NAT at $0.059/GB no matter what this endpoint does, and
# the saving attributed to it here was close to zero rather than close to all of it.
#
# It stays anyway, on the reasons that survive: it costs nothing, S3 is reached for the Terraform state and
# for whatever the operator and gateway images do pull from ECR, and traffic that takes it never leaves the
# VPC. Those are worth a free route. They are not worth the sentence that was here.
#
# The honest number for a session is therefore "a few GB of NAT data processing per fresh node", and it has
# not been measured. Mirroring the three public images into ECR would move that traffic onto this endpoint
# and is the change that would make the original claim true -- see docs/09, where the same correction is
# recorded against the endpoint arithmetic.
#
# This is a resource rather than a module argument because terraform-aws-modules/vpc moved its endpoints into
# a submodule at v4 -- enable_s3_endpoint is a v3 input and v5.13.0 rejects it as an unsupported argument.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.cluster_name}-s3" })
}
