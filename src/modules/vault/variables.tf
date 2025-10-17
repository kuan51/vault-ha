variable "release_name" {
  description = "Name of the Helm release"
  type        = string
  default     = "vault"
}

variable "namespace" {
  description = "Kubernetes namespace to deploy Vault into"
  type        = string
  default     = "vault"
}

variable "create_namespace" {
  description = "Create the namespace if it does not exist"
  type        = bool
  default     = true
}

variable "replicas" {
  description = "Number of Vault replicas for HA cluster (minimum 3 recommended for production)"
  type        = number
  default     = 3

  validation {
    condition     = var.replicas >= 1
    error_message = "Replicas must be at least 1."
  }
}

variable "chart_version" {
  description = "Version of the HashiCorp Vault Helm chart"
  type        = string
  default     = "0.31.0"
}

variable "vault_image_tag" {
  description = "Vault Docker image tag"
  type        = string
  default     = "1.20.4"
}

variable "vault_k8s_image_tag" {
  description = "Vault K8s sidecar injector image tag"
  type        = string
  default     = "1.7.0"
}

variable "storage_size" {
  description = "Size of persistent volume for each Vault pod"
  type        = string
  default     = "10Gi"
}

variable "storage_class" {
  description = "Storage class for Vault data PVCs (null uses cluster default)"
  type        = string
  default     = null
}

variable "enable_ui" {
  description = "Enable Vault UI"
  type        = bool
  default     = true
}

variable "enable_ingress" {
  description = "Enable Ingress for Vault UI"
  type        = bool
  default     = true
}

variable "ingress_class_name" {
  description = "Ingress class name (e.g., nginx, traefik)"
  type        = string
  default     = "nginx"
}

variable "ingress_host" {
  description = "Hostname for Vault UI ingress"
  type        = string
  default     = "vault.local"
}

variable "tls_disable" {
  description = "Disable TLS for Vault (dev/test only, not recommended for production)"
  type        = bool
  default     = true
}

variable "enable_service_monitor" {
  description = "Enable Prometheus ServiceMonitor for metrics collection"
  type        = bool
  default     = false
}

variable "log_level" {
  description = "Vault server log level (trace, debug, info, warn, error)"
  type        = string
  default     = "info"

  validation {
    condition     = contains(["trace", "debug", "info", "warn", "error"], var.log_level)
    error_message = "Log level must be one of: trace, debug, info, warn, error."
  }
}

variable "log_format" {
  description = "Vault server log format (standard, json)"
  type        = string
  default     = "json"

  validation {
    condition     = contains(["standard", "json"], var.log_format)
    error_message = "Log format must be either 'standard' or 'json'."
  }
}

variable "values_file" {
  description = "Path to custom Helm values file (relative to module root)"
  type        = string
  default     = ""
}

variable "extra_values" {
  description = "Additional Helm values to merge with the defaults"
  type        = map(any)
  default     = {}
}

variable "pod_resources" {
  description = "Resource requests and limits for Vault pods"
  type = object({
    requests = object({
      memory = string
      cpu    = string
    })
    limits = object({
      memory = string
      cpu    = string
    })
  })
  default = {
    requests = {
      memory = "256Mi"
      cpu    = "250m"
    }
    limits = {
      memory = "512Mi"
      cpu    = "500m"
    }
  }
}

variable "enable_audit_storage" {
  description = "Enable persistent storage for Vault audit logs"
  type        = bool
  default     = false
}

variable "audit_storage_size" {
  description = "Size of persistent volume for Vault audit logs"
  type        = string
  default     = "10Gi"
}

variable "labels" {
  description = "Additional labels to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Additional annotations to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "kube_context" {
  description = "Kubernetes context to use for deployment (from kubeconfig). Set via TF_VAR_KUBE_CONTEXT environment variable or pass directly."
  type        = string
  default     = ""
}
