#!/bin/sh
# Vault Secret Provisioner for Dapr Integration
# Populates Vault with secrets for Redis, EMQX, and other services

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print functions using printf for POSIX compliance
print_info() {
    printf "%b[INFO]%b %s\n" "${BLUE}" "${NC}" "$1"
}

print_success() {
    printf "%b[SUCCESS]%b %s\n" "${GREEN}" "${NC}" "$1"
}

print_warning() {
    printf "%b[WARNING]%b %s\n" "${YELLOW}" "${NC}" "$1"
}

print_error() {
    printf "%b[ERROR]%b %s\n" "${RED}" "${NC}" "$1"
}

# Wait for Vault to be ready
wait_for_vault() {
    _max_wait=60
    _elapsed=0

    print_info "Waiting for Vault to be ready..."

    while [ $_elapsed -lt $_max_wait ]; do
        if wget -q -O- http://vault-lb:8200/v1/sys/health | grep -q '"sealed":false'; then
            print_success "Vault is ready and unsealed"
            return 0
        fi
        sleep 2
        _elapsed=$((_elapsed + 2))
    done

    print_error "Vault failed to become ready after ${_max_wait}s"
    return 1
}

# Enable KV v2 secrets engine (with retry logic)
enable_kv_engine() {
    print_info "Enabling KV v2 secrets engine at 'applications'..."

    # Check if already enabled
    _check=$(wget -q -O- --header="X-Vault-Token: $VAULT_TOKEN" \
        http://vault-lb:8200/v1/sys/mounts 2>/dev/null | grep -o '"applications/"' || true)

    if [ -n "$_check" ]; then
        print_warning "KV engine already enabled at applications/"
        return 0
    fi

    # Enable KV v2 with retry logic for cluster stabilization
    _max_attempts=5
    _attempt=1

    while [ $_attempt -le $_max_attempts ]; do
        if wget -q -O- --post-data='{"type":"kv","options":{"version":"2"}}' \
            --header="X-Vault-Token: $VAULT_TOKEN" \
            --header='Content-Type: application/json' \
            http://vault-lb:8200/v1/sys/mounts/applications 2>/dev/null; then
            print_success "KV v2 engine enabled"
            return 0
        fi

        if [ $_attempt -lt $_max_attempts ]; then
            print_warning "Attempt $_attempt failed, retrying in 5 seconds..."
            sleep 5
        fi
        _attempt=$((_attempt + 1))
    done

    print_error "Failed to enable KV engine after $_max_attempts attempts"
    return 1
}

# Write secret to Vault
write_secret() {
    _path=$1
    _data=$2

    print_info "Writing secret to $_path..."

    wget -q -O- --post-data="$_data" \
        --header="X-Vault-Token: $VAULT_TOKEN" \
        --header='Content-Type: application/json' \
        http://vault-lb:8200/v1/applications/data/$_path > /dev/null

    print_success "Secret written to $_path"
}

# Provision all secrets
provision_secrets() {
    print_info "=== Provisioning secrets ==="

    # Redis credentials
    write_secret "redis" "{
        \"data\": {
            \"redis-host\": \"${REDIS_HOST:-redis:6379}\",
            \"redis-username\": \"${REDIS_USERNAME:-xenter}\",
            \"redis-password\": \"${REDIS_PASSWORD:-redis-secret-password}\"
        }
    }"

    # MQTT credentials
    write_secret "mqtt" "{
        \"data\": {
            \"mqtt-url\": \"tcp://${MQTT_USERNAME:-xenter}:${MQTT_PASSWORD:-mqtt-secret-password}@emqx:1883\",
            \"mqtt-username\": \"${MQTT_USERNAME:-xenter}\",
            \"mqtt-password\": \"${MQTT_PASSWORD:-mqtt-secret-password}\"
        }
    }"

    # PostgreSQL credentials (if needed)
    write_secret "postgres" "{
        \"data\": {
            \"postgres-connection-string\": \"${POSTGRES_CONNECTION_STRING:-postgresql://user:password@postgres:5432/dbname}\"
        }
    }"

    # MinIO credentials (if needed)
    write_secret "minio" "{
        \"data\": {
            \"minio-access-key\": \"${MINIO_ACCESS_KEY:-minioadmin}\",
            \"minio-secret-key\": \"${MINIO_SECRET_KEY:-minioadmin}\",
            \"minio-endpoint\": \"${MINIO_ENDPOINT:-minio:9000}\"
        }
    }"

    print_success "All secrets provisioned"
}

# Create Dapr policy and token
create_dapr_policy() {
    print_info "Creating Dapr read-only policy..."

    # Create policy with proper escaping
    # Include both KV v1 (applications/*) and KV v2 (applications/data/*) paths
    # This handles Dapr's inconsistent path construction for different component versions
    _policy='{"policy":"path \"applications/data/*\" {\n  capabilities = [\"read\", \"list\"]\n}\n\npath \"applications/*\" {\n  capabilities = [\"read\", \"list\"]\n}"}'

    wget -q -O- --post-data="$_policy" \
        --header="X-Vault-Token: $VAULT_TOKEN" \
        --header='Content-Type: application/json' \
        http://vault-lb:8200/v1/sys/policies/acl/dapr-read-only > /dev/null

    print_success "Dapr policy created"

    # Create token for Dapr
    print_info "Creating token for Dapr..."

    _token_response=$(wget -q -O- --post-data='{"policies":["dapr-read-only"],"ttl":"24h","renewable":true}' \
        --header="X-Vault-Token: $VAULT_TOKEN" \
        --header='Content-Type: application/json' \
        http://vault-lb:8200/v1/auth/token/create)

    _dapr_token=$(echo "$_token_response" | grep -o '"client_token":"[^"]*"' | cut -d':' -f2 | tr -d '"')

    if [ -z "$_dapr_token" ]; then
        print_warning "Failed to create Dapr token, using root token instead"
        _dapr_token="$VAULT_TOKEN"
    fi

    # Write token to shared volume
    echo "$_dapr_token" > /vault-token/token
    chmod 644 /vault-token/token  # Make readable by all users (Dapr sidecar runs as non-root)

    print_success "Dapr token written to /vault-token/token"
}

# Main execution
main() {
    print_info "=== Vault Secret Provisioner ==="

    # Read root token
    if [ -f /vault-keys/root-token ]; then
        VAULT_TOKEN=$(cat /vault-keys/root-token)
    elif [ -n "$VAULT_TOKEN" ]; then
        print_info "Using VAULT_TOKEN from environment"
    else
        print_error "VAULT_TOKEN not found"
        exit 1
    fi

    # Wait for Vault to be ready
    wait_for_vault

    # Enable KV engine
    enable_kv_engine

    # Provision secrets
    provision_secrets

    # Create Dapr policy and token
    create_dapr_policy

    print_success "Secret provisioning complete!"
}

main "$@"
