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

log "Starting kernel signing script..."

# Read configuration
INITRAMFS=$(echo "$1" | jq -r '.initramfs // false')
SIGNING_KEY=$(echo "$1" | jq -r '.sign.key // ""')
SIGNING_CERT=$(echo "$1" | jq -r '.sign.cert // ""')
MOK_PASSWORD=$(echo "$1" | jq -r '.sign["mok-password"] // ""')

SECURE_BOOT=false

# Validate signing config
if [[ -z "${SIGNING_KEY}" && -z "${SIGNING_CERT}" && -z "${MOK_PASSWORD}" ]]; then
    log "SecureBoot signing disabled."
elif [[ -f "${SIGNING_KEY}" && -f "${SIGNING_CERT}" && -n "${MOK_PASSWORD}" ]]; then
    log "SecureBoot signing enabled."
    SECURE_BOOT=true
else
    error "Invalid signing config:"
    error "  sign.key:  ${SIGNING_KEY:-<empty>}"
    error "  sign.cert: ${SIGNING_CERT:-<empty>}"
    error "  sign.mok-password: ${MOK_PASSWORD:-<empty>}"
    exit 1
fi

# Validate key + certificate
if [[ ${SECURE_BOOT} == true ]]; then
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
fi

# Detect kernel version
KERNEL_VERSION="$(uname -r)"
MODULE_ROOT="/usr/lib/modules/${KERNEL_VERSION}"

log "Detected kernel version: ${KERNEL_VERSION}"

sign_kernel() {
    local VMLINUZ="${MODULE_ROOT}/vmlinuz"

    if [[ ! -f "${VMLINUZ}" ]]; then
        error "Kernel image not found: ${VMLINUZ}"
        return 1
    fi

    log "Signing kernel image: ${VMLINUZ}"

    local SIGNED_VMLINUZ
    SIGNED_VMLINUZ="$(mktemp)"

    sbsign \
        --key "${SIGNING_KEY}" \
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

    sha256sum "${VMLINUZ}" > /tmp/vmlinuz.sha
}

sign_kernel_modules() {
    local SIGN_FILE="${MODULE_ROOT}/build/scripts/sign-file"

    if [[ ! -x "${SIGN_FILE}" ]]; then
        error "sign-file not found: ${SIGN_FILE}"
        return 1
    fi

    log "Signing kernel modules..."

    while IFS= read -r -d '' mod; do
        case "${mod}" in
        *.ko)
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}"
            ;;
        *.ko.xz)
            xz -d -q "${mod}"
            raw="${mod%.xz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"
            xz -z -q "${raw}"
            ;;
        *.ko.zst)
            zstd -d -q --rm "${mod}"
            raw="${mod%.zst}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"
            zstd -q "${raw}"
            ;;
        *.ko.gz)
            gunzip -q "${mod}"
            raw="${mod%.gz}"
            "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${raw}"
            gzip -q "${raw}"
            ;;
        esac
    done < <(find "${MODULE_ROOT}" -type f \( -name "*.ko*" \) -print0)
}

create_mok_enroll_unit() {
    local UNIT_FILE="/usr/lib/systemd/system/mok-enroll.service"
    local MOK_CERT="/usr/share/cert/MOK.der"

    log "Creating MOK enrollment service..."

    openssl x509 \
        -in "${SIGNING_CERT}" \
        -outform DER \
        -out "${MOK_CERT}"

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
}

generate_initramfs() {
    log "Generating initramfs..."

    TMP_INITRAMFS="$(mktemp)"

    DRACUT_NO_XATTR=1 dracut \
        --no-hostonly \
        --kver "${KERNEL_VERSION}" \
        --reproducible \
        --add ostree \
        -f "${TMP_INITRAMFS}" \
        -v

    install -D -m 0600 "${TMP_INITRAMFS}" "${MODULE_ROOT}/initramfs.img"
    rm -f "${TMP_INITRAMFS}"
}

if [[ ${SECURE_BOOT} == true ]]; then
    sign_kernel
    sign_kernel_modules
    create_mok_enroll_unit

    sha256sum -c /tmp/vmlinuz.sha || {
        error "Kernel modified after signing"
        exit 1
    }

    rm -f /tmp/vmlinuz.sha
fi

if [[ ${INITRAMFS} == true ]]; then
    generate_initramfs
fi

log "Kernel signing complete."
