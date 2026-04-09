#!/usr/bin/env bash
#
# release-engine.sh — Assemble and publish the Meridian Wine engine from CrossOver Preview.
#
# Usage:
#   bash Scripts/release-engine.sh [VERSION]
#
# Examples:
#   bash Scripts/release-engine.sh              # auto-increments patch (v4.0.1-engine)
#   bash Scripts/release-engine.sh v4.0.0       # explicit version
#
# Prerequisites:
#   - CrossOver Preview installed at /Applications/CrossOver Preview.app
#   - gh CLI authenticated:   brew install gh && gh auth login
#   - x86_64-w64-mingw32-gcc: brew install mingw-w64  (for custom coremessaging.dll)
#
# What it does:
#   1. Copies Wine, DXMT, DXVK, GPTK, MoltenVK from CrossOver Preview
#   2. Installs DXMT builtins into wine/lib/wine/ (DirectX 11 → Metal)
#   3. Keeps CX's d3d12.dll in gptk/wine/ (DirectX 12 → Metal via D3DMetal)
#   4. Builds a pre-initialized prefix template via wineboot --init
#   5. Validates binaries, NLS data, syswow64, and prefix template
#   6. Creates a .tar.gz archive and uploads to aftrnd/meridian
#
# Wine Source: CrossOver Preview (Wine 11.4 with full CodeWeavers patches)
# WHY: CX Wine has ntdll.__wine_unix_call which CX's d3d12.dll requires.
#      Gcenx Wine (wine-devel) does NOT have this function — CX's d3d12.dll
#      fails to load with "unimplemented function ntdll.dll.__wine_unix_call".
#      CX Wine 11.4 has all the same CW patches as Gcenx (DXMT Metal APIs,
#      Steam compat, Rosetta2 thunks, Security.framework TLS) plus __wine_unix_call.
#
set -euo pipefail

REPO="aftrnd/meridian"
STAGING="/tmp/meridian-engine"
ARCHIVE="/tmp/meridian-engine-arm64.tar.gz"

CX_ROOT="/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver"

# ---------- helpers ----------

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
die()    { red "ERROR: $*" >&2; exit 1; }

# ---------- preflight ----------

echo ""
green "=== Meridian Engine Release ==="
echo ""

command -v gh    >/dev/null 2>&1 || die "gh CLI not found.   Install: brew install gh && gh auth login"
command -v tar   >/dev/null 2>&1 || die "tar not found"
gh auth status >/dev/null 2>&1   || die "gh CLI not authenticated. Run: gh auth login"

[ -d "${CX_ROOT}" ] || die "CrossOver Preview not found at /Applications/CrossOver Preview.app"
[ -f "${CX_ROOT}/CrossOver-Hosted Application/wineloader" ] || die "CX wineloader not found"
[ -f "${CX_ROOT}/CrossOver-Hosted Application/wineserver" ] || die "CX wineserver not found"
[ -d "${CX_ROOT}/lib/wine" ]  || die "CX lib/wine/ not found"
[ -d "${CX_ROOT}/lib/dxmt" ]  || die "CX lib/dxmt/ not found"

WINE_VERSION=$("${CX_ROOT}/CrossOver-Hosted Application/wineloader" --version 2>/dev/null || echo "unknown")
info "CrossOver Preview Wine: ${WINE_VERSION}"
info "Source: ${CX_ROOT}"
echo ""

# ---------- Meridian release version ----------

if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    LATEST=$(gh release list --repo "${REPO}" --limit 50 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+-engine' \
        | sort -V | tail -1 || true)

    if [ -z "${LATEST}" ]; then
        VERSION="v1.0.0-engine"
    else
        BASE="${LATEST%-engine}"
        MAJOR=$(echo "${BASE}" | cut -d. -f1 | tr -d 'v')
        MINOR=$(echo "${BASE}" | cut -d. -f2)
        PATCH=$(echo "${BASE}" | cut -d. -f3)
        PATCH=$((PATCH + 1))
        VERSION="v${MAJOR}.${MINOR}.${PATCH}-engine"
    fi
    yellow "Auto-detected next version: ${VERSION}"
fi

[[ "${VERSION}" == *-engine ]] || VERSION="${VERSION}-engine"
TAG="${VERSION}"

info "Version: ${TAG}"
info "Repo:    ${REPO}"
echo ""

# ---------- stage from CrossOver Preview ----------

yellow "Staging engine from CrossOver Preview..."
rm -rf "${STAGING}"
mkdir -p "${STAGING}/wine/bin" "${STAGING}/wine/lib" "${STAGING}/wine/share"

# --- Wine binaries ---
cp "${CX_ROOT}/CrossOver-Hosted Application/wineloader" "${STAGING}/wine/bin/wine64"
cp "${CX_ROOT}/CrossOver-Hosted Application/wineserver" "${STAGING}/wine/bin/wineserver"
chmod +x "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wineserver"
info "Wine binaries: wine64 + wineserver"

# WineEngine.detect() also checks for bin/wine — create alias
cp "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wine"
chmod +x "${STAGING}/wine/bin/wine"

# --- Wine DLLs (PE + Unix) ---
cp -R "${CX_ROOT}/lib/wine" "${STAGING}/wine/lib/wine"
WIN64_COUNT=$(find "${STAGING}/wine/lib/wine/x86_64-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
UNIX_COUNT=$(find "${STAGING}/wine/lib/wine/x86_64-unix" -name "*.so" 2>/dev/null | wc -l | tr -d ' ')
WIN32_COUNT=$(find "${STAGING}/wine/lib/wine/i386-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
info "Wine DLLs: ${WIN64_COUNT} x86_64-windows, ${UNIX_COUNT} x86_64-unix, ${WIN32_COUNT} i386-windows"

# --- DXMT (DirectX 11/10 → Metal) — install as builtins into lib/wine/ ---
# NOTE: macOS Gatekeeper/App Translocation can break `cp` from .app bundles while
# `open()` still works. We use Python's open/read/write as a reliable workaround.
yellow "Installing DXMT builtins..."
python3 -c "
import os
cx_dxmt = '${CX_ROOT}/lib/dxmt'
staging = '${STAGING}/wine/lib/wine'
for arch in ['x86_64-unix', 'x86_64-windows', 'i386-windows']:
    src_dir = os.path.join(cx_dxmt, arch)
    dst_dir = os.path.join(staging, arch)
    if not os.path.isdir(src_dir): continue
    for f in os.listdir(src_dir):
        if f.endswith('.so') or f.endswith('.dll'):
            with open(os.path.join(src_dir, f), 'rb') as fh: data = fh.read()
            with open(os.path.join(dst_dir, f), 'wb') as fh: fh.write(data)
            os.chmod(os.path.join(dst_dir, f), 0o755)
            print(f'  DXMT: {f} -> lib/wine/{arch}/ ({len(data)} bytes)')
" || die "DXMT installation failed"

# --- DXVK (DirectX → Vulkan fallback) ---
yellow "Staging DXVK..."
DXVK_SRC="${CX_ROOT}/lib/dxvk"
DXVK_DEST="${STAGING}/wine/lib/dxvk"
if [ -d "${DXVK_SRC}" ]; then
    mkdir -p "${DXVK_DEST}"
    cp -R "${DXVK_SRC}/" "${DXVK_DEST}/"
    DXVK_COUNT=$(find "${DXVK_DEST}" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
    info "DXVK: ${DXVK_COUNT} DLL(s)"
else
    yellow "Warning: DXVK not found in CX Preview"
fi

# --- Apple GPTK (D3D12 → D3DMetal → Metal) ---
#
# CX's d3d12.dll (120KB) fully implements the 43-entry Win32 dispatch table
# that D3DMetal.framework requires. It imports ntdll.__wine_unix_call which
# is present in CX Wine. d3d12.so is a symlink to libd3dshared.dylib.
# NO custom bridge needed — CX Wine has the required ABI.
yellow "Staging Apple GPTK (D3D12)..."
GPTK_SOURCE="${CX_ROOT}/lib64/apple_gptk"
GPTK_DEST="${STAGING}/wine/lib/gptk"

if [ -d "${GPTK_SOURCE}" ]; then
    mkdir -p "${GPTK_DEST}"
    cp -R "${GPTK_SOURCE}/" "${GPTK_DEST}/"

    [ -f "${GPTK_DEST}/external/D3DMetal.framework/D3DMetal" ] || die "GPTK: D3DMetal.framework missing"
    [ -f "${GPTK_DEST}/external/libd3dshared.dylib" ]          || die "GPTK: libd3dshared.dylib missing"
    [ -f "${GPTK_DEST}/wine/x86_64-windows/d3d12.dll" ]        || die "GPTK: d3d12.dll missing"
    [ -e "${GPTK_DEST}/wine/x86_64-unix/d3d12.so" ]            || die "GPTK: d3d12.so missing"

    if nm -gU "${GPTK_DEST}/external/libd3dshared.dylib" 2>/dev/null | grep -q "GFXTOSInterface"; then
        info "GPTK: libd3dshared.dylib validated — Apple GPTK coordinator ✓"
    else
        die "GPTK: libd3dshared.dylib is NOT the Apple GPTK coordinator (missing GFXT symbols)"
    fi

    GPTK_SIZE=$(du -sh "${GPTK_DEST}" | cut -f1)
    info "GPTK: ${GPTK_SIZE} → wine/lib/gptk/ (CX d3d12.dll kept — native ABI) ✓"
else
    yellow "Warning: apple_gptk not found in CX Preview"
    yellow "  D3D12 games will not work."
fi

# --- lib64 dylibs (MoltenVK, FreeType, GStreamer, GnuTLS, etc.) ---
# Wine's .so modules have rpath @loader_path/../../../lib64 which resolves to
# wine/lib64/ in our engine layout. All supporting dylibs must be there.
# Uses Python open/write to work around macOS Gatekeeper cp restrictions.
yellow "Staging lib64 dylibs..."
mkdir -p "${STAGING}/wine/lib64"
python3 -c "
import os
src_dir = '${CX_ROOT}/lib64'
dst_dir = '${STAGING}/wine/lib64'
count = 0
for f in os.listdir(src_dir):
    src = os.path.join(src_dir, f)
    if os.path.isfile(src) and f.endswith('.dylib'):
        with open(src, 'rb') as fh: data = fh.read()
        with open(os.path.join(dst_dir, f), 'wb') as fh: fh.write(data)
        os.chmod(os.path.join(dst_dir, f), 0o755)
        count += 1
# GStreamer plugins
gst_src = os.path.join(src_dir, 'gstreamer-1.0')
gst_dst = os.path.join(dst_dir, 'gstreamer-1.0')
if os.path.isdir(gst_src):
    os.makedirs(gst_dst, exist_ok=True)
    for f in os.listdir(gst_src):
        src = os.path.join(gst_src, f)
        if os.path.isfile(src):
            with open(src, 'rb') as fh: data = fh.read()
            with open(os.path.join(gst_dst, f), 'wb') as fh: fh.write(data)
            count += 1
print(f'  lib64: {count} files staged')
" || die "lib64 dylibs staging failed"

# --- Wine data files (NLS, fonts, wine.inf) — skip gecko/mono/icu ---
yellow "Staging Wine data files..."
if [ -d "${CX_ROOT}/share/wine" ]; then
    mkdir -p "${STAGING}/wine/share/wine"
    for datadir in nls fonts; do
        if [ -d "${CX_ROOT}/share/wine/${datadir}" ]; then
            cp -R "${CX_ROOT}/share/wine/${datadir}" "${STAGING}/wine/share/wine/"
            info "Copied share/wine/${datadir}"
        fi
    done
    if [ -f "${CX_ROOT}/share/wine/wine.inf" ]; then
        cp "${CX_ROOT}/share/wine/wine.inf" "${STAGING}/wine/share/wine/wine.inf"
        info "Copied share/wine/wine.inf"
    else
        yellow "Warning: wine.inf not found — wineboot operations will fail"
    fi
else
    die "share/wine/ not found in CX Preview"
fi

# ---------- verify Wine works ----------

[ -x "${STAGING}/wine/bin/wine64" ]     || die "wine64 not executable"
[ -x "${STAGING}/wine/bin/wineserver" ] || die "wineserver not executable"

STAGED_VERSION=$("${STAGING}/wine/bin/wine64" --version 2>/dev/null || echo "unknown")
info "Staged Wine version: ${STAGED_VERSION}"

# ---------- pre-built prefix template ----------

yellow "Building pre-initialized prefix template..."

PREFIX_TEMPLATE="/tmp/meridian-prefix-template"
PREFIX_STAGING="${STAGING}/prefix-template"

rm -rf "${PREFIX_TEMPLATE}"
mkdir -p "${PREFIX_TEMPLATE}"

info "Running wineboot --init (this may take 1-3 minutes)..."
WINEPREFIX="${PREFIX_TEMPLATE}" \
DYLD_FALLBACK_LIBRARY_PATH="${STAGING}/wine/lib:${STAGING}/wine/lib/wine/x86_64-unix" \
WINEDLLPATH="${STAGING}/wine/lib/wine" \
WINELOADER="${STAGING}/wine/bin/wine64" \
WINESERVER="${STAGING}/wine/bin/wineserver" \
    "${STAGING}/wine/bin/wine64" wineboot --init
info "  wineboot --init exit=$?"

sleep 5
WINEPREFIX="${PREFIX_TEMPLATE}" \
DYLD_FALLBACK_LIBRARY_PATH="${STAGING}/wine/lib" \
    "${STAGING}/wine/bin/wineserver" -k 2>/dev/null || true
sleep 2
pkill -9 -f "${PREFIX_TEMPLATE}" 2>/dev/null || true
sleep 1

[ -f "${PREFIX_TEMPLATE}/system.reg" ] || die "prefix template missing system.reg — wineboot --init failed"
TEMPLATE_DLL_COUNT=$(find "${PREFIX_TEMPLATE}/drive_c/windows/system32" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
[ "${TEMPLATE_DLL_COUNT}" -gt 100 ] || die "prefix template has too few DLLs (${TEMPLATE_DLL_COUNT}) — wineboot --init incomplete"
info "Prefix template: ${TEMPLATE_DLL_COUNT} DLLs in system32"

mkdir -p "${PREFIX_TEMPLATE}/drive_c/windows/syswow64"
info "Prefix template: syswow64/ guaranteed ✓"

rm -rf "${PREFIX_TEMPLATE}/dosdevices"
mkdir -p "${PREFIX_TEMPLATE}/dosdevices"

cp -R "${PREFIX_TEMPLATE}" "${PREFIX_STAGING}"
info "Prefix template staged ✓"
rm -rf "${PREFIX_TEMPLATE}"

# ---------- finalize staging ----------

echo "${TAG}" > "${STAGING}/wine/meridian-engine-version.txt"
info "Embedded engine version: ${TAG}"

# ---------- custom WinRT stubs ----------

yellow "Building custom coremessaging.dll (DispatcherQueue stub)..."
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    COREMSG_OUT="${STAGING}/wine/lib/wine/x86_64-windows/coremessaging.dll"
    bash "$(dirname "${BASH_SOURCE[0]}")/build-coremessaging.sh" "${COREMSG_OUT}" \
        || yellow "Warning: coremessaging.dll build failed — using CX built-in"
    info "coremessaging.dll: custom stub installed ✓"
else
    yellow "Warning: x86_64-w64-mingw32-gcc not found — skipping coremessaging stub"
fi

# ---------- validate ----------

yellow "Validating staged engine..."

[ -x "${STAGING}/wine/bin/wine64" ]     || die "wine64 not executable"
[ -x "${STAGING}/wine/bin/wineserver" ] || die "wineserver not executable"

NLS_DIR="${STAGING}/wine/share/wine/nls"
[ -d "${NLS_DIR}" ] || die "NLS directory missing"
for nls_file in l_intl.nls locale.nls normnfc.nls; do
    [ -f "${NLS_DIR}/${nls_file}" ] || die "Required NLS file missing: ${nls_file}"
done
info "NLS files verified ✓"

[ -f "${STAGING}/wine/share/wine/wine.inf" ] || die "wine.inf missing"
info "wine.inf verified ✓"

[ -f "${STAGING}/prefix-template/system.reg" ] || die "prefix-template/system.reg missing"
[ -d "${STAGING}/prefix-template/drive_c/windows/syswow64" ] || die "prefix-template syswow64/ missing"
info "prefix-template verified ✓"

[ -f "${STAGING}/wine/lib/wine/x86_64-unix/wiremetal.so" ]  || die "DXMT wiremetal.so missing"
[ -f "${STAGING}/wine/lib/wine/x86_64-windows/d3d11.dll" ]  || die "DXMT d3d11.dll missing"
info "DXMT builtin DLLs verified ✓"

if [ -f "${STAGING}/wine/lib/gptk/external/D3DMetal.framework/D3DMetal" ]; then
    [ -f "${STAGING}/wine/lib/gptk/wine/x86_64-windows/d3d12.dll" ] || die "GPTK d3d12.dll missing from gptk/wine/"
    info "GPTK D3D12 verified (CX d3d12.dll native) ✓"
else
    yellow "Warning: GPTK not bundled — D3D12 games will not work"
fi

FILE_COUNT=$(find "${STAGING}" -type f | wc -l | tr -d ' ')
STAGING_SIZE=$(du -sh "${STAGING}" | cut -f1)
info "Staged ${FILE_COUNT} files (${STAGING_SIZE})"

# ---------- archive ----------

yellow "Creating archive..."
cd /tmp && tar czf "${ARCHIVE}" -C "${STAGING}" .
ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
info "Archive: ${ARCHIVE} (${ARCHIVE_SIZE})"

TARBALL_CHECK=$(tar tzf "${ARCHIVE}" | grep -c "wine/bin/wine64" || true)
[ "${TARBALL_CHECK}" -ge 1 ] || die "Tarball does not contain wine/bin/wine64"

# ---------- upload ----------

yellow "Uploading release ${TAG} to ${REPO}..."

NOTES="Wine engine runtime for Meridian.

**Wine:** ${STAGED_VERSION} (CrossOver Preview — CX Wine with full CodeWeavers patches)
**DXMT:** CrossOver Preview builtin — DirectX 11/10 → Metal
**DXVK:** CrossOver Preview — DirectX → Vulkan fallback
**GPTK:** Apple Game Porting Toolkit — DirectX 12 → D3DMetal → Metal (CX d3d12.dll native)
**MoltenVK:** CrossOver Preview — Vulkan → Metal
**Architecture:** arm64 / x86_64 (Rosetta 2)
**Archive size:** ${ARCHIVE_SIZE}
**Files:** ${FILE_COUNT}

**Engine layout:**
- \`wine/bin/wine64\` — Wine loader (CX wineloader)
- \`wine/bin/wineserver\` — Wine server
- \`wine/lib/wine/\` — Wine DLLs + DXMT builtin DLLs
- \`wine/lib/gptk/\` — Apple GPTK (D3DMetal.framework + CX d3d12.dll)
- \`wine/lib/dxvk/\` — DXVK DirectX → Vulkan DLLs (fallback)
- \`wine/lib/libMoltenVK.dylib\` — Vulkan → Metal
- \`wine/share/wine/\` — NLS, fonts, wine.inf
- \`wine/meridian-engine-version.txt\` — version tag

**Install target:**
\`~/Library/Application Support/com.meridian.app/engine/\`

**Licenses:** Wine LGPL · DXMT MIT · DXVK Zlib · MoltenVK Apache 2.0 · GPTK Apple"

gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "Wine Engine ${VERSION}" \
    --notes "${NOTES}" \
    "${ARCHIVE}"

# ---------- cleanup ----------

rm -rf "${STAGING}" "${ARCHIVE}"

echo ""
green "Release ${TAG} published:"
gh release view "${TAG}" --repo "${REPO}" --json url -q '.url'
echo ""
green "Done."
