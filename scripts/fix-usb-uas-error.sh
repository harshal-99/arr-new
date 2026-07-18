#!/bin/bash
# Script to fix the USB UAS read-only filesystem error for RTL9201 (0bda:9201)

set -e

# Ensure the script is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (e.g., sudo ./scripts/fix-usb-uas-error.sh)."
  exit 1
fi

echo "=== Step 1: Stopping Docker ARR Stack ==="
# Stop docker containers first to unlock the /mnt/hdd filesystem
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ -n "$SUDO_USER" ]; then
  echo "Stopping systemd user service for $SUDO_USER..."
  sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$SUDO_USER")/bus systemctl --user stop arr-stack.service || true
else
  echo "Stopping stack via docker compose..."
  docker compose down
fi

echo "=== Step 2: Configuring USB Storage Quirk ==="
# Create modprobe quirk config to disable UAS for 0bda:9201 (RTL9201)
QUIRK_FILE="/etc/modprobe.d/usb-storage.conf"
QUIRK_LINE="options usb-storage quirks=0bda:9201:u"

if [ -f "$QUIRK_FILE" ] && grep -q "0bda:9201" "$QUIRK_FILE"; then
  echo "UAS quirk for 0bda:9201 already exists in $QUIRK_FILE."
else
  echo "$QUIRK_LINE" >> "$QUIRK_FILE"
  echo "Added UAS quirk to $QUIRK_FILE."
fi

echo "=== Step 3: Updating initramfs ==="
update-initramfs -u

echo "=== Step 4: Unmounting /mnt/hdd ==="
if mountpoint -q /mnt/hdd; then
  echo "Unmounting /mnt/hdd..."
  umount -l /mnt/hdd || true
else
  echo "/mnt/hdd is already unmounted."
fi

echo "=== Step 5: Running fsck to repair any filesystem errors ==="
UUID_PATH="/dev/disk/by-uuid/684bd0de-c039-4704-8b99-f12e74b6e4f9"
if [ ! -e "$UUID_PATH" ]; then
  echo "Error: Could not find HDD partition by UUID 684bd0de-c039-4704-8b99-f12e74b6e4f9"
  exit 1
fi

HDD_DEV=$(readlink -f "$UUID_PATH")
if [ -b "$HDD_DEV" ]; then
  echo "Running fsck on $HDD_DEV..."
  fsck -f -y "$HDD_DEV" || true
else
  echo "Error: Resolved path $HDD_DEV is not a block device."
  exit 1
fi

echo "=== Done ==="
echo "Please reboot your system ('sudo reboot') or physically unplug and replug the USB drive."
echo "Once restarted, the drive will mount using the stable usb-storage driver instead of UAS,"
echo "and your write permissions will be restored."
