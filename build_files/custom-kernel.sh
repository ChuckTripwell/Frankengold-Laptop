#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[custom-kernel] $*"
}

error() {
    echo "[custom-kernel] Error: $*"
}

log "Starting kernel signing script..."

# Read configuration
SIGNING_KEY=$(echo "$1")
SIGNING_CERT=$(echo "$2")
MOK_PASSWORD=$(echo "$3")
INITRAMFS=$(echo "$4")

SECURE_BOOT=false

# Populate /tmp/MOK.priv from GitHub secret
if [[ -n "${KERNEL_SECRET:-}" ]]; then
    log "Writing GitHub secret to /tmp/MOK.priv"
    umask 077
    echo -n "${KERNEL_SECRET}" > /tmp/MOK.priv
    chmod 600 /tmp/MOK.priv
else
    log "KERNEL_SECRET not set; skipping /tmp/MOK.priv creation"
fi

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

# Find all kernel versions under /usr/lib/modules
KERNEL_DIRS=(/usr/lib/modules/*)
if [[ ${#KERNEL_DIRS[@]} -eq 0 ]]; then
    error "No kernel modules found under /usr/lib/modules"
    exit 1
fi

sign_kernel() {
    local KMOD_DIR="$1"
    local VMLINUZ="${KMOD_DIR}/vmlinuz"

    if [[ ! -f "${VMLINUZ}" ]]; then
        log "No kernel image found at ${VMLINUZ}, skipping."
        return 0
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
        error "Kernel signature verification failed for ${VMLINUZ}"
        rm -f "${SIGNED_VMLINUZ}"
        return 1
    fi

    install -m 0644 "${SIGNED_VMLINUZ}" "${VMLINUZ}"
    rm -f "${SIGNED_VMLINUZ}"

    sha256sum "${VMLINUZ}" > "${KMOD_DIR}/vmlinuz.sha"
}

sign_kernel_modules() {
    local KMOD_DIR="$1"
    local SIGN_FILE="${KMOD_DIR}/build/scripts/sign-file"

    if [[ ! -x "${SIGN_FILE}" ]]; then
        log "sign-file not found in ${SIGN_FILE}, skipping module signing."
        return 0
    fi

    log "Signing modules in ${KMOD_DIR}..."

    find "${KMOD_DIR}" -type f \( -name "*.ko*" \) -print0 |
    while IFS= read -r -d '' mod; do
        case "${mod}" in
        *.ko) "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}" ;;
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
    done
}

create_mok_enroll_unit() {
    local UNIT_FILE="/usr/lib/systemd/system/mok-enroll.service"
    local MOK_CERT="/usr/share/cert/MOK.der"

    log "Creating MOK enrollment service..."

    openssl x509 -in "${SIGNING_CERT}" -outform DER -out "${MOK_CERT}"

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
    local KMOD_DIR="$1"

    log "Generating initramfs for ${KMOD_DIR}..."
    TMP_INITRAMFS="$(mktemp)"
    dracut --force --kver "$(basename "${KMOD_DIR}")" --reproducible -v "${TMP_INITRAMFS}"
    install -D -m 0600 "${TMP_INITRAMFS}" "${KMOD_DIR}/initramfs.img"
    rm -f "${TMP_INITRAMFS}"
}

for KDIR in "${KERNEL_DIRS[@]}"; do
    if [[ ${SECURE_BOOT} == true ]]; then
        sign_kernel "${KDIR}"
        sign_kernel_modules "${KDIR}"
        create_mok_enroll_unit
    fi

    if [[ ${INITRAMFS} == true ]]; then
        generate_initramfs "${KDIR}"
    fi
done

log "Kernel signing script complete."
