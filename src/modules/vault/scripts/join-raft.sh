#!/usr/bin/env bash
# Vault Raft Join Script for Kubernetes
# This script manually joins a Vault pod to an existing Raft cluster
# Useful when retry_join fails or when adding new nodes

set -euo pipefail

# Default values
NAMESPACE="${VAULT_NAMESPACE:-vault}"
RELEASE_NAME="${VAULT_RELEASE:-vault}"
LEADER_POD="${VAULT_LEADER:-${RELEASE_NAME}-0}"

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

# Usage information
usage() {
    echo "Usage: $0 [OPTIONS] <follower-pod>"
    echo ""
    echo "Join a Vault pod to an existing Raft cluster"
    echo ""
    echo "Arguments:"
    echo "  <follower-pod>    Name of the pod to join to the cluster"
    echo ""
    echo "Options:"
    echo "  -n, --namespace   Kubernetes namespace (default: ${NAMESPACE})"
    echo "  -r, --release     Helm release name (default: ${RELEASE_NAME})"
    echo "  -l, --leader      Leader pod name (default: ${LEADER_POD})"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 vault-1"
    echo "  $0 -n vault -l vault-0 vault-2"
    echo ""
    exit 1
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--release)
                RELEASE_NAME="$2"
                shift 2
                ;;
            -l|--leader)
                LEADER_POD="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            -*)
                print_error "Unknown option: $1"
                usage
                ;;
            *)
                if [[ -z "${FOLLOWER_POD:-}" ]]; then
                    FOLLOWER_POD="$1"
                else
                    print_error "Too many arguments"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${FOLLOWER_POD:-}" ]]; then
        print_error "Missing required argument: follower-pod"
        usage
    fi
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    # Check if namespace exists
    if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
        print_error "Namespace '${NAMESPACE}' does not exist"
        exit 1
    fi

    # Check if leader pod exists and is running
    if ! kubectl -n "${NAMESPACE}" get pod "${LEADER_POD}" &> /dev/null; then
        print_error "Leader pod '${LEADER_POD}' does not exist"
        exit 1
    fi

    local leader_status
    leader_status=$(kubectl -n "${NAMESPACE}" get pod "${LEADER_POD}" -o jsonpath='{.status.phase}')
    if [[ "${leader_status}" != "Running" ]]; then
        print_error "Leader pod '${LEADER_POD}' is not running (status: ${leader_status})"
        exit 1
    fi

    # Check if follower pod exists and is running
    if ! kubectl -n "${NAMESPACE}" get pod "${FOLLOWER_POD}" &> /dev/null; then
        print_error "Follower pod '${FOLLOWER_POD}' does not exist"
        exit 1
    fi

    local follower_status
    follower_status=$(kubectl -n "${NAMESPACE}" get pod "${FOLLOWER_POD}" -o jsonpath='{.status.phase}')
    if [[ "${follower_status}" != "Running" ]]; then
        print_error "Follower pod '${FOLLOWER_POD}' is not running (status: ${follower_status})"
        exit 1
    fi

    print_success "Prerequisites check passed"
}

# Check if pod is already initialized
is_pod_initialized() {
    local pod=$1

    local initialized
    initialized=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

    if [[ "${initialized}" == "true" ]]; then
        return 0  # Pod is initialized
    else
        return 1  # Pod is not initialized
    fi
}

# Get leader address
get_leader_address() {
    local leader_api_addr="http://${LEADER_POD}.${RELEASE_NAME}-internal:8200"
    echo "${leader_api_addr}"
}

# Join pod to Raft cluster
join_raft_cluster() {
    local leader_addr
    leader_addr=$(get_leader_address)

    print_info "=== Joining ${FOLLOWER_POD} to Raft cluster ==="
    print_info "Leader address: ${leader_addr}"

    # Check if follower is already initialized
    if is_pod_initialized "${FOLLOWER_POD}"; then
        print_warning "${FOLLOWER_POD} is already initialized (already in cluster)"
        print_info "If you need to rejoin, you must first remove the pod from the cluster"
        return 1
    fi

    # Join the cluster
    print_info "Joining ${FOLLOWER_POD} to cluster via ${LEADER_POD}..."

    if kubectl -n "${NAMESPACE}" exec "${FOLLOWER_POD}" -- \
        vault operator raft join "${leader_addr}"; then
        print_success "${FOLLOWER_POD} joined the cluster successfully"

        # Wait for cluster sync
        print_info "Waiting for cluster synchronization..."
        sleep 3

        return 0
    else
        print_error "Failed to join ${FOLLOWER_POD} to cluster"
        print_info "Checking leader status..."
        kubectl -n "${NAMESPACE}" exec "${LEADER_POD}" -- vault status || true
        return 1
    fi
}

# Verify cluster membership
verify_membership() {
    print_info "=== Verifying cluster membership ==="

    # Check follower status
    print_info "Checking ${FOLLOWER_POD} status..."
    if kubectl -n "${NAMESPACE}" exec "${FOLLOWER_POD}" -- vault status; then
        print_success "${FOLLOWER_POD} is operational"
    else
        print_warning "${FOLLOWER_POD} may need to be unsealed"
    fi

    echo ""
}

# Display cluster information
display_cluster_info() {
    print_info "=== Raft Cluster Peers ==="

    # Try to list Raft peers (requires authentication)
    print_info "Attempting to list Raft peers from ${LEADER_POD}..."
    print_warning "Note: This command requires VAULT_TOKEN to be set on the leader pod"
    echo ""

    if kubectl -n "${NAMESPACE}" exec "${LEADER_POD}" -- vault operator raft list-peers 2>/dev/null; then
        print_success "Cluster information retrieved successfully"
    else
        print_warning "Unable to list Raft peers (authentication required)"
        echo ""
        print_info "To manually check cluster peers, run:"
        echo "  kubectl exec -n ${NAMESPACE} ${LEADER_POD} -- \\"
        echo "    env VAULT_TOKEN=<your-token> vault operator raft list-peers"
    fi
}

# Main execution
main() {
    parse_args "$@"

    echo ""
    echo "======================================================================"
    echo "  Vault Raft Join Script (Kubernetes)"
    echo "======================================================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:     ${NAMESPACE}"
    echo "  Release Name:  ${RELEASE_NAME}"
    echo "  Leader Pod:    ${LEADER_POD}"
    echo "  Follower Pod:  ${FOLLOWER_POD}"
    echo ""

    check_prerequisites

    if join_raft_cluster; then
        verify_membership
        display_cluster_info

        echo ""
        print_success "Raft join operation completed!"
        echo ""
        print_info "Next steps:"
        echo "  1. Unseal ${FOLLOWER_POD} using the unseal-vault.sh script"
        echo "  2. Verify cluster status with Raft list-peers command"
        echo ""
    else
        print_error "Raft join operation failed"
        exit 1
    fi
}

main "$@"
