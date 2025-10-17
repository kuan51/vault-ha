# Vault Docker Permissions Solution

## Problem

When using HashiCorp Vault with Docker Compose and volume mounts, permission errors occur:

```
Error initializing storage of type raft: failed to create fsm:
failed to open bolt file: open /vault/data/vault.db: permission denied
```

## Root Cause

The HashiCorp Vault Docker image (`hashicorp/vault:1.15.6`) has specific directory structure and ownership:

### Built-in Directories

| Directory | Owner | Purpose | Auto-chown by Entrypoint |
|-----------|-------|---------|--------------------------|
| `/vault/config` | `vault:vault` (100:1000) | Configuration files | ✅ Yes |
| `/vault/logs` | `vault:vault` (100:1000) | Log files | ✅ Yes |
| `/vault/file` | `vault:vault` (100:1000) | File storage backend | ✅ Yes |
| `/vault/data` | ❌ **Does not exist** | N/A | ❌ No |

### Entrypoint Behavior

The official Vault entrypoint (`/usr/local/bin/docker-entrypoint.sh`) automatically fixes ownership for specific directories:

```bash
# From docker-entrypoint.sh (lines 66-77)
if [ "$1" = 'vault' ]; then
    if [ -z "$SKIP_CHOWN" ]; then
        # If the config dir is bind mounted then chown it
        if [ "$(stat -c %u /vault/config)" != "$(id -u vault)" ]; then
            chown -R vault:vault /vault/config
        fi

        # If the logs dir is bind mounted then chown it
        if [ "$(stat -c %u /vault/logs)" != "$(id -u vault)" ]; then
            chown -R vault:vault /vault/logs
        fi

        # If the file dir is bind mounted then chown it
        if [ "$(stat -c %u /vault/file)" != "$(id -u vault)" ]; then
            chown -R vault:vault /vault/file
        fi
    fi
    # ... (no handling for /vault/data)
fi
```

**Key Observation:** The entrypoint ONLY manages `/vault/config`, `/vault/logs`, and `/vault/file` - NOT `/vault/data`!

---

## Solutions Comparison

### ❌ Solution 1: Use `/vault/data` with Custom Entrypoint (Original Approach)

**docker-compose.yml:**
```yaml
services:
  vault-0:
    user: root  # Run as root
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        chown -R vault:vault /vault/data /vault/logs
        exec docker-entrypoint.sh server
    volumes:
      - vault_data1:/vault/data
    environment:
      VAULT_LOCAL_CONFIG: |
        storage "raft" {
          path = "/vault/data"  # Custom directory
        }
```

**Drawbacks:**
- ❌ Requires custom entrypoint override
- ❌ Requires running container as root
- ❌ Breaks official image design patterns
- ❌ More complex to maintain
- ❌ May cause issues with future image updates

---

### ✅ Solution 2: Use `/vault/file` (Recommended)

**docker-compose.yml:**
```yaml
services:
  vault-0:
    # No user override needed
    # No entrypoint override needed
    volumes:
      - vault_file1:/vault/file  # Use built-in directory
    environment:
      VAULT_LOCAL_CONFIG: |
        storage "raft" {
          path = "/vault/file"  # Built-in directory
        }
```

**Benefits:**
- ✅ Uses official image design patterns
- ✅ No custom entrypoint required
- ✅ No root user required
- ✅ Entrypoint automatically manages permissions
- ✅ Simpler configuration
- ✅ More maintainable
- ✅ Future-proof with image updates

---

## Implementation

### Step 1: Update Storage Path

Change Raft storage path from `/vault/data` to `/vault/file`:

```yaml
storage "raft" {
  path = "/vault/file"  # ← Changed from /vault/data
  node_id = "vault-0"
  # ... rest of config
}
```

### Step 2: Update Volume Mounts

Change volume names and mount points:

```yaml
volumes:
  - vault_file1:/vault/file  # ← Changed from vault_data1:/vault/data
  - vault_logs1:/vault/logs
```

### Step 3: Remove Custom Overrides

Remove these lines if present:

```yaml
# REMOVE these:
user: root
entrypoint: ["/bin/sh", "-c"]
command:
  - |
    chown -R vault:vault /vault/data /vault/logs
    exec docker-entrypoint.sh server
```

### Step 4: Update Volume Definitions

```yaml
volumes:
  vault_file1:  # ← Changed from vault_data1
  vault_file2:
  vault_file3:
  vault_logs1:
  vault_logs2:
  vault_logs3:
```

---

## Why This Works

### 1. Built-in Directory Exists

The `/vault/file` directory is created at image build time with correct ownership:

```bash
$ docker run --rm hashicorp/vault:1.15.6 ls -la /vault/file
drwxr-xr-x    2 vault    vault         4096 Feb 28  2024 .
```

### 2. Entrypoint Handles Permissions

When a volume is mounted to `/vault/file`, the entrypoint script automatically fixes ownership:

```bash
# Entrypoint checks ownership and fixes it if needed
if [ "$(stat -c %u /vault/file)" != "$(id -u vault)" ]; then
    chown -R vault:vault /vault/file
fi
```

### 3. Vault Process Runs as Non-Root

The entrypoint drops privileges to the `vault` user:

```bash
if [ "$(id -u)" = '0' ]; then
  set -- su-exec vault "$@"  # Drop to vault user
fi
```

This provides security best practices without manual intervention.

---

## Verification

### Check Directory Ownership in Running Container

```bash
docker exec vault-0 ls -la /vault/file
# Should show: drwxr-xr-x vault vault
```

### Check Vault Process User

```bash
docker exec vault-0 ps aux | grep vault
# Should show: vault user running the process
```

### Check Raft Database

```bash
docker exec vault-0 ls -la /vault/file/vault.db
# Should exist with vault:vault ownership after initialization
```

---

## Alternative Solutions (Not Recommended)

### Option A: SKIP_CHOWN Environment Variable

```yaml
environment:
  SKIP_CHOWN: "true"  # Disable automatic chown
```

**Issue:** Still requires pre-configuring volume permissions, doesn't solve the problem.

### Option B: Docker Volume Options

```yaml
volumes:
  vault_data1:
    driver: local
    driver_opts:
      type: none
      o: bind,uid=100,gid=1000
      device: ./vault-data/vault-0
```

**Issue:** Requires pre-creating directories on host, platform-specific, less portable.

### Option C: Init Container Pattern

**Issue:** Adds complexity, requires Docker Compose v3.9+, overkill for this use case.

---

## Conclusion

**Recommended Solution:** Use `/vault/file` instead of `/vault/data`

This aligns with the official Vault Docker image design and eliminates the need for permission workarounds.

### Key Takeaway

> **Always use directories that exist in the base image and are managed by the official entrypoint script. Don't create custom directories unless absolutely necessary.**

---

## References

- **Vault Docker Image:** https://hub.docker.com/_/vault
- **Vault Dockerfile:** https://github.com/hashicorp/docker-vault
- **Vault Entrypoint:** `/usr/local/bin/docker-entrypoint.sh` in the image
- **Vault File Storage Backend:** https://developer.hashicorp.com/vault/docs/configuration/storage/filesystem
- **Vault Raft Storage Backend:** https://developer.hashicorp.com/vault/docs/configuration/storage/raft

---

## Change History

| Date | Change | Reason |
|------|--------|--------|
| 2025-10-16 | Changed from `/vault/data` to `/vault/file` | Align with official image design, eliminate permission workarounds |
| 2025-10-16 | Removed `user: root` override | No longer needed with `/vault/file` |
| 2025-10-16 | Removed custom entrypoint | No longer needed with `/vault/file` |
