#!/usr/bin/env bash
# Script to restore the ARR stack configuration from a tar.gz backup.

set -euo pipefail

# Ensure the script is run with root privileges (needed to write/restore /docker/appdata)
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (e.g., sudo $0 <backup_file_path>)" >&2
  exit 1
fi

# Check if a backup file argument was provided
if [ "$#" -ne 1 ]; then
  echo "Usage: sudo $0 <path_to_backup_tarball>" >&2
  exit 1
fi

BACKUP_FILE="$1"

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
  echo "Error: Backup file '$BACKUP_FILE' does not exist." >&2
  exit 1
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"
APPDATA_ROOT="/docker/appdata"

# Determine the non-root user who invoked sudo
REAL_USER="${SUDO_USER:-harshal}"
REAL_UID=$(id -u "$REAL_USER")
export XDG_RUNTIME_DIR="/run/user/$REAL_UID"

log() {
  echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 1. Warn user and ask for confirmation
echo "=== ARR Stack Configuration Restore ==="
echo "Backup File: $BACKUP_FILE"
echo "Target User: $REAL_USER (UID: $REAL_UID)"
echo "App Directory: $APP_DIR"
echo "========================================"
echo "WARNING: Restoring will overwrite existing configuration files in $APPDATA_ROOT"
echo "and your ARR project folder. To prevent data loss, the current folders will"
echo "be moved to backup locations (.bak) before extraction."
echo -n "Are you sure you want to proceed? (y/N): "
read -r CONFIRM

if [[ ! "$CONFIRM" =~ ^[yY](es)?$ ]]; then
  echo "Restore aborted by user."
  exit 0
fi

# 2. Check if systemd user service is used and active
SYSTEMD_SERVICE_FILE="/home/${REAL_USER}/.config/systemd/user/arr-stack.service"
USING_SYSTEMD=false
WAS_ACTIVE=false

if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
  USING_SYSTEMD=true
  if sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user is-active arr-stack.service >/dev/null 2>&1; then
    WAS_ACTIVE=true
  fi
fi

# 3. Stop services to ensure clean restore
log "Step 1: Stopping services before restore..."
if [ "$WAS_ACTIVE" = true ] || [ "$USING_SYSTEMD" = true ]; then
  echo "Stopping via systemd user service..."
  sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user stop arr-stack.service || true
else
  echo "Stopping via docker compose down..."
  sudo -u "$REAL_USER" docker --context default compose -f "${APP_DIR}/docker-compose.yml" down || true
fi

# 4. Safely move existing directories to .bak
log "Step 2: Relocating current configuration directories..."
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

backup_and_clear() {
  local target_path="$1"
  if [ -e "$target_path" ]; then
    local bak_path="${target_path}.bak_${TIMESTAMP}"
    echo "  Moving $target_path to $bak_path"
    mv "$target_path" "$bak_path"
  fi
}

backup_and_clear "$APPDATA_ROOT"
backup_and_clear "${APP_DIR}/.env"
# We do not rename docker-compose.yml itself to prevent loss of setup files,
# but tar extraction will naturally overwrite it if it's in the backup.
backup_and_clear "${APP_DIR}/homepage/config"
backup_and_clear "${APP_DIR}/profilarr/config"

# 5. Extract the backup tarball
log "Step 3: Extracting backup files..."
tar -xzf "$BACKUP_FILE" -C /
echo "Backup extraction complete."

# 6. Ensure correct permissions
log "Step 4: Ensuring correct file permissions and ownership..."
# Restore ownership of application configs in home directory back to the user
chown -R "$REAL_USER:$REAL_USER" "${APP_DIR}/homepage/config" 2>/dev/null || true
chown -R "$REAL_USER:$REAL_USER" "${APP_DIR}/profilarr/config" 2>/dev/null || true
if [ -f "${APP_DIR}/.env" ]; then
  chown "$REAL_USER:$REAL_USER" "${APP_DIR}/.env"
fi

# 7. Restart services
log "Step 5: Restarting services..."
if [ "$USING_SYSTEMD" = true ]; then
  echo "Starting via systemd user service..."
  sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start arr-stack.service
  
  # Verify systemd service status
  sleep 3
  sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user status arr-stack.service --no-pager || true
else
  echo "Starting via docker compose..."
  cd "$APP_DIR"
  sudo -u "$REAL_USER" docker --context default compose up -d
fi

log "=== ARR Stack Configuration Restore Completed Successfully ==="
