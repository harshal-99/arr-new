#!/usr/bin/env bash
# Script to configure Apache as a reverse proxy for the ARR stack.

set -euo pipefail

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (e.g., sudo ./setup-apache-proxy.sh)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_SOURCE="${SCRIPT_DIR}/apache-arr.conf"
CONFIG_DEST="/etc/apache2/sites-available/arr-stack.conf"

if [ ! -f "$CONFIG_SOURCE" ]; then
  echo "Error: Configuration file not found at $CONFIG_SOURCE" >&2
  exit 1
fi

echo "Copying Apache configuration..."
cp "$CONFIG_SOURCE" "$CONFIG_DEST"

echo "Enabling Apache reverse proxy modules..."
a2enmod proxy >/dev/null 2>&1 || true
a2enmod proxy_http >/dev/null 2>&1 || true
a2enmod proxy_wstunnel >/dev/null 2>&1 || true
a2enmod headers >/dev/null 2>&1 || true
a2enmod rewrite >/dev/null 2>&1 || true
# Enable modules explicitly
a2enmod proxy proxy_http proxy_wstunnel headers rewrite

echo "Enabling arr-stack VirtualHost configuration..."
a2ensite arr-stack.conf

echo "Testing Apache configuration..."
if apache2ctl configtest; then
  echo "Restarting Apache service..."
  systemctl restart apache2
  echo "Apache has been successfully configured as a reverse proxy!"
else
  echo "Error: Apache configuration test failed. Reverting changes..." >&2
  a2dissite arr-stack.conf || true
  rm -f "$CONFIG_DEST"
  exit 1
fi
