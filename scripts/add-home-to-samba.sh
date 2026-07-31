#!/bin/bash
# Script to add /home/harshal as a Samba share

SHARE_BLOCK="
[home]
   comment = Harshal Home Share
   path = /home/harshal
   browseable = yes
   read only = no
   guest ok = yes
   force user = harshal
   force group = harshal
   create mask = 0664
   directory mask = 0775
   veto files = /._*/.DS_Store/.Trashes/.TemporaryItems/
   delete veto files = yes
"

# Check if /etc/samba/smb.conf exists
if [ ! -f /etc/samba/smb.conf ]; then
    echo "Error: /etc/samba/smb.conf not found."
    exit 1
fi

# Check if [home] share already exists
if grep -q "^\[home\]" /etc/samba/smb.conf; then
    echo "Warning: [home] share is already defined in /etc/samba/smb.conf. Skipping append."
else
    echo "Adding [home] share to /etc/samba/smb.conf..."
    echo "$SHARE_BLOCK" | sudo tee -a /etc/samba/smb.conf > /dev/null
fi

echo "Verifying Samba configuration..."
testparm -s

echo "Restarting Samba service..."
sudo systemctl restart smbd

echo "Done!"
