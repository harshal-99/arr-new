#!/usr/bin/env bash

# This script configures apcupsd on the Master machine (connected via USB to the UPS).
# It must be run with sudo/root privileges.

set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo or as root." >&2
  exit 1
fi

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

echo "Configuring Master apcupsd settings..."
set_config_val "UPSCABLE" "usb" "$CONF_FILE"
set_config_val "UPSTYPE" "usb" "$CONF_FILE"
set_config_val "DEVICE" "" "$CONF_FILE" # For USB, this must be blank
set_config_val "NETSERVER" "on" "$CONF_FILE"
set_config_val "NISIP" "0.0.0.0" "$CONF_FILE" # Listen on all network interfaces
set_config_val "NISPORT" "3551" "$CONF_FILE"
set_config_val "BATTERYLEVEL" "10" "$CONF_FILE" # Shutdown if battery <= 10%
set_config_val "MINUTES" "10" "$CONF_FILE" # Shutdown if remaining runtime <= 10 mins
set_config_val "TIMEOUT" "0" "$CONF_FILE" # Disable timeout (use battery & minutes level)

# Enable startup in /etc/default/apcupsd if it exists (Debian/Ubuntu specific)
if [ -f "$DEFAULT_FILE" ]; then
  sed -i 's/^ISCONFIGURED=no/ISCONFIGURED=yes/' "$DEFAULT_FILE"
fi

# UFW Firewall handling (if UFW is active)
if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
  echo "UFW firewall detected. Opening port 3551/tcp for UPS status queries..."
  ufw allow 3551/tcp comment 'Allow apcupsd master NIS'
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
echo "Check UPS status with: sudo apcaccess status"
