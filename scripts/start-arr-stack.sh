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
    
    # Check if the mount path is in a stale/shutdown state returning Input/output error
    local ls_check
    ls_check=$(ls "$mount_path" 2>&1 || true)
    if [[ "$ls_check" == *"Input/output error"* ]]; then
        local active_dev
        active_dev=$(readlink -f /dev/disk/by-uuid/684bd0de-c039-4704-8b99-f12e74b6e4f9 2>/dev/null || echo "/dev/sdc1")
        echo "ERROR: Storage mount ($mount_path) is reporting an Input/output error (stale USB mount)."
        
        # Check if we have root privileges or passwordless sudo
        if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
            echo "Root/sudo access detected. Attempting automatic recovery..."
            
            echo "Unmounting stale mount..."
            if [ "$EUID" -eq 0 ]; then
                umount -l /mnt/hdd
            else
                sudo -n umount -l /mnt/hdd
            fi
            
            echo "Running filesystem check on $active_dev..."
            if [ "$EUID" -eq 0 ]; then
                fsck -f -y "$active_dev"
            else
                sudo -n fsck -f -y "$active_dev"
            fi
            
            echo "Re-triggering automount..."
            ls "$mount_path" >/dev/null 2>&1 || true
            
            # Check if mount is now healthy
            if [ -d "$mount_path/media" ] && [ -d "$mount_path/torrents" ]; then
                echo "Recovery successful! Storage mount ($mount_path) is active."
                return 0
            else
                echo "ERROR: Automatic recovery completed, but storage mount is still not ready."
                return 1
            fi
        else
            echo "To resolve this, please run the following commands in your terminal:"
            echo "  sudo umount -l /mnt/hdd"
            echo "  sudo fsck -f -y $active_dev"
            return 1
        fi
    fi

    # Access directory to trigger systemd automount
    ls "$mount_path" >/dev/null 2>&1
    
    while [ $mount_counter -lt $mount_max_wait ]; do
        # Confirm the mount is loaded by checking if known subdirectories exist
        if [ -d "$mount_path/media" ] && [ -d "$mount_path/torrents" ]; then
            echo "Storage mount ($mount_path) is ready."
            return 0
        fi
        sleep 2
        mount_counter=$((mount_counter + 2))
        ls "$mount_path" >/dev/null 2>&1
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

