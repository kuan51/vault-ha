# Vault HA Cluster - Docker Compose

This directory contains a Docker Compose setup for running a 3-node HashiCorp Vault HA cluster with Raft storage for local development and testing.

## Overview

**Purpose:** Local development environment for Vault HA testing
**Architecture:** 3-node cluster with Raft integrated storage
**Ports:** 18200-18202 (avoids conflict with Kubernetes Vault on 8200)

## Quick Start

### 1. Start the Cluster

```bash
cd docker

# Clean start (recommended first time)
docker-compose down -v

# Start all containers
docker-compose up -d

# Check container status
docker-compose ps
```

### 2. Initialize and Configure

```bash
# Run the initialization script
./init-vault-cluster.sh
```

This script will:
- Wait for all containers to be ready
- Initialize vault-0 (leader) with 5 key shares, threshold 3
- Unseal all three nodes
- Verify cluster formation
- Display access information

### 3. Access Vault

**CLI Access:**
```bash
export VAULT_ADDR=http://localhost:18200
export VAULT_TOKEN=<root-token-from-init>
vault status
```

**UI Access:**
- URL: http://localhost:18200/ui
- Token: Use root token from initialization

**Direct Node Access:**
```bash
# vault-0 (leader)
docker exec vault-0 vault status

# vault-1 (follower)
docker exec vault-1 vault status

# vault-2 (follower)
docker exec vault-2 vault status
```

## Configuration Details

### Network Architecture

```
┌─────────────────────────────────────────────────┐
│                Docker Host                      │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │     vault_network (bridge)              │   │
│  │                                         │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │  │ vault-0  │  │ vault-1  │  │ vault-2  │ │
│  │  │ :8200    │  │ :8200    │  │ :8200    │ │
│  │  └──────────┘  └──────────┘  └──────────┘ │
│  │       │             │             │       │   │
│  └───────┼─────────────┼─────────────┼───────┘   │
│          │             │             │           │
│     :18200        :18201        :18202           │
└─────────────────────────────────────────────────┘
```

### Port Mapping

| Service | Internal Port | External Port | Purpose |
|---------|--------------|---------------|---------|
| vault-0 | 8200 | 18200 | API/UI access (leader) |
| vault-1 | 8200 | 18201 | API/UI access (follower) |
| vault-2 | 8200 | 18202 | API/UI access (follower) |

**Why 18200-18202?**
- Avoids conflict with Kubernetes Vault (port 8200)
- Allows both environments to run simultaneously
- Easy to remember: 18xxx = Docker Vault

### Storage Configuration

**Raft Integrated Storage:**
- **Type:** Raft consensus protocol with BoltDB backend
- **Data Path:** `/vault/file` (uses Vault image's built-in directory)
- **Autopilot:** Enabled for automated cluster management
- **Min Quorum:** 2 nodes required for operations

**Volume Mounts:**
- `vault_file1`, `vault_file2`, `vault_file3` - Raft data persistence
- `vault_logs1`, `vault_logs2`, `vault_logs3` - Vault logs

**Why `/vault/file`?**
- Built into the Vault image with correct permissions (`vault:vault`, UID 100:1000)
- Entrypoint automatically manages permissions for bind mounts
- No need for custom entrypoint or root user workarounds
- Follows HashiCorp's official image design patterns

### Key Features

1. **Autopilot Configuration**
   - Automatic dead server cleanup
   - Server stabilization: 10s
   - Last contact threshold: 10s
   - Minimum quorum: 2 nodes

2. **High Availability**
   - 3-node cluster with automatic leader election
   - `retry_join` for automatic cluster formation
   - Raft consensus for state replication

3. **Development-Friendly**
   - TLS disabled for easier testing
   - UI enabled on all nodes
   - JSON logging for better debugging
   - Healthchecks for monitoring

## Common Operations

### View Cluster Status

```bash
# Set environment
export VAULT_ADDR=http://localhost:18200
export VAULT_TOKEN=<your-root-token>

# Check Raft peers
vault operator raft list-peers

# Expected output:
# Node       Address        State     Voter
# ----       -------        -----     -----
# vault-0    10.x.x.x:8201  leader    true
# vault-1    10.x.x.x:8201  follower  true
# vault-2    10.x.x.x:8201  follower  true
```

### Check Container Logs

```bash
# All containers
docker-compose logs -f

# Specific container
docker-compose logs -f vault-0

# Last 100 lines
docker-compose logs --tail=100 vault-0
```

### Restart Cluster

```bash
# Restart all containers
docker-compose restart

# After restart, you'll need to unseal again
docker exec vault-0 vault operator unseal <key1>
docker exec vault-0 vault operator unseal <key2>
docker exec vault-0 vault operator unseal <key3>
# Repeat for vault-1 and vault-2
```

### Stop Cluster

```bash
# Stop containers (keeps data)
docker-compose stop

# Stop and remove containers (keeps volumes)
docker-compose down

# Stop, remove containers AND volumes (clean slate)
docker-compose down -v
```

### Force Leader Election

```bash
# Current leader steps down
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-0 vault operator step-down

# New leader will be elected automatically
```

## Troubleshooting

### Containers Exit Immediately

**Issue:** Permission denied errors on volumes

**Solution:** Configuration uses `/vault/file` which has built-in permission management
```bash
# If issue persists, clean volumes and restart
docker-compose down -v
docker-compose up -d
```

### Port Already in Use

**Issue:** Port 18200-18202 already allocated

**Solution:** Check what's using the port
```bash
# Find process using port
sudo lsof -i :18200

# Kill if needed
sudo kill <PID>

# Or change ports in docker-compose.yml
```

### Node Won't Join Cluster

**Issue:** `retry_join` not working

**Solution:**
```bash
# Check network connectivity
docker exec vault-1 ping -c 3 vault-0

# Check if node already initialized
docker exec vault-1 vault status

# If initialized separately, need to clean volumes
docker-compose down -v
docker-compose up -d
```

### Cluster Split Brain

**Issue:** Multiple leaders or conflicting Raft states

**Solution:** Clean slate and reinitialize
```bash
docker-compose down -v
rm -f vault-keys.json
docker-compose up -d
./init-vault-cluster.sh
```

### Container Keeps Restarting

**Check logs:**
```bash
docker-compose logs vault-0

# Common issues:
# - Port conflict
# - Permission issues
# - Invalid configuration
```

## Differences from Production (Kubernetes)

| Aspect | Docker Compose | Kubernetes (Phase 4) |
|--------|----------------|---------------------|
| **Initialization** | `retry_join` (automatic) | Manual join (vault-raft-join job) |
| **TLS** | Disabled | Required |
| **Auto-Unseal** | Manual (Shamir) | Azure Key Vault |
| **Service Discovery** | Docker DNS | Kubernetes Service |
| **Persistence** | Docker volumes | PersistentVolumeClaims |
| **RBAC** | None | Kubernetes RBAC + Vault policies |
| **Monitoring** | Manual | Loki, Prometheus, Grafana |

## Security Considerations

⚠️ **This setup is for DEVELOPMENT ONLY**

**Not Production-Ready Because:**
1. **TLS Disabled** - All communication unencrypted
2. **Root User** - Containers run as root
3. **No Auto-Unseal** - Manual unseal after restarts
4. **No Access Controls** - No network policies or firewalls
5. **No Audit Logging** - No FDA CFR Part 11 compliance
6. **Keys in Plain Text** - vault-keys.json not encrypted

**For Production:** Use the Kubernetes deployment in Phase 4 with:
- TLS encryption
- Auto-unseal with cloud KMS
- Network policies
- RBAC and least-privilege policies
- Audit logging to Loki
- Secret rotation and compliance tracking

## Useful Commands

### Health Checks

```bash
# Check all containers
docker-compose ps

# Detailed health status
docker inspect vault-0 | grep -A 10 Health

# Quick status check
docker exec vault-0 vault status
```

### Backup and Restore

```bash
# Take Raft snapshot
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-0 \
  vault operator raft snapshot save /vault/logs/snapshot.snap

# Copy snapshot out
docker cp vault-0:/vault/logs/snapshot.snap ./backup-$(date +%Y%m%d).snap

# Restore snapshot (on clean cluster)
docker cp ./backup-20241016.snap vault-0:/vault/logs/restore.snap
docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-0 \
  vault operator raft snapshot restore /vault/logs/restore.snap
```

### Enable Secret Engines

```bash
export VAULT_ADDR=http://localhost:18200
export VAULT_TOKEN=<root-token>

# KV v2 secrets
vault secrets enable -path=secret kv-v2

# PKI for certificates
vault secrets enable pki

# Database secrets
vault secrets enable database
```

## Files

- `docker-compose.yml` - Main configuration
- `init-vault-cluster.sh` - Initialization script
- `README.md` - This file
- `vault-keys.json` - Generated unseal keys (gitignored)

## References

- [HashiCorp Vault Documentation](https://developer.hashicorp.com/vault/docs)
- [Vault Raft Storage](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [Kubernetes Vault Deployment](../docs/operations/vault-ha-implementation-guide.md)

## Support

For issues related to:
- **Docker Compose setup**: Check this README and troubleshooting section
- **Kubernetes deployment**: See `docs/operations/vault-ha-implementation-guide.md`
- **Vault configuration**: See `src/4-infrastructure-services/modules/vault/`
