#!/usr/bin/env bash
set -euo pipefail

log() {
    local PREFIX="[custom-kernel]"
    echo -e "${PREFIX} $*"
}

error() {
    local PREFIX="[custom-kernel] Error:"
    echo -e "${PREFIX} $*"
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

# Detect installed kernel version
KERNEL_VERSION="$(uname -r)"
log "Detected kernel version: ${KERNEL_VERSION}"

# Sign kernel image
sign_kernel() {
    local MODULE_ROOT="/usr/lib/modules/${KERNEL_VERSION}"
    local VMLINUZ="${MODULE_ROOT}/vmlinuz"

    if [[ -f "${VMLINUZ}" ]]; then
        log "Signing kernel image: ${VMLINUZ}"
        local SIGNED_VMLINUZ
        SIGNED_VMLINUZ="$(mktemp)"

        sbsign \
            --key  "${SIGNING_KEY}" \
            --cert "${SIGNING_CERT}" \
            --output "${SIGNED_VMLINUZ}" \
            "${VMLINUZ}"

        if ! sbverify --cert "${SIGNING_CERT}" "${SIGNED_VMLINUZ}"; then
            error "Kernel signature verification failed"
            rm -f "${SIGNED_VMLINUZ}"
            return 1
        fi

        install -m 0644 "${SIGNED_VMLINUZ}" "${VMLINUZ}"
        rm -f "${SIGNED_VMLINUZ}"
    else
        error "Can't find kernel image: ${VMLINUZ}"
        return 1
    fi

    sha256sum "${VMLINUZ}" > /tmp/vmlinuz.sha
}

# Sign all kernel modules
sign_kernel_modules() {
    local MODULE_ROOT="/usr/lib/modules/${KERNEL_VERSION}"
    local SIGN_FILE="${MODULE_ROOT}/build/scripts/sign-file"

    if [[ ! -x "${SIGN_FILE}" ]]; then
        error "sign-file not found or not executable: ${SIGN_FILE}"
        return 1
    fi

    while IFS= read -r -d '' mod; do
        case "${mod}" in
        *.ko)
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" || return 1
            ;;
        *.ko.xz)
            xz -d -q "${mod}"
            raw="${mod%.xz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            xz -z -q "${raw}"
            ;;
        *.ko.zst)
            zstd -d -q --rm "${mod}"
            raw="${mod%.zst}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            zstd -q "${raw}"
            ;;
        *.ko.gz)
            gunzip -q "${mod}"
            raw="${mod%.gz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}" || return 1
            gzip -q "${raw}"
            ;;
        esac
    done < <(find "${MODULE_ROOT}" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0)
}

# Create MOK enroll systemd service
create_mok_enroll_unit() {
    local UNIT_NAME="mok-enroll.service"
    local UNIT_FILE="/usr/lib/systemd/system/${UNIT_NAME}"
    local MOK_CERT="/usr/share/cert/MOK.der"
    local TMP_DER
    TMP_DER="$(mktemp)"

    openssl x509 \
        -in "${SIGNING_CERT}" \
        -outform DER \
        -out "${TMP_DER}" || { rm -f "${TMP_DER}"; return 1; }

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
    log "Created and enabled ${UNIT_NAME}"
}

# Run signing steps
log "Signing the kernel."
sign_kernel || exit 1

log "Signing kernel modules."
sign_kernel_modules || exit 1

log "Creating MOK enroll unit for first boot."
create_mok_enroll_unit || exit 1

# Final verification
sha256sum -c /tmp/vmlinuz.sha || { error "Kernel modified after signing."; exit 1; }
rm -f /tmp/vmlinuz.sha
log "Kernel signing complete."
