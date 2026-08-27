data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # EKS CreateCluster requires subnets in at least two AZs, and GPU capacity wants a third.
  #
  # The node groups no longer pin to the first AZ -- placement.tf derives each one's subnets from the zones
  # that actually offer its instance type. That is what makes the third zone worth having: in
  # ap-northeast-2 g5 is offered in a, c and d but NOT in b, so with two zones the A10G groups get exactly
  # one home and an InsufficientInstanceCapacity there ends the session. G instances are the ones AWS runs
  # out of.
  #
  # This list and both subnet lists below MUST stay the same length: placement.tf zips azs with the private
  # subnets, and a mismatch is not a syntax error -- `terraform validate` accepts it and `plan` is where it
  # fails.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
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
  public_subnets  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 4, 3), cidrsubnet(var.vpc_cidr, 4, 4), cidrsubnet(var.vpc_cidr, 4, 5)]

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

# The S3 gateway endpoint is free, and it is the one endpoint whose arithmetic is not close.
#
# ECR stores image layers in S3, so a node pulling the vLLM image (several GB) sends that traffic through
# whatever route reaches S3. Through the NAT gateway it is billed at the NAT data-processing rate; through a
# gateway endpoint it costs nothing and never enters the NAT at all.
#
# The interface endpoints (ecr.api, ecr.dkr, sts, ec2, logs, ssm, ssmmessages, ec2messages, ...) are
# deliberately absent. Going fully private would need roughly nine of them, each billed per hour per AZ, and
# nine of those cost more per hour than the single NAT gateway they would replace. The private-subnet threat
# model is already satisfied by the NAT; buying it a second time through PrivateLink is not.
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
