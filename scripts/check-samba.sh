#!/usr/bin/env bash

# Verifies the live Samba config still contains the tracked [tdarr-transcode]
# share (samba/tdarr-transcode.conf) and that it points at the Tdarr server's
# transcode cache. Ubuntu release upgrades replace /etc/samba/smb.conf with the
# stock file, which silently drops the share and stops remote Tdarr nodes.
# Read-only; does not need sudo. Exits non-zero on any mismatch.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKED="$REPO_DIR/samba/tdarr-transcode.conf"
SECTION="tdarr-transcode"
status=0

# Normalise both sides through testparm so formatting/defaults don't matter
expected="$(testparm -s --section-name="$SECTION" "$TRACKED" 2>/dev/null)"
live="$(testparm -s --section-name="$SECTION" 2>/dev/null || true)"

if [ -z "$live" ]; then
  echo "FAIL: [$SECTION] share is missing from /etc/samba/smb.conf"
  echo "  fix: sudo tee -a /etc/samba/smb.conf < $TRACKED && sudo systemctl reload smbd"
  exit 1
fi

if [ "$expected" != "$live" ]; then
  echo "FAIL: live [$SECTION] differs from $TRACKED:"
  diff <(echo "$expected") <(echo "$live") | sed 's/^/  /' || true
  status=1
else
  echo "OK: live [$SECTION] matches tracked config"
fi

# The share must serve the same directory the Tdarr server mounts as /temp
share_path="$(echo "$live" | sed -n 's/^\s*path = //p')"
cache_root="$(grep -E '^TDARR_TRANSCODE_ROOT=' "$REPO_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2-)"
cache_root="${cache_root:-/tmp/tdarr-transcode}"
if [ "$share_path" != "$cache_root" ]; then
  echo "FAIL: share path $share_path != TDARR_TRANSCODE_ROOT $cache_root"
  status=1
else
  echo "OK: share path matches TDARR_TRANSCODE_ROOT ($cache_root)"
fi

if ! systemctl is-active --quiet smbd; then
  echo "FAIL: smbd is not running"
  status=1
else
  echo "OK: smbd is running"
fi

exit $status
