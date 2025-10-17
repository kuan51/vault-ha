# Basic configuration
release_name = "vault"
namespace    = "vault"
replicas     = 3 # Set to 1 for development, 3+ for production HA

# Helm chart configuration
chart_version       = "0.31.0"
vault_image_tag     = "1.20.4"
vault_k8s_image_tag = "1.7.0"

# Storage configuration
storage_size  = "10Gi"
storage_class = null # Uses cluster default storage class

# UI and Ingress configuration
enable_ui          = true
enable_ingress     = true
ingress_class_name = "nginx"
ingress_host       = "vault.local" # Change to your domain

# Security configuration
tls_disable = true # Set to false for production with proper TLS certificates

# Logging configuration
log_level  = "info" # Options: trace, debug, info, warn, error
log_format = "json" # Options: json, standard

# Monitoring configuration
enable_service_monitor = false # Set to true if using Prometheus Operator

# Resource limits
pod_resources = {
  requests = {
    memory = "256Mi"
    cpu    = "250m"
  }
  limits = {
    memory = "512Mi"
    cpu    = "500m"
  }
}

# Audit logging (optional)
enable_audit_storage = false
audit_storage_size   = "10Gi"

# Custom labels and annotations
labels = {
  environment = "production"
  managed-by  = "terraform"
}

annotations = {}

# Alternative: Use a custom values file instead of inline values
# values_file = "values/vault-ha-raft.yaml"
