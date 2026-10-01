#!/usr/bin/env bash

# Installs the tracked NUT config (nut/) into /etc/nut and restarts NUT.
# This host is the UPS server (USB to the APC); the NAS logs in as "nasmonitor".
# Re-run after an OS upgrade - release upgrades replace /etc/nut/* with stock
# files (keeping ours as *.dpkg-old), which leaves nut-server/nut-monitor failing.
# It must be run with sudo/root privileges.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo or as root." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_DIR/nut"
DEST_DIR="/etc/nut"

# Read only the NUT passwords from .env (not sourcing it - other values aren't shell-safe)
env_value() {
  grep -E "^$1=" "$REPO_DIR/.env" | tail -n1 | cut -d= -f2-
}
NUT_LOCALMONITOR_PASSWORD="$(env_value NUT_LOCALMONITOR_PASSWORD)"
NUT_NASMONITOR_PASSWORD="$(env_value NUT_NASMONITOR_PASSWORD)"
if [ -z "$NUT_LOCALMONITOR_PASSWORD" ] || [ -z "$NUT_NASMONITOR_PASSWORD" ]; then
  echo "Error: NUT_LOCALMONITOR_PASSWORD and NUT_NASMONITOR_PASSWORD must be set in $REPO_DIR/.env" >&2
  exit 1
fi
export NUT_LOCALMONITOR_PASSWORD NUT_NASMONITOR_PASSWORD

if ! command -v upsd &> /dev/null; then
  echo "NUT is not installed. Installing..."
  apt-get update && apt-get install -y nut
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
  if [ -f "$DEST_DIR/$f" ]; then
    cp -a "$DEST_DIR/$f" "$DEST_DIR/$f.bak-$STAMP"
  fi
  # Only substitute our two variables, so any other '$' in the files is left alone
  envsubst '${NUT_LOCALMONITOR_PASSWORD} ${NUT_NASMONITOR_PASSWORD}' < "$SRC_DIR/$f" > "$DEST_DIR/$f"
  chown root:nut "$DEST_DIR/$f"
  chmod 640 "$DEST_DIR/$f"
done
echo "Installed config into $DEST_DIR (previous files kept as *.bak-$STAMP)"

# Editing ups.conf triggers nut-driver-enumerator via its .path unit. Left to race
# with our own restarts, it deadlocks: it waits on "systemctl restart nut-server"
# while nut-server waits on nut-driver.target, which waits on the enumerator.
# So pause the trigger, run the enumeration ourselves, then restart in order.
systemctl stop nut-driver-enumerator.path nut-driver-enumerator.service
systemctl reset-failed 'nut-*' 2>/dev/null || true
/usr/libexec/nut-driver-enumerator.sh
systemctl restart nut-driver.target nut-server nut-monitor
systemctl start nut-driver-enumerator.path

sleep 3
systemctl is-active nut-server nut-monitor
upsc apc1500@localhost 2>/dev/null | grep -E 'ups.status|battery.charge:|battery.runtime:'
