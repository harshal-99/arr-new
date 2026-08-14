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

# Function to wait for a storage mount path to be active
wait_for_mount() {
    local mount_path="$1"
    local mount_counter=0
    local mount_max_wait=30
    
    echo "Waiting for storage mount ($mount_path) to be active..."
    
    while [ $mount_counter -lt $mount_max_wait ]; do
        # Access directory to trigger systemd automount and check for errors
        local ls_output
        if ls_output=$(ls "$mount_path" 2>&1); then
            # Confirm the mount is loaded by checking if known subdirectories exist
            if [ -d "$mount_path/media" ] && [ -d "$mount_path/torrents" ]; then
                echo "Storage mount ($mount_path) is ready."
                return 0
            fi
            echo "Storage mount path exists, but 'media' and/or 'torrents' subdirectories are not found."
        else
            echo "Warning: Error accessing storage mount ($mount_path): $ls_output"
        fi
        
        sleep 2
        mount_counter=$((mount_counter + 2))
    done
    return 1
}

# Wait for host IP and Tailscale IP to be active to ensure port binding succeeds
wait_for_ip "192.168.0.19" "Local Host"
wait_for_ip "100.104.142.22" "Tailscale"

# Wait for storage mount to be active before starting stack
if ! wait_for_mount "/mnt/hdd/data"; then
    echo "ERROR: Storage mount (/mnt/hdd/data) did not become ready. Aborting stack startup to prevent writing to the root filesystem or throwing I/O errors."
    exit 1
fi

echo "Starting ARR stack..."
cd /home/harshal/arr-new || exit

if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    echo "Running Docker compose as user $SUDO_USER..."
    export XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")"
    exec sudo -u "$SUDO_USER" DOCKER_CONTEXT="$DOCKER_CONTEXT" "$DOCKER_BIN" --context "$DOCKER_CONTEXT" compose up -d
else
    exec "$DOCKER_BIN" --context "$DOCKER_CONTEXT" compose up -d
fi

