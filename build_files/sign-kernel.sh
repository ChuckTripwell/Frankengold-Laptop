#!/usr/bin/env bash
set -euo pipefail

############################
# Variables
############################

MOK_PASSWORD="universalblue"
MOK_DER="/usr/share/cert/MOK.der"
MOK_PRIV="/tmp/MOK.priv"
SERVICE_PATH="/etc/systemd/system/mok-enroll.service"

############################
# Install certs
############################

#install -dm755 /usr/share/cert
#install -m644 MOK.der "$MOK_DER"

############################
# Load private key
############################

VMLINUZ="$1"

sbsign --key "$MOK_PRIV" --cert /usr/share/cert/MOK.pem --output "$VMLINUZ" "$VMLINUZ"
shred -u "$MOK_PRIV" || rm -f "$MOK_PRIV"

#umask 077
#printf '%s\n' "$KERNEL_SECRET" > "$MOK_PRIV"

#printf "%s" "$KERNEL_SECRET" | tr -d '\r' > "$MOK_PRIV"
#chmod 600 "$MOK_PRIV"

############################
# Sign kernel modules (DER)
############################

#while IFS= read -r module; do
#    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$module"
#done < <(find /usr/lib/modules -type f -name "*.ko")

############################
# Sign kernel images (DER)
############################

#while IFS= read -r kernel; do
#    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$kernel"
#done < <(find /usr/lib/modules -type f -name "vmlinuz*")

############################
# Refresh module metadata
############################

for dir in /usr/lib/modules/*; do
    depmod -b /usr "$dir"
done

############################
# Create systemd service for MOK enrollment
############################

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${MOK_DER}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c "printf '%s\n%s\n' \"$MOK_PASSWORD\" \"$MOK_PASSWORD\" | mokutil --import \"$MOK_DER\""
ExecStartPost=/usr/bin/touch /var/.mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable mok-enroll.service

############################
# Cleanup
############################

shred -u "$MOK_PRIV" || rm -f "$MOK_PRIV"
