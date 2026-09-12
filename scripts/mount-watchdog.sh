#!/bin/bash
# Mount Watchdog Script for ARR Stack
# Periodically checks if bind mounts inside Docker containers are stale (Input/output error)
# and restarts the arr-stack service if needed. Also self-recovers arr-stack.service if it's
# sitting in a failed/start-limit-hit state (e.g. a prolonged NAS outage burned through
# systemd's restart budget) instead of leaving the stack down until someone notices.
#
# Transient network blips (e.g. a router reboot dropping the CIFS mount for a
# few seconds) can make a single check look stale even though it recovers on
# its own. Retry a few times with a delay before triggering a full restart.
#
# Restart/recovery attempts back off exponentially (5m/15m/30m/60m, capped) so a
# prolonged NAS outage doesn't cause a restart storm that re-exhausts systemd's
# start limit. Backoff state lives under XDG_RUNTIME_DIR so it resets naturally
# across logins/reboots, and clears as soon as things are confirmed healthy again.

set -euo pipefail

RETRIES="${MOUNT_WATCHDOG_RETRIES:-3}"
RETRY_DELAY="${MOUNT_WATCHDOG_RETRY_DELAY:-15}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/arr-mount-watchdog.state"
BACKOFF_LEVELS=(300 900 1800 3600) # 5m, 15m, 30m, 60m (capped)

# Ensure DOCKER_CONTEXT is set to default if not already set
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"

# Ensure we can communicate with Docker
if ! docker info >/dev/null 2>&1; then
    echo "$(date): Error: Cannot connect to Docker daemon using context '${DOCKER_CONTEXT}'."
    exit 0
fi

clear_backoff() {
    rm -f "${STATE_FILE}"
}

# Returns 0 if enough time has passed since the last attempt to try again, 1 otherwise.
backoff_ready() {
    local last_ts=0 level=0
    if [[ -f "${STATE_FILE}" ]]; then
        read -r last_ts level < "${STATE_FILE}" || true
    fi
    local max_index=$(( ${#BACKOFF_LEVELS[@]} - 1 ))
    [[ "${level}" -gt "${max_index}" ]] && level="${max_index}"
    local wait_secs="${BACKOFF_LEVELS[${level}]}"
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - last_ts ))
    if [[ "${elapsed}" -lt "${wait_secs}" ]]; then
        echo "$(date): Backoff active (level ${level}, need ${wait_secs}s between attempts, ${elapsed}s elapsed). Skipping."
        return 1
    fi
    return 0
}

record_attempt() {
    local last_ts=0 level=0
    if [[ -f "${STATE_FILE}" ]]; then
        read -r last_ts level < "${STATE_FILE}" || true
    fi
    local max_index=$(( ${#BACKOFF_LEVELS[@]} - 1 ))
    level=$(( level + 1 ))
    [[ "${level}" -gt "${max_index}" ]] && level="${max_index}"
    echo "$(date +%s) ${level}" > "${STATE_FILE}"
}

# Self-recovery: if arr-stack.service is sitting failed (e.g. start-limit-hit),
# systemd refuses to start/restart it again until reset-failed is called. Do
# that here so the stack isn't stuck down forever waiting for a human to notice.
# Returns 0 if it recovered (or attempted to), 1 if failed but not ready to
# retry yet, 2 if the service isn't in a failed state at all.
recover_if_failed() {
    if systemctl --user is-failed --quiet arr-stack.service; then
        if ! timeout 5 ls /mnt/hdd/data >/dev/null 2>&1; then
            echo "$(date): arr-stack.service is failed and /mnt/hdd/data is still unreachable. Not recovering yet."
            return 1
        fi
        if ! backoff_ready; then
            return 1
        fi
        echo "$(date): arr-stack.service is failed and the mount looks healthy. Clearing failed state and starting..."
        systemctl --user reset-failed arr-stack.service
        systemctl --user start arr-stack.service
        record_attempt
        return 0
    fi
    return 2
}

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

# A failed service has no running containers for run_checks to inspect, so
# handle that case first and independently.
recover_status=0
recover_if_failed || recover_status=$?
if [[ "${recover_status}" -ne 2 ]]; then
    exit 0
fi

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
    if run_checks; then
        echo "$(date): All container bind mounts are healthy."
        clear_backoff
        exit 0
    fi

    if [ "$attempt" -lt "$RETRIES" ]; then
        echo "$(date): Stale mount check ${attempt}/${RETRIES} failed, retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
done

if ! backoff_ready; then
    exit 0
fi

echo "$(date): Stale mount persisted across ${RETRIES} checks! Restarting arr-stack.service..."
systemctl --user reset-failed arr-stack.service 2>/dev/null || true
systemctl --user restart arr-stack.service
record_attempt
