#!/bin/bash
# Vault HA Cluster Initialization Script
# This script initializes and configures a 3-node Vault cluster in Docker Compose

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        exit 1
    fi

    if ! command -v docker-compose &> /dev/null; then
        print_error "Docker Compose is not installed or not in PATH"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed. Install it for better JSON parsing: sudo apt-get install jq"
    fi

    print_success "Prerequisites check passed"
}

# Wait for container to be healthy
wait_for_container() {
    local container=$1
    local max_wait=60
    local elapsed=0

    print_info "Waiting for $container to be ready..."

    while [ $elapsed -lt $max_wait ]; do
        if docker exec $container vault status &> /dev/null || [ $? -eq 2 ]; then
            print_success "$container is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    print_error "$container failed to become ready after ${max_wait}s"
    return 1
}

# Initialize the cluster
init_cluster() {
    print_info "=== Phase 1: Initializing vault-0 (leader) ==="

    # Initialize vault-0
    if docker exec vault-0 vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json > vault-keys.json 2>/dev/null; then
        print_success "Vault initialized successfully"
    else
        print_error "Failed to initialize Vault"
        print_info "Checking if Vault is already initialized..."
        if docker exec vault-0 vault status 2>&1 | grep -q "Initialized.*true"; then
            print_warning "Vault is already initialized. Using existing vault-keys.json"
            if [ ! -f vault-keys.json ]; then
                print_error "vault-keys.json not found. Cannot proceed without unseal keys."
                exit 1
            fi
        else
            exit 1
        fi
    fi

    # Extract keys and token
    if command -v jq &> /dev/null; then
        UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' vault-keys.json)
        UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' vault-keys.json)
        UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' vault-keys.json)
        ROOT_TOKEN=$(jq -r '.root_token' vault-keys.json)
    else
        print_warning "jq not available. You'll need to manually extract keys from vault-keys.json"
        print_info "Looking for keys in vault-keys.json..."
        UNSEAL_KEY_1=$(grep -o '"unseal_keys_b64":\[.*\]' vault-keys.json | grep -o '"[^"]*"' | sed -n '2p' | tr -d '"')
        UNSEAL_KEY_2=$(grep -o '"unseal_keys_b64":\[.*\]' vault-keys.json | grep -o '"[^"]*"' | sed -n '3p' | tr -d '"')
        UNSEAL_KEY_3=$(grep -o '"unseal_keys_b64":\[.*\]' vault-keys.json | grep -o '"[^"]*"' | sed -n '4p' | tr -d '"')
        ROOT_TOKEN=$(grep -o '"root_token":"[^"]*"' vault-keys.json | cut -d':' -f2 | tr -d '"')
    fi

    print_info "Keys extracted from vault-keys.json"
}

# Join a follower node to the Raft cluster
join_node_to_cluster() {
    local node=$1
    local leader=${2:-vault-0}

    print_info "Joining $node to Raft cluster via $leader..."

    # Check if node is already initialized (means it's already in cluster)
    if docker exec $node vault status 2>&1 | grep -q "Initialized.*true"; then
        print_warning "$node is already initialized (already in cluster)"
        return 0
    fi

    # Join the cluster using the leader's cluster address
    if docker exec $node vault operator raft join "http://${leader}:8200"; then
        print_success "$node joined the cluster"
        sleep 2  # Wait for cluster sync
        return 0
    else
        print_error "Failed to join $node to cluster"
        print_info "Checking $leader status..."
        docker exec $leader vault status || true
        return 1
    fi
}

# Unseal a single node
unseal_node() {
    local node=$1
    print_info "Unsealing $node..."

    docker exec $node vault operator unseal "$UNSEAL_KEY_1" > /dev/null
    docker exec $node vault operator unseal "$UNSEAL_KEY_2" > /dev/null
    docker exec $node vault operator unseal "$UNSEAL_KEY_3" > /dev/null

    print_success "$node unsealed"
}

# Verify cluster status
verify_cluster() {
    print_info "=== Verifying cluster status ==="

    export VAULT_TOKEN="$ROOT_TOKEN"

    # Check seal status
    for node in vault-0 vault-1 vault-2; do
        print_info "Checking $node status..."
        docker exec $node vault status || true
        echo ""
    done

    # Check Raft peers
    print_info "Checking Raft cluster members..."
    if docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault-0 vault operator raft list-peers; then
        # Count the number of peers (should be 3)
        peer_count=$(docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault-0 vault operator raft list-peers -format=json | grep -o '"node_id"' | wc -l)

        if [ "$peer_count" -eq 3 ]; then
            print_success "All 3 nodes successfully joined the Raft cluster"
        else
            print_warning "Expected 3 nodes in cluster, found $peer_count"
        fi
    else
        print_error "Failed to list Raft peers"
        return 1
    fi

    print_success "Cluster verification complete"
}

# Main execution
main() {
    echo ""
    echo "======================================================================"
    echo "  Vault HA Cluster Initialization"
    echo "======================================================================"
    echo ""

    check_prerequisites

    # Wait for all containers to be ready
    print_info "=== Waiting for containers to start ==="
    for node in vault-0 vault-1 vault-2; do
        wait_for_container $node
    done

    sleep 5  # Extra wait for retry_join to settle

    # Initialize the cluster
    init_cluster

    # Unseal the leader first
    print_info "=== Phase 2: Unsealing leader node ==="
    unseal_node vault-0

    # Join and unseal follower nodes
    print_info "=== Phase 3: Joining and unsealing follower nodes ==="

    print_info "Processing vault-1..."
    if join_node_to_cluster vault-1 vault-0; then
        unseal_node vault-1
    else
        print_error "Failed to join vault-1 to cluster. Aborting."
        exit 1
    fi

    print_info "Processing vault-2..."
    if join_node_to_cluster vault-2 vault-0; then
        unseal_node vault-2
    else
        print_error "Failed to join vault-2 to cluster. Aborting."
        exit 1
    fi

    # Verify cluster formation
    if ! verify_cluster; then
        print_error "Cluster verification failed"
        exit 1
    fi

    # Display access information
    echo ""
    echo "======================================================================"
    print_success "Vault HA cluster initialized successfully!"
    echo "======================================================================"
    echo ""
    echo "Access Information:"
    echo "  vault-0: http://localhost:18200"
    echo "  vault-1: http://localhost:18201"
    echo "  vault-2: http://localhost:18202"
    echo ""
    echo "Root Token: $ROOT_TOKEN"
    echo ""
    echo "Unseal keys saved in: vault-keys.json"
    echo ""
    print_warning "IMPORTANT: Store vault-keys.json securely and never commit to git!"
    echo ""
    echo "To access Vault CLI:"
    echo "  export VAULT_ADDR=http://localhost:18200"
    echo "  export VAULT_TOKEN=$ROOT_TOKEN"
    echo "  vault status"
    echo ""
    echo "To access Vault UI:"
    echo "  Open: http://localhost:18200/ui"
    echo "  Token: $ROOT_TOKEN"
    echo ""
}

main "$@"
