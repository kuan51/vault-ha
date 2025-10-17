# Vault HA on Local Kubernetes

Quick start guide for deploying HashiCorp Vault with HA and Raft storage on a local Kubernetes cluster.

## Prerequisites

- Docker Desktop with Kubernetes enabled (or kind/minikube/k3d)
- kubectl installed and configured
- Terraform >= 1.0
- Helm 3.x (optional - Terraform manages it)

## Quick Start

```bash
# Clone and navigate to project

# Copy environment template
cp .env.template .env

# Edit .env and configure:
# - VAULT_REPLICAS=1 for local testing (or 3+ for HA testing)
# - KUBE_CONTEXT="docker-desktop" (or your local k8s context)

# Load environment variables
export TF_VAR_KUBE_CONTEXT=$(grep KUBE_CONTEXT .env | cut -d '=' -f2 | tr -d '"')
export VAULT_REPLICAS=$(grep VAULT_REPLICAS .env | cut -d '=' -f2)

# Navigate to Terraform module
cd src/modules/vault

# Initialize and deploy
terraform init
terraform apply -var="replicas=${VAULT_REPLICAS}"

# Initialize and unseal Vault cluster
./scripts/init-vault.sh

# Save the root token and unseal keys displayed by init-vault.sh
```

## Access Vault

```bash
# Port forward to access Vault UI
kubectl port-forward -n vault svc/vault 8200:8200

# In another terminal, set environment variables
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='<root-token-from-init-script>'

# Verify Vault status
vault status
```

Access Vault UI at http://localhost:8200

## Cleanup

```bash
cd src/modules/vault
terraform destroy
```

## Next Steps

- See [src/modules/vault/README.md](src/modules/vault/README.md) for comprehensive documentation
- See [docker/README.md](docker/README.md) for Docker Compose alternative
