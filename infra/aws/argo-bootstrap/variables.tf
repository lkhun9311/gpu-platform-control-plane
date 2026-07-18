variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (bootstrap output from the cluster root)."
  type        = string
  default     = "gpu-platform"
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint."
  type        = string
}

variable "cluster_ca" {
  description = "Base64-encoded cluster CA certificate."
  type        = string
}

variable "argocd_chart_version" {
  description = "Pinned argo-cd Helm chart version from the argo-helm repository."
  type        = string
  default     = "7.7.0"
}

variable "argocd_namespace" {
  description = "Namespace Argo CD is installed into."
  type        = string
  default     = "argocd"
}
