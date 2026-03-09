#!/bin/bash
set -e

# --- Variables ---
MOK_PASSWORD="universalblue"
MOK_CERT_PEM="/usr/share/pki/MOK.pem"
MOK_CERT_DER="/usr/share/pki/MOK.der"
MOK_PRIV="/tmp/MOK.priv"
SERVICE_PATH="/usr/lib/systemd/system/enroll-mok.service"

echo "Starting Kernel Signing Process..."

# 1. Handle Secrets (Assumes KERNEL_SECRET is passed as an Env Var or Build Arg)
# To keep this out of image layers, ensure this script runs in a single RUN command
# and that /tmp/MOK.priv is deleted before the layer commits.
if [ -z "$KERNEL_SECRET" ]; then
    echo "Error: KERNEL_SECRET not found."
    exit 1
fi
echo "$KERNEL_SECRET" > "$MOK_PRIV"
chmod 600 "$MOK_PRIV"

# 2. Identify the Kernel
# Since we can't use 'uname -r', we look in /usr/lib/modules
KERNEL_VERSION=$(ls /usr/lib/modules | head -n 1)
VMLINUZ_PATH="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

if [ ! -f "$VMLINUZ_PATH" ]; then
    echo "Error: vmlinuz not found at $VMLINUZ_PATH"
    exit 1
fi

# 3. Sign the Kernel
echo "Signing kernel version ${KERNEL_VERSION}..."
sbsign --key "$MOK_PRIV" --cert "$MOK_CERT_PEM" --output "${VMLINUZ_PATH}.signed" "$VMLINUZ_PATH"

# Replace original with signed version
mv "${VMLINUZ_PATH}.signed" "$VMLINUZ_PATH"

# 4. Create the systemd Enrollment Service
# We use /usr/lib/systemd/system for OSTree images
cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Enroll MOK key on first boot
ConditionPathExists=${MOK_CERT_DER}
ConditionPathExists=!/var/lib/mok-enrolled

[Service]
Type=oneshot
# Note: Use -f to avoid interactive prompts where possible
ExecStart=/usr/bin/sh -c '(echo "${MOK_PASSWORD}"; echo "${MOK_PASSWORD}") | mokutil --import "${MOK_CERT_DER}"'
ExecStartPost=/usr/bin/touch /var/lib/mok-enrolled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 5. Enable the service
# On OSTree, we usually symlink this in /usr/lib/systemd/system/multi-user.target.wants/
mkdir -p /usr/lib/systemd/system/multi-user.target.wants
ln -s "$SERVICE_PATH" /usr/lib/systemd/system/multi-user.target.wants/enroll-mok.service

# 6. Cleanup sensitive data
rm -f "$MOK_PRIV"
echo "Signing complete. Private key removed from /tmp."
