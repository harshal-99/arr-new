#!/bin/sh
# NIC receive-stall watchdog for the QNAP TS-433 NAS (192.168.0.18)
# The NAS's 2.5GbE port (eth0, Realtek RTL8125, r8125 driver) periodically
# stops receiving: the link stays up but the NIC drops nearly every inbound
# frame (`ethtool -S eth0` rx_mac_missed climbs into the millions), so the NAS
# goes dark for every client - and the ARR stack's CIFS mount goes stale -
# until the link is reset (cable replug, router reboot or NAS reboot).
# This pings the gateway and the ARR host; when neither answers for about a
# minute while the cable is still connected, it renegotiates the link (the
# same effect as a replug), falling back to a full interface bounce.
# Runs as root from autorun.sh (see nas/autorun.sh); busybox sh compatible.

IFACE="${NIC_WATCHDOG_IFACE:-eth0}"
TARGETS="${NIC_WATCHDOG_TARGETS:-192.168.0.1 192.168.0.19}"
INTERVAL="${NIC_WATCHDOG_INTERVAL:-15}"
FAILS="${NIC_WATCHDOG_FAILS:-4}"
COOLDOWN="${NIC_WATCHDOG_COOLDOWN:-300}"
LOG_DIR=/share/CACHEDEV1_DATA/.nic-watchdog
PIDFILE=/var/run/nic-watchdog.pid

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "nic-watchdog already running (pid $(cat "$PIDFILE"))"
    exit 0
fi
echo $$ > "$PIDFILE"

# The data volume may not be mounted yet this early in boot.
log() {
    if [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null; then
        logfile="$LOG_DIR/nic-watchdog.log"
    else
        logfile=/tmp/nic-watchdog.log
    fi
    echo "$(date '+%F %T') $*" >> "$logfile"
}

# Also surfaces in QTS Notification Center / QuLog as a warning.
event() {
    log "$*"
    /sbin/log_tool -t 1 -a "[NIC watchdog] $*" >/dev/null 2>&1
}

reachable() {
    for t in $TARGETS; do
        ping -c 1 -W 2 "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

missed() {
    ethtool -S "$IFACE" 2>/dev/null | awk '/rx_mac_missed/ {print $2; exit}'
}

log "started (iface=$IFACE targets=$TARGETS interval=${INTERVAL}s fails=$FAILS cooldown=${COOLDOWN}s rx_mac_missed=$(missed))"

fails=0
last_reset=0
while true; do
    # A real unplug or router reboot drops carrier; only act when the link
    # claims to be up but nothing gets through.
    if [ "$(cat /sys/class/net/"$IFACE"/carrier 2>/dev/null)" = "1" ] && ! reachable; then
        fails=$((fails + 1))
    else
        fails=0
    fi

    if [ "$fails" -ge "$FAILS" ]; then
        now=$(date +%s)
        if [ $((now - last_reset)) -ge "$COOLDOWN" ]; then
            last_reset=$now
            event "No reply from $TARGETS for ~$((FAILS * INTERVAL))s with $IFACE link up (rx_mac_missed=$(missed)); renegotiating link"
            defroute="$(ip route show default | head -1)"
            ethtool -r "$IFACE"
            sleep 20
            if reachable; then
                event "$IFACE recovered after link renegotiation (rx_mac_missed=$(missed))"
            else
                log "still unreachable after renegotiation; bouncing $IFACE"
                ip link set "$IFACE" down
                sleep 5
                ip link set "$IFACE" up
                sleep 15
                # Taking the interface down deletes its routes.
                if [ -n "$defroute" ] && ! ip route show default | grep -q .; then
                    ip route add $defroute
                fi
                if reachable; then
                    event "$IFACE recovered after interface bounce (rx_mac_missed=$(missed))"
                else
                    event "$IFACE still unreachable after interface bounce; will retry in ${COOLDOWN}s"
                fi
            fi
        fi
        fails=0
    fi
    sleep "$INTERVAL"
done
