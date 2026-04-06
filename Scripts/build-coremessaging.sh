#!/usr/bin/env bash
#
# build-coremessaging.sh — Cross-compile a custom coremessaging.dll
#
# Produces a replacement for Wine's coremessaging.dll that adds the missing
# IDispatcherQueueStatics activation factory for Windows.System.DispatcherQueue.
# Wine's shipped DLL only handles DispatcherQueueController; Unity 6.3+ also
# needs DispatcherQueue::GetForCurrentThread() or it crashes on startup.
#
# Usage:
#   bash Scripts/build-coremessaging.sh [OUTPUT_PATH]
#
#   OUTPUT_PATH defaults to /tmp/coremessaging.dll
#   Pass the engine DLL path to update it directly:
#     bash Scripts/build-coremessaging.sh \
#       ~/Library/Application\ Support/com.meridian.app/engine/wine/lib/wine/x86_64-windows/coremessaging.dll
#
# Requirements:
#   brew install mingw-w64   (provides x86_64-w64-mingw32-gcc)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/coremessaging/coremessaging_stub.c"
OUTPUT="${1:-/tmp/coremessaging.dll}"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

echo ""
green "=== Build coremessaging.dll (DispatcherQueue stub) ==="
echo ""

# -- Preflight --
command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || \
    die "x86_64-w64-mingw32-gcc not found. Install: brew install mingw-w64"

[ -f "${SOURCE}" ] || die "Source not found: ${SOURCE}"

info "Source:  ${SOURCE}"
info "Output:  ${OUTPUT}"
echo ""

# -- Compile --
# -shared             → output a DLL (PE shared library)
# -Wl,--dll           → mark output as a DLL, not an EXE
# -O2                 → optimize (keeps binary small)
# -Wall               → catch issues
# -Wno-unused-param   → stubs intentionally ignore params
# -lole32             → for CoTaskMemAlloc (not used, but standard linkage)

x86_64-w64-mingw32-gcc \
    -shared \
    -Wl,--dll \
    -Wl,--out-implib,"${OUTPUT%.dll}.lib" \
    -O2 \
    -Wall \
    -Wno-unused-parameter \
    -o "${OUTPUT}" \
    "${SOURCE}" \
    -lole32

echo ""
green "Built: ${OUTPUT} ($(du -sh "${OUTPUT}" | cut -f1))"

# -- Basic validation --
# Check DllGetActivationFactory is exported
if command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
    EXPORTS=$(x86_64-w64-mingw32-objdump -p "${OUTPUT}" 2>/dev/null | grep "DllGetActivationFactory\|CreateDispatcherQueueController\|GetDispatcherQueueForCurrentThread" || true)
    if [ -n "${EXPORTS}" ]; then
        info "Exports verified:"
        echo "${EXPORTS}" | sed 's/^/    /'
    else
        red "Warning: expected exports not found in DLL"
    fi
fi

echo ""
green "Done."
