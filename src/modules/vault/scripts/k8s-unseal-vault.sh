#!/usr/bin/env bash
# Vault Unseal Script for Kubernetes
# This script unseals all Vault pods by retrieving keys from Kubernetes Secret
# Designed to run after pod restarts or cluster failures

set -euo pipefail

# Configuration from environment variables
NAMESPACE="${VAULT_NAMESPACE:-vault}"
RELEASE_NAME="${VAULT_RELEASE:-vault}"
SECRET_NAME="${VAULT_SECRET_NAME:-vault-unseal-keys}"
KEY_THRESHOLD="${VAULT_KEY_THRESHOLD:-3}"
MAX_RETRY="${MAX_RETRY_ATTEMPTS:-5}"
POD_TIMEOUT="${POD_TIMEOUT:-120}"
DEBUG="${DEBUG:-false}"

# Color definitions for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_with_timestamp() {
    local level=$1
    shift
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

print_info() {
    log_with_timestamp "INFO" "${BLUE}[INFO]${NC} $1"
}

print_success() {
    log_with_timestamp "SUCCESS" "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    log_with_timestamp "WARNING" "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    log_with_timestamp "ERROR" "${RED}[ERROR]${NC} $1"
}

print_debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        log_with_timestamp "DEBUG" "[DEBUG] $1"
    fi
}

# Retry helper function with exponential backoff
retry_command() {
    local max_attempts=$1
    shift
    local cmd=("$@")
    local attempt=1
    local delay=2

    while [ $attempt -le $max_attempts ]; do
        print_debug "Attempt $attempt/$max_attempts: ${cmd[*]}"

        if "${cmd[@]}"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            print_warning "Command failed, retrying in ${delay}s... (attempt $attempt/$max_attempts)"
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
            attempt=$((attempt + 1))
        else
            print_error "Command failed after $max_attempts attempts"
            return 1
        fi
    done
}

# Cleanup function for error handling
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Script failed with exit code: $exit_code"
    fi
}

trap cleanup_on_error EXIT

# Validate environment variables
validate_environment() {
    print_info "Validating environment variables..."

    local required_vars=("NAMESPACE" "RELEASE_NAME" "SECRET_NAME" "KEY_THRESHOLD")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        print_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi

    # Validate numeric values
    if ! [[ "$KEY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$KEY_THRESHOLD" -lt 1 ]; then
        print_error "KEY_THRESHOLD must be a positive integer"
        exit 1
    fi

    print_success "Environment validation passed"
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

    # Verify kubectl can access cluster (list pods in namespace)
    if ! kubectl get pods -n "${NAMESPACE}" &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster or access namespace '${NAMESPACE}'"
        exit 1
    fi

    print_success "Prerequisites check passed"
}

# Check if Kubernetes Secret exists
check_secret_exists() {
    print_info "Checking for initialization secret..."

    if ! retry_command ${MAX_RETRY} kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        print_error "Secret '${SECRET_NAME}' not found in namespace '${NAMESPACE}'"
        print_error "Run k8s-init-vault.sh first to initialize the cluster"
        exit 1
    fi

    print_success "Secret ${SECRET_NAME} found"
}

# Retrieve and decode secret data
get_vault_secret() {
    print_info "Retrieving unseal keys from secret..."

    local secret_data
    if ! secret_data=$(retry_command ${MAX_RETRY} kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o json 2>&1); then
        print_error "Failed to retrieve secret ${SECRET_NAME}"
        print_error "Error: ${secret_data}"
        exit 1
    fi

    # Decode unseal keys
    local unseal_keys_b64
    unseal_keys_b64=$(echo "${secret_data}" | jq -r '.data.unseal_keys_b64' | base64 -d 2>/dev/null || echo "")

    if [[ -z "${unseal_keys_b64}" || "${unseal_keys_b64}" == "null" ]]; then
        print_error "Failed to decode unseal_keys_b64 from secret"
        exit 1
    fi

    # Validate key array length
    local key_count
    key_count=$(echo "${unseal_keys_b64}" | jq '. | length' 2>/dev/null || echo "0")

    print_debug "Found ${key_count} unseal keys in secret"

    if [[ ${key_count} -lt ${KEY_THRESHOLD} ]]; then
        print_error "Not enough keys in secret. Need ${KEY_THRESHOLD}, found ${key_count}"
        exit 1
    fi

    # Also get key threshold from secret if available
    local stored_threshold
    stored_threshold=$(echo "${secret_data}" | jq -r '.data.key_threshold' | base64 -d 2>/dev/null || echo "")

    if [[ -n "${stored_threshold}" && "${stored_threshold}" != "null" ]]; then
        if [[ "${stored_threshold}" != "${KEY_THRESHOLD}" ]]; then
            print_warning "KEY_THRESHOLD (${KEY_THRESHOLD}) differs from stored value (${stored_threshold})"
            print_warning "Using stored value: ${stored_threshold}"
            KEY_THRESHOLD="${stored_threshold}"
        fi
    fi

    print_success "Retrieved unseal keys from secret"

    # Export for use in unsealing
    export UNSEAL_KEYS="${unseal_keys_b64}"
}

# Get replica count
get_replica_count() {
    local replicas
    replicas=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    echo "${replicas}"
}

# Check if pod is sealed
is_pod_sealed() {
    local pod=$1

    if ! kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
        print_debug "Pod ${pod} does not exist"
        return 1
    fi

    # Get vault status output (text format is more reliable than JSON when sealed)
    local status_output
    status_output=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status 2>&1 || true)

    # Parse the "Sealed" field from the output
    local sealed
    sealed=$(echo "${status_output}" | grep -E "^Sealed" | awk '{print $2}' || echo "")

    print_debug "Pod ${pod} sealed status: '${sealed}'"

    if [[ "${sealed}" == "true" ]]; then
        return 0  # Pod is sealed
    elif [[ "${sealed}" == "false" ]]; then
        return 1  # Pod is not sealed
    else
        # Unable to determine status, assume sealed to be safe
        print_debug "Could not determine sealed status for ${pod}, assuming sealed"
        return 0
    fi
}

# Unseal a single pod
unseal_pod() {
    local pod=$1

    print_info "Processing pod: ${pod}..."

    # Check if pod exists and is running
    if ! kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
        print_warning "Pod ${pod} does not exist, skipping"
        return 1
    fi

    local pod_status
    pod_status=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

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

    # Extract unseal keys from environment variable
    local keys=()
    for ((i=0; i<KEY_THRESHOLD; i++)); do
        local key
        key=$(echo "${UNSEAL_KEYS}" | jq -r ".[${i}]")

        if [[ -z "${key}" || "${key}" == "null" ]]; then
            print_error "Invalid or missing unseal key at index ${i}"
            return 1
        fi

        keys+=("${key}")
    done

    # Unseal with threshold number of keys
    local unseal_count=0
    for key in "${keys[@]}"; do
        if retry_command 3 kubectl -n "${NAMESPACE}" exec "${pod}" -- \
            vault operator unseal "${key}" > /dev/null 2>&1; then
            unseal_count=$((unseal_count + 1))
        else
            print_error "Failed to apply unseal key to ${pod}"
            return 1
        fi
    done

    # Verify unsealed
    if ! is_pod_sealed "${pod}"; then
        print_success "Pod ${pod} unsealed successfully"
        return 0
    else
        print_error "Pod ${pod} still sealed after applying ${unseal_count} keys"
        return 1
    fi
}

# Join follower node to Raft cluster (if not already a member)
join_follower_to_raft() {
    local follower_pod=$1
    local leader_pod="${RELEASE_NAME}-0"

    # Skip if this is the leader pod
    if [[ "${follower_pod}" == "${leader_pod}" ]]; then
        print_debug "${follower_pod} is the leader, skipping join"
        return 0
    fi

    print_info "Checking if ${follower_pod} needs to join Raft cluster..."

    # Check if already a member using raft_joined status
    local is_member
    is_member=$(kubectl -n "${NAMESPACE}" exec "${follower_pod}" -- \
        vault status -format=json 2>/dev/null | jq -r '.raft_joined' || echo "false")

    if [[ "${is_member}" == "true" ]]; then
        print_debug "${follower_pod} is already a member of the Raft cluster"
        return 0
    fi

    # Get leader address
    local leader_addr="http://${leader_pod}.${RELEASE_NAME}-internal:8200"

    print_info "Joining ${follower_pod} to Raft cluster..."

    # Attempt to join the Raft cluster
    local join_output
    if join_output=$(kubectl -n "${NAMESPACE}" exec "${follower_pod}" -- \
        vault operator raft join "${leader_addr}" 2>&1); then
        print_success "${follower_pod} joined Raft cluster successfully"

        # Wait for cluster sync
        sleep 2
        return 0
    else
        # Check if error is due to already being a member
        if echo "${join_output}" | grep -q "node already part of cluster\|already joined"; then
            print_debug "${follower_pod} is already a member of the Raft cluster"
            return 0
        else
            print_warning "Failed to join ${follower_pod} to Raft cluster"
            print_debug "Join output: ${join_output}"
            return 1
        fi
    fi
}

# Unseal all pods
unseal_all_pods() {
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Unsealing Vault pods ==="
    print_info "Found ${replicas} replica(s)"

    local unsealed_count=0
    local already_unsealed=0
    local failed_count=0
    local skipped_count=0

    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"

        # Check if pod is already unsealed before attempting
        if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
            if ! is_pod_sealed "${pod}"; then
                print_info "Pod ${pod} is already unsealed, skipping"
                already_unsealed=$((already_unsealed + 1))
                continue
            fi
        fi

        if unseal_pod "${pod}"; then
            unsealed_count=$((unsealed_count + 1))

            # Join to Raft cluster if this is a follower node (not vault-0)
            if [[ "${pod}" != "${RELEASE_NAME}-0" ]]; then
                if join_follower_to_raft "${pod}"; then
                    print_debug "${pod} successfully joined to Raft cluster"
                else
                    print_warning "${pod} unsealed but may not be joined to cluster"
                fi
            fi
        else
            if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
                local pod_status
                pod_status=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}')
                if [[ "${pod_status}" == "Running" ]]; then
                    failed_count=$((failed_count + 1))
                else
                    skipped_count=$((skipped_count + 1))
                fi
            else
                skipped_count=$((skipped_count + 1))
            fi
        fi
    done

    echo ""
    echo "======================================================================"
    print_info "Unseal Summary:"
    echo "  Total replicas:     ${replicas}"
    echo "  Already unsealed:   ${already_unsealed}"
    echo "  Newly unsealed:     ${unsealed_count}"
    echo "  Failed:             ${failed_count}"
    echo "  Skipped:            ${skipped_count}"
    echo "======================================================================"
    echo ""

    local total_unsealed=$((already_unsealed + unsealed_count))
    if [[ ${total_unsealed} -gt 0 ]]; then
        return 0
    else
        return 1
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
            kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status 2>/dev/null || \
                print_warning "Could not get status for ${pod}"
        fi
    done

    # If HA mode, show Raft peers
    if [[ ${replicas} -gt 1 ]]; then
        echo ""
        print_info "=== Raft Cluster Peers ==="

        # Try to get root token from secret
        local root_token
        root_token=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")

        if [[ -n "${root_token}" ]]; then
            kubectl -n "${NAMESPACE}" exec "${RELEASE_NAME}-0" -- \
                env VAULT_TOKEN="${root_token}" vault operator raft list-peers 2>/dev/null || \
                print_warning "Unable to list Raft peers (authentication may be required)"
        else
            print_warning "Cannot list Raft peers - root token not available"
            echo ""
            print_info "To manually check cluster peers, run:"
            echo "  ROOT_TOKEN=\$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.root_token}' | base64 -d)"
            echo "  kubectl exec -n ${NAMESPACE} ${RELEASE_NAME}-0 -- env VAULT_TOKEN=\$ROOT_TOKEN vault operator raft list-peers"
        fi
    fi
}

# Main execution
main() {
    echo ""
    echo "======================================================================"
    echo "  Vault Unseal Script for Kubernetes"
    echo "======================================================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:        ${NAMESPACE}"
    echo "  Release Name:     ${RELEASE_NAME}"
    echo "  Secret Name:      ${SECRET_NAME}"
    echo "  Key Threshold:    ${KEY_THRESHOLD}"
    echo "  Max Retries:      ${MAX_RETRY}"
    echo "  Pod Timeout:      ${POD_TIMEOUT}s"
    echo "  Debug Mode:       ${DEBUG}"
    echo ""

    validate_environment
    check_prerequisites
    check_secret_exists
    get_vault_secret

    if unseal_all_pods; then
        print_success "Unseal operation completed successfully!"
    else
        print_warning "Some pods could not be unsealed"
    fi

    display_status

    echo ""
    print_info "To access Vault:"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME} 8200:8200"
    echo "  export VAULT_ADDR=http://localhost:8200"
    echo "  export VAULT_TOKEN=\$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.root_token}' | base64 -d)"
    echo "  vault status"
    echo ""
}

main "$@"
