#!/bin/bash
# Wait for Docker to be ready before starting compose

MAX_WAIT=60  # Maximum wait time in seconds
COUNTER=0
DOCKER_BIN=/usr/bin/docker
DOCKER_CONTEXT=default

echo "Waiting for Docker daemon to be ready..."

# Wait for Docker socket to exist and be accessible
while [ $COUNTER -lt $MAX_WAIT ]; do
    if "$DOCKER_BIN" --context "$DOCKER_CONTEXT" info >/dev/null 2>&1; then
        echo "Docker is ready on context '$DOCKER_CONTEXT'."
        break
    fi

    echo "Docker context '$DOCKER_CONTEXT' not ready yet, waiting... ($COUNTER/$MAX_WAIT)"
    sleep 2
    COUNTER=$((COUNTER + 2))
done

if [ $COUNTER -ge $MAX_WAIT ]; then
    echo "ERROR: Docker context '$DOCKER_CONTEXT' did not become ready within ${MAX_WAIT} seconds"
    exit 1
fi

# Function to wait for a specific IP to be assigned to the host
wait_for_ip() {
    local ip="$1"
    local name="$2"
    local ip_counter=0
    local ip_max_wait=30
    
    echo "Waiting for $name IP ($ip) to be assigned..."
    while [ $ip_counter -lt $ip_max_wait ]; do
        if ip addr show | grep -Fq "$ip"; then
            echo "$name IP ($ip) is ready."
            return 0
        fi
        sleep 2
        ip_counter=$((ip_counter + 2))
    done
    echo "WARNING: $name IP ($ip) did not become ready within $ip_max_wait seconds. Starting stack anyway..."
    return 1
}

# Wait for host IP and Tailscale IP to be active to ensure port binding succeeds
wait_for_ip "192.168.0.19" "Local Host"
wait_for_ip "100.104.142.22" "Tailscale"

echo "Starting ARR stack..."
cd /home/harshal/arr-new || exit
exec "$DOCKER_BIN" --context "$DOCKER_CONTEXT" compose up -d
