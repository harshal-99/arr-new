#!/usr/bin/env bash

# This script configures apcupsd on the Slave machine (which connects to the Master via LAN).
# It must be run with sudo/root privileges.

set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo or as root." >&2
  exit 1
fi

# Usage help
if [ $# -lt 1 ]; then
  echo "Usage: sudo $0 <master_ip> [shutdown_minutes]" >&2
  echo "Example: sudo $0 192.168.0.19 12" >&2
  exit 1
fi

MASTER_IP="$1"
SHUTDOWN_MINUTES="${2:-12}" # Default to 12 minutes (shuts down slightly before master's 10 mins)

CONF_FILE="/etc/apcupsd/apcupsd.conf"
DEFAULT_FILE="/etc/default/apcupsd"

# Install apcupsd if not present
if ! command -v apcaccess &> /dev/null; then
  echo "apcupsd is not installed. Installing..."
  if command -v apt-get &> /dev/null; then
    apt-get update && apt-get install -y apcupsd
  elif command -v dnf &> /dev/null; then
    dnf install -y apcupsd
  elif command -v pacman &> /dev/null; then
    pacman -Sy --noconfirm apcupsd
  else
    echo "Error: Package manager not supported. Please install apcupsd manually." >&2
    exit 1
  fi
fi

# Backup configuration file
if [ -f "$CONF_FILE" ]; then
  echo "Backing up existing configuration to ${CONF_FILE}.bak"
  cp "$CONF_FILE" "${CONF_FILE}.bak"
else
  echo "Error: Configuration file $CONF_FILE not found." >&2
  exit 1
fi

# Helper function to safely set key-value configurations in apcupsd.conf
set_config_val() {
  local key="$1"
  local val="$2"
  local file="$3"
  
  if grep -qE "^#?${key}([[:space:]]|$)" "$file"; then
    sed -i -E "s/^#?${key}([[:space:]]+.*|)$/${key} ${val}/" "$file"
  else
    echo "${key} ${val}" >> "$file"
  fi
}

echo "Configuring Slave apcupsd settings (Master IP: $MASTER_IP, Shutdown at: $SHUTDOWN_MINUTES minutes left)..."
set_config_val "UPSCABLE" "ether" "$CONF_FILE"
set_config_val "UPSTYPE" "net" "$CONF_FILE"
set_config_val "DEVICE" "${MASTER_IP}:3551" "$CONF_FILE"
set_config_val "NETSERVER" "on" "$CONF_FILE"
set_config_val "NISIP" "127.0.0.1" "$CONF_FILE"
set_config_val "NISPORT" "3551" "$CONF_FILE"
set_config_val "BATTERYLEVEL" "10" "$CONF_FILE"
set_config_val "MINUTES" "$SHUTDOWN_MINUTES" "$CONF_FILE"
set_config_val "TIMEOUT" "0" "$CONF_FILE"

# Enable startup in /etc/default/apcupsd if it exists (Debian/Ubuntu specific)
if [ -f "$DEFAULT_FILE" ]; then
  sed -i 's/^ISCONFIGURED=no/ISCONFIGURED=yes/' "$DEFAULT_FILE"
fi

echo "Restarting apcupsd service..."
if command -v systemctl &> /dev/null; then
  systemctl daemon-reload
  systemctl enable apcupsd
  systemctl restart apcupsd
else
  service apcupsd restart
fi

echo "Configuration completed successfully!"
echo "Check connection and UPS status with: sudo apcaccess status"
