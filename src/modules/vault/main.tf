# HashiCorp Vault HA Deployment with Raft Storage
# This module deploys Vault in high availability mode using the official Helm chart

# Create namespace if it doesn't exist
resource "kubernetes_namespace" "vault" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
    labels = merge(
      {
        name                          = var.namespace
        "app.kubernetes.io/name"      = "vault"
        "app.kubernetes.io/component" = "server"
      },
      var.labels
    )
    annotations = var.annotations
  }
}

# Read custom values file if provided
locals {
  # Determine if using HA mode (replicas > 1)
  is_ha_mode = var.replicas > 1

  # Load custom values file if provided, otherwise use inline values
  custom_values_content = var.values_file != "" ? file("${path.module}/${var.values_file}") : ""

  # Build inline values for Vault configuration
  vault_values = {
    global = {
      enabled    = true
      tlsDisable = var.tls_disable
    }

    injector = {
      enabled = true
      image = {
        repository = "hashicorp/vault-k8s"
        tag        = var.vault_k8s_image_tag
      }
      agentImage = {
        repository = "hashicorp/vault"
        tag        = var.vault_image_tag
      }
    }

    server = {
      image = {
        repository = "hashicorp/vault"
        tag        = var.vault_image_tag
      }

      # Resource configuration
      resources = {
        requests = {
          memory = var.pod_resources.requests.memory
          cpu    = var.pod_resources.requests.cpu
        }
        limits = {
          memory = var.pod_resources.limits.memory
          cpu    = var.pod_resources.limits.cpu
        }
      }

      # Extra labels and annotations
      extraLabels = var.labels
      annotations = var.annotations

      # Logging configuration
      logLevel  = var.log_level
      logFormat = var.log_format

      # Data storage configuration
      dataStorage = {
        enabled      = true
        size         = var.storage_size
        storageClass = var.storage_class
        accessMode   = "ReadWriteOnce"
      }

      # Audit storage configuration
      auditStorage = {
        enabled      = var.enable_audit_storage
        size         = var.audit_storage_size
        storageClass = var.storage_class
        accessMode   = "ReadWriteOnce"
      }

      # Pod anti-affinity for HA node distribution
      affinity = local.is_ha_mode ? yamlencode({
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name"     = "vault"
                "app.kubernetes.io/instance" = var.release_name
                "component"                  = "server"
              }
            }
            topologyKey = "kubernetes.io/hostname"
          }]
        }
      }) : null

      # HA configuration (conditional based on replica count)
      ha = {
        enabled  = local.is_ha_mode
        replicas = var.replicas

        raft = {
          enabled   = local.is_ha_mode
          setNodeId = true

          config = <<-EOF
            ui = true

            listener "tcp" {
              address     = "[::]:8200"
              cluster_address = "[::]:8201"
              tls_disable = "${var.tls_disable ? 1 : 0}"
            }

            storage "raft" {
              path = "/vault/data"

              %{for i in range(var.replicas)~}
              retry_join {
                leader_api_addr = "http://${var.release_name}-${i}.${var.release_name}-internal:8200"
              }
              %{endfor~}

              autopilot {
                cleanup_dead_servers      = true
                last_contact_threshold    = "10s"
                max_trailing_logs         = 1000
                server_stabilization_time = "10s"
                min_quorum                = ${max(2, floor(var.replicas / 2) + 1)}
                disable_upgrade_migration = false
              }
            }

            service_registration "kubernetes" {}

            log_level  = "${var.log_level}"
            log_format = "${var.log_format}"
          EOF
        }

        # Pod disruption budget for HA resilience
        disruptionBudget = {
          enabled        = local.is_ha_mode
          maxUnavailable = local.is_ha_mode ? max(1, floor((var.replicas - 1) / 2)) : null
        }
      }

      # Standalone configuration (when replicas = 1)
      standalone = {
        enabled = !local.is_ha_mode

        config = <<-EOF
          ui = true

          listener "tcp" {
            address     = "[::]:8200"
            cluster_address = "[::]:8201"
            tls_disable = "${var.tls_disable ? 1 : 0}"
          }

          storage "file" {
            path = "/vault/data"
          }

          log_level  = "${var.log_level}"
          log_format = "${var.log_format}"
        EOF
      }

      # Service configuration
      service = {
        enabled = true
        active = {
          enabled = local.is_ha_mode
        }
        standby = {
          enabled = local.is_ha_mode
        }
      }

      # Service account configuration
      serviceAccount = {
        create = true
        name   = "${var.release_name}-sa"
        serviceDiscovery = {
          enabled = true
        }
      }

      # Auth delegator for Kubernetes auth
      authDelegator = {
        enabled = true
      }
    }

    # UI configuration
    ui = {
      enabled                  = var.enable_ui
      serviceType              = "ClusterIP"
      externalPort             = 8200
      publishNotReadyAddresses = true
    }

    # Server telemetry configuration
    serverTelemetry = {
      serviceMonitor = {
        enabled = var.enable_service_monitor
      }
    }
  }

  # Merge custom values with inline values
  final_values = var.values_file != "" ? [] : [yamlencode(merge(local.vault_values, var.extra_values))]
}

# Deploy Vault using Helm
resource "helm_release" "vault" {
  name             = var.release_name
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  # Use custom values file if provided, otherwise use inline values
  values = var.values_file != "" ? [local.custom_values_content] : local.final_values

  # Dependency on namespace creation
  depends_on = [
    kubernetes_namespace.vault
  ]
}

# Create Ingress for Vault UI if enabled
resource "kubernetes_ingress_v1" "vault_ui" {
  count = var.enable_ingress ? 1 : 0

  metadata {
    name      = "${var.release_name}-ui"
    namespace = var.namespace
    annotations = merge(
      {
        "kubernetes.io/ingress.class" = var.ingress_class_name
      },
      var.annotations
    )
    labels = merge(
      {
        "app.kubernetes.io/name"      = "vault"
        "app.kubernetes.io/component" = "ui"
      },
      var.labels
    )
  }

  spec {
    ingress_class_name = var.ingress_class_name

    rule {
      host = var.ingress_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "${var.release_name}-ui"
              port {
                number = 8200
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.vault
  ]
}
