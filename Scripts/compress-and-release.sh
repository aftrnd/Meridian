#!/usr/bin/env bash
# =============================================================================
# compress-and-release.sh — Compress a Meridian raw image for GitHub Release
#
# Compresses meridian-base.img with LZFSE and splits it into ≤1.9 GB parts
# for upload to GitHub Releases (2 GB per-asset limit).
#
# ────────────────────────────────────────────────────────────────────────────
# CRITICAL: Run this ONLY after the build VM has done a CLEAN SHUTDOWN.
#
# The base image MUST be shut down with 'systemctl poweroff', NOT 'poweroff -f'.
#
# 'poweroff -f' bypasses the systemd shutdown sequence: filesystems are NOT
# unmounted and LVM VGs are NOT deactivated. The image is left with:
#   • ext4 journal in a dirty (uncommitted) state
#   • LVM metadata with the VG flagged as "in-use"
#
# LZFSE faithfully compresses this dirty state. When the image is later
# decompressed and booted in a fresh QEMU or Apple Virtualization.framework
# environment, one of these failures occurs:
#
#   Black screen + no SSH:
#     LVM activation fails because the VG metadata says it was never cleanly
#     deactivated. The kernel cannot mount the root device → panic → halt.
#
#   "launch command failed: operation can't be completed i/o error":
#     VZDiskImageStorageDeviceAttachment detects an inconsistent raw image
#     (invalid GPT backup, LVM header CRC mismatch) and refuses to open it.
#
# The fix is exactly one command change inside the build VM before copying:
#     BAD:  sudo poweroff -f          ← skips unmount/LVM deactivation
#     GOOD: sudo systemctl poweroff   ← full clean shutdown, safe to compress
# ────────────────────────────────────────────────────────────────────────────
#
# Requirements:
#   lzfse    — brew install lzfse   (or shipped with macOS Command Line Tools)
#   qemu-img — brew install qemu    (used for image integrity check)
#
# Usage:
#   bash Scripts/compress-and-release.sh
#   bash Scripts/compress-and-release.sh --image /path/to/meridian-base.img
#   bash Scripts/compress-and-release.sh --image /tmp/meridian-vm/meridian-base.img \
#       --version v1.0.4-base --output-dir /tmp/release
#
# VMImageProvider naming convention (must match exactly):
#   meridian-base-<VERSION>.img.lzfse.partaa   ← part 1
#   meridian-base-<VERSION>.img.lzfse.partab   ← part 2  (more if image is large)
# =============================================================================
set -euo pipefail

# ── Defaults (overridden by --flags below) ────────────────────────────────────
IMG="${1:-/tmp/meridian-vm/meridian-base.img}"
RELEASE_VERSION="${RELEASE_VERSION:-v1.0.3-base}"
OUTPUT_DIR=""
PART_SIZE="1900m"    # 1.9 GB — safely under GitHub's 2 GB asset limit

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)       IMG="$2";             shift 2 ;;
        --version)     RELEASE_VERSION="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";      shift 2 ;;
        --part-size)   PART_SIZE="$2";       shift 2 ;;
        -h|--help)
            sed -n '2,60p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1  (use --help for usage)"
            exit 1 ;;
    esac
done

[[ -z "${OUTPUT_DIR}" ]] && OUTPUT_DIR="$(dirname "${IMG}")"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "\n${BOLD}▶ $*${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
die()   { echo -e "\n${RED}✗ FATAL: $*${NC}\n"; exit 1; }
step()  { echo -e "  → $*"; }

# ── Strip quarantine xattrs before compressing ───────────────────────────────
# macOS sets com.apple.quarantine on files written by sandboxed apps.
# If the compressed image retains this xattr, every user who downloads and
# decompresses it will hit "operation couldn't be completed: I/O error" when
# VZDiskImageStorageDeviceAttachment tries to open the decompressed file.
_strip_quarantine() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    for attr in com.apple.quarantine com.apple.provenance; do
        xattr "${f}" 2>/dev/null | grep -q "${attr}" && \
            xattr -d "${attr}" "${f}" 2>/dev/null || true
    done
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
info "Pre-flight checks"

[[ -f "${IMG}" ]] || die "Image not found: ${IMG}"
ok "Image: ${IMG}  ($(du -sh "${IMG}" | cut -f1) on disk)"

# Locate lzfse
LZFSE_CMD=""
for candidate in lzfse /usr/bin/lzfse "$(brew --prefix lzfse 2>/dev/null)/bin/lzfse"; do
    if command -v "${candidate}" &>/dev/null 2>&1 || [[ -x "${candidate}" ]]; then
        LZFSE_CMD="${candidate}"
        break
    fi
done
[[ -n "${LZFSE_CMD}" ]] \
    || die "lzfse not found.  Install with: brew install lzfse"
ok "lzfse: ${LZFSE_CMD}"

# qemu-img for image integrity check
command -v qemu-img &>/dev/null \
    || die "qemu-img not found.  Run: brew install qemu"

# ── Image integrity check ─────────────────────────────────────────────────────
info "Image integrity check"

# Basic readability and size sanity
IMG_JSON=$(qemu-img info --output json "${IMG}" 2>/dev/null) \
    || die "qemu-img cannot read image — file may be corrupt"
IMG_VSIZE=$(echo "${IMG_JSON}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['virtual-size'])" 2>/dev/null || echo 0)
IMG_ASIZE=$(echo "${IMG_JSON}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('actual-size', 0))" 2>/dev/null || echo 0)

if [[ "${IMG_VSIZE}" -lt $(( 10 * 1024 * 1024 * 1024 )) ]]; then
    die "Image virtual size is only ${IMG_VSIZE} bytes — expected ≥10 GB.  Build may have been truncated."
fi
ok "Virtual size: $(( IMG_VSIZE / 1024 / 1024 / 1024 )) GiB"
ok "Actual size:  $(( IMG_ASIZE / 1024 / 1024 )) MiB  ($(du -sh "${IMG}" | cut -f1) on disk)"

# Warn if the image was modified very recently — VM might still be running
IMG_MOD_TIME=$(stat -f %m "${IMG}" 2>/dev/null || stat -c %Y "${IMG}" 2>/dev/null || echo 0)
MOD_AGE=$(( $(date +%s) - IMG_MOD_TIME ))
if [[ "${MOD_AGE}" -lt 30 ]]; then
    warn "Image was modified ${MOD_AGE}s ago."
    warn "Make sure the build VM has FULLY SHUT DOWN before compressing."
    warn "A dirty image compresses fine but FAILS TO BOOT after decompression."
    read -rp "  Press Enter to continue anyway, or Ctrl-C to abort… "
elif [[ "${MOD_AGE}" -lt 300 ]]; then
    warn "Image was modified ${MOD_AGE}s ago — verify the VM has powered off."
fi

mkdir -p "${OUTPUT_DIR}"

# ── Strip quarantine from source image before compressing ────────────────────
info "Stripping quarantine xattrs"
_strip_quarantine "${IMG}"
ok "Quarantine cleared from $(basename "${IMG}")"

# ── Compress ──────────────────────────────────────────────────────────────────
COMPRESSED="${OUTPUT_DIR}/meridian-base-${RELEASE_VERSION}.img.lzfse"
OUT_PREFIX="${OUTPUT_DIR}/meridian-base-${RELEASE_VERSION}.img.lzfse.part"

info "Compressing with LZFSE"
step "Input:  ${IMG}  ($(du -sh "${IMG}" | cut -f1))"
step "Output: ${COMPRESSED}"
step "This takes ~5–15 minutes depending on disk speed…"

rm -f "${COMPRESSED}"
START=$(date +%s)
"${LZFSE_CMD}" -encode -i "${IMG}" -o "${COMPRESSED}"
ELAPSED=$(( $(date +%s) - START ))
ok "Compressed: $(du -sh "${COMPRESSED}" | cut -f1)  (${ELAPSED}s)"

# Compression ratio
COMPRESSED_BYTES=$(stat -f %z "${COMPRESSED}" 2>/dev/null || stat -c %s "${COMPRESSED}" 2>/dev/null || echo 1)
RATIO=$(python3 -c "print(f'{${IMG_VSIZE} / ${COMPRESSED_BYTES}:.1f}x')" 2>/dev/null || echo "?")
ok "Compression ratio: ${RATIO}"

# ── Split into ≤1.9 GB parts ──────────────────────────────────────────────────
info "Splitting into ≤${PART_SIZE} parts for GitHub Release upload"

rm -f "${OUT_PREFIX}"??    # clean up any stale parts from previous runs
split -b "${PART_SIZE}" "${COMPRESSED}" "${OUT_PREFIX}"

PARTS=( "${OUT_PREFIX}"?? )
ok "Created ${#PARTS[@]} part(s):"
for p in "${PARTS[@]}"; do
    echo "    $(du -sh "${p}" | cut -f1)  $(basename "${p}")"
done

if [[ "${#PARTS[@]}" -gt 2 ]]; then
    warn "More than 2 parts created — VMImageProvider handles any number of parts"
    warn "alphabetically, so this is fine as long as all parts are uploaded."
fi

# ── Roundtrip sanity check ────────────────────────────────────────────────────
info "Roundtrip sanity check (partial decompression)"

VERIFY_CAT="/tmp/meridian-verify-concat-$$.lzfse"
VERIFY_OUT="/tmp/meridian-verify-$$.img"

cat "${PARTS[@]}" > "${VERIFY_CAT}"
CONCAT_SIZE=$(stat -f %z "${VERIFY_CAT}" 2>/dev/null || stat -c %s "${VERIFY_CAT}" 2>/dev/null || echo 0)
COMP_SIZE=$(stat -f %z "${COMPRESSED}" 2>/dev/null || stat -c %s "${COMPRESSED}" 2>/dev/null || echo 0)

if [[ "${CONCAT_SIZE}" -ne "${COMP_SIZE}" ]]; then
    warn "Concatenated parts size (${CONCAT_SIZE}) ≠ compressed size (${COMP_SIZE})"
    warn "This may indicate a split error — verify parts before uploading."
else
    ok "Part concatenation size matches compressed file (${CONCAT_SIZE} bytes)"
fi

step "Decompressing first ~512 MB to verify LZFSE stream integrity…"
"${LZFSE_CMD}" -decode -i "${VERIFY_CAT}" -o "${VERIFY_OUT}" &
LZFSE_PID=$!
sleep 15
kill "${LZFSE_PID}" 2>/dev/null || true
wait "${LZFSE_PID}" 2>/dev/null || true

if [[ -f "${VERIFY_OUT}" ]]; then
    VERIFY_BYTES=$(stat -f %z "${VERIFY_OUT}" 2>/dev/null || stat -c %s "${VERIFY_OUT}" 2>/dev/null || echo 0)
    if [[ "${VERIFY_BYTES}" -gt $(( 512 * 1024 * 1024 )) ]]; then
        ok "LZFSE stream is valid (decompressed ${VERIFY_BYTES} bytes in 15s)"
    else
        warn "Only ${VERIFY_BYTES} bytes decompressed in 15s — stream may be truncated or corrupted"
    fi
fi
rm -f "${VERIFY_CAT}" "${VERIFY_OUT}"

# Remove intermediate compressed file — parts are the final upload artifacts
rm -f "${COMPRESSED}"

# ── Summary ───────────────────────────────────────────────────────────────────
info "Done — ready for GitHub Release"
echo ""
echo "  Upload these files to a release tagged '${RELEASE_VERSION}':"
echo ""
for p in "${PARTS[@]}"; do
    echo "    $(du -sh "${p}" | cut -f1)  $(basename "${p}")"
done
if [[ -f "${OUTPUT_DIR}/vmlinuz" ]]; then
    echo "    $(du -sh "${OUTPUT_DIR}/vmlinuz" | cut -f1)  vmlinuz"
fi
if [[ -f "${OUTPUT_DIR}/initrd" ]]; then
    echo "    $(du -sh "${OUTPUT_DIR}/initrd" | cut -f1)  initrd"
fi
echo ""
echo "  VMImageProvider download + assembly pipeline:"
echo "    1. Downloads partaa + partab → concatenates → meridian-base-${RELEASE_VERSION}.img.lzfse"
echo "    2. Decompresses LZFSE → meridian-base.img  (4 MB in / 8 MB out streaming)"
echo "    3. Persists release tag; deletes temp files"
echo ""
echo "  Verify the final image before shipping:"
echo "    MERIDIAN_VM_DIR=$(dirname "${IMG}") bash Tests/Integration/test-guest.sh"
