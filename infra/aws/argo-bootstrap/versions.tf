terraform {
  # 1.10 is the floor because that is where the S3 backend learned to lock on a state-adjacent object
  # (use_lockfile) instead of a DynamoDB table. Everything below that line needs the table back.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
  }
}

provider "aws" {
  region = var.region
  # Refuses to plan or apply with credentials for any other account (r5 finding 8, proposal P3): a profile name is not an
  # account, and environment credentials outrank it.
  allowed_account_ids = var.allowed_account_ids
}

# The helm and kubernetes providers authenticate to the cluster via the AWS CLI token helper.
#
# terraform validate does not connect, so these blocks only need to be schema-valid here.
provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_ca)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    }
  }
}
