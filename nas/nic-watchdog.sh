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
#
# Logging (to $LOG_DIR/nic-watchdog.log, rotated to .1 at $LOG_MAX_KB):
#   check    - every check where a target failed, the carrier was down, or
#              rx_mac_missed grew by >= $MISSED_ALERT since the last check;
#              shows each target's ping result and the NIC counter deltas
#   recovered - when a degraded run ends: its length and counter deltas
#   status   - every $STATUS_EVERY checks: counter deltas over that period
# so an outage records what the NAS itself saw, not only what clients saw.
# Runs as root from autorun.sh (see nas/autorun.sh); busybox sh compatible.

IFACE="${NIC_WATCHDOG_IFACE:-eth0}"
TARGETS="${NIC_WATCHDOG_TARGETS:-192.168.0.1 192.168.0.19}"
INTERVAL="${NIC_WATCHDOG_INTERVAL:-15}"
FAILS="${NIC_WATCHDOG_FAILS:-4}"
COOLDOWN="${NIC_WATCHDOG_COOLDOWN:-300}"
STATUS_EVERY="${NIC_WATCHDOG_STATUS_EVERY:-20}"
MISSED_ALERT="${NIC_WATCHDOG_MISSED_ALERT:-20000}"  # baseline ~1400/check (2026-11-14)
LOG_MAX_KB="${NIC_WATCHDOG_LOG_MAX_KB:-1024}"
LOG_DIR="${NIC_WATCHDOG_LOG_DIR:-/share/CACHEDEV1_DATA/.nic-watchdog}"
PIDFILE="${NIC_WATCHDOG_PIDFILE:-/var/run/nic-watchdog.pid}"

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
    size_kb=$(du -k "$logfile" 2>/dev/null | awk '{print $1}')
    if [ "${size_kb:-0}" -ge "$LOG_MAX_KB" ]; then
        mv -f "$logfile" "$logfile.1"
    fi
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

# Pings every target (no short-circuit) so the log shows which ones answered.
# Sets: probe_result ("192.168.0.1=ok 192.168.0.19=FAIL"), probe_ok (0/1),
# probe_allok (0/1).
probe() {
    probe_result=""
    probe_ok=0
    probe_allok=1
    for t in $TARGETS; do
        if ping -c 1 -W 2 "$t" >/dev/null 2>&1; then
            probe_result="$probe_result $t=ok"
            probe_ok=1
        else
            probe_result="$probe_result $t=FAIL"
            probe_allok=0
        fi
    done
    probe_result="${probe_result# }"
}

missed() {
    ethtool -S "$IFACE" 2>/dev/null | awk '/rx_mac_missed/ {print $2; exit}'
}

# Prints "rx_mac_missed rx_missed rx_pause_on tx_pause_on" (0 if absent).
counters() {
    ethtool -S "$IFACE" 2>/dev/null | awk '
        $1 == "rx_mac_missed:" { m = $2 }
        $1 == "rx_missed:"     { r = $2 }
        $1 == "rx_pause_on:"   { rp = $2 }
        $1 == "tx_pause_on:"   { tp = $2 }
        END {
            if (m == "") m = 0; if (r == "") r = 0
            if (rp == "") rp = 0; if (tp == "") tp = 0
            print m, r, rp, tp
        }'
}

# "rx_mac_missed=+N rx_missed=+N rx_pause_on=+N tx_pause_on=+N" between two
# counters() snapshots passed as 8 args. A reset counter (driver reload)
# shows as a negative delta.
deltas() {
    echo "rx_mac_missed=+$(($5 - $1)) rx_missed=+$(($6 - $2)) rx_pause_on=+$(($7 - $3)) tx_pause_on=+$(($8 - $4))"
}

log "started (iface=$IFACE targets=$TARGETS interval=${INTERVAL}s fails=$FAILS cooldown=${COOLDOWN}s status_every=$STATUS_EVERY missed_alert=$MISSED_ALERT rx_mac_missed=$(missed))"

fails=0
last_reset=0
checks=0
bad_run=0          # consecutive degraded checks (any target failed / no carrier)
prev=$(counters)   # snapshot at the previous check
status_base=$prev  # snapshot at the last status line
run_base=$prev     # snapshot when the current degraded run started
run_start=""
while true; do
    carrier="$(cat /sys/class/net/"$IFACE"/carrier 2>/dev/null)"
    probe
    now_c=$(counters)
    # shellcheck disable=SC2086 # word-splitting the snapshots is intended
    step=$(deltas $prev $now_c)
    step_missed=$(echo "$step" | sed 's/^rx_mac_missed=+\(-*[0-9]*\).*/\1/')

    degraded=0
    if [ "$carrier" != "1" ] || [ "$probe_allok" -ne 1 ]; then
        degraded=1
    fi

    if [ "$degraded" -eq 1 ]; then
        if [ "$bad_run" -eq 0 ]; then
            run_start=$(date '+%T')
            run_base=$prev
        fi
        bad_run=$((bad_run + 1))
    fi

    # A real unplug or router reboot drops carrier; only act when the link
    # claims to be up but nothing gets through.
    if [ "$carrier" = "1" ] && [ "$probe_ok" -eq 0 ]; then
        fails=$((fails + 1))
    else
        fails=0
    fi

    if [ "$degraded" -eq 0 ] && [ "$bad_run" -gt 0 ]; then
        # shellcheck disable=SC2086
        log "recovered after $bad_run degraded checks (~$((bad_run * INTERVAL))s, since $run_start) $(deltas $run_base $prev)"
        bad_run=0
    fi
    if [ "$degraded" -eq 1 ] || [ "${step_missed:-0}" -ge "$MISSED_ALERT" ]; then
        log "check carrier=${carrier:-?} $probe_result fails=$fails/$FAILS $step"
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
        else
            log "would reset $IFACE but in cooldown ($((COOLDOWN - (now - last_reset)))s left)"
        fi
        fails=0
    fi

    checks=$((checks + 1))
    if [ "$checks" -ge "$STATUS_EVERY" ]; then
        # shellcheck disable=SC2086
        log "status last ~$((checks * INTERVAL))s: $(deltas $status_base $now_c) total_rx_mac_missed=${now_c%% *}"
        status_base=$now_c
        checks=0
    fi

    prev=$now_c
    sleep "$INTERVAL"
done
