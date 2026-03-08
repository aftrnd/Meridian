#!/usr/bin/env bash
# =============================================================================
# install-local.sh — Install built VM artifacts directly into the Meridian
#                    app's local sandbox (bypasses GitHub download entirely).
#
# Run this after build-meridian-image.sh completes.
# The Meridian app will boot from these files immediately — no internet needed.
#
# Usage:
#   bash Scripts/install-local.sh
#   bash Scripts/install-local.sh --vm-dir /tmp/meridian-vm
# =============================================================================
set -euo pipefail

VM_DIR="${VM_DIR:-/tmp/meridian-vm}"
APP_SUPPORT="${HOME}/Library/Application Support/com.meridian.app/vm"
SANDBOX_SUPPORT="${HOME}/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-dir) VM_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "\n${RED}✗ FATAL: $*${NC}\n"; exit 1; }
step() { echo -e "  → $*"; }

echo -e "\n${BOLD}Installing Meridian VM artifacts → local sandbox${NC}"

# ── Verify source files ───────────────────────────────────────────────────────
[[ -f "${VM_DIR}/meridian-base.img" ]] \
    || die "meridian-base.img not found in ${VM_DIR}\n  Run: bash Scripts/build-meridian-image.sh"
[[ -f "${VM_DIR}/vmlinuz" ]] \
    || die "vmlinuz not found in ${VM_DIR}"
[[ -f "${VM_DIR}/initrd" ]] \
    || die "initrd not found in ${VM_DIR}"

echo ""
echo "  Source:      ${VM_DIR}"
echo "  Destination: ${APP_SUPPORT}"
echo ""
echo "  $(du -sh "${VM_DIR}/meridian-base.img" | cut -f1)  meridian-base.img"
echo "  $(du -sh "${VM_DIR}/vmlinuz"           | cut -f1)  vmlinuz"
echo "  $(du -sh "${VM_DIR}/initrd"            | cut -f1)  initrd"
echo ""

# ── Create sandbox directory ──────────────────────────────────────────────────
mkdir -p "${APP_SUPPORT}"

# ── Install files ─────────────────────────────────────────────────────────────
# Use APFS clones (cp -c) when source + dest are on the same APFS volume.
# This is instant and uses no extra disk space for the shared blocks.
# Fall back to regular cp if cloning isn't available.

install_file() {
    local src="$1" dst="$2" label="$3"
    local src_real dst_real
    src_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${src}")"
    dst_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${dst}" 2>/dev/null || true)"
    if [[ -n "${dst_real}" && "${src_real}" == "${dst_real}" ]]; then
        warn "${label} skipped (source and destination are identical)"
        return
    fi
    # Remove any existing file first so we don't write on top of a VZ-locked file
    rm -f "${dst}"
    if cp -c "${src}" "${dst}" 2>/dev/null; then
        ok "${label}  (APFS clone — instant, no extra disk space)"
    else
        echo -n "  Copying ${label}…"
        cp "${src}" "${dst}"
        echo " done"
    fi
}

install_file "${VM_DIR}/meridian-base.img" "${APP_SUPPORT}/meridian-base.img" "meridian-base.img"
install_file "${VM_DIR}/vmlinuz"           "${APP_SUPPORT}/vmlinuz"           "vmlinuz"
install_file "${VM_DIR}/initrd"            "${APP_SUPPORT}/initrd"            "initrd"

# Write a local tag so the app doesn't prompt for an update
echo "local-build-$(date +%Y%m%d)" > "${APP_SUPPORT}/image.tag"
ok "image.tag written (suppresses GitHub update check)"

# Keep sandboxed dev builds in sync as well (Xcode-run app location).
if [[ -d "$(dirname "${SANDBOX_SUPPORT}")" ]]; then
    mkdir -p "${SANDBOX_SUPPORT}"
    install_file "${VM_DIR}/meridian-base.img" "${SANDBOX_SUPPORT}/meridian-base.img" "sandbox meridian-base.img"
    install_file "${VM_DIR}/vmlinuz"           "${SANDBOX_SUPPORT}/vmlinuz"           "sandbox vmlinuz"
    install_file "${VM_DIR}/initrd"            "${SANDBOX_SUPPORT}/initrd"            "sandbox initrd"
    echo "local-build-$(date +%Y%m%d)" > "${SANDBOX_SUPPORT}/image.tag"
    ok "sandbox image.tag written"
fi

# ── Strip quarantine + provenance xattrs ─────────────────────────────────────
# macOS sets com.apple.quarantine on files created by sandboxed apps.
# VZDiskImageStorageDeviceAttachment fails with an I/O error when the disk
# image has a quarantine xattr — macOS tries to security-scan a 12+ GB file
# and the operation times out or is denied.
echo ""
step "Stripping macOS quarantine xattrs from VM image files…"
for f in "${APP_SUPPORT}/meridian-base.img" "${APP_SUPPORT}/expansion.img" \
          "${APP_SUPPORT}/vmlinuz" "${APP_SUPPORT}/initrd" \
          "${SANDBOX_SUPPORT}/meridian-base.img" "${SANDBOX_SUPPORT}/expansion.img" \
          "${SANDBOX_SUPPORT}/vmlinuz" "${SANDBOX_SUPPORT}/initrd"; do
    [[ -f "${f}" ]] || continue
    for attr in com.apple.quarantine com.apple.provenance; do
        xattr "${f}" 2>/dev/null | grep -q "${attr}" && \
            xattr -d "${attr}" "${f}" 2>/dev/null && \
            echo "  cleared ${attr} from $(basename "${f}")" || true
    done
done
ok "Quarantine xattrs cleared"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Sandbox contents:${NC}"
ls -lh "${APP_SUPPORT}/" | tail -n +2 | sed 's/^/  /'

echo ""
echo -e "${GREEN}${BOLD}Done.${NC}  Launch Meridian — it will boot directly from the local image."
echo ""
echo "  If the app shows 'Set Up' instead of your library:"
echo "    1. Sign in with Steam + paste your API key"
echo "    2. The VM will start automatically when you click Play"
echo ""
echo "  To watch the VM boot log in real time:"
echo "    tail -f \"${APP_SUPPORT}/console.log\""
echo ""
echo "  To SSH into the running VM (for debugging):"
echo "    ssh -p 2222 meridian@localhost   # only works if you add port-forward to VMConfiguration"
