# Argo CD lives in its own state so routine cluster plan/apply never fights its in-cluster drift.
#
# terraform validate runs with -backend=false, so this is inert until a real init.
terraform {
  backend "s3" {
    key     = "argo-bootstrap/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
