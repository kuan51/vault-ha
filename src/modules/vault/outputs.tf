output "release_name" {
  description = "Name of the Helm release"
  value       = helm_release.vault.name
}

output "namespace" {
  description = "Kubernetes namespace where Vault is deployed"
  value       = helm_release.vault.namespace
}

output "chart_version" {
  description = "Version of the Vault Helm chart deployed"
  value       = helm_release.vault.version
}

output "vault_service_name" {
  description = "Name of the Vault service"
  value       = helm_release.vault.name
}

output "vault_service_fqdn" {
  description = "Fully qualified domain name of the Vault service"
  value       = "${helm_release.vault.name}.${helm_release.vault.namespace}.svc.cluster.local"
}

output "vault_ui_service_name" {
  description = "Name of the Vault UI service"
  value       = "${helm_release.vault.name}-ui"
}

output "vault_active_service_name" {
  description = "Name of the Vault active (leader) service"
  value       = "${helm_release.vault.name}-active"
}

output "vault_standby_service_name" {
  description = "Name of the Vault standby (follower) service"
  value       = "${helm_release.vault.name}-standby"
}

output "vault_port" {
  description = "Vault API port"
  value       = 8200
}

output "vault_cluster_port" {
  description = "Vault cluster port for HA communication"
  value       = 8201
}

output "vault_addr" {
  description = "Vault API address (for use with VAULT_ADDR environment variable)"
  value       = "http://${helm_release.vault.name}.${helm_release.vault.namespace}.svc.cluster.local:8200"
}

output "ingress_host" {
  description = "Ingress hostname for Vault UI (if ingress is enabled)"
  value       = var.enable_ingress ? var.ingress_host : null
}

output "ingress_url" {
  description = "Full URL for Vault UI via ingress (if ingress is enabled)"
  value       = var.enable_ingress ? "http://${var.ingress_host}" : null
}

output "replicas" {
  description = "Number of Vault replicas configured"
  value       = var.replicas
}

output "release_status" {
  description = "Status of the Helm release"
  value       = helm_release.vault.status
}

output "release_metadata" {
  description = "Metadata about the Helm release"
  value       = helm_release.vault.metadata
  sensitive   = true
}

output "init_command" {
  description = "Command to initialize Vault (run from a Vault pod)"
  value       = "kubectl exec -n ${helm_release.vault.namespace} ${helm_release.vault.name}-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json"
}

output "unseal_command_example" {
  description = "Example command to unseal a Vault pod"
  value       = "kubectl exec -n ${helm_release.vault.namespace} ${helm_release.vault.name}-0 -- vault operator unseal <unseal-key>"
}

output "status_command" {
  description = "Command to check Vault status"
  value       = "kubectl exec -n ${helm_release.vault.namespace} ${helm_release.vault.name}-0 -- vault status"
}

output "raft_peers_command" {
  description = "Command to list Raft cluster peers"
  value       = "kubectl exec -n ${helm_release.vault.namespace} ${helm_release.vault.name}-0 -- vault operator raft list-peers"
}

output "port_forward_command" {
  description = "Command to port-forward to Vault UI"
  value       = "kubectl port-forward -n ${helm_release.vault.namespace} svc/${helm_release.vault.name} 8200:8200"
}

# Auto-initialization outputs
output "auto_initialize_enabled" {
  description = "Whether auto-initialization is enabled"
  value       = var.auto_initialize
}

output "init_secret_name" {
  description = "Name of the Kubernetes Secret containing Vault init keys (if auto_initialize enabled)"
  value       = var.auto_initialize ? var.init_secret_name : null
}

output "get_root_token_command" {
  description = "Command to retrieve the Vault root token from Kubernetes Secret"
  value       = var.auto_initialize ? "kubectl get secret ${var.init_secret_name} -n ${helm_release.vault.namespace} -o jsonpath='{.data.root_token}' | base64 -d" : null
}

output "get_unseal_keys_command" {
  description = "Command to retrieve Vault unseal keys from Kubernetes Secret"
  value       = var.auto_initialize ? "kubectl get secret ${var.init_secret_name} -n ${helm_release.vault.namespace} -o jsonpath='{.data.unseal_keys_b64}' | base64 -d | jq" : null
}

output "init_job_status_command" {
  description = "Command to check the status of the initialization job"
  value       = var.auto_initialize ? "kubectl get job ${helm_release.vault.name}-auto-init -n ${helm_release.vault.namespace}" : null
}

output "init_job_logs_command" {
  description = "Command to view logs from the initialization job"
  value       = var.auto_initialize ? "kubectl logs -n ${helm_release.vault.namespace} job/${helm_release.vault.name}-auto-init" : null
}

output "manual_unseal_script" {
  description = "Path to manual unseal script (for unsealing after pod restarts)"
  value       = var.auto_initialize ? "${path.module}/scripts/k8s-unseal-vault.sh" : "${path.module}/scripts/unseal-vault.sh"
}
