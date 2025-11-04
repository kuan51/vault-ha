# Vault HA + Dapr Service Mesh - Docker Compose

This directory contains a complete Docker Compose stack for running a **3-node HashiCorp Vault HA cluster** integrated with **Dapr service mesh**, **Redis**, **EMQX MQTT broker**, and a sample **API application**. This setup provides automated initialization, secret provisioning, and demonstrates zero-trust architecture patterns for local development and testing.

## Overview

**Purpose:** Production-like local development environment with HA Vault and Dapr integration
**Architecture:** 3-node Vault cluster (Raft) + Dapr control plane + Infrastructure services
**Key Features:**
- ✅ **HA Mode:** 3-node Raft cluster with nginx load balancer
- ✅ **Auto-Unseal:** Automated cluster initialization and unsealing
- ✅ **Auto-Provisioning:** Secrets automatically populated from .env
- ✅ **Auto-Joining:** Raft cluster formation via retry_join
- ✅ **Zero-Trust:** API accesses secrets only via Dapr → Vault

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                     Docker Compose Stack                          │
│                                                                    │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Vault HA Cluster (vault_network)                           │  │
│  │                                                             │  │
│  │  ┌─────────┐      ┌─────────┐      ┌─────────┐           │  │
│  │  │vault-0  │◄────►│vault-1  │◄────►│vault-2  │           │  │
│  │  │(leader) │      │(follower│      │(follower│           │  │
│  │  └────┬────┘      └─────────┘      └─────────┘           │  │
│  │       │                                                    │  │
│  │       │ Raft Consensus                                    │  │
│  │       ▼                                                    │  │
│  │  ┌──────────────┐                                         │  │
│  │  │  vault-lb    │ (Nginx load balancer)                  │  │
│  │  └──────┬───────┘                                         │  │
│  └─────────┼─────────────────────────────────────────────────┘  │
│            │                                                     │
│            │ 8200                                                │
│            ▼                                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Initialization Layer                                     │   │
│  │                                                           │   │
│  │  ┌────────────────────┐                                 │   │
│  │  │ vault-init-ha      │ (auto-initialize & unseal)      │   │
│  │  └─────────┬──────────┘                                 │   │
│  │            ▼                                             │   │
│  │  ┌────────────────────┐                                 │   │
│  │  │ vault-provisioner  │ (populate secrets)              │   │
│  │  │                    │                                 │   │
│  │  │ - Enables KV v2    │                                 │   │
│  │  │ - Writes secrets   │                                 │   │
│  │  │ - Creates token    │──► /vault-token/token           │   │
│  │  └────────────────────┘                                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Infrastructure Layer (app_network)                       │   │
│  │                                                           │   │
│  │  ┌──────────┐              ┌──────────┐                 │   │
│  │  │  redis   │              │   emqx   │                 │   │
│  │  └────┬─────┘              └────┬─────┘                 │   │
│  │       ▼                         ▼                        │   │
│  │  ┌──────────┐              ┌──────────┐                 │   │
│  │  │redis-init│              │emqx-init │                 │   │
│  │  └──────────┘              └──────────┘                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Dapr Control Plane (dapr_network)                        │   │
│  │                                                           │   │
│  │  ┌─────────────────┐    ┌─────────────────┐             │   │
│  │  │ dapr-placement  │    │ dapr-dashboard  │             │   │
│  │  └─────────────────┘    └─────────────────┘             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Application Layer                                        │   │
│  │                                                           │   │
│  │  ┌──────────┐      ┌──────────────────┐                 │   │
│  │  │   API    │◄─────┤   api-dapr       │                 │   │
│  │  │  :8080   │      │   (sidecar)      │                 │   │
│  │  └──────────┘      │   :3500          │                 │   │
│  │                    └─────┬────────────┘                 │   │
│  │                          │                               │   │
│  │                          ▼                               │   │
│  │          ┌───────────────────────────┐                  │   │
│  │          │  Dapr Components:         │                  │   │
│  │          │  - vault-secretstore      │                  │   │
│  │          │  - redis-statestore       │                  │   │
│  │          │  - mqtt-pubsub            │                  │   │
│  │          └───────────────────────────┘                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

Credential Flow:
  .env → vault-provisioner → Vault KV → Dapr vault-secretstore
    → Components (redis/mqtt) → API
```

## Quick Start

### Prerequisites

- Docker Engine (20.10+)
- Docker Compose (2.0+)
- GitHub Personal Access Token (for pulling API image)

### 1. Configure Environment

```bash
cd docker

# Copy environment template
cp .env.template .env

# Edit .env and set:
# - GITHUB_TOKEN (required for API image)
# - Redis/MQTT passwords (or use defaults)
nano .env
```

### 2. Start the Stack

```bash
# Clean start (recommended first time)
docker-compose down -v

# Start all services
docker-compose up -d

# Watch initialization logs
docker-compose logs -f vault-init-ha vault-provisioner
```

### 3. Verify Deployment

```bash
# Check all containers are running
docker-compose ps

# Verify Vault cluster
docker exec vault-0 vault operator raft list-peers

# Check Dapr dashboard
open http://localhost:9999

# Check API health
curl http://localhost:8080/health
```

## Startup Sequence (Automated)

The stack initializes automatically in this order:

1. **Vault HA Cluster** (5-10 seconds)
   - vault-0, vault-1, vault-2 start
   - Raft cluster forms via retry_join

2. **Vault Initialization** (10-15 seconds)
   - vault-init-ha runs
   - Initializes vault-0 with 5 keys (threshold 3)
   - Unseals all 3 nodes
   - Writes vault-keys.json to volume

3. **Load Balancer** (2-5 seconds)
   - vault-lb starts
   - Health checks enabled

4. **Secret Provisioning** (5-10 seconds)
   - vault-provisioner runs
   - Enables KV v2 at 'applications' path
   - Writes secrets (redis, mqtt, etc.)
   - Creates Dapr token
   - Writes token to /vault-token/token

5. **Infrastructure Services** (5-10 seconds)
   - redis, emqx start in parallel
   - redis-init creates ACL user
   - emqx-init creates MQTT user

6. **Dapr Control Plane** (2-5 seconds)
   - dapr-placement starts
   - dapr-dashboard starts

7. **Application** (5-10 seconds)
   - api starts
   - api-dapr sidecar starts
   - Dapr components load secrets from Vault

**Total startup time:** ~30-60 seconds

## Port Mappings

### Vault HA

| Service | External Port | Internal Port | Purpose |
|---------|--------------|---------------|---------|
| vault-0 | 18200 | 8200 | Vault node 0 (direct access) |
| vault-1 | 18201 | 8200 | Vault node 1 (direct access) |
| vault-2 | 18202 | 8200 | Vault node 2 (direct access) |
| vault-lb | 8200 | 8200 | **Load balancer** (recommended endpoint) |

### Infrastructure Services

| Service | External Port | Internal Port | Purpose |
|---------|--------------|---------------|---------|
| redis | 6379 | 6379 | Redis state store |
| emqx | 1883 | 1883 | MQTT broker |
| emqx | 8083 | 8083 | MQTT WebSocket |
| emqx | 18083 | 18083 | EMQX Dashboard |

### Dapr & Application

| Service | External Port | Internal Port | Purpose |
|---------|--------------|---------------|---------|
| dapr-placement | 50005 | 50005 | Dapr placement service |
| dapr-dashboard | 9999 | 8080 | Dapr monitoring UI |
| api | 8080 | 8080 | API application |
| api-dapr | 3500 | 3500 | Dapr HTTP API (sidecar) |

## Accessing Services

### Vault

**Via Load Balancer (Recommended):**
```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
vault status
vault operator raft list-peers
vault kv get applications/redis
```

**Via Individual Nodes:**
```bash
# vault-0 (leader)
export VAULT_ADDR=http://localhost:18200

# vault-1 (follower)
export VAULT_ADDR=http://localhost:18201

# vault-2 (follower)
export VAULT_ADDR=http://localhost:18202
```

**Vault UI:**
- Load balancer: http://localhost:8200/ui
- vault-0: http://localhost:18200/ui
- vault-1: http://localhost:18201/ui
- vault-2: http://localhost:18202/ui
- Token: Root token from vault-keys.json

### Redis

```bash
# Using credentials from .env
redis-cli -h localhost -p 6379 \
  --user xenter \
  --pass redis-secret-password \
  PING

# Check ACL users
redis-cli -h localhost -p 6379 ACL LIST
```

### EMQX MQTT Broker

**Dashboard:**
- URL: http://localhost:18083
- Username: `admin`
- Password: Value from EMQX_DASHBOARD_PASSWORD in .env (default: `public`)

**MQTT Client:**
```bash
# Using mosquitto_pub/sub
mosquitto_pub -h localhost -p 1883 \
  -u xenter -P mqtt-secret-password \
  -t test/topic -m "Hello from Vault HA!"

mosquitto_sub -h localhost -p 1883 \
  -u xenter -P mqtt-secret-password \
  -t test/topic
```

### Dapr

**Dashboard:**
- URL: http://localhost:9999
- View components, applications, and logs

**Dapr API (via API sidecar):**
```bash
# Get state from Redis via Dapr
curl http://localhost:3500/v1.0/state/redis-statestore/mykey

# Publish to MQTT via Dapr
curl -X POST http://localhost:3500/v1.0/publish/mqtt-pubsub/test/topic \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello via Dapr!"}'

# Get secret from Vault via Dapr
curl http://localhost:3500/v1.0/secrets/vault-secretstore/redis
```

### API Application

```bash
# Health check
curl http://localhost:8080/health

# API endpoints (depends on your application)
curl http://localhost:8080/api/v1/...
```

## Files and Directories

```
docker/
├── docker-compose.yml          # Main orchestration file
├── .env.template               # Environment variable template
├── .env                        # Your configuration (gitignored)
├── init-vault-cluster.sh       # Manual initialization script (fallback)
├── config/
│   ├── vault-nginx.conf        # Nginx load balancer config
│   └── dapr-config.yaml        # Dapr control plane config
├── components/
│   ├── vault-secretstore.yaml  # Vault secret backend
│   ├── redis-statestore.yaml   # Redis state management
│   ├── redis-binding.yaml      # Redis bindings
│   └── mqtt-pubsub.yaml        # EMQX pub/sub
└── scripts/
    ├── vault-init-ha.sh        # Automated Vault init
    └── vault-provisioner.sh    # Secret provisioning
```

## Configuration Details

### Vault Configuration

**Storage:** Raft integrated storage (no external dependencies)
**Replication:** 3-node cluster with autopilot
**Initialization:** 5 key shares, threshold 3
**Secrets Engine:** KV v2 at 'applications' path
**TLS:** Disabled (development mode)
**UI:** Enabled on all nodes

**Secrets Stored:**
- `applications/redis` - Redis connection and credentials
- `applications/mqtt` - MQTT URL and credentials
- `applications/postgres` - PostgreSQL connection string
- `applications/minio` - MinIO S3 credentials

### Dapr Configuration

**mTLS:** Disabled (development mode)
**Tracing:** Disabled
**Components:**
- vault-secretstore (secretstores.hashicorp.vault)
- redis-statestore (state.redis)
- redis-binding (bindings.redis)
- mqtt-pubsub (pubsub.mqtt3)

**Sidecar Pattern:**
- api-dapr shares network namespace with api container
- Dapr intercepts all external service access
- Credentials retrieved from Vault at runtime

## Troubleshooting

### Vault Pods Not Unsealing

```bash
# Check vault-init-ha logs
docker-compose logs vault-init-ha

# Manually unseal if needed
docker exec vault-0 vault operator unseal <key1>
docker exec vault-0 vault operator unseal <key2>
docker exec vault-0 vault operator unseal <key3>

# Or use the manual script
./init-vault-cluster.sh
```

### Raft Cluster Not Forming

```bash
# Check Vault logs
docker-compose logs vault-0 vault-1 vault-2

# Check network connectivity
docker exec vault-1 ping vault-0

# Verify Raft configuration
docker exec vault-0 cat /vault/config/extraconfig-from-values.hcl

# Check Raft status
docker exec -e VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token') \
  vault-0 vault operator raft list-peers
```

### Secret Provisioning Failed

```bash
# Check provisioner logs
docker-compose logs vault-provisioner

# Verify Vault is unsealed
docker exec vault-0 vault status

# Manually re-run provisioner
docker-compose up -d vault-provisioner
docker-compose logs -f vault-provisioner
```

### Dapr Components Not Loading

```bash
# Check api-dapr logs
docker-compose logs api-dapr

# Verify Vault token exists
docker exec api-dapr cat /vault-token/token

# Test Vault connection
docker exec api-dapr wget -q -O- http://vault-lb:8200/v1/sys/health

# Restart Dapr sidecar
docker-compose restart api-dapr
```

### API Cannot Access Redis/EMQX

```bash
# Check Dapr component status
curl http://localhost:3500/v1.0/metadata

# Test secret retrieval
curl http://localhost:3500/v1.0/secrets/vault-secretstore/redis

# Check Redis connectivity
docker exec api ping redis

# Check EMQX connectivity
docker exec api ping emqx
```

### GitHub API Image Pull Failed

```bash
# Verify GITHUB_TOKEN in .env
cat .env | grep GITHUB_TOKEN

# Test token
docker login ghcr.io -u YOUR_USERNAME -p $GITHUB_TOKEN

# Pull image manually
docker pull ghcr.io/xentermd/api.xen.me:stage-amd64-latest
```

## Manual Operations

### Restart After Shutdown

```bash
# Start all services
docker-compose up -d

# Wait 30-60 seconds for initialization

# Verify cluster
docker exec vault-0 vault operator raft list-peers
```

**Note:** vault-keys.json is persisted in a Docker volume, so re-initialization is automatic.

### Clean Slate Restart

```bash
# Remove all containers and volumes
docker-compose down -v

# Remove vault-keys.json from volume (if needed)
docker volume rm docker_vault-keys

# Start fresh
docker-compose up -d
```

### Manual Vault Initialization (Fallback)

If automated initialization fails:

```bash
# Start only Vault cluster
docker-compose up -d vault-0 vault-1 vault-2

# Run manual script
./init-vault-cluster.sh

# Then start remaining services
docker-compose up -d
```

### Backup Vault Data

```bash
# Create Raft snapshot
docker exec -e VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token') \
  vault-0 vault operator raft snapshot save /tmp/snapshot.snap

# Copy to host
docker cp vault-0:/tmp/snapshot.snap ./backup-$(date +%Y%m%d).snap
```

### Restore Vault Data

```bash
# Copy snapshot to container
docker cp ./backup.snap vault-0:/tmp/restore.snap

# Restore
docker exec -e VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token') \
  vault-0 vault operator raft snapshot restore /tmp/restore.snap

# Restart cluster
docker-compose restart vault-0 vault-1 vault-2
```

## Security Considerations

⚠️ **Development Mode Only**

This setup is designed for **local development and testing** with these security trade-offs:

**Current Security Posture:**
- ✅ Secrets stored in Vault (not environment variables)
- ✅ Redis ACL authentication
- ✅ EMQX user authentication
- ✅ Dapr uses token (not root token)
- ❌ No TLS (HTTP only)
- ❌ Root token in plaintext file
- ❌ Unseal keys in Docker volume
- ❌ No audit logging
- ❌ No Dapr mTLS

**For Production Deployment:**
1. Enable TLS for Vault, Redis, EMQX
2. Enable Dapr mTLS (requires Kubernetes)
3. Use Cloud KMS auto-unseal (AWS KMS, Azure Key Vault, GCP)
4. Enable Vault audit logging
5. Implement secret rotation
6. Use Vault AppRole instead of token file
7. Deploy to Kubernetes (use src/modules/vault/)

## Next Steps

### Migrate to Kubernetes

For production deployments, use the Terraform module:

```bash
cd ../src/modules/vault/
terraform apply -var="auto_initialize=true" -var="replicas=3"
```

See: [Kubernetes Deployment Guide](../src/modules/vault/README.md)

### Add More Services

To add additional services (PostgreSQL, MinIO, etc.):

1. Add service to docker-compose.yml
2. Update vault-provisioner.sh to add secrets
3. Create Dapr component in components/
4. Configure scopes in component metadata

### Enable Monitoring

Add Prometheus and Grafana:

```yaml
# docker-compose.yml
prometheus:
  image: prom/prometheus
  ports:
    - "9090:9090"
  volumes:
    - ./prometheus.yml:/etc/prometheus/prometheus.yml

grafana:
  image: grafana/grafana
  ports:
    - "3000:3000"
```

## References

- [HashiCorp Vault Documentation](https://developer.hashicorp.com/vault)
- [Dapr Documentation](https://docs.dapr.io)
- [Vault Helm Chart](https://github.com/hashicorp/vault-helm)
- [Raft Storage Backend](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [Dapr Secret Stores](https://docs.dapr.io/reference/components-reference/supported-secret-stores/)
