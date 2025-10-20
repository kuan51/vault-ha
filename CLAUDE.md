# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository provides infrastructure-as-code for deploying HashiCorp Vault in High Availability (HA) mode using:
- **Docker Compose** for local development/testing
- **Terraform + Kubernetes** for production deployments

Both approaches use Raft integrated storage for consensus without external dependencies.

## Key Commands

### Docker Compose Deployment

```bash
# Navigate to docker directory
cd docker

# Start 3-node cluster
docker-compose up -d

# Initialize and unseal (creates vault-keys.json)
./init-vault-cluster.sh

# Access Vault
export VAULT_ADDR=http://localhost:18200
export VAULT_TOKEN=<root-token-from-init>
vault status

# Cleanup
docker-compose down -v  # -v removes volumes for clean slate
```

### Terraform/Kubernetes Deployment

```bash
cd src/modules/vault

# Initialize Terraform
terraform init

# Deploy with auto-initialization (dev/test)
terraform apply -var="auto_initialize=true" -var="replicas=3"

# OR deploy with manual initialization (production)
terraform apply -var="auto_initialize=false" -var="replicas=3"

# For manual initialization: Initialize and unseal
chmod +x scripts/*.sh
./scripts/init-vault.sh  # Creates vault-keys.json
./scripts/unseal-vault.sh  # After pod restarts

# For auto-initialization: Access credentials
kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root_token}' | base64 -d
./scripts/k8s-unseal-vault.sh  # After pod restarts

# Access Vault
kubectl port-forward -n vault svc/vault 8200:8200 &
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(jq -r '.root_token' vault-keys.json)  # If manual init
vault status
vault operator raft list-peers

# Destroy
terraform destroy
```

### Common Vault Operations

```bash
# Check cluster health
kubectl get pods -n vault
vault operator raft list-peers

# Backup Raft snapshot
vault operator raft snapshot save /tmp/snapshot.snap
kubectl cp vault/vault-0:/tmp/snapshot.snap ./backup.snap

# Restore snapshot
kubectl cp ./backup.snap vault/vault-0:/tmp/restore.snap
vault operator raft snapshot restore /tmp/restore.snap

# Scale cluster (manual init only)
terraform apply -var="replicas=5"
./scripts/join-raft.sh vault-3
./scripts/join-raft.sh vault-4
./scripts/unseal-vault.sh
```

## Architecture

### Docker Compose (docker/)

**Purpose:** Local development only

**Structure:**
- 3 fixed nodes (vault-0, vault-1, vault-2)
- Ports 18200-18202 (avoids K8s conflict on 8200)
- Automatic cluster formation via `retry_join`
- Manual initialization with `init-vault-cluster.sh`
- Data persisted in Docker volumes

**Key Files:**
- `docker-compose.yml` - 3-node cluster definition
- `init-vault-cluster.sh` - Initialization script
- `vault-keys.json` - Generated unseal keys (gitignored)

### Terraform Module (src/modules/vault/)

**Purpose:** Production-ready Kubernetes deployment

**Module Structure:**
```
main.tf (226 lines)
├── kubernetes_namespace (create vault namespace)
├── locals
│   ├── is_ha_mode (replicas > 1)
│   └── vault_values (Helm configuration)
│       ├── server (Vault pods)
│       │   ├── ha (Raft config when replicas > 1)
│       │   └── standalone (file storage when replicas = 1)
│       └── ui (Ingress config)
└── helm_release.vault (deploy Vault)

init-automation.tf (249 lines) - Auto-initialization Job
├── kubernetes_job_v1.vault_init
│   ├── init_container (wait for pods)
│   └── main_container (initialize + unseal)
└── Stores keys in K8s Secret (dev/test only)

init-rbac.tf (126 lines) - RBAC for init job
├── ServiceAccount
├── Role (minimal permissions)
└── RoleBinding

init-scripts.tf - ConfigMap with bash scripts
```

**Key Terraform Files:**
- `main.tf` - Helm release with dynamic configuration
- `variables.tf` - 40+ configurable variables
- `outputs.tf` - Service URLs and access commands
- `init-automation.tf` - Auto-initialization Job (when `auto_initialize=true`)
- `init-rbac.tf` - ServiceAccount and RBAC for init Job
- `init-scripts.tf` - ConfigMap with initialization scripts

**Deployment Modes:**
- **HA Mode** (`replicas > 1`): Raft consensus, 3+ pods, PVCs per pod
- **Standalone** (`replicas = 1`): File storage, single pod, dev/test only

**Initialization Modes:**
- **Auto-init** (`auto_initialize=true`): K8s Job stores keys in Secret (dev/test only)
- **Manual** (`auto_initialize=false`): Run scripts, keys in vault-keys.json (production)

**Scripts (src/modules/vault/scripts/):**
- `init-vault.sh` - Manual init, stores keys in local file
- `unseal-vault.sh` - Unseal pods using local file
- `join-raft.sh` - Manually join pod to cluster
- `k8s-init-vault.sh` - Auto-init script (runs in Job)
- `k8s-unseal-vault.sh` - Unseal using K8s Secret

**Values Files (values/):**
- `vault-ha-raft.yaml` - Production HA (3 replicas)
- `vault-dev.yaml` - Development (1 replica)

### Important Variables

**Core Configuration:**
- `kube_context` - K8s context (or use `TF_VAR_KUBE_CONTEXT`)
- `replicas` - Number of pods (1=standalone, 3+=HA)
- `namespace` - Default: `vault`
- `storage_size` - PVC size per pod (default: `10Gi`)

**Auto-Initialization (dev/test only):**
- `auto_initialize` - Enable K8s Job init (default: `false`)
- `auto_unseal_enabled` - Auto-unseal after init (default: `true`)
- `init_key_shares` - Shamir key shares (default: `5`)
- `init_key_threshold` - Keys to unseal (default: `3`)
- `init_secret_name` - K8s Secret name (default: `vault-unseal-keys`)

**Networking:**
- `enable_ui` - Expose Vault UI (default: `true`)
- `enable_ingress` - Create Ingress (default: `true`)
- `ingress_host` - Ingress hostname (default: `vault.local`)

**Security:**
- `tls_disable` - Disable TLS (default: `true` for dev)
- `enable_service_monitor` - Prometheus metrics (default: `false`)

## Development Workflow

### Making Changes to Terraform Module

1. **Edit Terraform files** in `src/modules/vault/`
2. **Validate changes:**
   ```bash
   cd src/modules/vault
   terraform validate
   terraform fmt
   terraform plan -out=tfplan
   ```
3. **Apply changes:**
   ```bash
   terraform apply tfplan
   ```
4. **Test initialization:**
   - With auto-init: Check `kubectl logs -n vault job/vault-auto-init`
   - With manual: Run `./scripts/init-vault.sh`

### Testing Docker Changes

1. **Edit** `docker/docker-compose.yml`
2. **Restart cluster:**
   ```bash
   cd docker
   docker-compose down -v  # Clean slate
   docker-compose up -d
   ./init-vault-cluster.sh
   ```

### Adding New Scripts

1. **Create script** in `src/modules/vault/scripts/`
2. **Make executable:** `chmod +x scripts/<script-name>.sh`
3. **Test locally** before committing
4. **If for auto-init:** Update `init-scripts.tf` ConfigMap

## Critical Implementation Details

### Storage Backend

- **Raft Consensus:** Built-in storage, no external dependencies (Consul/etcd)
- **Cluster Formation:** Uses `retry_join` for automatic discovery
- **Autopilot:** Enabled for dead server cleanup
- **Data Path:**
  - Docker: `/vault/file` (Vault image built-in, correct permissions)
  - K8s: PersistentVolumeClaims (one per pod in HA mode)

### Initialization Patterns

**Docker Compose:**
1. All nodes start and attempt `retry_join`
2. Run `init-vault-cluster.sh` to initialize vault-0
3. Script unseals all 3 nodes
4. Keys saved to `vault-keys.json` (gitignored)

**Kubernetes - Auto-Initialization:**
1. Terraform creates Job with init script
2. Job waits for all vault-N pods to be Running
3. Initializes vault-0, stores keys in K8s Secret
4. Auto-unseals all pods
5. Job auto-deletes after 5 minutes

**Kubernetes - Manual Initialization:**
1. Deploy with `auto_initialize=false`
2. Run `./scripts/init-vault.sh`
3. Initialize vault-0, save keys to `vault-keys.json`
4. Unseal all pods
5. After restarts: `./scripts/unseal-vault.sh`

### Security Considerations

**⚠️ Auto-Initialization Warning:**
- Stores unseal keys in K8s Secrets (NOT production-ready)
- Anyone with Secret read access can retrieve keys
- Circular dependency: K8s securing Vault that secures K8s
- **Use only for dev/test environments**

**Production Recommendations:**
1. Use `auto_initialize=false` for production
2. Enable Cloud KMS auto-unseal (AWS KMS, Azure Key Vault, GCP)
3. Enable TLS: `tls_disable=false` with proper certificates
4. Enable audit logging: `enable_audit_storage=true`
5. Implement Kubernetes Network Policies
6. Store root token in external secret manager, not K8s
7. Rotate root token immediately after initialization

**Current Config (Development):**
- TLS disabled by default
- No auto-unseal (Shamir seal only)
- Root token in K8s Secret (auto-init) or local file (manual)
- No audit logging by default
- Pod-to-pod communication unrestricted

### Port Mappings

**Docker Compose:**
- vault-0: `localhost:18200`
- vault-1: `localhost:18201`
- vault-2: `localhost:18202`
- Why 18xxx? Avoids K8s Vault on port 8200

**Kubernetes:**
- Service: `vault.vault.svc.cluster.local:8200`
- Ingress: `vault.local` (or custom hostname)
- Port-forward: `kubectl port-forward -n vault svc/vault 8200:8200`

## Environment Configuration

The repository uses `.env` file for environment variables:

```bash
# .env (copy from .env.template)
VAULT_REPLICAS=3
KUBE_CONTEXT="docker-desktop"
export TF_VAR_KUBE_CONTEXT="${KUBE_CONTEXT}"

# Load environment
source .env
```

## Troubleshooting

### Vault Pods Not Starting

```bash
# Check pod status and events
kubectl get pods -n vault
kubectl describe pod vault-0 -n vault

# Check logs
kubectl logs -n vault vault-0

# Check PVC status
kubectl get pvc -n vault
```

### Pods Stuck in Sealed State

```bash
# Manual init: Run unseal script
./scripts/unseal-vault.sh

# Auto-init: Run K8s unseal script
./scripts/k8s-unseal-vault.sh

# Or manually unseal each pod
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>
```

### Raft Cluster Not Forming

```bash
# Check pod network connectivity
kubectl exec -n vault vault-1 -- ping vault-0.vault-internal

# Manually join pod to cluster
./scripts/join-raft.sh vault-1
./scripts/unseal-vault.sh

# Verify Raft configuration
kubectl exec -n vault vault-0 -- cat /vault/config/extraconfig-from-values.hcl
```

### Auto-Init Job Failing

```bash
# Check job status
kubectl get job vault-auto-init -n vault
kubectl describe job vault-auto-init -n vault

# View logs
kubectl logs -n vault job/vault-auto-init

# Common issues:
# - Pods not ready (check pod status)
# - Secret already exists (delete and re-run)
# - Timeout (increase OPERATION_TIMEOUT in init-automation.tf)

# Manual cleanup
kubectl delete job vault-auto-init -n vault
kubectl delete secret vault-unseal-keys -n vault
terraform apply  # Recreate resources
```

### Docker Volume Permission Issues

```bash
# Clean volumes and restart
cd docker
docker-compose down -v
docker-compose up -d

# Note: Using /vault/file (built-in to image) avoids permission issues
```

## Git Workflow

**Current Branch:** `main`
**Main Branch:** `master` (use for PRs)

**Recent Work:**
- Added auto-initialization support (init-automation.tf, init-rbac.tf, init-scripts.tf)
- Improved unseal scripts for reliability
- Added Kubernetes-native init scripts (k8s-init-vault.sh, k8s-unseal-vault.sh)

**When Committing:**
- Ensure `vault-keys.json` is gitignored (contains secrets)
- Ensure `.env` is gitignored (local config)
- Run `terraform fmt` before committing Terraform files
- Test scripts locally before committing

## Important Notes for Claude Code

1. **Never commit secrets:** `vault-keys.json`, `.env`, and `*.tfstate` are gitignored
2. **Auto-init is dev/test only:** Always warn users about security implications
3. **Terraform state:** Located in `src/modules/vault/terraform.tfstate` (local backend)
4. **Script permissions:** Make scripts executable with `chmod +x scripts/*.sh`
5. **Docker uses /vault/file:** Built-in path with correct permissions, don't suggest changing
6. **Port conflicts:** Docker uses 18200-18202, K8s uses 8200
7. **Raft requires quorum:** Minimum 2 nodes for operations in 3-node cluster
8. **Unsealing is manual:** Unless using cloud KMS auto-unseal (not configured by default)

## Technology Stack

- **Terraform:** >= 1.0
- **Terraform Providers:**
  - hashicorp/helm ~> 3.0.2
  - hashicorp/kubernetes ~> 2.38.0
- **Vault Helm Chart:** v0.31.0
- **Vault Image:** hashicorp/vault:1.20.4
- **Init Job Image:** alpine/k8s:1.31.1
- **Kubernetes:** >= 1.23
- **Docker Engine:** For local development
- **Dependencies:** kubectl, jq, bash 4.0+

## References

- Root README: `/home/rex/github/vault/README.md`
- Module README: `/home/rex/github/vault/src/modules/vault/README.md`
- Docker README: `/home/rex/github/vault/docker/README.md`
- HashiCorp Vault Docs: https://developer.hashicorp.com/vault
- Vault Helm Chart: https://github.com/hashicorp/vault-helm
- Raft Storage: https://developer.hashicorp.com/vault/docs/configuration/storage/raft
