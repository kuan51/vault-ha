#!/usr/bin/env bash
# Vault HA Cluster Initialization Script for Kubernetes
# This script initializes a Vault HA cluster running in Kubernetes with Raft storage

set -euo pipefail

# Default values
NAMESPACE="${VAULT_NAMESPACE:-vault}"
RELEASE_NAME="${VAULT_RELEASE:-vault}"
KEY_SHARES="${VAULT_KEY_SHARES:-5}"
KEY_THRESHOLD="${VAULT_KEY_THRESHOLD:-3}"
OUTPUT_FILE="${VAULT_KEYS_FILE:-vault-keys.json}"

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

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

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed. Install it for better JSON parsing"
    fi

    # Check if namespace exists
    if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
        print_error "Namespace '${NAMESPACE}' does not exist"
        exit 1
    fi

    print_success "Prerequisites check passed"
}

# Wait for pod to be ready
wait_for_pod() {
    local pod=$1
    local max_wait=120
    local elapsed=0

    print_info "Waiting for pod ${pod} to be ready..."

    while [ $elapsed -lt $max_wait ]; do
        if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
            local status
            status=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}')
            if [[ "${status}" == "Running" ]]; then
                print_success "Pod ${pod} is ready"
                return 0
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    print_error "Pod ${pod} failed to become ready after ${max_wait}s"
    return 1
}

# Get number of replicas
get_replica_count() {
    local replicas
    replicas=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    echo "${replicas}"
}

# Initialize Vault
init_vault() {
    local leader_pod="${RELEASE_NAME}-0"

    print_info "=== Phase 1: Initializing Vault cluster ==="

    # Wait for leader pod
    if ! wait_for_pod "${leader_pod}"; then
        print_error "Failed to wait for leader pod"
        exit 1
    fi

    # Check if already initialized
    if kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- vault status &> /dev/null; then
        local initialized
        initialized=$(kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

        if [[ "${initialized}" == "true" ]]; then
            print_warning "Vault is already initialized"
            if [[ ! -f "${OUTPUT_FILE}" ]]; then
                print_error "Vault is initialized but ${OUTPUT_FILE} not found"
                print_error "Cannot proceed without unseal keys"
                exit 1
            fi
            return 0
        fi
    fi

    # Initialize Vault
    print_info "Initializing Vault with ${KEY_SHARES} key shares and ${KEY_THRESHOLD} threshold"
    if kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
        vault operator init \
        -key-shares="${KEY_SHARES}" \
        -key-threshold="${KEY_THRESHOLD}" \
        -format=json > "${OUTPUT_FILE}"; then
        print_success "Vault initialized successfully"
        print_info "Unseal keys and root token saved to: ${OUTPUT_FILE}"
    else
        print_error "Failed to initialize Vault"
        exit 1
    fi
}

# Unseal a single pod
unseal_pod() {
    local pod=$1

    print_info "Unsealing pod ${pod}..."

    # Validate that we have enough keys
    local total_keys
    total_keys=$(jq -r '.unseal_keys_b64 | length' "${OUTPUT_FILE}")

    if [[ ${total_keys} -lt ${KEY_THRESHOLD} ]]; then
        print_error "Not enough keys in ${OUTPUT_FILE}. Need ${KEY_THRESHOLD}, found ${total_keys}"
        exit 1
    fi

    # Extract and apply threshold number of keys dynamically
    for ((i=0; i<KEY_THRESHOLD; i++)); do
        local key
        key=$(jq -r ".unseal_keys_b64[${i}]" "${OUTPUT_FILE}")

        if [[ -z "${key}" || "${key}" == "null" ]]; then
            print_error "Invalid key at index ${i}"
            exit 1
        fi

        if ! kubectl -n "${NAMESPACE}" exec "${pod}" -- vault operator unseal "${key}" > /dev/null 2>&1; then
            print_error "Failed to apply unseal key ${i} to ${pod}"
            exit 1
        fi
    done

    # Verify unsealed
    local sealed
    sealed=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status -format=json 2>/dev/null | jq -r '.sealed')

    if [[ "${sealed}" == "false" ]]; then
        print_success "Pod ${pod} unsealed successfully"
    else
        print_error "Pod ${pod} still sealed after unseal attempt"
        exit 1
    fi
}

# Unseal all pods
unseal_cluster() {
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Phase 2: Unsealing all Vault pods ==="
    print_info "Found ${replicas} replica(s)"

    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"

        # Wait for pod to be ready
        if wait_for_pod "${pod}"; then
            unseal_pod "${pod}"
        else
            print_warning "Skipping ${pod} - not ready"
        fi
    done
}

# Verify cluster status
verify_cluster() {
    local leader_pod="${RELEASE_NAME}-0"
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Phase 3: Verifying cluster status ==="

    # Get root token
    local root_token
    if command -v jq &> /dev/null; then
        root_token=$(jq -r '.root_token' "${OUTPUT_FILE}")
    else
        print_error "jq is required to extract root token"
        exit 1
    fi

    # Check seal status of all pods
    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"
        print_info "Checking status of ${pod}..."
        kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status || true
        echo ""
    done

    # Check Raft cluster members (if HA mode)
    if [[ ${replicas} -gt 1 ]]; then
        print_info "Checking Raft cluster members..."
        if kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
            env VAULT_TOKEN="${root_token}" vault operator raft list-peers; then
            print_success "Raft cluster is healthy"
        else
            print_warning "Failed to list Raft peers - cluster may not be fully formed yet"
        fi
    fi

    print_success "Cluster verification complete"
}

# Display access information
display_info() {
    local root_token
    if command -v jq &> /dev/null; then
        root_token=$(jq -r '.root_token' "${OUTPUT_FILE}")
    fi

    echo ""
    echo "======================================================================"
    print_success "Vault cluster initialized and unsealed successfully!"
    echo "======================================================================"
    echo ""
    echo "Access Information:"
    echo "  Namespace: ${NAMESPACE}"
    echo "  Release:   ${RELEASE_NAME}"
    echo "  Replicas:  $(get_replica_count)"
    echo ""
    echo "Root Token: ${root_token}"
    echo ""
    echo "Unseal keys saved in: ${OUTPUT_FILE}"
    echo ""
    print_warning "IMPORTANT: Store ${OUTPUT_FILE} securely and never commit to git!"
    echo ""
    echo "To access Vault:"
    echo "  # Port-forward to Vault service"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME} 8200:8200"
    echo ""
    echo "  # Set environment variables"
    echo "  export VAULT_ADDR=http://localhost:8200"
    echo "  export VAULT_TOKEN=${root_token}"
    echo "  vault status"
    echo ""
}

# Main execution
main() {
    echo ""
    echo "======================================================================"
    echo "  Vault HA Cluster Initialization (Kubernetes)"
    echo "======================================================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:     ${NAMESPACE}"
    echo "  Release Name:  ${RELEASE_NAME}"
    echo "  Key Shares:    ${KEY_SHARES}"
    echo "  Key Threshold: ${KEY_THRESHOLD}"
    echo "  Output File:   ${OUTPUT_FILE}"
    echo ""

    check_prerequisites
    init_vault
    unseal_cluster
    verify_cluster
    display_info
}

main "$@"
