# This root installs Argo CD once and owns nothing else.
#
# It is never run on routine cluster plan or apply.
#
# After install, Argo CD owns in-cluster resources and this release is left alone.
resource "helm_release" "argocd" {
  name             = "argo-cd"
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # The chart's cluster-scoped CRDs are installed here once.
  #
  # Routine applies never own them, matching the ownership boundary in docs/09.
  skip_crds = false
}

# Read only so the AWS provider is configured, and with it allowed_account_ids: this root's one resource is a Helm release,
# and terraform does not configure a provider nothing uses, so the account pin would otherwise never be checked (the
# adversarial review of the session cloud safety design, round 1).
data "aws_caller_identity" "pin" {}
