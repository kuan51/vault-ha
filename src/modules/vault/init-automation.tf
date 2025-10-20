# Kubernetes Job for Vault Auto-Initialization
# This Job runs after Helm deployment to initialize and unseal Vault automatically
# Stores credentials in Kubernetes Secret (suitable for dev/test environments)
# Using kubernetes_job_v1 instead of kubernetes_manifest to avoid label conflicts

resource "kubernetes_job_v1" "vault_init" {
  count = var.auto_initialize ? 1 : 0

  metadata {
    name      = "${var.release_name}-auto-init"
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

  spec {
    # Automatically clean up Job after completion
    ttl_seconds_after_finished = var.init_job_cleanup_seconds
    backoff_limit              = 3

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "vault-init"
          "app.kubernetes.io/component" = "initialization"
          "app.kubernetes.io/part-of"   = "vault"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.vault_init[0].metadata[0].name
        restart_policy       = "OnFailure"

        # Init container: Wait for all Vault pods to be Running
        init_container {
          name    = "wait-for-vault-pods"
          image   = var.init_job_image
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            # Install bash and jq if not present (alpine/k8s doesn't include them)
            if ! command -v bash &> /dev/null || ! command -v jq &> /dev/null; then
              echo "Installing bash and jq..."
              apk add --no-cache bash jq
            fi

            # Switch to bash for the rest of the script
            bash <<'BASH_SCRIPT'
            set -e
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Waiting for Vault pods to be Running and responsive..."

            # Get expected replica count
            REPLICAS=$(kubectl get statefulset ${var.release_name} -n ${var.namespace} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Expected replicas: $REPLICAS"

            MAX_WAIT=300
            ELAPSED=0

            while [ $ELAPSED -lt $MAX_WAIT ]; do
              # Check if statefulset exists
              if ! kubectl get statefulset ${var.release_name} -n ${var.namespace} &>/dev/null; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] Waiting for StatefulSet ${var.release_name} to be created..."
                sleep 5
                ELAPSED=$((ELAPSED + 5))
                continue
              fi

              # Count pods in Running state (not Ready - they won't be ready until unsealed!)
              RUNNING=$(kubectl get pods -n ${var.namespace} -l app.kubernetes.io/name=vault,component=server \
                -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "Running" || echo "0")

              echo "[$(date +'%Y-%m-%d %H:%M:%S')] Running pods: $RUNNING / $REPLICAS"

              if [ "$RUNNING" -ge "$REPLICAS" ]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] All Vault pods are running!"

                # Verify vault-0 can respond to commands (even if sealed)
                # Vault responds to 'vault status' even when sealed
                if kubectl exec -n ${var.namespace} ${var.release_name}-0 -- vault status &>/dev/null || \
                   kubectl exec -n ${var.namespace} ${var.release_name}-0 -- vault status 2>&1 | grep -q "Sealed"; then
                  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Vault is responsive! Proceeding with initialization..."
                  exit 0
                else
                  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Vault pods running but not responsive yet, waiting..."
                fi
              fi

              sleep 5
              ELAPSED=$((ELAPSED + 5))
            done

            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Vault pods did not become running and responsive within $MAX_WAIT seconds"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Current pod status:"
            kubectl get pods -n ${var.namespace} -l app.kubernetes.io/name=vault
            echo ""
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Attempting to get vault-0 status:"
            kubectl exec -n ${var.namespace} ${var.release_name}-0 -- vault status 2>&1 || true
            exit 1
            BASH_SCRIPT
            EOT
          ]

          resources {
            requests = {
              memory = "64Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "128Mi"
              cpu    = "100m"
            }
          }
        }

        # Main container: Initialize and unseal Vault
        container {
          name    = "vault-initializer"
          image   = var.init_job_image
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            set -e

            # Install bash and jq if not present (alpine/k8s doesn't include them)
            echo "Installing dependencies..."
            apk add --no-cache bash jq

            # Configure kubectl to use in-cluster config
            # The ServiceAccount token is mounted at /var/run/secrets/kubernetes.io/serviceaccount/
            echo "Configuring kubectl for in-cluster access..."
            kubectl config set-cluster kubernetes \
              --server=https://kubernetes.default.svc \
              --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

            kubectl config set-credentials serviceaccount \
              --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

            kubectl config set-context default \
              --cluster=kubernetes \
              --user=serviceaccount \
              --namespace=${var.namespace}

            kubectl config use-context default

            # Verify kubectl works
            echo "Verifying kubectl connectivity..."
            kubectl version --client

            # Run the init script (already executable from ConfigMap defaultMode=0755)
            echo "Starting Vault initialization..."
            bash /scripts/init-vault.sh
            EOT
          ]

          env {
            name  = "VAULT_NAMESPACE"
            value = var.namespace
          }

          env {
            name  = "VAULT_RELEASE"
            value = var.release_name
          }

          env {
            name  = "VAULT_KEY_SHARES"
            value = tostring(var.init_key_shares)
          }

          env {
            name  = "VAULT_KEY_THRESHOLD"
            value = tostring(var.init_key_threshold)
          }

          env {
            name  = "VAULT_SECRET_NAME"
            value = var.init_secret_name
          }

          env {
            name  = "AUTO_UNSEAL"
            value = tostring(var.auto_unseal_enabled)
          }

          env {
            name  = "MAX_RETRY_ATTEMPTS"
            value = "5"
          }

          env {
            name  = "OPERATION_TIMEOUT"
            value = "300"
          }

          env {
            name  = "DEBUG"
            value = "false"
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = {
              memory = "128Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "256Mi"
              cpu    = "200m"
            }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.vault_init_scripts[0].metadata[0].name
            default_mode = "0755"
          }
        }
      }
    }
  }

  wait_for_completion = false

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    helm_release.vault,
    kubernetes_service_account.vault_init,
    kubernetes_role_binding.vault_init,
    kubernetes_config_map.vault_init_scripts
  ]
}

# Kubernetes Job for Unsealing Follower Nodes
# This Job runs after the init job to unseal and join follower nodes to the Raft cluster
resource "kubernetes_job_v1" "vault_unseal_followers" {
  count = var.auto_initialize ? 1 : 0

  metadata {
    name      = "${var.release_name}-unseal-followers"
    namespace = var.namespace
    labels = merge(
      {
        "app.kubernetes.io/name"       = "vault-unseal"
        "app.kubernetes.io/component"  = "unsealing"
        "app.kubernetes.io/part-of"    = "vault"
        "app.kubernetes.io/managed-by" = "terraform"
      },
      var.labels
    )
  }

  spec {
    # Automatically clean up Job after completion
    ttl_seconds_after_finished = var.init_job_cleanup_seconds
    backoff_limit              = 3

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "vault-unseal"
          "app.kubernetes.io/component" = "unsealing"
          "app.kubernetes.io/part-of"   = "vault"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.vault_init[0].metadata[0].name
        restart_policy       = "OnFailure"

        # Init container: Wait for initialization to complete
        init_container {
          name    = "wait-for-init"
          image   = var.init_job_image
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            set -e

            # Install jq for JSON parsing
            if ! command -v jq &> /dev/null; then
              echo "Installing jq..."
              apk add --no-cache jq
            fi

            # Wait for initialization secret to exist
            echo "Waiting for vault initialization to complete..."
            MAX_WAIT=300
            ELAPSED=0
            while ! kubectl get secret ${var.init_secret_name} -n ${var.namespace} &>/dev/null; do
              if [ $ELAPSED -ge $MAX_WAIT ]; then
                echo "ERROR: Timeout waiting for initialization secret"
                exit 1
              fi
              echo "Waiting for ${var.init_secret_name} secret... ($ELAPSED/$MAX_WAIT seconds)"
              sleep 5
              ELAPSED=$((ELAPSED + 5))
            done
            echo "Initialization secret found"

            # Wait for vault-0 to be unsealed
            echo "Waiting for vault-0 to be unsealed..."
            ELAPSED=0
            while true; do
              if [ $ELAPSED -ge $MAX_WAIT ]; then
                echo "ERROR: Timeout waiting for vault-0 to unseal"
                exit 1
              fi

              STATUS=$(kubectl exec -n ${var.namespace} ${var.release_name}-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
              if [[ "$STATUS" == "false" ]]; then
                echo "vault-0 is unsealed and ready"
                break
              fi
              echo "Waiting for vault-0 to be unsealed... ($ELAPSED/$MAX_WAIT seconds)"
              sleep 5
              ELAPSED=$((ELAPSED + 5))
            done

            # Give vault-0 a moment to stabilize
            echo "Waiting for cluster stabilization..."
            sleep 10
            echo "Ready to unseal follower nodes"
            EOT
          ]
        }

        # Main container: Unseal and join follower nodes
        container {
          name    = "vault-unsealer"
          image   = var.init_job_image
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            set -e

            # Install dependencies
            echo "Installing dependencies..."
            apk add --no-cache bash jq

            # Configure kubectl for in-cluster access
            echo "Configuring kubectl..."
            kubectl config set-cluster kubernetes \
              --server=https://kubernetes.default.svc \
              --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

            kubectl config set-credentials serviceaccount \
              --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

            kubectl config set-context default \
              --cluster=kubernetes \
              --user=serviceaccount \
              --namespace=${var.namespace}

            kubectl config use-context default

            # Verify kubectl connectivity
            echo "Verifying kubectl connectivity..."
            kubectl version --client

            # Run the unseal script
            echo "Starting follower node unsealing and joining..."
            bash /scripts/unseal-vault.sh
            EOT
          ]

          env {
            name  = "VAULT_NAMESPACE"
            value = var.namespace
          }

          env {
            name  = "VAULT_RELEASE"
            value = var.release_name
          }

          env {
            name  = "VAULT_SECRET_NAME"
            value = var.init_secret_name
          }

          env {
            name  = "VAULT_KEY_THRESHOLD"
            value = tostring(var.init_key_threshold)
          }

          env {
            name  = "MAX_RETRY_ATTEMPTS"
            value = "5"
          }

          env {
            name  = "POD_WAIT_TIMEOUT"
            value = "120"
          }

          env {
            name  = "DEBUG"
            value = "false"
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = {
              memory = "128Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "256Mi"
              cpu    = "250m"
            }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.vault_init_scripts[0].metadata[0].name
            default_mode = "0755"
          }
        }
      }
    }
  }

  wait_for_completion = false

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_job_v1.vault_init,
    kubernetes_config_map.vault_init_scripts
  ]
}
