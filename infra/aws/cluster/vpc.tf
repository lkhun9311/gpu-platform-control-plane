data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # EKS CreateCluster requires subnets in at least two AZs.
  #
  # The second AZ exists only to satisfy that; all node groups pin to the first AZ.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
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
