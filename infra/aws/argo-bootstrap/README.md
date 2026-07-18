# infra/aws/argo-bootstrap

Installs the Argo CD Helm chart once, in its own Terraform state. Nothing else
lives here. After install, Argo CD owns in-cluster resources via the app-of-apps
in `config/argocd`, and this state is left alone so routine cluster plan/apply
does not fight Argo CD's drift.

Nothing here is provisioned yet. This is the documented procedure for when it is.

## Run once

```bash
cd infra/aws/argo-bootstrap

terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="dynamodb_table=<lock-table>" \
  -backend-config="kms_key_id=<state-kms-key-arn>"

terraform apply \
  -var "cluster_endpoint=<from cluster output>" \
  -var "cluster_ca=<from cluster output>"
```

Verify the argo-cd chart version against the argo-helm repository before applying:
`helm search repo argo/argo-cd --versions`.
