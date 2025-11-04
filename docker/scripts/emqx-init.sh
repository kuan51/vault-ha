#!/bin/sh
#
# EMQX Initialization Script
# Creates MQTT user via EMQX API with proper JSON handling
#
# Environment Variables:
#   EMQX_HOST               - EMQX server hostname (default: emqx)
#   EMQX_API_PORT           - EMQX API port (default: 18083)
#   EMQX_ADMIN_USER         - Admin username (default: admin)
#   EMQX_DASHBOARD_PASSWORD - Admin password
#   MQTT_USERNAME           - MQTT username to create
#   MQTT_PASSWORD           - MQTT password for the user
#

set -e  # Exit on error
set -u  # Exit on undefined variable

# Configuration
EMQX_HOST="${EMQX_HOST:-emqx}"
EMQX_API_PORT="${EMQX_API_PORT:-18083}"
EMQX_ADMIN_USER="${EMQX_ADMIN_USER:-admin}"
MAX_RETRIES=5
RETRY_DELAY=3

echo "==> EMQX MQTT User Initialization"
echo "==> Target: ${EMQX_HOST}:${EMQX_API_PORT}"
echo "==> User: ${MQTT_USERNAME}"

# Install dependencies
echo "==> Installing dependencies..."
if ! command -v curl > /dev/null 2>&1; then
    apk add --no-cache curl
fi
if ! command -v jq > /dev/null 2>&1; then
    apk add --no-cache jq
fi

# EMQX API URL
EMQX_API_URL="http://${EMQX_HOST}:${EMQX_API_PORT}"
EMQX_LOGIN_URL="${EMQX_API_URL}/api/v5/login"
EMQX_AUTH_URL="${EMQX_API_URL}/api/v5/authentication"
EMQX_AUTH_DB_URL="${EMQX_AUTH_URL}/password_based:built_in_database"
EMQX_USERS_URL="${EMQX_AUTH_DB_URL}/users"

# Function to get bearer token
get_bearer_token() {
    TOKEN=$(curl -s -X POST "${EMQX_LOGIN_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${EMQX_ADMIN_USER}\",\"password\":\"${EMQX_DASHBOARD_PASSWORD}\"}" \
        | jq -r '.token // empty')

    if [ -z "$TOKEN" ]; then
        return 1
    fi
    echo "$TOKEN"
    return 0
}

# Function to check if EMQX API is ready
check_emqx_ready() {
    TOKEN=$(get_bearer_token 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        curl -sf -H "Authorization: Bearer $TOKEN" \
             "${EMQX_API_URL}/api/v5/status" > /dev/null 2>&1
    else
        return 1
    fi
}

# Wait for EMQX API to be ready
echo "==> Waiting for EMQX API to be ready..."
retry_count=0
while ! check_emqx_ready; do
    retry_count=$((retry_count + 1))
    if [ $retry_count -ge $MAX_RETRIES ]; then
        echo "ERROR: EMQX API is not accessible after ${MAX_RETRIES} attempts"
        echo "       URL: ${EMQX_API_URL}/api/v5/status"
        exit 1
    fi
    echo "    Attempt ${retry_count}/${MAX_RETRIES}: API not ready, waiting ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done

echo "==> EMQX API is ready!"

# Get bearer token for API requests
echo "==> Obtaining authentication token..."
BEARER_TOKEN=$(get_bearer_token)
if [ -z "$BEARER_TOKEN" ]; then
    echo "ERROR: Failed to obtain bearer token"
    exit 1
fi

# Check if authenticator exists, create if not
echo "==> Checking if password_based:built_in_database authenticator exists..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/emqx_auth_list.json \
    -X GET "${EMQX_AUTH_URL}" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Content-Type: application/json"
)

AUTH_EXISTS=false
if [ "$HTTP_CODE" = "200" ]; then
    if jq -e '.[] | select(.mechanism == "password_based" and .backend == "built_in_database")' /tmp/emqx_auth_list.json > /dev/null 2>&1; then
        AUTH_EXISTS=true
        echo "==> INFO: Authenticator already exists"
    fi
fi

if [ "$AUTH_EXISTS" = "false" ]; then
    echo "==> Creating password_based:built_in_database authenticator..."
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/emqx_auth_create.json \
        -X POST "${EMQX_AUTH_URL}" \
        -H "Authorization: Bearer ${BEARER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{
            "mechanism": "password_based",
            "backend": "built_in_database",
            "user_id_type": "username",
            "password_hash_algorithm": {
                "name": "sha256",
                "salt_position": "suffix"
            }
        }'
    )

    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
        echo "==> SUCCESS: Authenticator created"
    else
        echo "ERROR: Failed to create authenticator (HTTP ${HTTP_CODE})"
        cat /tmp/emqx_auth_create.json
        exit 1
    fi
fi

# Check if user already exists
echo "==> Checking if user '${MQTT_USERNAME}' exists..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/emqx_list_users.json \
    -X GET "${EMQX_USERS_URL}" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Content-Type: application/json"
)

USER_EXISTS=false
if [ "$HTTP_CODE" = "200" ]; then
    # Check if user exists in response
    if jq -e ".data[] | select(.user_id == \"${MQTT_USERNAME}\")" /tmp/emqx_list_users.json > /dev/null 2>&1; then
        USER_EXISTS=true
        echo "==> INFO: User '${MQTT_USERNAME}' already exists"
    fi
fi

# Build JSON payload using jq (handles ALL escaping automatically)
# This is the CORRECT way to handle special characters in JSON
echo "==> Building JSON payload..."
JSON_PAYLOAD=$(jq -n \
    --arg user_id "${MQTT_USERNAME}" \
    --arg password "${MQTT_PASSWORD}" \
    '{
        user_id: $user_id,
        password: $password
    }'
)

# Create or update user
if [ "$USER_EXISTS" = "true" ]; then
    echo "==> Updating existing user '${MQTT_USERNAME}'..."

    # Update user (PUT request)
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/emqx_response.json \
        -X PUT "${EMQX_USERS_URL}/${MQTT_USERNAME}" \
        -H "Authorization: Bearer ${BEARER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${JSON_PAYLOAD}"
    )

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
        echo "==> SUCCESS: User '${MQTT_USERNAME}' updated successfully"
    else
        echo "ERROR: Failed to update user (HTTP ${HTTP_CODE})"
        echo "Response:"
        cat /tmp/emqx_response.json
        exit 1
    fi
else
    echo "==> Creating new user '${MQTT_USERNAME}'..."

    # Create user (POST request)
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/emqx_response.json \
        -X POST "${EMQX_USERS_URL}" \
        -H "Authorization: Bearer ${BEARER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${JSON_PAYLOAD}"
    )

    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "==> SUCCESS: User '${MQTT_USERNAME}' created successfully"
    elif [ "$HTTP_CODE" = "409" ]; then
        echo "==> INFO: User '${MQTT_USERNAME}' already exists (HTTP 409)"
        echo "         This is expected if the user was created between checks"
    else
        echo "ERROR: Failed to create user (HTTP ${HTTP_CODE})"
        echo "Response:"
        cat /tmp/emqx_response.json

        # Check if it's an authentication error
        if [ "$HTTP_CODE" = "401" ]; then
            echo ""
            echo "HINT: Check EMQX_DASHBOARD_PASSWORD is correct"
            echo "      Current admin user: ${EMQX_ADMIN_USER}"
        fi

        exit 1
    fi
fi

# Verify user exists
echo "==> Verifying user creation..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/emqx_verify.json \
    -X GET "${EMQX_USERS_URL}" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Content-Type: application/json"
)

if [ "$HTTP_CODE" = "200" ]; then
    if jq -e ".data[] | select(.user_id == \"${MQTT_USERNAME}\")" /tmp/emqx_verify.json > /dev/null 2>&1; then
        echo "==> Verification successful!"

        # Display user info
        echo "==> User details:"
        jq ".data[] | select(.user_id == \"${MQTT_USERNAME}\")" /tmp/emqx_verify.json
    else
        echo "WARNING: User not found in verification check"
    fi
else
    echo "WARNING: Could not verify user creation (HTTP ${HTTP_CODE})"
fi

# Cleanup
rm -f /tmp/emqx_*.json

echo "==> EMQX initialization complete"

# Exit with success
exit 0
