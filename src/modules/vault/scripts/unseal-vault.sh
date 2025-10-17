#!/usr/bin/env bash
# Vault Unseal Script for Kubernetes
# This script unseals all Vault pods in a Kubernetes cluster
# Run this after pod restarts or cluster failures

set -euo pipefail

# Default values
NAMESPACE="${VAULT_NAMESPACE:-vault}"
RELEASE_NAME="${VAULT_RELEASE:-vault}"
KEYS_FILE="${VAULT_KEYS_FILE:-vault-keys.json}"
KEY_THRESHOLD="${VAULT_KEY_THRESHOLD:-3}"

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
        print_error "jq is required for parsing unseal keys"
        exit 1
    fi

    if [[ ! -f "${KEYS_FILE}" ]]; then
        print_error "Keys file not found: ${KEYS_FILE}"
        print_error "Run init-vault.sh first to initialize the cluster"
        exit 1
    fi

    # Check if namespace exists
    if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
        print_error "Namespace '${NAMESPACE}' does not exist"
        exit 1
    fi

    print_success "Prerequisites check passed"
}

# Get number of replicas
get_replica_count() {
    local replicas
    replicas=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    echo "${replicas}"
}

# Check if pod is sealed
is_pod_sealed() {
    local pod=$1

    if ! kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
        return 1
    fi

    # Get vault status output (text format is more reliable than JSON when sealed)
    local status_output
    status_output=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status 2>&1 || true)

    # Parse the "Sealed" field from the output
    local sealed
    sealed=$(echo "${status_output}" | grep -E "^Sealed" | awk '{print $2}' || echo "")

    # Debug: show what we got
    # Uncomment for troubleshooting: echo "[DEBUG] Pod ${pod} sealed status: '${sealed}'" >&2

    if [[ "${sealed}" == "true" ]]; then
        return 0  # Pod is sealed
    elif [[ "${sealed}" == "false" ]]; then
        return 1  # Pod is not sealed
    else
        # Unable to determine status, assume sealed to be safe
        return 0
    fi
}

# Unseal a single pod
unseal_pod() {
    local pod=$1

    # Check if pod exists and is running
    if ! kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
        print_warning "Pod ${pod} does not exist, skipping"
        return 1
    fi

    local pod_status
    pod_status=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}')
    if [[ "${pod_status}" != "Running" ]]; then
        print_warning "Pod ${pod} is not running (status: ${pod_status}), skipping"
        return 1
    fi

    # Check if already unsealed
    if ! is_pod_sealed "${pod}"; then
        print_info "Pod ${pod} is already unsealed"
        return 0
    fi

    print_info "Unsealing pod ${pod}..."

    # Extract unseal keys from JSON
    local unseal_keys=()
    for ((i=0; i<KEY_THRESHOLD; i++)); do
        local key
        key=$(jq -r ".unseal_keys_b64[${i}]" "${KEYS_FILE}")
        unseal_keys+=("${key}")
    done

    # Unseal with threshold number of keys
    for key in "${unseal_keys[@]}"; do
        if ! kubectl -n "${NAMESPACE}" exec "${pod}" -- vault operator unseal "${key}" > /dev/null 2>&1; then
            print_error "Failed to unseal ${pod} with key"
            return 1
        fi
    done

    # Verify unsealed
    if ! is_pod_sealed "${pod}"; then
        print_success "Pod ${pod} unsealed successfully"
        return 0
    else
        print_error "Pod ${pod} still sealed after unseal attempt"
        return 1
    fi
}

# Unseal all pods
unseal_all_pods() {
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Unsealing Vault pods ==="
    print_info "Found ${replicas} replica(s)"

    local unsealed_count=0
    local failed_count=0
    local skipped_count=0

    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"

        if unseal_pod "${pod}"; then
            unsealed_count=$((unsealed_count + 1))
        else
            if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
                failed_count=$((failed_count + 1))
            else
                skipped_count=$((skipped_count + 1))
            fi
        fi
    done

    echo ""
    echo "======================================================================"
    print_info "Unseal Summary:"
    echo "  Total replicas:  ${replicas}"
    echo "  Unsealed:        ${unsealed_count}"
    echo "  Failed:          ${failed_count}"
    echo "  Skipped:         ${skipped_count}"
    echo "======================================================================"

    if [[ ${failed_count} -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# Display cluster status
display_status() {
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Cluster Status ==="

    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"

        if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
            echo ""
            print_info "Status of ${pod}:"
            kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status || true
        fi
    done

    # If HA mode, show Raft peers
    if [[ ${replicas} -gt 1 ]]; then
        echo ""
        print_info "=== Raft Cluster Peers ==="

        local root_token
        if [[ -f "${KEYS_FILE}" ]]; then
            root_token=$(jq -r '.root_token' "${KEYS_FILE}")
            kubectl -n "${NAMESPACE}" exec "${RELEASE_NAME}-0" -- \
                env VAULT_TOKEN="${root_token}" vault operator raft list-peers 2>/dev/null || \
                print_warning "Unable to list Raft peers (authentication may be required)"
        else
            print_warning "Cannot list Raft peers - keys file not found"
        fi
    fi
}

# Main execution
main() {
    echo ""
    echo "======================================================================"
    echo "  Vault Unseal Script (Kubernetes)"
    echo "======================================================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:     ${NAMESPACE}"
    echo "  Release Name:  ${RELEASE_NAME}"
    echo "  Keys File:     ${KEYS_FILE}"
    echo "  Key Threshold: ${KEY_THRESHOLD}"
    echo ""

    check_prerequisites

    if unseal_all_pods; then
        print_success "All pods unsealed successfully!"
    else
        print_warning "Some pods failed to unseal"
    fi

    display_status

    echo ""
    print_info "To access Vault:"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME} 8200:8200"
    echo "  export VAULT_ADDR=http://localhost:8200"
    echo "  export VAULT_TOKEN=\$(jq -r '.root_token' ${KEYS_FILE})"
    echo ""
}

main "$@"
