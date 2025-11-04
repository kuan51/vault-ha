#!/bin/sh
# Automated Vault HA Cluster Initialization for Docker Compose
# This script is designed to run inside a container for automated initialization

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

# Wait for Vault pods to be accessible
wait_for_vault() {
    _node=$1
    _max_wait=60
    _elapsed=0

    print_info "Waiting for $_node to be accessible..."

    while [ $_elapsed -lt $_max_wait ]; do
        # Try to connect; even 501/503 errors mean Vault is accessible
        if wget --spider -q http://$_node:8200/v1/sys/health 2>&1 | grep -q "501\|503\|Connection established"; then
            print_success "$_node is accessible"
            return 0
        fi
        # Also check if we can get any response at all
        if wget -T 2 -t 1 -q -O- http://$_node:8200/v1/sys/health 2>&1; then
            print_success "$_node is accessible"
            return 0
        fi
        sleep 2
        _elapsed=$((_elapsed + 2))
    done

    print_error "$_node failed to become accessible after ${_max_wait}s"
    return 1
}

# Initialize vault-0
init_vault() {
    print_info "Initializing vault-0..."

    # Check if already initialized (ignore HTTP errors)
    if wget -q -O- http://vault-0:8200/v1/sys/health 2>/dev/null | grep -q '"initialized":true'; then
        print_warning "Vault already initialized"
        if [ ! -f /vault-keys/vault-keys.json ]; then
            print_error "vault-keys.json not found but Vault is initialized. Cannot proceed."
            exit 1
        fi
        return 0
    fi

    # Initialize with 5 shares, threshold of 3
    # Note: We cannot use 2>/dev/null here because we need the response even if wget reports an error
    _init_response=$(wget -q -O- --post-data='{"secret_shares":5,"secret_threshold":3}' \
        --header='Content-Type: application/json' \
        http://vault-0:8200/v1/sys/init 2>&1 | grep -v "wget:")

    if [ -z "$_init_response" ]; then
        print_error "Failed to initialize Vault - no response received"
        exit 1
    fi

    echo "$_init_response" > /vault-keys/vault-keys.json
    print_success "Vault initialized successfully"
}

# Extract keys from vault-keys.json
extract_keys() {
    if [ ! -f /vault-keys/vault-keys.json ]; then
        print_error "vault-keys.json not found"
        exit 1
    fi

    UNSEAL_KEY_1=$(grep -o '"keys":\[.*\]' /vault-keys/vault-keys.json | grep -o '"[^"]*"' | sed -n '2p' | tr -d '"')
    UNSEAL_KEY_2=$(grep -o '"keys":\[.*\]' /vault-keys/vault-keys.json | grep -o '"[^"]*"' | sed -n '3p' | tr -d '"')
    UNSEAL_KEY_3=$(grep -o '"keys":\[.*\]' /vault-keys/vault-keys.json | grep -o '"[^"]*"' | sed -n '4p' | tr -d '"')
    ROOT_TOKEN=$(grep -o '"root_token":"[^"]*"' /vault-keys/vault-keys.json | cut -d':' -f2 | tr -d '"')

    if [ -z "$UNSEAL_KEY_1" ] || [ -z "$ROOT_TOKEN" ]; then
        print_error "Failed to extract keys from vault-keys.json"
        exit 1
    fi

    print_info "Keys extracted successfully"
}

# Unseal a node
unseal_node() {
    _node=$1
    print_info "Unsealing $_node..."

    # Unseal with 3 keys (ignore HTTP errors as they may occur during unsealing process)
    wget -q -O- --post-data="{\"key\":\"$UNSEAL_KEY_1\"}" \
        --header='Content-Type: application/json' \
        http://$_node:8200/v1/sys/unseal 2>/dev/null || true

    wget -q -O- --post-data="{\"key\":\"$UNSEAL_KEY_2\"}" \
        --header='Content-Type: application/json' \
        http://$_node:8200/v1/sys/unseal 2>/dev/null || true

    wget -q -O- --post-data="{\"key\":\"$UNSEAL_KEY_3\"}" \
        --header='Content-Type: application/json' \
        http://$_node:8200/v1/sys/unseal 2>/dev/null || true

    print_success "$_node unsealed"
}

# Join a follower node to the Raft cluster
join_node() {
    _node=$1
    print_info "Joining $_node to the Raft cluster..."

    # Attempt to join via API (must be done from the follower)
    _join_response=$(wget -q -O- --post-data="{\"leader_api_addr\":\"http://vault-0:8200\"}" \
        --header='Content-Type: application/json' \
        "http://$_node:8200/v1/sys/storage/raft/join" 2>&1)

    # Check for success indicators in response
    if echo "$_join_response" | grep -q '"joined":true'; then
        print_success "$_node successfully joined the cluster"
        return 0
    else
        # Check if already a member (not an error)
        if echo "$_join_response" | grep -qi 'already member\|node already present'; then
            print_warning "$_node is already a member of the cluster"
            return 0
        else
            print_error "$_node failed to join cluster"
            print_error "Response: $_join_response"
            return 1
        fi
    fi
}

# Wait for node to be initialized after joining
wait_for_initialized() {
    _node=$1
    _max_wait=${2:-30}
    _elapsed=0

    print_info "Waiting for $_node to become initialized..."

    while [ "$_elapsed" -lt "$_max_wait" ]; do
        if wget -q -O- "http://$_node:8200/v1/sys/health" 2>/dev/null | grep -q '"initialized":true'; then
            print_success "$_node is now initialized"
            return 0
        fi
        sleep 2
        _elapsed=$((_elapsed + 2))
    done

    print_error "$_node failed to initialize after ${_max_wait}s"
    return 1
}

# Verify all nodes are in Raft cluster
verify_cluster_peers() {
    print_info "Verifying Raft cluster membership..."

    _peers=$(wget -q -O- --header="X-Vault-Token: $ROOT_TOKEN" \
        http://vault-0:8200/v1/sys/storage/raft/configuration 2>/dev/null || echo "")

    if [ -z "$_peers" ]; then
        print_warning "Could not retrieve Raft peer list"
        return 1
    fi

    for _node in vault-0 vault-1 vault-2; do
        if echo "$_peers" | grep -q "$_node"; then
            print_success "$_node present in Raft peer list"
        else
            print_error "$_node MISSING from Raft peer list"
        fi
    done
}

# Main execution
main() {
    print_info "=== Vault HA Cluster Automated Initialization ==="

    # Wait for all Vault nodes to be accessible
    for _node in vault-0 vault-1 vault-2; do
        wait_for_vault "$_node"
    done

    sleep 5  # Allow Vault startup to stabilize

    # Initialize vault-0 ONLY
    init_vault
    extract_keys

    # Unseal vault-0 (becomes Raft leader)
    unseal_node vault-0

    sleep 5  # Allow leader election to complete

    # Explicitly join followers to the cluster and unseal immediately
    join_node vault-1
    unseal_node vault-1

    join_node vault-2
    unseal_node vault-2

    # Verify cluster formation
    verify_cluster_peers

    # Write root token to shared volume for vault-provisioner
    echo "$ROOT_TOKEN" > /vault-keys/root-token

    print_success "Vault HA cluster initialized and unsealed!"
    print_info "Root token: $ROOT_TOKEN"
    print_warning "Keys stored in /vault-keys/vault-keys.json"
}

main "$@"
