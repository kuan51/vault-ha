#!/bin/sh
#
# Redis Initialization Script
# Creates Redis ACL user with proper special character handling
#
# Environment Variables:
#   REDIS_HOST       - Redis server hostname (default: redis)
#   REDIS_USERNAME   - Username to create
#   REDIS_PASSWORD   - Password for the user
#

set -e  # Exit on error
set -u  # Exit on undefined variable

# Configuration
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
MAX_RETRIES=5
RETRY_DELAY=2

echo "==> Redis ACL User Initialization"
echo "==> Target: ${REDIS_HOST}:${REDIS_PORT}"
echo "==> User: ${REDIS_USERNAME}"

# Function to check if Redis is ready
check_redis_ready() {
    redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping > /dev/null 2>&1
}

# Wait for Redis to be ready
echo "==> Waiting for Redis to be ready..."
retry_count=0
while ! check_redis_ready; do
    retry_count=$((retry_count + 1))
    if [ $retry_count -ge $MAX_RETRIES ]; then
        echo "ERROR: Redis is not accessible after ${MAX_RETRIES} attempts"
        exit 1
    fi
    echo "    Attempt ${retry_count}/${MAX_RETRIES}: Redis not ready, waiting ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done

echo "==> Redis is ready!"

# Check if user already exists
if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ACL LIST | grep -q "user ${REDIS_USERNAME}"; then
    echo "==> INFO: User '${REDIS_USERNAME}' already exists"
    echo "==> Updating user..."
else
    echo "==> Creating new user '${REDIS_USERNAME}'..."
fi

# Create/update Redis user with ACL
# Note: Special characters must be quoted for shell, but passed literally to redis-cli
#
# Redis ACL Syntax:
#   >password  = Set password
#   ~*         = Allow all key patterns
#   &*         = Allow all pubsub channels
#   +@all      = Allow all commands
#
# Shell Quoting:
#   ">${REDIS_PASSWORD}"  = Double quotes allow variable expansion, > is literal
#   '~*'                  = Single quotes make ~* literal (no tilde expansion, no glob)
#   '&*'                  = Single quotes make &* literal (no background job, no glob)
#   '+@all'               = Single quotes protect +

redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ACL SETUSER "${REDIS_USERNAME}" \
    on \
    ">${REDIS_PASSWORD}" \
    '~*' \
    '&*' \
    '+@all'

# Verify user was created successfully
if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ACL LIST | grep -q "user ${REDIS_USERNAME}"; then
    echo "==> SUCCESS: Redis user '${REDIS_USERNAME}' configured successfully"

    # Display user info (without password)
    echo "==> User ACL rules:"
    redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ACL LIST | grep "user ${REDIS_USERNAME}"
else
    echo "ERROR: Failed to create/update Redis user"
    exit 1
fi

# Test authentication (optional)
if [ "${TEST_AUTH:-false}" = "true" ]; then
    echo "==> Testing authentication..."
    if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" \
        -u "redis://${REDIS_USERNAME}:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}" \
        ping > /dev/null 2>&1; then
        echo "==> SUCCESS: Authentication test passed"
    else
        echo "WARNING: Authentication test failed"
        echo "         This may be expected if Redis is not configured for ACL authentication"
    fi
fi

echo "==> Redis initialization complete"
