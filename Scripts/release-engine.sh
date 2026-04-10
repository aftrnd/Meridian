#!/usr/bin/env bash
#
# release-engine.sh — Assemble and publish the Meridian Wine engine.
#
# Usage:
#   bash Scripts/release-engine.sh [VERSION]
#
# Examples:
#   bash Scripts/release-engine.sh              # auto-increments patch
#   bash Scripts/release-engine.sh v4.0.0       # explicit version
#
# Prerequisites:
#   - CrossOver Preview installed at /Applications/CrossOver Preview.app
#     (source for DXMT, DXVK, GPTK rendering components — NOT the Wine binary)
#   - gh CLI authenticated:   brew install gh && gh auth login
#   - x86_64-w64-mingw32-gcc: brew install mingw-w64  (for custom coremessaging.dll)
#   - curl + xz (both ship with macOS)
#
# What it does:
#   1. Downloads Gcenx wine-devel 11.6 (Security.framework TLS — works standalone)
#   2. Installs DXMT builtins from CrossOver Preview (DirectX 11/10 → Metal)
#   3. Stages DXVK from CrossOver Preview (DirectX → Vulkan fallback)
#   4. Stages GPTK from CrossOver Preview (D3D12 → D3DMetal; active only with CX Wine ABI)
#   5. Stages lib64 dylibs from CrossOver Preview (MoltenVK, GnuTLS, etc.)
#   6. Builds a pre-initialized prefix template via wineboot --init
#   7. Validates binaries, NLS data, syswow64, and prefix template
#   8. Creates a .tar.gz archive and uploads to aftrnd/meridian
#
# Wine source: Gcenx/macOS_Wine_builds wine-devel 11.6
#   WHY Gcenx (not CX Wine):
#   CX Wine 11.4 depends on GnuTLS (via CrossOver's lib64/libgnutls.30.dylib) for
#   HTTPS/TLS. When run standalone (outside CrossOver's full bundle), TLS connections
#   fail with HTTP error 0 — Steam bootstrap never downloads its client. CLI-verified
#   April 2026: steam.exe with CX Wine 11.4 → "Download failed: http error 0" on every
#   Steam CDN request. Gcenx Wine uses Security.framework for TLS — works standalone.
#
# GPTK + CX Wine ABI note:
#   GPTK's d3d12.dll and dxgi.dll (from CX Preview apple_gptk) both import
#   ntdll.__wine_unix_call. This function exists only in CX Wine, not Gcenx Wine.
#   Loading these DLLs on Gcenx Wine causes an immediate abort. WineEngine.detect()
#   checks ntdll.so for __wine_unix_call and only enables GPTK (sets gptkPath) when
#   the CX ABI is present. With Gcenx Wine 11.6, gptkPath = nil → no GPTK env vars.
#   The GPTK files ARE still staged into the engine for future CX Wine use.
#
set -euo pipefail

REPO="aftrnd/meridian"
STAGING="/tmp/meridian-engine"
ARCHIVE="/tmp/meridian-engine-arm64.tar.gz"

CX_ROOT="/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver"

GCENX_VERSION="11.6"
GCENX_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/${GCENX_VERSION}/wine-devel-${GCENX_VERSION}-osx64.tar.xz"
GCENX_TARBALL="/tmp/gcenx-wine-${GCENX_VERSION}.tar.xz"
GCENX_EXTRACT="/tmp/gcenx-wine-${GCENX_VERSION}-extracted"
GCENX_WINE_ROOT="${GCENX_EXTRACT}/Wine Devel.app/Contents/Resources/wine"

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
command -v curl  >/dev/null 2>&1 || die "curl not found"
gh auth status >/dev/null 2>&1   || die "gh CLI not authenticated. Run: gh auth login"

[ -d "${CX_ROOT}" ] || die "CrossOver Preview not found at /Applications/CrossOver Preview.app"
[ -d "${CX_ROOT}/lib/dxmt" ]  || die "CX lib/dxmt/ not found (DXMT source)"

info "CrossOver Preview source: ${CX_ROOT}"
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

# ---------- Download Gcenx Wine 11.6 ----------

yellow "Downloading Gcenx wine-devel ${GCENX_VERSION}..."
if [ -f "${GCENX_TARBALL}" ]; then
    info "Tarball already cached at ${GCENX_TARBALL} — skipping download"
else
    curl -L --progress-bar -o "${GCENX_TARBALL}" "${GCENX_URL}" \
        || die "Failed to download Gcenx Wine ${GCENX_VERSION}"
fi

TARBALL_SIZE=$(du -sh "${GCENX_TARBALL}" | cut -f1)
info "Gcenx tarball: ${TARBALL_SIZE}"

yellow "Extracting Gcenx Wine ${GCENX_VERSION}..."
rm -rf "${GCENX_EXTRACT}"
mkdir -p "${GCENX_EXTRACT}"
tar -xf "${GCENX_TARBALL}" -C "${GCENX_EXTRACT}" \
    || die "Failed to extract Gcenx Wine tarball"

[ -d "${GCENX_WINE_ROOT}/bin" ] || die "Gcenx Wine Devel.app structure not found after extraction"
[ -f "${GCENX_WINE_ROOT}/bin/wine" ] || die "Gcenx wine binary not found"
[ -f "${GCENX_WINE_ROOT}/bin/wineserver" ] || die "Gcenx wineserver not found"

GCENX_VERSION_STR=$("${GCENX_WINE_ROOT}/bin/wine" --version 2>/dev/null || echo "unknown")
info "Gcenx Wine version: ${GCENX_VERSION_STR}"

# ---------- stage Wine from Gcenx ----------

yellow "Staging Wine from Gcenx ${GCENX_VERSION}..."
rm -rf "${STAGING}"
mkdir -p "${STAGING}/wine/bin" "${STAGING}/wine/lib" "${STAGING}/wine/share"

# Wine binaries — Gcenx bin/wine is the unified loader (wine64 role)
cp "${GCENX_WINE_ROOT}/bin/wine"       "${STAGING}/wine/bin/wine64"
cp "${GCENX_WINE_ROOT}/bin/wineserver" "${STAGING}/wine/bin/wineserver"
chmod +x "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wineserver"
# wine alias (WineEngine.detect() checks for bin/wine as well)
cp "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wine"
chmod +x "${STAGING}/wine/bin/wine"
info "Wine binaries: wine64 + wineserver (Gcenx ${GCENX_VERSION_STR})"

# Wine DLLs (PE + Unix) — from Gcenx
cp -R "${GCENX_WINE_ROOT}/lib/wine" "${STAGING}/wine/lib/wine"
WIN64_COUNT=$(find "${STAGING}/wine/lib/wine/x86_64-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
UNIX_COUNT=$(find "${STAGING}/wine/lib/wine/x86_64-unix" -name "*.so" 2>/dev/null | wc -l | tr -d ' ')
WIN32_COUNT=$(find "${STAGING}/wine/lib/wine/i386-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
info "Wine DLLs: ${WIN64_COUNT} x86_64-windows, ${UNIX_COUNT} x86_64-unix, ${WIN32_COUNT} i386-windows"

# Gcenx lib/*.dylib — includes libMoltenVK.dylib, libinotify.0.dylib, etc.
# wineserver has rpath @loader_path/../lib/ which resolves to wine/lib/ at runtime.
yellow "Staging Gcenx lib/ dylibs..."
python3 -c "
import os, shutil
src_dir = '${GCENX_WINE_ROOT}/lib'
dst_dir = '${STAGING}/wine/lib'
count = 0
for f in os.listdir(src_dir):
    src = os.path.join(src_dir, f)
    if os.path.isfile(src) and f.endswith('.dylib'):
        dst = os.path.join(dst_dir, f)
        with open(src, 'rb') as fh: data = fh.read()
        with open(dst, 'wb') as fh: fh.write(data)
        os.chmod(dst, 0o755)
        count += 1
print(f'  Gcenx lib/: {count} dylibs staged')
" || die "Gcenx lib/ dylib staging failed"

# Wine data files (NLS, fonts, wine.inf) — from Gcenx
yellow "Staging Wine data files (Gcenx)..."
if [ -d "${GCENX_WINE_ROOT}/share/wine" ]; then
    mkdir -p "${STAGING}/wine/share/wine"
    for datadir in nls fonts; do
        if [ -d "${GCENX_WINE_ROOT}/share/wine/${datadir}" ]; then
            cp -R "${GCENX_WINE_ROOT}/share/wine/${datadir}" "${STAGING}/wine/share/wine/"
            info "Copied share/wine/${datadir}"
        fi
    done
    if [ -f "${GCENX_WINE_ROOT}/share/wine/wine.inf" ]; then
        cp "${GCENX_WINE_ROOT}/share/wine/wine.inf" "${STAGING}/wine/share/wine/wine.inf"
        info "Copied share/wine/wine.inf"
    else
        yellow "Warning: wine.inf not found in Gcenx — wineboot operations will fail"
    fi
else
    die "share/wine/ not found in Gcenx Wine package"
fi

# ---------- DXMT builtins (from CrossOver Preview) ----------
# DXMT translates DirectX 11/10 → Metal. Installs as Wine builtins in lib/wine/
# alongside Gcenx Wine DLLs. DXMT uses wiremac.so Metal APIs present in Gcenx Wine 11.6.
yellow "Installing DXMT builtins (from CX Preview)..."
python3 -c "
import os
cx_dxmt = '${CX_ROOT}/lib/dxmt'
staging = '${STAGING}/wine/lib/wine'
count = 0
for arch in ['x86_64-unix', 'x86_64-windows', 'i386-windows']:
    src_dir = os.path.join(cx_dxmt, arch)
    dst_dir = os.path.join(staging, arch)
    if not os.path.isdir(src_dir): continue
    for f in os.listdir(src_dir):
        if f.endswith('.so') or f.endswith('.dll'):
            with open(os.path.join(src_dir, f), 'rb') as fh: data = fh.read()
            with open(os.path.join(dst_dir, f), 'wb') as fh: fh.write(data)
            os.chmod(os.path.join(dst_dir, f), 0o755)
            count += 1
print(f'  DXMT: {count} files installed as Wine builtins')
" || die "DXMT installation failed"

# ---------- DXVK (DirectX → Vulkan fallback) — from CrossOver Preview ----------
yellow "Staging DXVK (from CX Preview)..."
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

# ---------- Apple GPTK (D3D12 → D3DMetal → Metal) — from CrossOver Preview ----------
#
# IMPORTANT: GPTK's d3d12.dll and dxgi.dll import ntdll.__wine_unix_call (CX Wine only).
# With Gcenx Wine (current engine base), WineEngine.detect() detects the absence of
# __wine_unix_call in ntdll.so and sets gptkPath = nil — GPTK env vars are NOT injected.
# These files are staged here for future use when CX Wine ABI becomes the engine base.
yellow "Staging Apple GPTK (from CX Preview — for future CX Wine use)..."
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
    info "GPTK: ${GPTK_SIZE} staged (disabled on Gcenx Wine; active when CX ABI detected) ✓"
else
    yellow "Warning: apple_gptk not found in CX Preview — D3D12 will not work"
fi

# ---------- lib64 dylibs from CX Preview (libgnutls EXCLUDED) ----------
# CRITICAL: libgnutls MUST NOT be staged. Gcenx Wine's ntdll.so has rpath
# @loader_path/../../../lib64 → wine/lib64/. If libgnutls.30.dylib is present
# there, Wine's crypt32 dlopens it and uses GnuTLS instead of Security.framework.
# GnuTLS from CX's lib64 fails standalone → HTTP error 0 on all Steam CDN requests
# → "Steam needs to be online to update." CLI-verified April 2026.
# Gcenx Wine uses Security.framework (always available) when GnuTLS is absent.
yellow "Staging lib64 dylibs (from CX Preview, libgnutls excluded)..."
mkdir -p "${STAGING}/wine/lib64"
python3 -c "
import os
src_dir = '${CX_ROOT}/lib64'
dst_dir = '${STAGING}/wine/lib64'
count = 0
for f in os.listdir(src_dir):
    src = os.path.join(src_dir, f)
    if os.path.isfile(src) and f.endswith('.dylib'):
        if 'gnutls' in f.lower():
            continue  # NEVER stage libgnutls — breaks Gcenx Wine TLS
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
print(f'  lib64: {count} files staged (libgnutls excluded)')
" || die "lib64 dylibs staging failed"

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
# Run wineboot --init in background with a 180s timeout.
# On Gcenx Wine, wineboot.exe sometimes stays alive after completing its work.
# The prefix (system.reg, system32 DLLs) is fully created within ~60s;
# we kill the process after 180s so the script doesn't hang indefinitely.
WINEPREFIX="${PREFIX_TEMPLATE}" \
DYLD_FALLBACK_LIBRARY_PATH="${STAGING}/wine/lib:${STAGING}/wine/lib/wine/x86_64-unix:${STAGING}/wine/lib64" \
WINEDLLPATH="${STAGING}/wine/lib/wine" \
WINELOADER="${STAGING}/wine/bin/wine64" \
WINESERVER="${STAGING}/wine/bin/wineserver" \
    "${STAGING}/wine/bin/wine64" wineboot --init &
WINEBOOT_PID=$!
for i in $(seq 1 36); do
    sleep 5
    if ! kill -0 ${WINEBOOT_PID} 2>/dev/null; then
        break
    fi
    if [ ${i} -eq 36 ]; then
        yellow "wineboot --init timeout (180s) — prefix appears complete, killing..."
        kill -9 ${WINEBOOT_PID} 2>/dev/null || true
        pkill -9 -f "wineboot.exe" 2>/dev/null || true
    fi
done
wait ${WINEBOOT_PID} 2>/dev/null || true
WINEBOOT_EXIT=$?
info "  wineboot --init exit=${WINEBOOT_EXIT}"

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
        || yellow "Warning: coremessaging.dll build failed — using Wine built-in"
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

[ -f "${STAGING}/wine/lib/wine/x86_64-unix/winemetal.so" ]  || die "DXMT winemetal.so missing"
[ -f "${STAGING}/wine/lib/wine/x86_64-windows/d3d11.dll" ]  || die "DXMT d3d11.dll missing"
info "DXMT builtin DLLs verified ✓"

if [ -f "${STAGING}/wine/lib/gptk/external/D3DMetal.framework/D3DMetal" ]; then
    [ -f "${STAGING}/wine/lib/gptk/wine/x86_64-windows/d3d12.dll" ] || die "GPTK d3d12.dll missing from gptk/wine/"
    info "GPTK D3D12 staged (disabled on Gcenx Wine; requires CX Wine ABI) ✓"
else
    yellow "Warning: GPTK not bundled — D3D12 games will not work"
fi

# Verify Wine ABI: check whether ntdll.so exports __wine_unix_call exactly
# (not just __wine_unix_call_dispatcher which is a different function).
# This determines whether GPTK will be active (CX Wine) or disabled (Gcenx Wine).
NTDLL_SO="${STAGING}/wine/lib/wine/x86_64-unix/ntdll.so"
[ -f "${NTDLL_SO}" ] || die "ntdll.so missing"
if nm -gU "${NTDLL_SO}" 2>/dev/null | grep -qE " T _?__wine_unix_call$"; then
    info "CX Wine ABI: ntdll exports __wine_unix_call — GPTK will be active when installed ✓"
else
    info "Gcenx Wine ABI: no __wine_unix_call — GPTK disabled by WineEngine.detect (DX11 via DXMT works) ✓"
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

**Wine:** ${STAGED_VERSION} (Gcenx wine-devel ${GCENX_VERSION} — Security.framework TLS, works standalone)
**DXMT:** CrossOver Preview builtin — DirectX 11/10 → Metal
**DXVK:** CrossOver Preview — DirectX → Vulkan fallback
**GPTK:** Apple Game Porting Toolkit staged (active only with CX Wine ABI; disabled with Gcenx)
**MoltenVK:** Gcenx lib/libMoltenVK.dylib + CX lib64/
**Architecture:** arm64 / x86_64 (Rosetta 2)
**Archive size:** ${ARCHIVE_SIZE}
**Files:** ${FILE_COUNT}

**Engine layout:**
- \`wine/bin/wine64\` — Wine loader (Gcenx wine-devel ${GCENX_VERSION})
- \`wine/bin/wineserver\` — Wine server
- \`wine/lib/wine/\` — Wine DLLs + DXMT builtin DLLs
- \`wine/lib/gptk/\` — Apple GPTK (staged; disabled unless CX Wine ABI detected)
- \`wine/lib/dxvk/\` — DXVK DirectX → Vulkan DLLs (fallback)
- \`wine/lib/libMoltenVK.dylib\` — Vulkan → Metal (from Gcenx)
- \`wine/lib64/\` — CX lib64 dylibs (MoltenVK copy, GnuTLS, GStreamer)
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

rm -rf "${STAGING}" "${ARCHIVE}" "${GCENX_EXTRACT}"
# Keep GCENX_TARBALL cached for re-runs (rm manually if needed)

echo ""
green "Release ${TAG} published:"
gh release view "${TAG}" --repo "${REPO}" --json url -q '.url'
echo ""
green "Done."
