#!/usr/bin/env bash
#
# release-engine.sh — Download, assemble, and publish the Meridian Wine engine.
#
# Usage:
#   bash Scripts/release-engine.sh [VERSION]
#
# Examples:
#   bash Scripts/release-engine.sh              # auto-increments patch (v2.0.1-engine)
#   bash Scripts/release-engine.sh v2.0.0       # explicit version
#
# Prerequisites:
#   - gh CLI authenticated:   brew install gh && gh auth login
#   - curl (standard on macOS)
#
# What it does:
#   1. Downloads wine-devel from Gcenx/macOS_Wine_builds (Wine 11.x with CW patches)
#   2. Downloads DXMT (builtin) from 3Shain/dxmt (DirectX → Metal)
#   3. Downloads DXVK from doitsujin/dxvk (DirectX → Vulkan fallback)
#   4. Assembles wine/bin, wine/lib, wine/share/wine/{nls,fonts}
#      Installs DXMT builtin DLLs into wine/lib/wine/x86_64-{unix,windows}
#      Installs DXVK DLLs into wine/lib/dxvk/
#   5. Builds a pre-initialized prefix template via wineboot --init
#   6. Validates binaries, NLS data, syswow64, and prefix template
#   7. Creates a .tar.gz archive and uploads to aftrnd/meridian
#
# Wine Source: Gcenx/macOS_Wine_builds (wine-devel variant)
# WHY: Gcenx/winecx (wine-crossover FOSS) stopped publishing new releases after
#      Wine 8.0.1 (Feb 2024). The macOS_Wine_builds repo publishes Wine 11.x+
#      with the same CodeWeavers patches (CW 22435 for DXMT Metal APIs, CW 13322/
#      17315/21883 for Steam, CW 20760 for Rosetta2 thunks, Security.framework TLS).
#      CLI-verified March 2026: Wine 11.5 fixes all 926 abort stubs, adds
#      IsMouseInPointerEnabled to user32, has macdrv Metal view APIs for DXMT,
#      and has Security.framework TLS in crypt32.so (Steam HTTPS works standalone).
#
set -euo pipefail

REPO="aftrnd/meridian"
STAGING="/tmp/meridian-engine"
ARCHIVE="/tmp/meridian-engine-arm64.tar.gz"
DOWNLOADS="/tmp/meridian-engine-downloads"

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
command -v curl  >/dev/null 2>&1 || die "curl not found (should be standard on macOS)"
command -v tar   >/dev/null 2>&1 || die "tar not found"
gh auth status >/dev/null 2>&1   || die "gh CLI not authenticated. Run: gh auth login"

# ---------- resolve component versions ----------

yellow "Resolving latest component versions..."

# Wine: Gcenx/macOS_Wine_builds — wine-devel variant (Wine 11.x with CW patches)
#
# Gcenx/winecx (wine-crossover FOSS) stopped publishing new releases after
# Wine 8.0.1 (Feb 2024). The macOS_Wine_builds repo publishes the same CodeWeavers
# patches on top of upstream Wine 11.x+:
#   - CW 22435: macdrv Metal view APIs (macdrv_view_create_metal_view etc.) — DXMT requires this
#   - CW 13322, 17315, 21883: Steam compatibility
#   - CW 20760: wow64cpu Rosetta2 thunks for Apple Silicon
#   - CW 18947: toggle_executable_pages_for_rosetta
#   - Security.framework TLS in crypt32.so (Steam HTTPS works standalone)
#
# CLI-verified March 2026 (Wine 11.5):
#   - user32.dll exports IsMouseInPointerEnabled (Unity games no longer abort)
#   - win32u.dll has 0 abort stubs (was 926 in Wine 8.0.1)
#   - wiremac.so exports macdrv Metal APIs (DXMT works)
#   - steam.exe bootstraps and downloads full client
#   - SteamCMD batch login succeeds with cached credentials
#   - Game launch: No I'm not a Human (Unity) ran 30+ seconds without crashing
#
# Use wine-devel (not wine-staging) — devel includes CodeWeavers' DXMT/Steam patches.
# wine-staging adds more patches that may cause regressions for our use case.
#
# NEVER use CrossOver Preview.app or CrossOver.app commercial binaries.
# NEVER use wine-staging from Gcenx/macOS_Wine_builds (different repo/variant).
WINE_REPO="Gcenx/macOS_Wine_builds"
WINE_LOCAL=false

# Download latest wine-devel from Gcenx/macOS_Wine_builds
WINE_TAG=$(gh release list --repo "${WINE_REPO}" --limit 10 2>/dev/null \
    | grep -v "Pre-release\|broken" \
    | grep -oE '[0-9]+\.[0-9]+(_[0-9]+)?' \
    | head -1)
[ -n "${WINE_TAG}" ] || die "Could not determine latest wine-devel release from ${WINE_REPO}"
WINE_ASSET="wine-devel-${WINE_TAG}-osx64.tar.xz"
WINE_URL=$(gh release view "${WINE_TAG}" --repo "${WINE_REPO}" --json assets \
    -q ".assets[] | select(.name == \"${WINE_ASSET}\") | .url" 2>/dev/null)
[ -n "${WINE_URL}" ] || die "Could not find asset '${WINE_ASSET}' in ${WINE_REPO}@${WINE_TAG}"
info "Wine:    ${WINE_TAG} (${WINE_ASSET}) [wine-devel with CW patches — Gcenx/macOS_Wine_builds]"

# DXMT: 3Shain/dxmt — builtin variant (DLLs go into lib/wine/ — no override needed)
# Use grep -oE to extract the tag regardless of column position (gh adds an extra
# "Latest" column for the newest release, shifting all other columns by one).
DXMT_REPO="3Shain/dxmt"
DXMT_TAG=$(gh release list --repo "${DXMT_REPO}" --limit 5 2>/dev/null \
    | grep -v "Pre-release" \
    | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | head -1)
[ -n "${DXMT_TAG}" ] || die "Could not determine latest DXMT release from ${DXMT_REPO}"
DXMT_ASSET="dxmt-${DXMT_TAG}-builtin.tar.gz"
DXMT_URL=$(gh release view "${DXMT_TAG}" --repo "${DXMT_REPO}" --json assets \
    -q ".assets[] | select(.name == \"${DXMT_ASSET}\") | .url" 2>/dev/null)
[ -n "${DXMT_URL}" ] || die "Could not find asset '${DXMT_ASSET}' in ${DXMT_REPO}@${DXMT_TAG}"
info "DXMT:    ${DXMT_TAG} (builtin)"

# DXVK: doitsujin/dxvk — standard release (macOS fallback for Vulkan path)
DXVK_REPO="doitsujin/dxvk"
DXVK_TAG=$(gh release list --repo "${DXVK_REPO}" --limit 5 2>/dev/null \
    | grep -v "Pre-release" \
    | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | head -1)
[ -n "${DXVK_TAG}" ] || die "Could not determine latest DXVK release from ${DXVK_REPO}"
DXVK_ASSET="dxvk-${DXVK_TAG#v}.tar.gz"
DXVK_URL=$(gh release view "${DXVK_TAG}" --repo "${DXVK_REPO}" --json assets \
    -q ".assets[] | select(.name == \"${DXVK_ASSET}\") | .url" 2>/dev/null)
[ -n "${DXVK_URL}" ] || die "Could not find asset '${DXVK_ASSET}' in ${DXVK_REPO}@${DXVK_TAG}"
info "DXVK:    ${DXVK_TAG}"

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

# ---------- download ----------

yellow "Downloading components..."
rm -rf "${DOWNLOADS}"
mkdir -p "${DOWNLOADS}"

WINE_FILE="${DOWNLOADS}/${WINE_ASSET}"
DXMT_FILE="${DOWNLOADS}/${DXMT_ASSET}"
DXVK_FILE="${DOWNLOADS}/${DXVK_ASSET}"

info "Downloading Wine ${WINE_TAG}..."
curl -fL --progress-bar -o "${WINE_FILE}" "${WINE_URL}" \
    || die "Failed to download Wine from ${WINE_URL}"
info "  → $(du -sh "${WINE_FILE}" | cut -f1)"

info "Downloading DXMT ${DXMT_TAG}..."
curl -fL --progress-bar -o "${DXMT_FILE}" "${DXMT_URL}" \
    || die "Failed to download DXMT from ${DXMT_URL}"
info "  → $(du -sh "${DXMT_FILE}" | cut -f1)"

info "Downloading DXVK ${DXVK_TAG}..."
curl -fL --progress-bar -o "${DXVK_FILE}" "${DXVK_URL}" \
    || die "Failed to download DXVK from ${DXVK_URL}"
info "  → $(du -sh "${DXVK_FILE}" | cut -f1)"

echo ""

# ---------- stage Wine ----------

yellow "Staging Wine ${WINE_TAG}..."
rm -rf "${STAGING}"
mkdir -p "${STAGING}/wine"

WINE_EXTRACT="/tmp/meridian-wine-extract"
rm -rf "${WINE_EXTRACT}"
mkdir -p "${WINE_EXTRACT}"
tar xf "${WINE_FILE}" -C "${WINE_EXTRACT}"

# Gcenx/macOS_Wine_builds archives are macOS .app bundles:
#   wine-devel: "Wine Devel.app/Contents/Resources/wine/{bin,lib,share}"
#   wine-staging: "Wine Staging.app/Contents/Resources/wine/{bin,lib,share}"
# Search for the first directory named "bin" that is a sibling of "lib".
WINE_BIN_DIR=$(find "${WINE_EXTRACT}" -type d -name "bin" | while read -r d; do
    parent="$(dirname "${d}")"
    [ -d "${parent}/lib" ] && echo "${parent}" && break
done | head -1)
WINE_ROOT="${WINE_BIN_DIR}"
[ -n "${WINE_ROOT}" ] && [ -d "${WINE_ROOT}/bin" ] || die "Could not locate bin/ inside Wine archive"
[ -d "${WINE_ROOT}/lib" ] || die "Could not locate lib/ inside Wine archive"
info "Wine root: ${WINE_ROOT}"

# Copy bin/ (wine/wine64, wineserver, wineboot, etc.)
cp -R "${WINE_ROOT}/bin" "${STAGING}/wine/bin"

# Wine 11+ ships a unified 'wine' binary (not 'wine64'). Create wine64 as a hard
# link / copy so that WineEngine.swift's detection path (looking for bin/wine64)
# continues to work without any changes to the app.
if [ ! -f "${STAGING}/wine/bin/wine64" ] && [ -f "${STAGING}/wine/bin/wine" ]; then
    cp "${STAGING}/wine/bin/wine" "${STAGING}/wine/bin/wine64"
    chmod +x "${STAGING}/wine/bin/wine64"
    info "Created wine64 alias from wine (Wine 11+ unified binary)"
fi

# Copy lib/ (wine DLLs, native libs)
cp -R "${WINE_ROOT}/lib" "${STAGING}/wine/lib"

# Copy share/wine/{nls,fonts} — required for wineserver startup; skip gecko/mono (~200MB)
# Copy share/wine/wine.inf — required for wineboot --init (new prefix) and
#   wineboot --update (DLL refresh after engine upgrade). Without wine.inf,
#   any Wine prefix operation fails and users get STATUS_DLL_NOT_FOUND (exit 53).
if [ -d "${WINE_ROOT}/share/wine" ]; then
    mkdir -p "${STAGING}/wine/share/wine"
    for datadir in nls fonts; do
        src="${WINE_ROOT}/share/wine/${datadir}"
        if [ -d "${src}" ]; then
            cp -R "${src}" "${STAGING}/wine/share/wine/"
            info "Copied share/wine/${datadir}"
        fi
    done
    # wine.inf is a single file, not a directory
    if [ -f "${WINE_ROOT}/share/wine/wine.inf" ]; then
        cp "${WINE_ROOT}/share/wine/wine.inf" "${STAGING}/wine/share/wine/wine.inf"
        info "Copied share/wine/wine.inf"
    else
        yellow "Warning: wine.inf not found in Wine archive — wineboot operations will fail for new prefixes"
    fi
else
    yellow "Warning: share/wine/ not found in Wine archive — NLS check may fail"
fi

if [ "${WINE_LOCAL}" != "true" ]; then
    rm -rf "${WINE_EXTRACT}"
fi

# Confirm wine64 and wineserver are executable
[ -x "${STAGING}/wine/bin/wine64" ]     || die "wine64 not executable after Wine extraction"
[ -x "${STAGING}/wine/bin/wineserver" ] || die "wineserver not executable after Wine extraction"

WINE_VERSION=$("${STAGING}/wine/bin/wine64" --version 2>/dev/null || echo "unknown")
info "Wine version: ${WINE_VERSION}"

# ---------- stage DXMT (builtin) ----------

yellow "Staging DXMT ${DXMT_TAG} (builtin)..."

DXMT_EXTRACT="/tmp/meridian-dxmt-extract"
rm -rf "${DXMT_EXTRACT}"
mkdir -p "${DXMT_EXTRACT}"
tar xf "${DXMT_FILE}" -C "${DXMT_EXTRACT}"

# DXMT builtin archive layout (3Shain/dxmt v0.70+):
#   v0.74/x86_64-unix/winemetal.so      → lib/wine/x86_64-unix/
#   v0.74/x86_64-windows/d3d11.dll      → lib/wine/x86_64-windows/
#   v0.74/x86_64-windows/dxgi.dll       → lib/wine/x86_64-windows/
#   v0.74/x86_64-windows/winemetal.dll  → lib/wine/x86_64-windows/
#   v0.74/x86_64-windows/d3d10core.dll  → lib/wine/x86_64-windows/  (optional)
#   v0.74/i386-windows/*.dll            → lib/wine/i386-windows/
#
# As builtin DLLs these live alongside Wine's own DLLs in lib/wine/x86_64-windows/.
# They do NOT need WINEDLLOVERRIDES=n,b — Wine loads them as builtins automatically.

UNIX_DLL_DIR="${STAGING}/wine/lib/wine/x86_64-unix"
WIN_DLL_DIR="${STAGING}/wine/lib/wine/x86_64-windows"
WIN32_DLL_DIR="${STAGING}/wine/lib/wine/i386-windows"
mkdir -p "${UNIX_DLL_DIR}" "${WIN_DLL_DIR}" "${WIN32_DLL_DIR}"

# Find the version subdirectory (e.g. v0.74/) inside the extract root
DXMT_VER_DIR=$(find "${DXMT_EXTRACT}" -maxdepth 1 -mindepth 1 -type d | head -1)
[ -d "${DXMT_VER_DIR}" ] || DXMT_VER_DIR="${DXMT_EXTRACT}"
info "DXMT archive root: ${DXMT_VER_DIR}"

# Install x86_64-unix/ (.so files — Unix-side Metal bridge)
if [ -d "${DXMT_VER_DIR}/x86_64-unix" ]; then
    for sofile in "${DXMT_VER_DIR}/x86_64-unix/"*.so; do
        [ -f "${sofile}" ] || continue
        fname="$(basename "${sofile}")"
        cp "${sofile}" "${UNIX_DLL_DIR}/${fname}"
        info "DXMT: installed ${fname} → lib/wine/x86_64-unix/"
    done
fi

# Install x86_64-windows/ (.dll files — 64-bit Windows DLLs)
if [ -d "${DXMT_VER_DIR}/x86_64-windows" ]; then
    for dllfile in "${DXMT_VER_DIR}/x86_64-windows/"*.dll; do
        [ -f "${dllfile}" ] || continue
        fname="$(basename "${dllfile}")"
        cp "${dllfile}" "${WIN_DLL_DIR}/${fname}"
        info "DXMT: installed ${fname} → lib/wine/x86_64-windows/"
    done
fi

# Install i386-windows/ (.dll files — 32-bit Windows DLLs)
if [ -d "${DXMT_VER_DIR}/i386-windows" ]; then
    for dllfile in "${DXMT_VER_DIR}/i386-windows/"*.dll; do
        [ -f "${dllfile}" ] || continue
        fname="$(basename "${dllfile}")"
        cp "${dllfile}" "${WIN32_DLL_DIR}/${fname}"
        info "DXMT: installed ${fname} → lib/wine/i386-windows/"
    done
fi

# Verify the critical DXMT files landed
for required_so in "winemetal.so"; do
    [ -f "${UNIX_DLL_DIR}/${required_so}" ] || die "DXMT: required file not found after extraction: ${required_so}"
done
for required_dll in "winemetal.dll" "d3d11.dll" "dxgi.dll"; do
    [ -f "${WIN_DLL_DIR}/${required_dll}" ] || die "DXMT: required file not found after extraction: ${required_dll}"
done
info "DXMT DLLs verified ✓"

rm -rf "${DXMT_EXTRACT}"

# ---------- stage DXVK ----------

yellow "Staging DXVK ${DXVK_TAG}..."

DXVK_EXTRACT="/tmp/meridian-dxvk-extract"
rm -rf "${DXVK_EXTRACT}"
mkdir -p "${DXVK_EXTRACT}"
tar xf "${DXVK_FILE}" -C "${DXVK_EXTRACT}"

# DXVK archive typically contains dxvk-X.Y.Z/{x32,x64}/*.dll
# We keep the x64 DLLs and store them in wine/lib/dxvk/x86_64-windows/
DXVK_ROOT=$(find "${DXVK_EXTRACT}" -maxdepth 1 -type d -name "dxvk-*" | head -1)
[ -d "${DXVK_ROOT}" ] || DXVK_ROOT="${DXVK_EXTRACT}"

DXVK_DEST="${STAGING}/wine/lib/dxvk"
mkdir -p "${DXVK_DEST}/x86_64-windows"

# Prefer x64 sub-directory if present
if [ -d "${DXVK_ROOT}/x64" ]; then
    cp "${DXVK_ROOT}/x64"/*.dll "${DXVK_DEST}/x86_64-windows/" 2>/dev/null || true
elif [ -d "${DXVK_ROOT}/x86_64" ]; then
    cp "${DXVK_ROOT}/x86_64"/*.dll "${DXVK_DEST}/x86_64-windows/" 2>/dev/null || true
else
    # Flat layout — copy any .dll files directly
    cp "${DXVK_ROOT}"/*.dll "${DXVK_DEST}/x86_64-windows/" 2>/dev/null || true
fi

DXVK_COUNT=$(find "${DXVK_DEST}" -name "*.dll" | wc -l | tr -d ' ')
[ "${DXVK_COUNT}" -gt 0 ] || die "DXVK: no DLL files found after extraction"
info "DXVK: installed ${DXVK_COUNT} DLL(s)"

rm -rf "${DXVK_EXTRACT}"

# ---------- Apple GPTK (D3D12 → Metal) ----------
#
# Apple's Game Porting Toolkit translates Direct3D 12 to Metal 3 via:
#   wine/lib/gptk/wine/x86_64-windows/d3d12.dll   (PE shim, 122KB)
#   wine/lib/gptk/wine/x86_64-unix/d3d12.so        (Unix bridge, 96KB)
#   wine/lib/gptk/external/libd3dshared.dylib       (coordinator, 96KB)
#   wine/lib/gptk/external/D3DMetal.framework/      (Apple Metal translator, 5MB)
#
# GPTK is sourced from a local CrossOver Preview installation. It is distributed
# by Apple as part of the Game Porting Toolkit and by CodeWeavers via CrossOver.
# Source: /Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/
#
# WineEngine.swift detects the presence of gptk/external/D3DMetal.framework and
# automatically configures DYLD_FALLBACK_LIBRARY_PATH, WINEDLLPATH, and
# WINEDLLOVERRIDES=d3d12=n,b so D3D12 games use GPTK while DXMT handles D3D11.
#
# GPTK is optional: if not bundled, D3D12 games fall back to Wine's builtin
# d3d12.dll stub (which currently fails to create a device). D3D11 games work
# regardless via DXMT.

GPTK_SOURCE="/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk"
GPTK_DEST="${STAGING}/wine/lib/gptk"

if [ -d "${GPTK_SOURCE}" ]; then
    yellow "Staging Apple GPTK from local CrossOver Preview..."
    mkdir -p "${GPTK_DEST}"
    cp -R "${GPTK_SOURCE}/" "${GPTK_DEST}/"

    # Validate key components
    [ -f "${GPTK_DEST}/external/D3DMetal.framework/D3DMetal" ] || die "GPTK: D3DMetal.framework missing"
    [ -f "${GPTK_DEST}/external/libd3dshared.dylib" ]          || die "GPTK: libd3dshared.dylib missing"
    [ -f "${GPTK_DEST}/wine/x86_64-windows/d3d12.dll" ]        || die "GPTK: d3d12.dll missing"
    GPTK_SIZE=$(du -sh "${GPTK_DEST}" | cut -f1)
    info "GPTK: staged ${GPTK_SIZE} → wine/lib/gptk/ ✓"
else
    yellow "Warning: CrossOver Preview not found at ${GPTK_SOURCE}"
    yellow "  GPTK (D3D12 support) will NOT be bundled in this engine release."
    yellow "  D3D12 games will fail to create a D3D12 device."
    yellow "  Install CrossOver Preview to enable GPTK bundling."
fi

# ---------- pre-built prefix template ----------
#
# Running wineboot --init at the user's machine during first launch is slow
# (2-6 minutes), fragile, and produces a static "preparing environment" spinner
# that looks like a frozen app. The correct approach — used by CrossOver, Whisky,
# and every serious Wine launcher — is to ship a pre-initialized prefix template
# built on the maintainer's machine and packaged into the archive.
#
# On first run the app simply copies this template (~instant) instead of running
# wineboot --init. On engine upgrades the template from the new engine has the
# correct DLLs pre-installed, so no wineboot --update is needed either.
#
# The template is built here with the same Wine/environment as the engine.
yellow "Building pre-initialized prefix template..."

PREFIX_TEMPLATE="/tmp/meridian-prefix-template"
PREFIX_STAGING="${STAGING}/prefix-template"

rm -rf "${PREFIX_TEMPLATE}"
mkdir -p "${PREFIX_TEMPLATE}"

info "Running wineboot --init (this may take 1-3 minutes on the build machine)..."
# Wine 11+: DYLD_FALLBACK_LIBRARY_PATH needs lib/ for dylibs
# and lib/wine/x86_64-unix for .so modules. The wine64 binary is an alias of wine.
# wineboot is a Windows PE (lib/wine/x86_64-windows/wineboot.exe) invoked via Wine.
WINEPREFIX="${PREFIX_TEMPLATE}" \
DYLD_FALLBACK_LIBRARY_PATH="${STAGING}/wine/lib:${STAGING}/wine/lib/wine/x86_64-unix" \
WINEDLLPATH="${STAGING}/wine/lib/wine" \
WINELOADER="${STAGING}/wine/bin/wine64" \
WINESERVER="${STAGING}/wine/bin/wineserver" \
    "${STAGING}/wine/bin/wine64" wineboot --init
info "  wineboot --init exit=$?"

# Wait for wineserver to finish (it may linger after wineboot exits).
# Use a 30s timeout — wineserver -w blocks until all Wine processes exit,
# but lingering child processes (winedevice, explorer, etc.) can take longer.
# If still running after 30s, force-kill it and continue.
sleep 5
WINEPREFIX="${PREFIX_TEMPLATE}" \
DYLD_FALLBACK_LIBRARY_PATH="${STAGING}/wine/lib" \
    "${STAGING}/wine/bin/wineserver" -k 2>/dev/null || true
sleep 2
pkill -9 -f "${PREFIX_TEMPLATE}" 2>/dev/null || true
sleep 1

# Validate the template was created correctly
[ -f "${PREFIX_TEMPLATE}/system.reg" ] || die "prefix template missing system.reg — wineboot --init failed"
TEMPLATE_DLL_COUNT=$(find "${PREFIX_TEMPLATE}/drive_c/windows/system32" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
[ "${TEMPLATE_DLL_COUNT}" -gt 100 ] || die "prefix template has too few DLLs (${TEMPLATE_DLL_COUNT}) — wineboot --init incomplete"
info "Prefix template: ${TEMPLATE_DLL_COUNT} DLLs in system32"

# Ensure syswow64/ exists in the template.
#
# Wine 8.x created an empty syswow64/ after wineboot --init. Wine 11.x does not
# create the directory at all. The app's WinePrefix.create() and
# resetToEngineTemplate() populate syswow64 from i386-windows/, but they must
# find the directory already existing — so we guarantee it here.
# Without this, SteamSetup.exe (32-bit PE) exits 53 (STATUS_DLL_NOT_FOUND / kernel32).
mkdir -p "${PREFIX_TEMPLATE}/drive_c/windows/syswow64"
info "Prefix template: syswow64/ guaranteed ✓"

# Strip user-specific and volatile files that should not be in the template
rm -f "${PREFIX_TEMPLATE}/dosdevices/z:"  # Z: drive points to build machine's root
# Recreate the dosdevices symlinks neutrally (they'll be set up at copy time)
rm -rf "${PREFIX_TEMPLATE}/dosdevices"
mkdir -p "${PREFIX_TEMPLATE}/dosdevices"

# Package the template alongside the Wine engine
cp -R "${PREFIX_TEMPLATE}" "${PREFIX_STAGING}"
info "Prefix template staged ✓"
rm -rf "${PREFIX_TEMPLATE}"

# ---------- finalize staging ----------

# Embed release tag so the app can display it in Settings → Updates.
echo "${TAG}" > "${STAGING}/wine/meridian-engine-version.txt"
info "Embedded engine version: ${TAG}"

# ---------- custom WinRT stubs ----------
#
# Wine's coremessaging.dll only implements DispatcherQueueController but not
# DispatcherQueue itself. Unity 6.3+ needs DispatcherQueue::GetForCurrentThread()
# or it crashes immediately after D3D11 initialization.
# Build and replace coremessaging.dll with our extended stub.

yellow "Building custom coremessaging.dll (DispatcherQueue stub)..."
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    COREMSG_OUT="${STAGING}/wine/lib/wine/x86_64-windows/coremessaging.dll"
    bash "$(dirname "${BASH_SOURCE[0]}")/build-coremessaging.sh" "${COREMSG_OUT}" \
        || yellow "Warning: coremessaging.dll build failed — using Wine's built-in (Unity 6.3+ games will not work)"
    info "coremessaging.dll: custom stub installed ✓"
else
    yellow "Warning: x86_64-w64-mingw32-gcc not found — skipping coremessaging stub build"
    yellow "  Install: brew install mingw-w64"
    yellow "  Unity 6.3+ games (Unity 6000.3+) will fail with CLASS_E_CLASSNOTAVAILABLE for Windows.System.DispatcherQueue"
fi

# ---------- validate ----------

yellow "Validating staged engine..."

[ -x "${STAGING}/wine/bin/wine64" ]     || die "wine64 not executable"
[ -x "${STAGING}/wine/bin/wineserver" ] || die "wineserver not executable"

# NLS files — wineserver aborts without these
NLS_DIR="${STAGING}/wine/share/wine/nls"
[ -d "${NLS_DIR}" ] || die "NLS directory missing: ${NLS_DIR}"
for nls_file in l_intl.nls locale.nls normnfc.nls; do
    [ -f "${NLS_DIR}/${nls_file}" ] || die "Required NLS file missing: ${nls_file}"
done
info "NLS files verified ✓"

# wine.inf — required for wineboot --init and wineboot --update
[ -f "${STAGING}/wine/share/wine/wine.inf" ] || die "wine.inf missing from engine — prefix creation and updates will fail. Check that the Wine archive contains share/wine/wine.inf."
info "wine.inf verified ✓"

# Prefix template — must exist and contain system.reg and syswow64/
[ -f "${STAGING}/prefix-template/system.reg" ] || die "prefix-template/system.reg missing — wineboot --init did not complete during packaging"
[ -d "${STAGING}/prefix-template/drive_c/windows/syswow64" ] || die "prefix-template syswow64/ missing — 32-bit apps (SteamSetup.exe) will fail with exit 53"
info "prefix-template verified ✓"

# DXMT critical files
[ -f "${STAGING}/wine/lib/wine/x86_64-unix/winemetal.so" ]       || die "DXMT winemetal.so missing"
[ -f "${STAGING}/wine/lib/wine/x86_64-windows/d3d11.dll" ]       || die "DXMT d3d11.dll missing"
[ -f "${STAGING}/wine/lib/wine/x86_64-windows/dxgi.dll" ]        || die "DXMT dxgi.dll missing"
info "DXMT builtin DLLs verified ✓"

# GPTK (optional — warn rather than die so builds work without CrossOver Preview)
if [ -f "${STAGING}/wine/lib/gptk/external/D3DMetal.framework/D3DMetal" ]; then
    info "GPTK D3D12 verified ✓"
else
    yellow "Warning: GPTK not bundled — D3D12 games will not work (install CrossOver Preview to enable)"
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

**Wine:** ${WINE_VERSION} (${WINE_TAG}, via Gcenx/macOS_Wine_builds)
**DXMT:** ${DXMT_TAG} — DirectX 11/10 → Metal (3Shain/dxmt, builtin DLLs)
**DXVK:** ${DXVK_TAG} — DirectX → Vulkan fallback (doitsujin/dxvk)
**GPTK:** Apple Game Porting Toolkit — DirectX 12 → Metal (if bundled)
**Architecture:** arm64 / x86_64 (Rosetta 2)
**Archive size:** ${ARCHIVE_SIZE}
**Files:** ${FILE_COUNT}

**Engine layout:**
- \`wine/bin/wine64\` — Wine 64-bit loader
- \`wine/bin/wineserver\` — Wine server process
- \`wine/lib/wine/\` — Wine DLLs + DXMT builtin DLLs (d3d11, dxgi, winemetal)
- \`wine/lib/dxvk/\` — DXVK DirectX → Vulkan DLLs (fallback path)
- \`wine/share/wine/nls/\` — NLS locale/encoding tables (required for startup)
- \`wine/share/wine/fonts/\` — Wine font data
- \`wine/meridian-engine-version.txt\` — version tag (read by Settings → Updates)

**Install target:**
\`~/Library/Application Support/com.meridian.app/engine/\`

**Licenses:** Wine LGPL · DXMT MIT · DXVK Zlib · MoltenVK Apache 2.0"

gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "Wine Engine ${VERSION}" \
    --notes "${NOTES}" \
    "${ARCHIVE}"

# ---------- cleanup ----------

rm -rf "${STAGING}" "${ARCHIVE}" "${DOWNLOADS}"

echo ""
green "Release ${TAG} published:"
gh release view "${TAG}" --repo "${REPO}" --json url -q '.url'
echo ""
green "Done."
