#!/bin/bash
# Network Watchdog Script for ARR Stack host
# Periodically checks LAN gateway, NAS, and WAN reachability so a future
# outage (like the Sep 2026 incident where the NAS and internet were both
# unreachable for ~20 minutes with no trail in the router's own log) gets
# flagged immediately, with enough detail to tell a LAN failure apart from
# a WAN failure.
#
# Transient blips can make a single check look down even though it recovers
# on its own, so retry a few times before alerting (same approach as
# mount-watchdog.sh).

set -uo pipefail

RETRIES="${NETWORK_WATCHDOG_RETRIES:-3}"
RETRY_DELAY="${NETWORK_WATCHDOG_RETRY_DELAY:-10}"
PING_TIMEOUT="${NETWORK_WATCHDOG_PING_TIMEOUT:-3}"

NAS_HOST="${NETWORK_WATCHDOG_NAS_HOST:-192.168.0.18}"
WAN_HOSTS=(1.1.1.1 8.8.8.8)
HC_URL="https://hc-ping.com/d97474f6-d0fe-4ab4-8843-8c6fec4dc589"

gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

check_host() {
    ping -c 1 -W "$PING_TIMEOUT" "$1" >/dev/null 2>&1
}

check_wan() {
    local h
    for h in "${WAN_HOSTS[@]}"; do
        check_host "$h" && return 0
    done
    return 1
}

run_checks() {
    local gw
    gw="$(gateway)"
    GW_OK=0; NAS_OK=0; WAN_OK=0
    [ -n "$gw" ] && check_host "$gw" && GW_OK=1
    check_host "$NAS_HOST" && NAS_OK=1
    check_wan && WAN_OK=1
    [ "$GW_OK" -eq 1 ] && [ "$NAS_OK" -eq 1 ] && [ "$WAN_OK" -eq 1 ]
}

status_line() {
    echo "gateway=$([ "$GW_OK" -eq 1 ] && echo up || echo DOWN) nas=$([ "$NAS_OK" -eq 1 ] && echo up || echo DOWN) wan=$([ "$WAN_OK" -eq 1 ] && echo up || echo DOWN)"
}

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
    if run_checks; then
        echo "$(date): Network OK ($(status_line))"
        curl -fsS --retry 2 -m 10 "$HC_URL" >/dev/null 2>&1
        exit 0
    fi

    echo "$(date): Check ${attempt}/${RETRIES} failed ($(status_line))"
    if [ "$attempt" -lt "$RETRIES" ]; then
        sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
done

status="$(status_line)"
echo "$(date): Network outage persisted across ${RETRIES} checks! ${status}"
curl -fsS --retry 2 -m 10 --data-raw "${status}" "${HC_URL}/fail" >/dev/null 2>&1
exit 1
