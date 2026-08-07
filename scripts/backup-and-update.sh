#!/usr/bin/env bash
# Script to create a backup of the ARR stack configuration, pull latest images, and restart services.

set -euo pipefail

# Ensure the script is run with root privileges (needed to read/backup /docker/appdata)
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (e.g., sudo $0)" >&2
  exit 1
fi

# Configuration
BACKUP_DIR="/docker/backups"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"
APPDATA_ROOT="/docker/appdata"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/arr_backup_${TIMESTAMP}.tar.gz"

# Use pigz for multi-core compression if available, fallback to standard gzip
COMPRESS_PROGRAM="gzip"
if command -v pigz >/dev/null 2>&1; then
  COMPRESS_PROGRAM="pigz"
fi

# Determine the non-root user who invoked sudo
REAL_USER="${SUDO_USER:-harshal}"
REAL_UID=$(id -u "$REAL_USER")
export XDG_RUNTIME_DIR="/run/user/$REAL_UID"

log() {
  echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "=== ARR Stack Backup & Update Started ==="
echo "Invoking User: $REAL_USER (UID: $REAL_UID)"
echo "App Directory: $APP_DIR"
echo "Backup Destination: $BACKUP_FILE"
echo "========================================"

# Change directory to the app directory so docker compose can resolve relative paths and .env
cd "$APP_DIR"

# 1. Validate Docker Compose configuration before making any changes
log "Step 1: Validating docker-compose configuration..."
if ! sudo -u "$REAL_USER" docker --context default compose config --quiet; then
  echo "Error: docker-compose.yml configuration is invalid! Aborting backup and update." >&2
  exit 1
fi
echo "Configuration is valid."

# 2. Check if systemd user service is used
SYSTEMD_SERVICE_FILE="/home/${REAL_USER}/.config/systemd/user/arr-stack.service"
USING_SYSTEMD=false
WAS_ACTIVE=false

if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
  USING_SYSTEMD=true
  echo "Systemd user service detected at $SYSTEMD_SERVICE_FILE"
  # Check if service is currently active
  if sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user is-active arr-stack.service >/dev/null 2>&1; then
    WAS_ACTIVE=true
    echo "Services are currently active via systemd."
  else
    echo "Services are currently inactive via systemd."
  fi
fi

# 3. Gracefully stop services to prevent DB corruption during backup
log "Step 2: Stopping services to ensure safe backup..."
if [ "$WAS_ACTIVE" = true ]; then
  echo "Stopping via systemd user service..."
  sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user stop arr-stack.service
else
  echo "Stopping via docker compose down..."
  sudo -u "$REAL_USER" docker --context default compose down
fi

# 4. Create backup directory and build target list
log "Step 3: Creating backup directory..."
mkdir -p "$BACKUP_DIR"
chown "$REAL_USER:$REAL_USER" "$BACKUP_DIR"

log "Building backup targets list..."
tar_targets=()

add_tar_target() {
  local target="$1"
  if [ -e "$target" ]; then
    # Strip leading slash for -C /
    tar_targets+=("${target#/}")
    echo "  + Added target: $target"
  else
    echo "  - Skipping target (does not exist): $target"
  fi
}

add_tar_target "$APPDATA_ROOT"
add_tar_target "${APP_DIR}/.env"
add_tar_target "${APP_DIR}/docker-compose.yml"
add_tar_target "${APP_DIR}/homepage/config"
add_tar_target "${APP_DIR}/profilarr/config"

if [ ${#tar_targets[@]} -eq 0 ]; then
  echo "Error: No valid backup targets found! Aborting." >&2
  # Restart services before exiting to avoid leaving the system down
  log "Restarting services before aborting..."
  if [ "$WAS_ACTIVE" = true ]; then
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start arr-stack.service
  else
    sudo -u "$REAL_USER" docker --context default compose up -d
  fi
  exit 1
fi

log "Creating compressed tarball backup (using ${COMPRESS_PROGRAM})..."
# Exclude cache, log, and temp directories to optimize backup size
tar -I "$COMPRESS_PROGRAM" -cf "$BACKUP_FILE" \
  --exclude="*/cache/*" \
  --exclude="*/Cache/*" \
  --exclude="*/logs/*" \
  --exclude="*/log/*" \
  --exclude="*/temp/*" \
  --exclude="*/tmp/*" \
  -C / \
  "${tar_targets[@]}"

# Set ownership of backup file to the real user
chown "$REAL_USER:$REAL_USER" "$BACKUP_FILE"
echo "Backup created successfully at: $BACKUP_FILE"
ls -lh "$BACKUP_FILE"

# 5. Pull latest docker images
log "Step 4: Pulling latest docker images..."
sudo -u "$REAL_USER" docker --context default compose pull

# 6. Restart services
log "Step 5: Restarting services..."
if [ "$USING_SYSTEMD" = true ]; then
  echo "Starting via systemd user service..."
  sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start arr-stack.service
  
  # Verify systemd service status
  sleep 3
  sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user status arr-stack.service --no-pager || true
else
  echo "Starting via docker compose..."
  sudo -u "$REAL_USER" docker --context default compose up -d
fi

log "=== ARR Stack Backup & Update Completed Successfully ==="
