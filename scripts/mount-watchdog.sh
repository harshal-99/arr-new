#!/bin/bash
# Mount Watchdog Script for ARR Stack
# Periodically checks if bind mounts inside Docker containers are stale (Input/output error)
# and restarts the arr-stack service if needed.

set -euo pipefail

# Ensure DOCKER_CONTEXT is set to default if not already set
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"

# Ensure we can communicate with Docker
if ! docker info >/dev/null 2>&1; then
    echo "$(date): Error: Cannot connect to Docker daemon using context '${DOCKER_CONTEXT}'."
    exit 0
fi

# Function to check container mount health
check_container_mount() {
    local container="$1"
    local check_path="$2"

    # Check if the container is running
    if docker ps --filter "name=^/${container}$" --filter "status=running" | grep -q "${container}"; then
        # Try to list the directory inside the container
        # If it returns a non-zero exit code or output contains I/O error, it is stale
        local output
        if ! output=$(timeout 5 docker exec "${container}" ls "${check_path}" 2>&1); then
            echo "Stale mount detected in container '${container}' on path '${check_path}': ${output}"
            return 1
        elif [[ "$output" == *"Input/output error"* || "$output" == *"I/O error"* ]]; then
            echo "Stale mount detected in container '${container}' on path '${check_path}' (grep match): ${output}"
            return 1
        fi
    fi
    return 0
}

# Check mounts in key containers
STALE=0

# Jellyfin check
if ! check_container_mount "jellyfin" "/data/media"; then
    STALE=1
fi

# Radarr check
if [ "$STALE" -eq 0 ] && ! check_container_mount "radarr" "/data"; then
    STALE=1
fi

# Sonarr check
if [ "$STALE" -eq 0 ] && ! check_container_mount "sonarr" "/data"; then
    STALE=1
fi

# qBittorrent check
if [ "$STALE" -eq 0 ] && ! check_container_mount "qbittorrent" "/data"; then
    STALE=1
fi

if [ "$STALE" -eq 1 ]; then
    echo "$(date): Stale mount found! Restarting arr-stack.service..."
    systemctl --user restart arr-stack.service
else
    echo "$(date): All container bind mounts are healthy."
fi
