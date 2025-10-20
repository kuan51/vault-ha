#!/usr/bin/env bash
# Vault Auto-Initialization Script for Kubernetes
# This script initializes a Vault HA cluster and stores unseal keys in Kubernetes Secret
# Designed to run in a Kubernetes Job with proper RBAC permissions

set -euo pipefail

# Configuration from environment variables
NAMESPACE="${VAULT_NAMESPACE:-vault}"
RELEASE_NAME="${VAULT_RELEASE:-vault}"
KEY_SHARES="${VAULT_KEY_SHARES:-5}"
KEY_THRESHOLD="${VAULT_KEY_THRESHOLD:-3}"
SECRET_NAME="${VAULT_SECRET_NAME:-vault-unseal-keys}"
AUTO_UNSEAL="${AUTO_UNSEAL:-true}"
MAX_RETRY="${MAX_RETRY_ATTEMPTS:-5}"
OPERATION_TIMEOUT="${OPERATION_TIMEOUT:-300}"
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
    log_with_timestamp "${BLUE}INFO${NC}" "$1"
}

print_success() {
    log_with_timestamp "${GREEN}SUCCESS${NC}" "$1"
}

print_warning() {
    log_with_timestamp "${YELLOW}WARNING${NC}" "$1"
}

print_error() {
    log_with_timestamp "${RED}ERROR${NC}" "$1"
}

print_debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        log_with_timestamp "DEBUG" "$1"
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
        print_info "Check logs above for details"
    fi
}

trap cleanup_on_error EXIT

# Validate environment variables
validate_environment() {
    print_info "Validating environment variables..."

    local required_vars=("NAMESPACE" "RELEASE_NAME" "SECRET_NAME" "KEY_SHARES" "KEY_THRESHOLD")
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
    if ! [[ "$KEY_SHARES" =~ ^[0-9]+$ ]] || [ "$KEY_SHARES" -lt 1 ]; then
        print_error "KEY_SHARES must be a positive integer"
        exit 1
    fi

    if ! [[ "$KEY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$KEY_THRESHOLD" -lt 1 ]; then
        print_error "KEY_THRESHOLD must be a positive integer"
        exit 1
    fi

    if [ "$KEY_THRESHOLD" -gt "$KEY_SHARES" ]; then
        print_error "KEY_THRESHOLD ($KEY_THRESHOLD) cannot be greater than KEY_SHARES ($KEY_SHARES)"
        exit 1
    fi

    print_success "Environment validation passed"
}

# Configure kubectl for in-cluster access
configure_kubectl() {
    print_info "Configuring kubectl for in-cluster access..."

    # ServiceAccount token and CA certificate are mounted by Kubernetes
    local token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
    local ca_file="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    local k8s_server="https://kubernetes.default.svc"

    # Verify ServiceAccount files exist
    if [[ ! -f "${token_file}" ]]; then
        print_error "ServiceAccount token not found at ${token_file}"
        exit 1
    fi

    if [[ ! -f "${ca_file}" ]]; then
        print_error "ServiceAccount CA certificate not found at ${ca_file}"
        exit 1
    fi

    # Configure kubectl cluster
    if ! kubectl config set-cluster kubernetes \
        --server="${k8s_server}" \
        --certificate-authority="${ca_file}" &>/dev/null; then
        print_error "Failed to configure kubectl cluster"
        exit 1
    fi

    # Configure kubectl credentials
    if ! kubectl config set-credentials serviceaccount \
        --token="$(cat "${token_file}")" &>/dev/null; then
        print_error "Failed to configure kubectl credentials"
        exit 1
    fi

    # Configure kubectl context
    if ! kubectl config set-context default \
        --cluster=kubernetes \
        --user=serviceaccount \
        --namespace="${NAMESPACE}" &>/dev/null; then
        print_error "Failed to configure kubectl context"
        exit 1
    fi

    # Use the context
    if ! kubectl config use-context default &>/dev/null; then
        print_error "Failed to use kubectl context"
        exit 1
    fi

    print_success "kubectl configured successfully for in-cluster access"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed or not in PATH"
        exit 1
    fi

    # Verify kubectl can access cluster (list pods in namespace)
    if ! kubectl get pods -n "${NAMESPACE}" &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster or access namespace '${NAMESPACE}'"
        exit 1
    fi

    # Verify RBAC permissions
    print_debug "Verifying RBAC permissions..."
    if ! kubectl auth can-i create pods/exec -n "${NAMESPACE}" &> /dev/null; then
        print_warning "May not have permission to exec into pods"
    fi

    print_success "Prerequisites check passed"
}

# Check if Kubernetes Secret exists
secret_exists() {
    retry_command 3 kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null
}

# Check if Vault is already initialized
is_vault_initialized() {
    local leader_pod="${RELEASE_NAME}-0"

    print_debug "Checking if Vault is initialized on ${leader_pod}..."

    local initialized
    initialized=$(kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
        vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

    print_debug "Vault initialized status: ${initialized}"

    if [[ "${initialized}" == "true" ]]; then
        return 0  # Already initialized
    else
        return 1  # Not initialized
    fi
}

# Wait for pod to be ready
wait_for_pod() {
    local pod=$1
    local max_wait=${OPERATION_TIMEOUT}
    local elapsed=0

    print_info "Waiting for pod ${pod} to be ready (timeout: ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
            local status
            status=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}')

            if [[ "${status}" == "Running" ]]; then
                # Check if Vault process is responsive (accepts commands even when sealed/uninitialized)
                # Capture output first to avoid pipefail issues with kubectl exit codes
                local vault_status
                vault_status=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status 2>&1 || true)

                # Check if we got valid output from vault
                if echo "${vault_status}" | grep -q -e "Seal Type" -e "Sealed" -e "Initialized"; then
                    # Vault is responsive (could be sealed, unsealed, initialized, or uninitialized)
                    print_success "Pod ${pod} is ready (Vault process is responsive)"
                    return 0
                fi
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))

        if [ $((elapsed % 30)) -eq 0 ]; then
            print_debug "Still waiting for ${pod}... (${elapsed}s/${max_wait}s)"
        fi
    done

    print_error "Pod ${pod} failed to become ready after ${max_wait}s"
    return 1
}

# Get replica count
get_replica_count() {
    local replicas
    replicas=$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE_NAME}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    echo "${replicas}"
}

# Create Kubernetes Secret with init data
create_vault_secret() {
    local init_data=$1

    print_info "Creating Kubernetes Secret: ${SECRET_NAME}"

    # Extract data from init output
    local root_token
    local unseal_keys_b64
    local unseal_keys_hex

    root_token=$(echo "${init_data}" | jq -r '.root_token')
    unseal_keys_b64=$(echo "${init_data}" | jq -c '.unseal_keys_b64')
    unseal_keys_hex=$(echo "${init_data}" | jq -c '.unseal_keys_hex')

    if [[ -z "${root_token}" || "${root_token}" == "null" ]]; then
        print_error "Failed to extract root token from init output"
        return 1
    fi

    # Create secret with all necessary data
    if kubectl create secret generic "${SECRET_NAME}" \
        -n "${NAMESPACE}" \
        --from-literal=root_token="${root_token}" \
        --from-literal=unseal_keys_b64="${unseal_keys_b64}" \
        --from-literal=unseal_keys_hex="${unseal_keys_hex}" \
        --from-literal=key_shares="${KEY_SHARES}" \
        --from-literal=key_threshold="${KEY_THRESHOLD}" \
        --from-literal=initialized_at="$(date -Iseconds)" \
        --dry-run=client -o yaml | kubectl apply -f - &> /dev/null; then
        print_success "Secret ${SECRET_NAME} created successfully"
        return 0
    else
        print_error "Failed to create secret ${SECRET_NAME}"
        return 1
    fi
}

# Initialize Vault cluster
initialize_vault() {
    local leader_pod="${RELEASE_NAME}-0"

    print_info "=== Phase 1: Initializing Vault cluster ==="
    print_info "Leader pod: ${leader_pod}"
    print_info "Key shares: ${KEY_SHARES}, threshold: ${KEY_THRESHOLD}"

    # Wait for leader pod to be ready
    if ! wait_for_pod "${leader_pod}"; then
        print_error "Leader pod is not ready, cannot initialize"
        exit 1
    fi

    # Perform initialization
    print_info "Initializing Vault..."

    local init_output
    if init_output=$(kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
        vault operator init \
        -key-shares="${KEY_SHARES}" \
        -key-threshold="${KEY_THRESHOLD}" \
        -format=json 2>&1); then

        print_success "Vault initialized successfully"
        print_debug "Init output length: ${#init_output} characters"

        # Store in Kubernetes Secret
        if create_vault_secret "${init_output}"; then
            print_success "Unseal keys and root token stored in Secret: ${SECRET_NAME}"
        else
            print_error "Failed to store init data in Secret"
            print_error "Init output: ${init_output}"
            exit 1
        fi

        # Export for unsealing
        export INIT_OUTPUT="${init_output}"
    else
        print_error "Failed to initialize Vault"
        print_error "Error output: ${init_output}"
        exit 1
    fi
}

# Unseal a single pod
unseal_pod() {
    local pod=$1
    local init_data=$2

    print_info "Unsealing pod: ${pod}..."

    # Check if pod exists and is running
    local pod_status
    pod_status=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "${pod_status}" != "Running" ]]; then
        print_warning "Pod ${pod} is not running (status: ${pod_status}), skipping"
        return 1
    fi

    # Check if already unsealed
    local sealed
    sealed=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- \
        vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")

    if [[ "${sealed}" == "false" ]]; then
        print_info "Pod ${pod} is already unsealed"
        return 0
    fi

    # Extract unseal keys
    local keys=()
    for ((i=0; i<KEY_THRESHOLD; i++)); do
        local key
        key=$(echo "${init_data}" | jq -r ".unseal_keys_b64[${i}]")
        if [[ -z "${key}" || "${key}" == "null" ]]; then
            print_error "Invalid or missing unseal key at index ${i}"
            return 1
        fi
        keys+=("${key}")
    done

    # Apply unseal keys with retry
    for key in "${keys[@]}"; do
        if ! retry_command 3 kubectl -n "${NAMESPACE}" exec "${pod}" -- \
            vault operator unseal "${key}" > /dev/null 2>&1; then
            print_error "Failed to apply unseal key to ${pod}"
            return 1
        fi
    done

    # Verify unsealed
    sealed=$(kubectl -n "${NAMESPACE}" exec "${pod}" -- \
        vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")

    if [[ "${sealed}" == "false" ]]; then
        print_success "Pod ${pod} unsealed successfully"
        return 0
    else
        print_error "Pod ${pod} still sealed after unseal attempt"
        return 1
    fi
}

# Join follower node to Raft cluster
join_follower_to_raft() {
    local follower_pod=$1
    local leader_pod="${RELEASE_NAME}-0"

    print_info "Joining ${follower_pod} to Raft cluster..."

    # Skip if this is the leader pod
    if [[ "${follower_pod}" == "${leader_pod}" ]]; then
        print_debug "${follower_pod} is the leader, skipping join"
        return 0
    fi

    # Check if already a member
    local is_member
    is_member=$(kubectl -n "${NAMESPACE}" exec "${follower_pod}" -- \
        vault status -format=json 2>/dev/null | jq -r '.raft_joined' || echo "false")

    if [[ "${is_member}" == "true" ]]; then
        print_info "${follower_pod} is already a member of the Raft cluster"
        return 0
    fi

    # Get leader address
    local leader_addr="http://${leader_pod}.${RELEASE_NAME}-internal:8200"

    # Attempt to join the Raft cluster (with retry for timing issues)
    local join_output
    if join_output=$(kubectl -n "${NAMESPACE}" exec "${follower_pod}" -- \
        vault operator raft join "${leader_addr}" 2>&1); then
        print_success "${follower_pod} joined Raft cluster successfully"

        # Wait for cluster sync
        print_debug "Waiting for cluster synchronization..."
        sleep 2
        return 0
    else
        # Check if error is due to already being a member
        if echo "${join_output}" | grep -q "node already part of cluster\|already joined"; then
            print_info "${follower_pod} is already a member of the Raft cluster"
            return 0
        else
            print_warning "Failed to join ${follower_pod} to Raft cluster"
            print_debug "Join output: ${join_output}"
            return 1
        fi
    fi
}

# Unseal all pods in the cluster
unseal_cluster() {
    local init_data=$1
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Phase 2: Unsealing Vault pods ==="
    print_info "Total replicas: ${replicas}"

    local unsealed_count=0
    local failed_count=0

    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"

        # Wait for pod to be ready
        if wait_for_pod "${pod}"; then
            if unseal_pod "${pod}" "${init_data}"; then
                unsealed_count=$((unsealed_count + 1))

                # Join to Raft cluster if this is a follower node (not vault-0)
                if [[ "${pod}" != "${RELEASE_NAME}-0" ]]; then
                    if join_follower_to_raft "${pod}"; then
                        print_debug "${pod} successfully joined to Raft cluster"
                    else
                        print_warning "${pod} unsealed but not joined to cluster yet"
                    fi
                fi
            else
                failed_count=$((failed_count + 1))
            fi
        else
            print_warning "Skipping ${pod} - not ready"
            failed_count=$((failed_count + 1))
        fi
    done

    echo ""
    echo "======================================================================"
    print_info "Unseal Summary:"
    echo "  Total replicas:  ${replicas}"
    echo "  Unsealed:        ${unsealed_count}"
    echo "  Failed:          ${failed_count}"
    echo "======================================================================"
    echo ""

    if [[ ${unsealed_count} -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Verify cluster health
verify_cluster() {
    local leader_pod="${RELEASE_NAME}-0"
    local replicas
    replicas=$(get_replica_count)

    print_info "=== Phase 3: Verifying cluster health ==="

    # Get root token from secret
    local root_token
    root_token=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "${root_token}" ]]; then
        print_warning "Could not retrieve root token from secret"
        return 1
    fi

    # Check seal status of all pods
    print_info "Checking status of all pods..."
    for ((i=0; i<replicas; i++)); do
        local pod="${RELEASE_NAME}-${i}"
        if kubectl -n "${NAMESPACE}" get pod "${pod}" &> /dev/null; then
            echo ""
            print_info "Status of ${pod}:"
            kubectl -n "${NAMESPACE}" exec "${pod}" -- vault status || true
        fi
    done

    # Check Raft cluster members (if HA mode)
    if [[ ${replicas} -gt 1 ]]; then
        echo ""
        print_info "Checking Raft cluster peers..."
        if kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
            env VAULT_TOKEN="${root_token}" vault operator raft list-peers 2>/dev/null; then

            # Count actual members
            local member_count
            member_count=$(kubectl -n "${NAMESPACE}" exec "${leader_pod}" -- \
                env VAULT_TOKEN="${root_token}" vault operator raft list-peers 2>/dev/null | \
                grep -c "vault-" || echo "0")

            if [[ ${member_count} -eq ${replicas} ]]; then
                print_success "All ${replicas} nodes are in the Raft cluster"
            elif [[ ${member_count} -gt 0 ]]; then
                print_warning "Only ${member_count} of ${replicas} nodes in Raft cluster"
            else
                print_warning "Could not count Raft cluster members"
            fi
        else
            print_warning "Failed to list Raft peers - cluster may not be fully formed yet"
        fi
    fi

    print_success "Cluster verification complete"
}

# Display access information
display_info() {
    local root_token
    root_token=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "<error-retrieving-token>")

    echo ""
    echo "======================================================================"
    print_success "Vault cluster initialized and unsealed successfully!"
    echo "======================================================================"
    echo ""
    echo "Access Information:"
    echo "  Namespace:     ${NAMESPACE}"
    echo "  Release:       ${RELEASE_NAME}"
    echo "  Replicas:      $(get_replica_count)"
    echo "  Secret Name:   ${SECRET_NAME}"
    echo ""
    echo "Root Token: ${root_token}"
    echo ""
    print_warning "IMPORTANT: Credentials are stored in Kubernetes Secret: ${SECRET_NAME}"
    print_warning "This is suitable for dev/test only. For production, use Cloud KMS auto-unseal."
    echo ""
    echo "To retrieve the root token:"
    echo "  kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.root_token}' | base64 -d"
    echo ""
    echo "To access Vault:"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME} 8200:8200"
    echo "  export VAULT_ADDR=http://localhost:8200"
    echo "  export VAULT_TOKEN=\"${root_token}\""
    echo "  vault status"
    echo ""
}

# Main execution
main() {
    echo ""
    echo "======================================================================"
    echo "  Vault Auto-Initialization for Kubernetes"
    echo "======================================================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:        ${NAMESPACE}"
    echo "  Release Name:     ${RELEASE_NAME}"
    echo "  Key Shares:       ${KEY_SHARES}"
    echo "  Key Threshold:    ${KEY_THRESHOLD}"
    echo "  Secret Name:      ${SECRET_NAME}"
    echo "  Auto Unseal:      ${AUTO_UNSEAL}"
    echo "  Max Retries:      ${MAX_RETRY}"
    echo "  Timeout:          ${OPERATION_TIMEOUT}s"
    echo "  Debug Mode:       ${DEBUG}"
    echo ""

    validate_environment
    configure_kubectl
    check_prerequisites

    # Check if already initialized
    if is_vault_initialized; then
        print_warning "Vault is already initialized!"

        if secret_exists; then
            print_info "Initialization secret exists: ${SECRET_NAME}"
        else
            print_error "Vault is initialized but secret ${SECRET_NAME} not found!"
            print_error "Cannot proceed without unseal keys"
            exit 1
        fi

        # Check if we need to unseal
        if [[ "${AUTO_UNSEAL}" == "true" ]]; then
            print_info "Checking if unsealing is needed..."

            # Retrieve init data from secret
            local unseal_keys_b64
            unseal_keys_b64=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
                -o jsonpath='{.data.unseal_keys_b64}' 2>/dev/null | base64 -d || echo "")

            if [[ -z "${unseal_keys_b64}" ]]; then
                print_error "Failed to retrieve unseal keys from secret"
                exit 1
            fi

            local init_data
            init_data=$(jq -n --argjson keys "${unseal_keys_b64}" '{"unseal_keys_b64": $keys}')

            if unseal_cluster "${init_data}"; then
                verify_cluster
            fi
        fi
    else
        print_info "Vault is not initialized. Starting initialization..."

        # Initialize Vault
        if ! initialize_vault; then
            print_error "Initialization failed"
            exit 1
        fi

        # Unseal if enabled
        if [[ "${AUTO_UNSEAL}" == "true" ]]; then
            if unseal_cluster "${INIT_OUTPUT}"; then
                verify_cluster
            fi
        fi
    fi

    display_info

    echo ""
    print_success "Auto-initialization complete!"
    echo ""
}

main "$@"
