#!/usr/bin/env bash
#
# build-wine-accessory.sh — compile meridian-wine-accessory.dylib
#
# Produces a universal (arm64 + x86_64) macOS dylib that Meridian injects
# via DYLD_INSERT_LIBRARIES into every Wine subprocess that runs Steam.
# The dylib's constructor calls `[NSApp setActivationPolicy:.accessory]`
# from inside the Wine process, killing its Dock tile and preventing
# self-activation (notification toasts, focus grabs, etc).
#
# ## Architecture
#
# x86_64 is REQUIRED because CrossOver's wine64 is x86_64-only (runs under
# Rosetta 2 on Apple Silicon). The dylib must match the loader's arch.
#
# arm64 is included for future-proofing: if a future CX release ships
# native arm64 Wine, this dylib will work unchanged.
#
# ## Codesigning
#
# Ad-hoc signed (`-` identity). wine64 has
# `com.apple.security.cs.disable-library-validation` entitlement so it
# can load our unsigned-by-team-id dylib.
#
# Usage:
#   bash Scripts/build-wine-accessory.sh [OUTPUT_PATH]
#   OUTPUT_PATH defaults to /tmp/meridian-wine-accessory.dylib
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/wine-accessory/meridian_wine_accessory.m"
OUTPUT="${1:-/tmp/meridian-wine-accessory.dylib}"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

echo ""
green "=== Build meridian-wine-accessory.dylib (DYLD_INSERT payload) ==="
echo ""

command -v clang >/dev/null 2>&1 || die "clang not found in PATH"
[ -f "${SOURCE}" ] || die "Source not found: ${SOURCE}"

info "source: ${SOURCE}"
info "output: ${OUTPUT}"

mkdir -p "$(dirname "${OUTPUT}")"

# Build into a scratch dir first. When invoked as an Xcode script build phase
# the output directory is inside a sandbox that denies lipo's tempfile writes
# (lipo generates `<output>.lipo` alongside the target for universal builds).
# Build → temp → cp satisfies the sandbox without giving up the universal slice.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
SCRATCH_OUT="${SCRATCH}/meridian-wine-accessory.dylib"

clang -dynamiclib \
    -arch arm64 -arch x86_64 \
    -framework AppKit \
    -framework Foundation \
    -O2 -Wall \
    -o "${SCRATCH_OUT}" \
    "${SOURCE}"

# Ad-hoc sign so the dylib loads cleanly under hardened runtime with
# library-validation-disabled binaries (wine64's entitlement set).
codesign --force --sign - "${SCRATCH_OUT}"

# Atomic place.
mv -f "${SCRATCH_OUT}" "${OUTPUT}"

info "binary size: $(stat -f%z "${OUTPUT}") bytes"
info "architectures: $(lipo -info "${OUTPUT}" 2>/dev/null | sed 's/.*://')"
green "✓ Built ${OUTPUT}"
