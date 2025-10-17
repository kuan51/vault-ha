# Provider Configuration for Vault Module
# Configures Kubernetes and Helm providers with optional context selection

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context != "" ? var.kube_context : null
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = var.kube_context != "" ? var.kube_context : null
  }
}
