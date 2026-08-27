#!/bin/bash
# Mount Watchdog Script for ARR Stack
# Periodically checks if bind mounts inside Docker containers are stale (Input/output error)
# and restarts the arr-stack service if needed.
#
# Transient network blips (e.g. a router reboot dropping the CIFS mount for a
# few seconds) can make a single check look stale even though it recovers on
# its own. Retry a few times with a delay before triggering a full restart.

set -euo pipefail

RETRIES="${MOUNT_WATCHDOG_RETRIES:-3}"
RETRY_DELAY="${MOUNT_WATCHDOG_RETRY_DELAY:-15}"

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

# Run all mount checks once; returns 1 if any container's mount is stale
run_checks() {
    local stale=0

    if ! check_container_mount "jellyfin" "/data/media"; then
        stale=1
    fi

    if [ "$stale" -eq 0 ] && ! check_container_mount "radarr" "/data"; then
        stale=1
    fi

    if [ "$stale" -eq 0 ] && ! check_container_mount "sonarr" "/data"; then
        stale=1
    fi

    if [ "$stale" -eq 0 ] && ! check_container_mount "qbittorrent" "/data"; then
        stale=1
    fi

    return "$stale"
}

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
    if run_checks; then
        echo "$(date): All container bind mounts are healthy."
        exit 0
    fi

    if [ "$attempt" -lt "$RETRIES" ]; then
        echo "$(date): Stale mount check ${attempt}/${RETRIES} failed, retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
done

echo "$(date): Stale mount persisted across ${RETRIES} checks! Restarting arr-stack.service..."
systemctl --user restart arr-stack.service
