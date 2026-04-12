#!/usr/bin/env bash
#
# build-d3d12-bridge.sh — Build Wine 11-compatible d3d12 bridge for GPTK
#
# Produces two files:
#   d3d12.dll  — PE shim (mingw-w64 + winecrt0), Wine builtin stamped,
#                replaces CX's ABI-incompatible version that imports the
#                stubbed ntdll.__wine_unix_call. This DLL uses Wine 11.x's
#                __wine_unix_call_dispatcher mechanism via winecrt0 instead.
#   d3d12.so   — Unix adapter (native clang x86_64), forwards
#                __wine_unix_call_funcs to libd3dshared.dylib at runtime.
#
# Usage:
#   bash Scripts/build-d3d12-bridge.sh [DLL_OUTPUT] [SO_OUTPUT]
#
#   DLL_OUTPUT defaults to /tmp/d3d12.dll
#   SO_OUTPUT  defaults to /tmp/d3d12.so
#
# Requirements:
#   brew install mingw-w64   (provides x86_64-w64-mingw32-gcc)
#   Xcode CLT                (provides clang for x86_64 cross-compilation)
#   Wine 11.x source         (auto-downloaded to /tmp if not cached)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PE_SOURCE="${SCRIPT_DIR}/d3d12-bridge/d3d12_pe.c"
UNIX_SOURCE="${SCRIPT_DIR}/d3d12-bridge/d3d12_adapter.c"
DLL_OUTPUT="${1:-/tmp/d3d12.dll}"
SO_OUTPUT="${2:-/tmp/d3d12.so}"

WINE_VERSION="11.6"
WINE_SRC="/tmp/wine-wine-${WINE_VERSION}"
WINEBUILD="/tmp/winebuild"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

echo ""
green "=== Build d3d12 bridge (Wine ${WINE_VERSION}-compatible GPTK adapter) ==="
echo ""

# -- Preflight --
command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || \
    die "x86_64-w64-mingw32-gcc not found. Install: brew install mingw-w64"
command -v clang >/dev/null 2>&1 || \
    die "clang not found. Install Xcode Command Line Tools."
[ -f "${PE_SOURCE}" ]   || die "PE source not found: ${PE_SOURCE}"
[ -f "${UNIX_SOURCE}" ] || die "Unix source not found: ${UNIX_SOURCE}"

# -- Ensure Wine source + winebuild are available --
if [ ! -f "${WINEBUILD}" ]; then
    yellow "Building winebuild from Wine ${WINE_VERSION} source..."
    if [ ! -d "${WINE_SRC}" ]; then
        info "Downloading Wine ${WINE_VERSION} source..."
        curl -L "https://github.com/wine-mirror/wine/archive/refs/tags/wine-${WINE_VERSION}.tar.gz" \
            -o "/tmp/wine-${WINE_VERSION}-src.tar.gz"
        tar xf "/tmp/wine-${WINE_VERSION}-src.tar.gz" -C /tmp/
    fi
    # Minimal config.h for standalone winebuild compilation
    cat > "${WINE_SRC}/include/config.h" << 'CFGEOF'
#ifndef __WINE_CONFIG_H
#define __WINE_CONFIG_H
#define PACKAGE_VERSION "11.6"
#define PACKAGE_NAME "Wine"
#define HAVE_STDBOOL_H 1
#define EXEEXT ""
#define BINDIR "/usr/local/bin"
#define LIBDIR "/usr/local/lib"
#define DATADIR "/usr/local/share"
#define DLLDIR "/usr/local/lib/wine"
#define INCLUDEDIR "/usr/local/include/wine"
#define CC "clang"
#define CXX "clang++"
#define CPP "clang -E"
#define LD "ld"
#endif
CFGEOF
    gcc -O2 -include "${WINE_SRC}/include/config.h" \
        -I "${WINE_SRC}/include" -I "${WINE_SRC}/tools" \
        "${WINE_SRC}"/tools/winebuild/main.c \
        "${WINE_SRC}"/tools/winebuild/import.c \
        "${WINE_SRC}"/tools/winebuild/parser.c \
        "${WINE_SRC}"/tools/winebuild/relay.c \
        "${WINE_SRC}"/tools/winebuild/res16.c \
        "${WINE_SRC}"/tools/winebuild/res32.c \
        "${WINE_SRC}"/tools/winebuild/spec16.c \
        "${WINE_SRC}"/tools/winebuild/spec32.c \
        "${WINE_SRC}"/tools/winebuild/utils.c \
        -o "${WINEBUILD}"
    info "winebuild $(${WINEBUILD} --version) built"
fi

info "PE source:   ${PE_SOURCE}"
info "Unix source: ${UNIX_SOURCE}"
info "DLL output:  ${DLL_OUTPUT}"
info "SO output:   ${SO_OUTPUT}"
echo ""

# -- Build winecrt0 objects (PE target) --
yellow "Building winecrt0 for PE..."
x86_64-w64-mingw32-gcc -c -O2 \
    -D__WINESRC__ -D__WINE_PE_BUILD \
    -ffunction-sections -fdata-sections \
    -include "${WINE_SRC}/include/config.h" \
    -isystem "${WINE_SRC}/include" \
    -isystem "${WINE_SRC}/include/wine" \
    "${WINE_SRC}/libs/winecrt0/unix_lib.c" \
    -o /tmp/wcrt_unix_lib.o

x86_64-w64-mingw32-gcc -c -O2 \
    -D__WINESRC__ -D__WINE_PE_BUILD \
    -include "${WINE_SRC}/include/config.h" \
    -isystem "${WINE_SRC}/include" \
    -isystem "${WINE_SRC}/include/wine" \
    "${WINE_SRC}/libs/winecrt0/stub.c" \
    -o /tmp/wcrt_stub.o

# -- Generate winebuild spec object (PE target) --
yellow "Generating spec object..."
"${WINEBUILD}" --dll -b x86_64-w64-mingw32 \
    -E "${SCRIPT_DIR}/d3d12-bridge/d3d12.spec" \
    -o /tmp/d3d12_spec.o -M d3d12.dll

# -- Compile PE source --
yellow "Compiling PE shim..."
x86_64-w64-mingw32-gcc -c -O2 \
    -D__WINESRC__ -D__WINE_PE_BUILD \
    -include "${WINE_SRC}/include/config.h" \
    -isystem "${WINE_SRC}/include" \
    -isystem "${WINE_SRC}/include/wine" \
    -Wno-unused-parameter \
    "${PE_SOURCE}" \
    -o /tmp/d3d12_pe.o

# -- Link PE DLL --
yellow "Linking PE DLL..."
cat > /tmp/d3d12_exports.def << 'DEFEOF'
LIBRARY d3d12
EXPORTS
    GetBehaviorValue = __wine_stub_GetBehaviorValue                              @100 NONAME
    D3D12CreateDevice                                                            @101
    D3D12GetDebugInterface                                                       @102
    D3D12CoreCreateLayeredDevice = __wine_stub_D3D12CoreCreateLayeredDevice      @103 NONAME
    D3D12CoreGetLayeredDeviceSize = __wine_stub_D3D12CoreGetLayeredDeviceSize    @104 NONAME
    D3D12CoreRegisterLayers = __wine_stub_D3D12CoreRegisterLayers                @105 NONAME
    D3D12CreateRootSignatureDeserializer                                         @106
    D3D12CreateVersionedRootSignatureDeserializer                                @107
    D3D12EnableExperimentalFeatures                                              @108
    D3D12SerializeRootSignature                                                  @109
    D3D12SerializeVersionedRootSignature                                         @110
DEFEOF

x86_64-w64-mingw32-gcc -shared -nostdlib \
    -Wl,-e,DllMain \
    -Wl,--exclude-all-symbols \
    -O2 \
    /tmp/d3d12_pe.o /tmp/d3d12_spec.o \
    /tmp/wcrt_unix_lib.o /tmp/wcrt_stub.o \
    /tmp/d3d12_exports.def \
    -o "${DLL_OUTPUT}" \
    -lntdll -lkernel32 -luser32

# -- Stamp as Wine builtin --
"${WINEBUILD}" --builtin "${DLL_OUTPUT}"
green "Built: ${DLL_OUTPUT} ($(du -sh "${DLL_OUTPUT}" | cut -f1))"

# -- Build Unix adapter (.so) --
yellow "Building Unix adapter (d3d12.so)..."
clang \
    -target x86_64-apple-macos10.14 \
    -shared -fPIC \
    -O2 \
    -Wall -Wno-unused-parameter \
    -o "${SO_OUTPUT}" \
    "${UNIX_SOURCE}" \
    -ldl

green "Built: ${SO_OUTPUT} ($(du -sh "${SO_OUTPUT}" | cut -f1))"

# -- Validation --
echo ""
yellow "Validating..."

# Check PE DLL ordinal base
if command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
    ORD_BASE=$(x86_64-w64-mingw32-objdump -p "${DLL_OUTPUT}" 2>/dev/null | awk '/^Ordinal Base/{print $NF; exit}')
    if [ "${ORD_BASE}" = "100" ]; then
        info "d3d12.dll: ordinal base 100 ✓"
    else
        red "Warning: ordinal base is ${ORD_BASE}, expected 100"
    fi
    D3D12_EXPORTS=$(x86_64-w64-mingw32-objdump -p "${DLL_OUTPUT}" 2>/dev/null | grep -c "D3D12") || true
    info "d3d12.dll: ${D3D12_EXPORTS} D3D12 entries"
fi

# Check Wine builtin stamp (winebuild embeds "Wine builtin DLL" string in the overlay)
if strings "${DLL_OUTPUT}" 2>/dev/null | grep -q "Wine builtin DLL"; then
    info "d3d12.dll: Wine builtin stamp ✓"
else
    red "Warning: missing 'Wine builtin DLL' stamp"
fi

# Check Unix .so
if nm -gU "${SO_OUTPUT}" 2>/dev/null | grep -q "__wine_unix_call_funcs"; then
    info "d3d12.so: __wine_unix_call_funcs ✓"
fi
if nm -gU "${SO_OUTPUT}" 2>/dev/null | grep -q "__wine_unix_lib_init"; then
    info "d3d12.so: __wine_unix_lib_init ✓"
fi

echo ""
green "Done. Install into engine:"
info "  ${DLL_OUTPUT} → wine/lib/wine/x86_64-windows/d3d12.dll"
info "  ${SO_OUTPUT}  → wine/lib/wine/x86_64-unix/d3d12.so"
info "  Also copy ${DLL_OUTPUT} → prefix system32/d3d12.dll"
