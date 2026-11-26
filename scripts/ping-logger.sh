#!/bin/bash
# Continuous ping logger for the ARR Stack host
# network-watchdog.sh only samples every 5 minutes, which is too coarse to
# localise a partial-packet-loss outage (e.g. 2026-09-27, when only this host
# lost gateway/NAS/WAN traffic for ~19 min while its link never dropped).
# This samples every few seconds and records per-target loss/RTT to a daily
# CSV, plus the NIC's received PAUSE-frame counter (a congested switch sends
# these). When loss starts, it also asks the NAS - which sits on the same
# 2.5G switch - whether it can reach the internet, to tell "whole switch or
# uplink is bad" apart from "only this host's port/cable is bad".
# It also records the CPU package temperature and the cumulative package
# thermal-throttle count, and fsyncs the CSV after each sample: the host has
# frozen silently under sustained Tdarr load at 93-95 C (2026-09-26,
# 2026-11-27) with nothing in the journal, so the last rows before a freeze
# are the only temperature evidence.

set -uo pipefail

INTERVAL="${PING_LOGGER_INTERVAL:-5}"
COUNT="${PING_LOGGER_COUNT:-3}"
KEEP_DAYS="${PING_LOGGER_KEEP_DAYS:-14}"
STREAK="${PING_LOGGER_STREAK:-2}"
IFACE="${PING_LOGGER_IFACE:-enp3s0}"
NAS_HOST="${PING_LOGGER_NAS_HOST:-192.168.0.18}"
NAS_SSH="${PING_LOGGER_NAS_SSH:-nas}"
WAN_HOST="${PING_LOGGER_WAN_HOST:-1.1.1.1}"
TEMP_ALERT="${PING_LOGGER_TEMP_ALERT:-95}"

HEADER="time,gw_loss,gw_rtt,nas_loss,nas_rtt,wan_loss,wan_rtt,rx_pause_xoff,cpu_temp_c,pkg_throttle_count"
THROTTLE_FILE=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
# thermal_zone numbering is not stable across kernels, so find it by type.
TEMP_FILE=""
for z in /sys/class/thermal/thermal_zone*; do
    if [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ]; then TEMP_FILE="$z/temp"; break; fi
done

LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/diagnostics/ping"
mkdir -p "$LOG_DIR"

gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

# Prints "<loss%>,<avg rtt ms>" (rtt empty when every packet was lost).
probe() {
    ping -n -q -c "$COUNT" -i 0.2 -W 1 "$1" 2>/dev/null | awk -F'[ /]' '
        /packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { sub("%", "", $i); loss = $i } }
        /^rtt|^round-trip/ { rtt = $8 }
        END { printf "%s,%s", (loss == "" ? 100 : loss), rtt }'
}

pause_frames() {
    ethtool -S "$IFACE" 2>/dev/null | awk '/rx_flow_control_xoff/ {print $2; exit}'
}

# Whole degrees C, empty when the sensor is missing.
cpu_temp() {
    [ -n "$TEMP_FILE" ] && awk '{printf "%d", $1 / 1000}' "$TEMP_FILE" 2>/dev/null
}

# Runs in the background so a slow/unreachable NAS can't stall sampling.
check_nas_wan() {
    local out
    # The NAS login isn't root and QNAP's busybox ping needs root, so probe
    # with HTTPS connects instead.
    out="$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 "$NAS_SSH" \
        "ok=0; for i in 1 2 3; do curl -s -o /dev/null -m 3 https://$WAN_HOST && ok=\$((ok+1)); done; echo \"\$ok/3 HTTPS connects to $WAN_HOST succeeded\"" 2>&1)"
    echo "$(date '+%F %T'): NAS view of WAN during loss: ${out:-no answer from NAS}"
}

lossy=0
hot=0
while true; do
    ts="$(date '+%F %T')"
    csv="$LOG_DIR/ping-$(date +%F).csv"
    if [ ! -f "$csv" ]; then
        echo "$HEADER" > "$csv"
    elif [ "$(head -1 "$csv")" != "$HEADER" ]; then
        # Started mid-day with an older column layout: keep those rows apart.
        mv "$csv" "${csv%.csv}-old-$(date +%H%M%S).csv"
        echo "$HEADER" > "$csv"
    fi

    gw="$(gateway)"
    # Run the three probes concurrently so one interval stays ~1s regardless.
    exec 3< <(probe "${gw:-192.168.0.1}")
    exec 4< <(probe "$NAS_HOST")
    exec 5< <(probe "$WAN_HOST")
    gw_res="$(cat <&3)"; nas_res="$(cat <&4)"; wan_res="$(cat <&5)"
    exec 3<&- 4<&- 5<&-
    temp="$(cpu_temp)"
    echo "$ts,$gw_res,$nas_res,$wan_res,$(pause_frames),$temp,$(cat "$THROTTLE_FILE" 2>/dev/null)" >> "$csv"
    sync "$csv"

    if [ -n "$temp" ] && [ "$temp" -ge "$TEMP_ALERT" ]; then
        [ "$hot" -eq 0 ] && echo "$ts: CPU package at ${temp}C (alert threshold ${TEMP_ALERT}C)"
        hot=1
    elif [ "$hot" -eq 1 ] && [ -n "$temp" ] && [ "$temp" -lt $((TEMP_ALERT - 5)) ]; then
        echo "$ts: CPU package back down to ${temp}C"
        hot=0
    fi

    # Only a loss streak (not a single dropped ping) is reported to the
    # journal and triggers the NAS-side check; the CSV has every sample.
    if [[ "${gw_res%%,*}" != 0 || "${nas_res%%,*}" != 0 || "${wan_res%%,*}" != 0 ]]; then
        lossy=$((lossy + 1))
        if [ "$lossy" -eq "$STREAK" ]; then
            echo "$ts: Packet loss started (gateway=${gw_res%%,*}% nas=${nas_res%%,*}% wan=${wan_res%%,*}%)"
            check_nas_wan &
        fi
    else
        [ "$lossy" -ge "$STREAK" ] && echo "$ts: Packet loss cleared after $lossy lossy samples"
        lossy=0
    fi

    find "$LOG_DIR" -name 'ping-*.csv' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
    sleep "$INTERVAL"
done
