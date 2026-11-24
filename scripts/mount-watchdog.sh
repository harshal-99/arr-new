#!/bin/bash
# Mount Watchdog Script for ARR Stack
# Periodically checks if the NAS mount (on the host and inside the Docker
# containers) is stale and restarts the arr-stack service if needed. Also
# self-recovers arr-stack.service if it's sitting in a failed/start-limit-hit
# state (e.g. a prolonged NAS outage burned through systemd's restart budget)
# instead of leaving the stack down until someone notices.
#
# Transient network blips (e.g. a router reboot dropping the CIFS mount for a
# few seconds) can make a single check look stale even though it recovers on
# its own. Retry a few times with a delay before triggering a full restart.
#
# A restart alone does not fix a *wedged* host CIFS mount: after a NAS network
# stall the kernel can keep a dead SMB session that every new mount reuses
# ("CIFS: VFS: ... wait timed out after 60000 ms", automount EBUSY), so the
# stack loops on its start timeout for hours. When the host mount itself is
# hung, recovery first kills every container using it (they keep the old
# session alive), lazily unmounts it, and only then restarts the stack, so the
# automount makes a fresh connection. The unmount needs root; it runs as
# `sudo -n` and needs the sudoers rule in sudoers.d/arr-mount-watchdog.
#
# The unmount only runs when a CIFS filesystem is really mounted there. With
# just the automount (autofs) in place, `umount -l` would remove the automount
# itself, and nothing would ever mount the NAS again. For the same reason a
# path only counts as healthy when CIFS is mounted on it: without that, the bare
# directories underneath on the root disk answer too. Re-arming a lost automount
# needs root, so that case is only reported, with the command to run.
#
# Restart/recovery attempts back off exponentially (5m/15m/30m/60m, capped) so a
# prolonged NAS outage doesn't cause a restart storm that re-exhausts systemd's
# start limit. Backoff state lives under XDG_RUNTIME_DIR so it resets naturally
# across logins/reboots, and clears as soon as things are confirmed healthy again.
#
# Alerting goes to an external healthchecks.io check rather than Uptime Kuma,
# since Uptime Kuma is itself a container in this stack and can't warn you
# about its own outage. Alerting is best-effort: when the internet is down the
# ping fails, and that must never stop a recovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

RETRIES="${MOUNT_WATCHDOG_RETRIES:-5}"
RETRY_DELAY="${MOUNT_WATCHDOG_RETRY_DELAY:-20}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="${RUNTIME_DIR}/arr-mount-watchdog.state"
PROBE_PID_FILE="${RUNTIME_DIR}/arr-mount-watchdog.probe.pid"
DIAG_DIR="${MOUNT_WATCHDOG_DIAG_DIR:-${SCRIPT_DIR}/../diagnostics}"
MOUNT_PATH="${MOUNT_WATCHDOG_MOUNT_PATH:-/mnt/hdd/data}"
MOUNTS_FILE="${MOUNT_WATCHDOG_MOUNTS_FILE:-/proc/mounts}"
NAS_HOST="${MOUNT_WATCHDOG_NAS_HOST:-192.168.0.18}"
PROBE_TIMEOUT="${MOUNT_WATCHDOG_PROBE_TIMEOUT:-10}"
BACKOFF_LEVELS=(300 900 1800 3600) # 5m, 15m, 30m, 60m (capped)
HC_URL="https://hc-ping.com/7e967114-a258-4b76-b50c-00ad2565bf68"

ping_ok() {
    curl -fsS --retry 2 -m 10 "${HC_URL}" >/dev/null 2>&1 || true
}

ping_fail() {
    curl -fsS --retry 2 -m 10 --data-raw "$1" "${HC_URL}/fail" >/dev/null 2>&1 || true
}

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

# Run "$@" in the background and wait at most $1 seconds for it. A process
# stuck on a dead CIFS mount sits in uninterruptible sleep (D state), where
# `timeout` can't kill it and would hang waiting for it, so a stuck command is
# abandoned instead. Returns the command's exit status, or 124 if it was still
# running when the time ran out.
run_detached() {
    local secs="$1"; shift
    "$@" >/dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "${pid}" 2>/dev/null; do
        if [[ "${waited}" -ge "${secs}" ]]; then
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    local rc=0
    wait "${pid}" || rc=$?
    return "${rc}"
}

# Returns 0 if a filesystem of type $1 is mounted at MOUNT_PATH. Reads the
# mount table only, so it can't hang on a dead mount.
mounted_as() {
    awk -v path="${MOUNT_PATH}" -v type="$1" \
        '$2 == path && $3 == type { found = 1 } END { exit !found }' "${MOUNTS_FILE}"
}

# Returns 0 if neither CIFS nor the automount is in place, i.e. nothing will
# mount the NAS again until the automount unit is started (needs root).
automount_missing() {
    ! mounted_as cifs && ! mounted_as autofs
}

report_automount_missing() {
    local unit
    unit="$(systemd-escape --path --suffix=automount "${MOUNT_PATH}")"
    local msg="${MOUNT_PATH}: automount is gone. Run: sudo systemctl reset-failed ${unit%.automount}.mount ${unit}; sudo systemctl start ${unit}"
    echo "$(date): ${msg}"
    ping_fail "${msg}"
}

# Returns 0 if CIFS is mounted on the host and answers, 1 if it is not mounted,
# hung or erroring.
# Stats a subdirectory so the automount gets triggered. An earlier probe that
# is still stuck (recorded in PROBE_PID_FILE) means the mount is still hung,
# so no new probe is started; that keeps one stuck process at most, not one
# per run.
host_mount_ok() {
    if [[ -f "${PROBE_PID_FILE}" ]]; then
        local old_pid
        old_pid="$(cat "${PROBE_PID_FILE}" 2>/dev/null || true)"
        # Check comm too, so a reused PID isn't mistaken for the old probe.
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null \
            && [[ "$(cat "/proc/${old_pid}/comm" 2>/dev/null)" == "stat" ]]; then
            return 1
        fi
        rm -f "${PROBE_PID_FILE}"
    fi
    stat -t "${MOUNT_PATH}/media" >/dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "${pid}" 2>/dev/null; do
        if [[ "${waited}" -ge "${PROBE_TIMEOUT}" ]]; then
            echo "${pid}" > "${PROBE_PID_FILE}"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "${pid}" || return 1
    # Checked after the stat, which triggers the automount.
    mounted_as cifs
}

nas_smb_reachable() {
    timeout 5 bash -c "</dev/tcp/${NAS_HOST}/445" 2>/dev/null
}

# Clear a wedged host CIFS mount: kill every running container that bind-mounts
# it (each one pins the dead SMB session), then lazily unmount it so the next
# access automounts on a fresh connection. Never fails the script; returns 1
# if the unmount could not be done.
unwedge_host_mount() {
    local containers=() name mounts
    while read -r name mounts; do
        [[ -z "${name}" ]] && continue
        if [[ " ${mounts} " == *" ${MOUNT_PATH}"* ]]; then
            containers+=("${name#/}")
        fi
    done < <(docker ps -q | xargs -r docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}{{end}}' 2>/dev/null || true)

    if [[ "${#containers[@]}" -gt 0 ]]; then
        echo "$(date): Killing containers that hold ${MOUNT_PATH}: ${containers[*]}"
        run_detached 30 docker kill "${containers[@]}" || true
    fi

    if ! mounted_as cifs; then
        echo "$(date): No CIFS mounted at ${MOUNT_PATH}; not unmounting, that would remove the automount."
        return 0
    fi

    echo "$(date): Lazily unmounting ${MOUNT_PATH}..."
    local rc=0
    run_detached 30 sudo -n /usr/bin/umount -l "${MOUNT_PATH}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "$(date): Unmount failed or still running (rc=${rc}). Is sudoers.d/arr-mount-watchdog installed?"
        return 1
    fi
    return 0
}

# Self-recovery: if arr-stack.service is sitting failed (e.g. start-limit-hit),
# systemd refuses to start/restart it again until reset-failed is called. Do
# that here so the stack isn't stuck down forever waiting for a human to notice.
# Returns 0 if it recovered (or attempted to), 1 if failed but not ready to
# retry yet, 2 if the service isn't in a failed state at all.
recover_if_failed() {
    if systemctl --user is-failed --quiet arr-stack.service; then
        if ! host_mount_ok; then
            if ! nas_smb_reachable; then
                echo "$(date): arr-stack.service is failed and the NAS is unreachable. Not recovering yet."
                ping_fail "arr-stack.service failed; NAS unreachable"
                return 1
            fi
            if ! backoff_ready; then
                ping_fail "arr-stack.service failed; ${MOUNT_PATH} wedged but backoff active"
                return 1
            fi
            echo "$(date): arr-stack.service is failed and ${MOUNT_PATH} is wedged while the NAS answers. Clearing the mount..."
            ping_fail "arr-stack.service failed; clearing wedged ${MOUNT_PATH}"
            capture_diagnostics
            unwedge_host_mount || true
        elif ! backoff_ready; then
            ping_fail "arr-stack.service failed; mount healthy but backoff active"
            return 1
        else
            echo "$(date): arr-stack.service is failed and the mount looks healthy. Clearing failed state and starting..."
            ping_fail "arr-stack.service was failed; attempting self-recovery"
        fi
        systemctl --user reset-failed arr-stack.service || true
        systemctl --user start --no-block arr-stack.service || true
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
        local output rc=0
        output=$(timeout 8 docker exec "${container}" ls "${check_path}" 2>&1) || rc=$?
        if [[ "${rc}" -eq 124 ]]; then
            # A bare timeout isn't proof of staleness: under heavy load (e.g.
            # Tdarr transcoding right after a restart) docker exec + ls over
            # CIFS can take >8s. run_checks only gets here after the host mount
            # answered, and a wedged session hangs the host side as well.
            echo "Slow (not stale): '${container}' took >8s to list '${check_path}' while the host mount answers."
        elif [[ "${rc}" -ne 0 ]]; then
            echo "Stale mount detected in container '${container}' on path '${check_path}': ${output}"
            return 1
        elif [[ "$output" == *"Input/output error"* || "$output" == *"I/O error"* ]]; then
            echo "Stale mount detected in container '${container}' on path '${check_path}' (grep match): ${output}"
            return 1
        fi
    fi
    return 0
}

# Snapshot host/container/CIFS state before restarting, so a restart doesn't
# destroy the only evidence of what was actually wrong (docker compose down/up
# recreates every container, wiping their logs). Best-effort only: it runs in
# a subshell without errexit (a grep that matches nothing must not end the
# watchdog), and every command has a short timeout so a still-stuck mount
# can't make the capture itself hang the watchdog.
capture_diagnostics() {
    mkdir -p "${DIAG_DIR}" 2>/dev/null || return 0
    local out="${DIAG_DIR}/stale-mount-$(date +%Y%m%d-%H%M%S).log"
    (
        set +e +o pipefail
        echo "=== $(date) - stale mount diagnostic capture ==="
        echo
        echo "--- host uptime/load ---"
        uptime
        echo
        echo "--- host CIFS/autofs mounts (/proc/mounts) ---"
        grep -E 'cifs|autofs' /proc/mounts
        echo
        echo "--- /proc/fs/cifs/DebugData ---"
        timeout 5 cat /proc/fs/cifs/DebugData 2>&1
        echo
        echo "--- established connections to NAS SMB port ---"
        ss -tan 2>&1 | grep ':445'
        echo
        echo "--- recent kernel CIFS messages ---"
        journalctl -k --since "15 minutes ago" --no-pager 2>&1 | grep -i cifs | tail -20
        echo
        for c in jellyfin radarr sonarr qbittorrent; do
            echo "--- container: ${c} ---"
            docker inspect "${c}" --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} startedAt={{.State.StartedAt}}' 2>&1
            timeout 5 docker exec "${c}" sh -c 'uptime' 2>&1
            echo
        done
        echo "--- recent dockerd errors ---"
        journalctl -u docker.service --since "10 minutes ago" --no-pager 2>&1 | grep -iE "error|broken pipe" | tail -20
    ) > "${out}" 2>&1
    echo "$(date): Captured pre-restart diagnostics to ${out}"
}

# Run all mount checks once; returns 1 if the host mount or any container's
# mount is stale. Sets HOST_MOUNT_HUNG=1 when the host side itself is hung,
# which is what needs unwedging rather than just a stack restart. Checking the
# host also catches the case where the containers are not running at all.
HOST_MOUNT_HUNG=0
run_checks() {
    HOST_MOUNT_HUNG=0
    if ! host_mount_ok; then
        echo "Host mount ${MOUNT_PATH} is not mounted, hung or erroring."
        HOST_MOUNT_HUNG=1
        return 1
    fi

    local c
    for c in "jellyfin:/data/media" "radarr:/data" "sonarr:/data" "qbittorrent:/data"; do
        if ! check_container_mount "${c%%:*}" "${c#*:}"; then
            return 1
        fi
    done
    return 0
}

main() {
    # Ensure DOCKER_CONTEXT is set to default if not already set
    export DOCKER_CONTEXT="${DOCKER_CONTEXT:-default}"

    # Ensure we can communicate with Docker
    if ! docker info >/dev/null 2>&1; then
        echo "$(date): Error: Cannot connect to Docker daemon using context '${DOCKER_CONTEXT}'."
        exit 0
    fi

    # No restart can help here, and the bare directory must not pass as healthy.
    if automount_missing; then
        report_automount_missing
        exit 0
    fi

    # A failed service has no running containers for run_checks to inspect, so
    # handle that case first and independently.
    local recover_status=0
    recover_if_failed || recover_status=$?
    if [[ "${recover_status}" -ne 2 ]]; then
        exit 0
    fi

    local attempt=1
    while [ "$attempt" -le "$RETRIES" ]; do
        if run_checks; then
            echo "$(date): All container bind mounts are healthy."
            clear_backoff
            ping_ok
            exit 0
        fi

        if [ "$attempt" -lt "$RETRIES" ]; then
            echo "$(date): Stale mount check ${attempt}/${RETRIES} failed, retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
        attempt=$((attempt + 1))
    done

    capture_diagnostics

    if ! backoff_ready; then
        ping_fail "stale mount persisted across ${RETRIES} checks; backoff active"
        exit 0
    fi

    if [[ "${HOST_MOUNT_HUNG}" -eq 1 ]]; then
        if ! nas_smb_reachable; then
            echo "$(date): Host mount is hung and the NAS SMB port is unreachable; waiting for the NAS instead of restarting."
            ping_fail "host mount hung; NAS unreachable"
            record_attempt
            exit 0
        fi
        echo "$(date): Host mount is hung while the NAS answers. Clearing the wedged mount before restarting..."
        ping_fail "host mount ${MOUNT_PATH} wedged; clearing it and restarting arr-stack.service"
        unwedge_host_mount || true
    else
        ping_fail "stale mount persisted across ${RETRIES} checks; restarting arr-stack.service"
    fi

    echo "$(date): Stale mount persisted across ${RETRIES} checks! Restarting arr-stack.service..."
    record_attempt
    systemctl --user reset-failed arr-stack.service 2>/dev/null || true
    # --no-block: the stack's own start can take up to 8 min (TimeoutStartSec),
    # longer than this watchdog's 5 min budget.
    systemctl --user restart --no-block arr-stack.service
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
