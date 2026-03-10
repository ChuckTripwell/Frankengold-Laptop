#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[custom-kernel] $*"
}

error() {
    echo "[custom-kernel] Error: $*"
}

log "Starting kernel signing..."

# Hardcoded signing configuration
SIGNING_KEY="/tmp/cert/MOK.priv"
SIGNING_CERT="/usr/share/cert/MOK.pem"
MOK_PASSWORD="universalblue"

# Verify key
openssl pkey -in "${SIGNING_KEY}" -noout >/dev/null 2>&1 \
    || { error "Invalid private key: ${SIGNING_KEY}"; exit 1; }

# Verify cert
openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 \
    || { error "Invalid certificate: ${SIGNING_CERT}"; exit 1; }

# Ensure key and cert match
if ! diff -q \
    <(openssl pkey -in "${SIGNING_KEY}" -pubout) \
    <(openssl x509 -in "${SIGNING_CERT}" -pubkey -noout); then
    error "Private key and certificate do not match"
    exit 1
fi

# Locate kernel image
VMLINUZ="$(echo /usr/lib/modules/*/vmlinuz)"

if [[ ! -f "${VMLINUZ}" ]]; then
    error "Kernel image not found"
    exit 1
fi

log "Signing kernel image: ${VMLINUZ}"

SIGNED_KERNEL="$(mktemp)"

sbsign \
    --key "${SIGNING_KEY}" \
    --cert "${SIGNING_CERT}" \
    --output "${SIGNED_KERNEL}" \
    "${VMLINUZ}"

# Verify signature
if ! sbverify --cert "${SIGNING_CERT}" "${SIGNED_KERNEL}"; then
    error "Kernel signature verification failed"
    rm -f "${SIGNED_KERNEL}"
    exit 1
fi

# Replace kernel
install -m 0644 "${SIGNED_KERNEL}" "${VMLINUZ}"
rm -f "${SIGNED_KERNEL}"

# Save checksum for final verification
sha256sum "${VMLINUZ}" > /tmp/vmlinuz.sha

log "Creating MOK enroll service..."

UNIT_FILE="/usr/lib/systemd/system/mok-enroll.service"
MOK_CERT="/usr/share/cert/MOK.der"
TMP_DER="$(mktemp)"

openssl x509 \
    -in "${SIGNING_CERT}" \
    -outform DER \
    -out "${TMP_DER}"

install -D -m 0644 "${TMP_DER}" "${MOK_CERT}"
rm -f "${TMP_DER}"

install -D -m 0644 /dev/stdin "${UNIT_FILE}" <<EOF
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

systemctl -f enable mok-enroll.service

# Final verification
sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing"; exit 1; }
rm -f /tmp/vmlinuz.sha

log "Kernel signing complete."
