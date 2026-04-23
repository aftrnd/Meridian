#!/usr/bin/env bash
#
# build-dpapi.sh — Cross-compile meridian-dpapi.exe (Wine CryptProtectData wrapper)
#
# Produces a small Windows PE console exe that wraps Wine's crypt32.dll
# CryptProtectData / CryptUnprotectData. Meridian uses this to write Steam's
# local.vdf ConnectCache blob from outside the Wine bottle — the resulting
# blob is byte-for-byte compatible with what Steam writes itself, because
# Wine's CryptProtectData is deterministic from:
#   - GetUserNameA() — always "crossover" in our bottles
#   - crypt32_protectdata_secret — Wine compile-time constant
#   - random salt — stored inside the blob itself
#   - optional entropy — supplied explicitly by both sides
#
# Usage:
#   bash Scripts/build-dpapi.sh [OUTPUT_PATH]
#
#   OUTPUT_PATH defaults to /tmp/meridian-dpapi.exe
#
# Requirements:
#   brew install mingw-w64   (provides x86_64-w64-mingw32-gcc)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/dpapi/meridian_dpapi.c"
OUTPUT="${1:-/tmp/meridian-dpapi.exe}"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

echo ""
green "=== Build meridian-dpapi.exe (Wine CryptProtectData wrapper) ==="
echo ""

command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || \
    die "x86_64-w64-mingw32-gcc not found. Install: brew install mingw-w64"

[ -f "${SOURCE}" ] || die "Source not found: ${SOURCE}"

info "source: ${SOURCE}"
info "output: ${OUTPUT}"

x86_64-w64-mingw32-gcc \
    -Os -s \
    -o "${OUTPUT}" \
    "${SOURCE}" \
    -lcrypt32 \
    -static-libgcc

info "binary size: $(stat -f%z "${OUTPUT}") bytes"
green "✓ Built ${OUTPUT}"
