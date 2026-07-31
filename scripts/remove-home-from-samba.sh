#!/bin/bash
# Script to remove /home/harshal as a Samba share

# Check if /etc/samba/smb.conf exists
if [ ! -f /etc/samba/smb.conf ]; then
    echo "Error: /etc/samba/smb.conf not found."
    exit 1
fi

# Create a secure unique temp file
TMP_FILE=$(mktemp)

# Use Python to safely parse and print the modified configuration to the temp file
# Status and warnings are printed to stderr
if python3 -c '
import sys
import re

try:
    with open("/etc/samba/smb.conf", "r") as f:
        content = f.read()
except Exception as e:
    print(f"Error reading /etc/samba/smb.conf: {e}", file=sys.stderr)
    sys.exit(1)

# Match [home] and all lines under it until the next section (starting with [) or end of file
pattern = r"\n*\[home\](?:\n[^\[]*)*"
new_content, count = re.subn(pattern, "", content)

if count > 0:
    print(f"Removed [home] section ({count} match found).", file=sys.stderr)
    print(new_content, end="")
else:
    print("Warning: [home] section not found in /etc/samba/smb.conf.", file=sys.stderr)
    sys.exit(1)
' > "$TMP_FILE"; then
    echo "Backing up existing Samba configuration to /etc/samba/smb.conf.bak..."
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    
    echo "Writing new Samba configuration..."
    sudo cp "$TMP_FILE" /etc/samba/smb.conf
    rm -f "$TMP_FILE"
else
    echo "No changes made."
    rm -f "$TMP_FILE"
    exit 1
fi

echo "Verifying Samba configuration..."
testparm -s

echo "Restarting Samba service..."
sudo systemctl restart smbd

echo "Done!"
