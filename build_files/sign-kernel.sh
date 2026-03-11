#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[custom-kernel] $*"
}

error() {
    echo "[custom-kernel] Error: $*"
}

log "Starting custom-kernel signing module..."

# Hardcoded signing configuration
SIGNING_KEY="/tmp/cert/MOK.priv"
SIGNING_CERT="/usr/share/cert/MOK.pem"
MOK_PASSWORD="universalblue"
SECURE_BOOT=true

# Verify key and cert
openssl pkey -in "${SIGNING_KEY}" -noout >/dev/null 2>&1 \
    || { error "sign.key is not a valid private key"; exit 1; }
openssl x509 -in "${SIGNING_CERT}" -noout >/dev/null 2>&1 \
    || { error "sign.cert is not a valid X509 cert"; exit 1; }

if ! diff -q \
    <(openssl pkey -in "${SIGNING_KEY}" -pubout) \
    <(openssl x509 -in "${SIGNING_CERT}" -pubkey -noout); then
    error "sign.key and sign.cert do not match"
    exit 1
fi

# Locate the kernel directory
KERNEL_DIR="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n 1)"
VMLINUZ="${KERNEL_DIR}/vmlinuz"

if [[ ! -f "${VMLINUZ}" ]]; then
    error "Kernel image not found at ${VMLINUZ}"
    exit 1
fi

log "Signing kernel image: ${VMLINUZ}"
SIGNED_VMLINUZ="$(mktemp)"
sbsign --key "${SIGNING_KEY}" --cert "${SIGNING_CERT}" --output "${SIGNED_VMLINUZ}" "${VMLINUZ}"

if ! sbverify --cert "${SIGNING_CERT}" "${SIGNED_VMLINUZ}"; then
    error "Kernel signature verification failed"
    rm -f "${SIGNED_VMLINUZ}"
    exit 1
fi

install -m 0644 "${SIGNED_VMLINUZ}" "${VMLINUZ}"
rm -f "${SIGNED_VMLINUZ}"

sha256sum "${VMLINUZ}" > /tmp/vmlinuz.sha

# Sign all modules in that directory
SIGN_FILE="${KERNEL_DIR}/build/scripts/sign-file"

if [[ ! -x "${SIGN_FILE}" ]]; then
    error "sign-file not found or not executable: ${SIGN_FILE}"
    exit 1
fi

log "Signing kernel modules..."
while IFS= read -r -d '' mod; do
    case "${mod}" in
    *.ko)
        "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" ;;
    *.ko.xz)
        xz -f -d -q "${mod}"
        raw="${mod%.xz}"
        "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"
        xz -f -z -q "${raw}" ;;
    *.ko.zst)
        zstd -d -q --rm "${mod}"
        raw="${mod%.zst}"
        "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"
        zstd -q "${raw}" ;;
    *.ko.gz)
        gunzip -q "${mod}"
        raw="${mod%.gz}"
        "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"
        gzip -q "${raw}" ;;
    esac
done < <(find "${KERNEL_DIR}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0)

# Create MOK enroll service
log "Creating MOK enroll unit..."
UNIT_NAME="mok-enroll.service"
UNIT_FILE="/usr/lib/systemd/system/${UNIT_NAME}"
MOK_CERT="/usr/share/cert/MOK.der"
TMP_DER="$(mktemp)"

openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${TMP_DER}"
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

systemctl -f enable "${UNIT_NAME}"

# Final verification
sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing."; exit 1; }
rm -f /tmp/vmlinuz.sha

log "Kernel signing complete."
