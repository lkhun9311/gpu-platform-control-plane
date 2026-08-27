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
  # This list and public_subnets below MUST stay the same length: placement.tf zips them together, and a
  # mismatch is not a syntax error -- `terraform validate` accepts it and `plan` is where it fails.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs            = local.azs
  public_subnets = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]

  # Public subnets only.
  #
  # No NAT gateway: public-subnet nodes reach the EKS API, ECR, and S3 over the internet gateway.
  enable_nat_gateway      = false
  map_public_ip_on_launch = true
  enable_dns_hostnames    = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}
