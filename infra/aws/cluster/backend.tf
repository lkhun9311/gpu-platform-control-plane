# The backend points at the bucket created by infra/aws/bootstrap.
#
# terraform validate runs with -backend=false, so this is inert until a real init.
terraform {
  backend "s3" {
    key     = "cluster/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
