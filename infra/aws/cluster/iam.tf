# The CI apply role needs kubectl to run pre-destroy teardown in a later increment.
#
# Without this access entry, destroy.yml cannot delete Argo apps in order.
#
# The entry is created only when the role ARN is supplied, so validate and plan work before bootstrap exists.
resource "aws_eks_access_entry" "ci_apply" {
  count         = var.ci_apply_role_arn == "" ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = var.ci_apply_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_apply_admin" {
  count         = var.ci_apply_role_arn == "" ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = var.ci_apply_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
