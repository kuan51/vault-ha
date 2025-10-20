# ConfigMap with Vault Initialization Scripts
# Contains Kubernetes-optimized scripts for initializing and unsealing Vault

resource "kubernetes_config_map" "vault_init_scripts" {
  count = var.auto_initialize ? 1 : 0

  metadata {
    name      = "${var.release_name}-init-scripts"
    namespace = var.namespace
    labels = merge(
      {
        "app.kubernetes.io/name"       = "vault-init"
        "app.kubernetes.io/component"  = "initialization"
        "app.kubernetes.io/part-of"    = "vault"
        "app.kubernetes.io/managed-by" = "terraform"
      },
      var.labels
    )
    annotations = var.annotations
  }

  data = {
    "init-vault.sh"   = file("${path.module}/scripts/k8s-init-vault.sh")
    "unseal-vault.sh" = file("${path.module}/scripts/k8s-unseal-vault.sh")
  }

  depends_on = [
    kubernetes_namespace.vault
  ]
}
