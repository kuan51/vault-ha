# RBAC Resources for Vault Auto-Initialization
# These resources provide minimal permissions for the initialization Job
# to initialize Vault and store unseal keys in Kubernetes Secrets

# ServiceAccount for the initialization Job
resource "kubernetes_service_account" "vault_init" {
  count = var.auto_initialize ? 1 : 0

  metadata {
    name      = "${var.release_name}-init"
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

  depends_on = [
    kubernetes_namespace.vault
  ]
}

# Role with minimum required permissions for initialization
resource "kubernetes_role" "vault_init" {
  count = var.auto_initialize ? 1 : 0

  metadata {
    name      = "${var.release_name}-init"
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
  }

  # Permission to exec into Vault pods for initialization and unsealing
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create", "get"]
  }

  # Permission to read pod status
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  # Permission to get StatefulSet replica count
  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets"]
    verbs      = ["get"]
  }

  # Permission to create and manage the init secrets
  # Note: resource_names is used to limit scope to specific secret
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [var.init_secret_name]
    verbs          = ["get", "update", "patch"]
  }

  # Permission to create secret initially (no resource_names filter)
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }

  # Permission to create ConfigMap for completion tracking
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create", "get"]
  }

  depends_on = [
    kubernetes_namespace.vault
  ]
}

# Bind Role to ServiceAccount
resource "kubernetes_role_binding" "vault_init" {
  count = var.auto_initialize ? 1 : 0

  metadata {
    name      = "${var.release_name}-init"
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
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.vault_init[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault_init[0].metadata[0].name
    namespace = var.namespace
  }
}
