#!/usr/bin/env bash
set -euo pipefail

############################
# Variables
############################

MOK_PASSWORD="universalblue"

MOK_CERT="/usr/share/cert/MOK.pem"
MOK_DER="/usr/share/cert/MOK.der"
MOK_PRIV="/tmp/MOK.priv"

SERVICE_PATH="/etc/systemd/system/mok-enroll.service"

SIGN_FILE="$(find /usr/src -type f -path "*/scripts/sign-file" | head -n1)"

############################
# Install certs
############################

install -dm755 /usr/share/cert
install -m644 MOK.pem "$MOK_CERT"
install -m644 MOK.der "$MOK_DER"

############################
# Load private key
############################

umask 077
printf "%s" "${KERNEL_SECRET:?missing KERNEL_SECRET}" > "$MOK_PRIV"

############################
# Sign kernel modules
############################

while IFS= read -r module; do
    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_CERT" "$module"
done < <(find /usr/lib/modules -type f -name "*.ko")

############################
# Sign kernel images
############################

while IFS= read -r kernel; do
    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_CERT" "$kernel"
done < <(find /usr/lib/modules -type f -name "vmlinuz*")

############################
# Refresh module metadata
############################

for dir in /usr/lib/modules/*; do
    depmod -b /usr "$dir"
done

############################
# Create systemd service
############################

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${MOK_CERT}
ConditionPathExists=!/var/.mok-enrolled

[Service]
Type=oneshot
ExecStart=/bin/sh -c '(echo "${MOK_PASSWORD}"; echo "${MOK_PASSWORD}") | mokutil --import "${MOK_CERT}"'
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
