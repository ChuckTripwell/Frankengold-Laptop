#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[custom-kernel] $*"
}

error() {
    echo "[custom-kernel] Error: $*"
}

log "Starting kernel module signing..."

SIGNING_KEY="/tmp/cert/MOK.priv"
SIGNING_CERT="/usr/share/cert/MOK.pem"

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

SIGN_FILE="$(echo /usr/src/kernels/*/scripts/sign-file)"

if [[ ! -f "${SIGN_FILE}" ]]; then
    error "sign-file not found"
    exit 1
fi

log "Signing kernel modules using: ${SIGN_FILE}"

mapfile -t MODULES < <(find /usr/lib/modules -type f -name "*.ko")

for mod in "${MODULES[@]}"; do
    log "Signing module: ${mod}"
    "${SIGN_FILE}" sha256 "${SIGNING_KEY}" "${SIGNING_CERT}" "${mod}"
done

log "Kernel module signing complete."
