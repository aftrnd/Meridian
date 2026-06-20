#!/usr/bin/env bash
#
# release-engine.sh — Assemble and publish the Meridian Wine engine from CrossOver Preview.
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
#   - gh CLI authenticated:   brew install gh && gh auth login
#   - x86_64-w64-mingw32-gcc: brew install mingw-w64  (for custom coremessaging.dll)
#
# What it does:
#   1. Copies Wine binary + DLLs from CrossOver Preview (CX Wine 11.4)
#   2. Stages DXMT from CrossOver Preview into lib/dxmt/ (DirectX 11/10 → Metal)
#   3. Stages DXVK from CrossOver Preview (DirectX → Vulkan fallback)
#   4. Stages GPTK from CrossOver Preview (D3D12 → D3DMetal → Metal — ACTIVE with CX Wine)
#   5. Stages lib64 dylibs from CrossOver Preview (MoltenVK, GStreamer, etc.)
#   6. Builds a pre-initialized prefix template via wineboot --init
#   7. Validates binaries, NLS data, syswow64, and prefix template
#   8. Creates a .tar.gz archive and uploads to aftrnd/meridian
#
# Wine source: CrossOver Preview (CX Wine 11.4 with full CodeWeavers patches)
#   WHY CX Wine (not Gcenx wine-devel):
#   1. TLS: secur32.so uses GnuTLS exclusively for Schannel/TLS (NOT Security.framework).
#      lib64 MUST be on DYLD_FALLBACK_LIBRARY_PATH at runtime so secur32.so can dlopen
#      libgnutls.30.dylib. libgnutls also needs @loader_path rpath (added below) so its
#      @rpath/libgmp.10.dylib dependency resolves. crypt32.so uses Security.framework
#      for certificate ops — its GnuTLS dlopen is only for PFX import/export.
#   2. GPTK: CX Wine has ntdll.__wine_unix_call which CX's d3d12.dll requires.
#      Gcenx Wine lacks this function — GPTK is permanently disabled with Gcenx.
#      CX Wine enables full D3D12 → D3DMetal → Metal support automatically.
#   3. Steam compat: CX Wine has CodeWeavers patches for Steam IPC, DXMT Metal APIs,
#      and Rosetta 2. Both binaries have the same patches, but only CX enables GPTK.
#
#   NOTE: Steam's own 32-bit bootstrapper statically links OpenSSL which fails TLS
#   under WoW64 on macOS 26. Meridian bypasses it with native macOS bootstrap
#   (SteamClientBootstrap.swift using URLSession). Wine's TLS (via GnuTLS) is
#   still needed for SteamCMD, WinHTTP, and other Wine HTTPS operations.
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

# ---------- stage Wine from CrossOver Preview ----------

yellow "Staging engine from CrossOver Preview..."
rm -rf "${STAGING}"
mkdir -p "${STAGING}/wine/bin" "${STAGING}/wine/lib" "${STAGING}/wine/share"

# Wine binaries — CX wineloader is the unified loader (wine64 role)
cp "${CX_ROOT}/CrossOver-Hosted Application/wineloader" "${STAGING}/wine/bin/wine64"
cp "${CX_ROOT}/CrossOver-Hosted Application/wineserver" "${STAGING}/wine/bin/wineserver"
chmod +x "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wineserver"
# wine alias (WineEngine.detect() checks for bin/wine as well)
cp "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wine"
chmod +x "${STAGING}/wine/bin/wine"
info "Wine binaries: wine64 + wineserver (${WINE_VERSION})"

# Wine DLLs (PE + Unix) — from CX lib/wine/
cp -R "${CX_ROOT}/lib/wine" "${STAGING}/wine/lib/wine"
WIN64_COUNT=$(find "${STAGING}/wine/lib/wine/x86_64-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
UNIX_COUNT=$(find "${STAGING}/wine/lib/wine/x86_64-unix" -name "*.so" 2>/dev/null | wc -l | tr -d ' ')
WIN32_COUNT=$(find "${STAGING}/wine/lib/wine/i386-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
info "Wine DLLs: ${WIN64_COUNT} x86_64-windows, ${UNIX_COUNT} x86_64-unix, ${WIN32_COUNT} i386-windows"

# Wine data files (NLS, fonts, wine.inf) — from CX share/wine/
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

# ---------- DXMT — stored in lib/dxmt/ (separate from Wine builtins) ----------
#
# CX Preview keeps DXMT in lib/dxmt/ completely separate from lib/wine/.
# Wine's original dxgi.dll (214KB) and d3d11.dll (416KB) remain in lib/wine/
# untouched. This preserves the ability to load GPTK's dxgi for D3D12 games:
#
#   DX11 games:  WINEDLLPATH = lib/dxmt:lib/wine  → DXMT loaded first ✓
#   D3D12 games: WINEDLLPATH = gptk/wine:lib/wine → GPTK loaded first ✓
#
# If DXMT were merged into lib/wine/ (old approach), GPTK could never take
# priority for dxgi — any =b override would still find DXMT's 1.7MB dxgi
# before GPTK's 92KB version, causing IDXGIAdapter4 NULL deref in D3D12 games.
yellow "Staging DXMT (from CX Preview → lib/dxmt/)..."
python3 -c "
import os
cx_dxmt = '${CX_ROOT}/lib/dxmt'
staging = '${STAGING}/wine/lib/dxmt'
count = 0
for arch in ['x86_64-unix', 'x86_64-windows', 'i386-windows']:
    src_dir = os.path.join(cx_dxmt, arch)
    dst_dir = os.path.join(staging, arch)
    if not os.path.isdir(src_dir): continue
    os.makedirs(dst_dir, exist_ok=True)
    for f in os.listdir(src_dir):
        if f.endswith('.so') or f.endswith('.dll'):
            with open(os.path.join(src_dir, f), 'rb') as fh: data = fh.read()
            with open(os.path.join(dst_dir, f), 'wb') as fh: fh.write(data)
            os.chmod(os.path.join(dst_dir, f), 0o755)
            count += 1
print(f'  DXMT: {count} files staged in lib/dxmt/ (separate from Wine builtins)')
" || die "DXMT staging failed"

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
# CX's d3d12.dll (from gptk/wine/) imports ntdll.__wine_unix_call (present in CX Wine).
# WineEngine.detect() checks ntdll.so for __wine_unix_call and sets gptkPath when found.
# With CX Wine: gptkPath is set → GPTK env vars injected for game launches → D3D12 works.
# d3d12.so (in gptk/wine/x86_64-unix/) is a symlink to libd3dshared.dylib.
yellow "Staging Apple GPTK (D3D12 → D3DMetal → Metal, ACTIVE with CX Wine)..."
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
    info "GPTK: ${GPTK_SIZE} staged — ACTIVE with CX Wine (ntdll.__wine_unix_call present) ✓"
else
    yellow "Warning: apple_gptk not found in CX Preview — D3D12 will not work"
fi

# ---------- lib64 dylibs from CX Preview ----------
# Wine's .so modules have rpath @loader_path/../../../lib64 which resolves to
# wine/lib64/ at runtime. All supporting dylibs must be there.
# lib64 IS on DYLD_FALLBACK_LIBRARY_PATH at runtime (steamCMDEnvironment and environment(for:)
# both include it). secur32.so needs to dlopen libgnutls.30.dylib for Wine TLS.
# libgnutls also needs @loader_path rpath to find @rpath/libgmp.10.dylib (fixed below).
yellow "Staging lib64 dylibs (from CX Preview)..."
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

# Fix libgnutls rpath so its @rpath/libgmp.10.dylib dependency resolves.
# CX Preview's libgnutls.30.dylib has ZERO LC_RPATH entries. secur32.so dlopen's
# it (found via DYLD_FALLBACK_LIBRARY_PATH), but libgnutls then needs libgmp.10.dylib
# via @rpath — which fails without an rpath pointing to its own directory.
yellow "Fixing libgnutls.30.dylib rpath for TLS support..."
GNUTLS_LIB64="${STAGING}/wine/lib64/libgnutls.30.dylib"
if [ -f "${GNUTLS_LIB64}" ]; then
    install_name_tool -add_rpath @loader_path "${GNUTLS_LIB64}" 2>/dev/null || true
    otool -l "${GNUTLS_LIB64}" | grep -q "LC_RPATH" \
        || die "libgnutls.30.dylib missing LC_RPATH after install_name_tool — TLS will be broken"
    info "  libgnutls.30.dylib: added @loader_path rpath ✓"
else
    yellow "  Warning: libgnutls.30.dylib not found in lib64 — Wine TLS will not work"
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
# Run wineboot --init in background with a 180s timeout.
# lib64 is included in DYLD here (build-time only) so wineserver can find MoltenVK/GStreamer.
# lib64 included in DYLD — same as app runtime. Needed for GnuTLS (secur32.so TLS).
#
# KNOWN LIMITATION (CLI-confirmed April 25 2026): on macOS hosts,
# `rundll32 setupapi InstallHinfSection DefaultInstall 128 wine.inf` (the
# step that registers Wine services from wine.inf) hits a runaway recursion
# in ntdll.so and never returns within 180s. `sample` showed 568 frames
# stacked at the same address. The 180 s timeout below kills it; the
# resulting `system.reg` ships with only 2 services (MountMgr,
# Tcpip\Parameters) instead of the 12+ a Linux-host wineboot would
# register — RpcSs, EventLog, PlugPlay, nsiproxy etc. are all absent.
#
# WHY THE TARBALL IS STILL SAFE: the runtime self-heal
# `WinePrefix.ensureCoreServices(engine:)` (called from BootstrapManager
# before Steam install) registers nsiproxy + RpcSs + EventLog + PlugPlay
# via `wine64 reg add` on every fresh prefix. That is the only set Steam
# actually depends on for Pattern-7-free startup. Do NOT add an
# app-level fallback that registers more services without first
# confirming a real-world need — `wine.inf`'s full set is documented
# in engine-research-findings.mdc.
#
# Future option: replace this block with a Linux Docker stage that
# runs wineboot natively, exports `system.reg`, and copies it into the
# tarball — eliminates the recursion entirely and yields a fully
# pre-initialised prefix. Tracked but not blocking.
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

# ---------- bundled steam.exe stub ----------
#
# Valve's `cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe` has
# been serving an outdated stub (CLI-verified April 22, 2026: Jan 29 build,
# 4.72 MB, MD5 b97ff5ac…) whose application manifest hard-reports Windows
# 6.2.9200.0. Steam's server-side deprecation check rejects Windows 8
# clients with "Steam is no longer supported on your operating system" and
# exits immediately — before its own self-update can run.
#
# CX Preview ships a newer stub (Mar 12 build, 5.77 MB, MD5 4f2ad574…)
# whose manifest reports Windows 10.0.19045.0 and runs cleanly. We include
# that stub in the engine tarball; `WinePrefix.refreshSteamStubFromEngineIfStale`
# overwrites the freshly-SteamSetup'd stub in the user's prefix with this
# bundled copy on every bootstrap.
#
# This is the same "harvest from CX at build time, ship to end users in the
# engine tarball" pattern we use for Wine, DXMT, DXVK, and GPTK. End users
# never need CrossOver installed (update-system.mdc line 102).

yellow "Staging bundled steam.exe stub (from CX Preview Steam bottle)..."
CX_STEAM_STUB="${HOME}/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe"
STUB_DEST_DIR="${STAGING}/wine/share/meridian"
STUB_DEST="${STUB_DEST_DIR}/steam.exe.stub"

if [ -f "${CX_STEAM_STUB}" ]; then
    mkdir -p "${STUB_DEST_DIR}"
    cp "${CX_STEAM_STUB}" "${STUB_DEST}"
    STUB_SIZE=$(stat -f%z "${STUB_DEST}" 2>/dev/null || stat -c%s "${STUB_DEST}")
    STUB_MD5=$(md5 -q "${STUB_DEST}" 2>/dev/null || md5sum "${STUB_DEST}" | cut -d' ' -f1)
    info "Bundled steam.exe stub: ${STUB_SIZE} bytes, MD5=${STUB_MD5}"

    # Sanity check: the stub must be a PE32 executable, must be > 4 MB
    # (old Jan stub is 4.7 MB; anything smaller is suspicious), and must
    # include Steam's build metadata. Minimum-viable regression guard.
    [ "${STUB_SIZE}" -gt 4000000 ] || die "steam.exe stub is suspiciously small (${STUB_SIZE} bytes)"
    file "${STUB_DEST}" | grep -q "PE32" || die "bundled steam.exe is not a PE32 executable"
else
    yellow "Warning: CX Preview Steam bottle not found at ${CX_STEAM_STUB}"
    yellow "  → engine tarball will NOT include a fresh stub"
    yellow "  → end users will fall back to the SteamSetup.exe-installed stub"
    yellow "  → THIS MEANS users may hit 'Steam is no longer supported' if the stub is stale"
    yellow "  → install Steam in CrossOver Preview first, then re-run this script"
fi

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

# ---------- meridian-dpapi.exe (Wine CryptProtectData wrapper) ----------
# Used by WinePrefix.writeSteamSessionLocalVdf to encrypt Steam's JWT refresh
# token into the bottle's local.vdf (AppData/Local/Steam). Steam's own
# CryptUnprotectData at sign-in time decrypts it. Reproduces what the
# Windows Steam client writes itself, byte-for-byte format-compatible.
# See Scripts/dpapi/meridian_dpapi.c + build-dpapi.sh.

yellow "Building meridian-dpapi.exe (Wine DPAPI wrapper for Steam local.vdf)..."
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    DPAPI_DEST_DIR="${STAGING}/wine/share/meridian"
    mkdir -p "${DPAPI_DEST_DIR}"
    DPAPI_OUT="${DPAPI_DEST_DIR}/meridian-dpapi.exe"
    bash "$(dirname "${BASH_SOURCE[0]}")/build-dpapi.sh" "${DPAPI_OUT}" \
        || die "meridian-dpapi.exe build failed"
    info "meridian-dpapi.exe: $(stat -f%z "${DPAPI_OUT}") bytes ✓"
else
    die "x86_64-w64-mingw32-gcc not found — cannot build meridian-dpapi.exe (required)"
fi

# ---------- meridian-wine-accessory.dylib (DYLD_INSERT payload) ----------
# Demotes every Wine subprocess Meridian launches for Steam to
# NSApplicationActivationPolicyAccessory — no Dock tile, no self-activation
# for download-complete toasts. Injected via DYLD_INSERT_LIBRARIES from
# WineEngine.steamCMDEnvironment. See Scripts/wine-accessory/
# meridian_wine_accessory.m for the full rationale.
yellow "Building meridian-wine-accessory.dylib (Dock-suppression DYLD_INSERT payload)..."
if command -v clang >/dev/null 2>&1; then
    ACCESSORY_DEST_DIR="${STAGING}/wine/share/meridian"
    mkdir -p "${ACCESSORY_DEST_DIR}"
    ACCESSORY_OUT="${ACCESSORY_DEST_DIR}/meridian-wine-accessory.dylib"
    bash "$(dirname "${BASH_SOURCE[0]}")/build-wine-accessory.sh" "${ACCESSORY_OUT}" \
        || die "meridian-wine-accessory.dylib build failed"
    info "meridian-wine-accessory.dylib: $(stat -f%z "${ACCESSORY_OUT}") bytes ✓"
else
    die "clang not found — cannot build meridian-wine-accessory.dylib (required)"
fi

# ---------- DepotDownloader fork (headless game installer) ----------
# Native macOS (arm64) binary that installs owned games via Meridian's OAuth
# refresh_token — no steam.exe. Patched fork of SteamRE/DepotDownloader (GPL-2.0,
# shipped as a separate executable, not linked). See Scripts/build-depotdownloader.sh
# + Scripts/depotdownloader/. Resolved at runtime by WineEngine.depotDownloaderURL.
# The engine-wide `xattr -rd com.apple.quarantine` on download covers it
# (Pattern 5 — quarantined binaries lose network access on macOS 26).
yellow "Building DepotDownloader fork (headless installer)..."
if command -v dotnet >/dev/null 2>&1; then
    DD_DEST_DIR="${STAGING}/tools/depotdownloader"
    mkdir -p "${DD_DEST_DIR}"
    DD_OUT="${DD_DEST_DIR}/DepotDownloader"
    bash "$(dirname "${BASH_SOURCE[0]}")/build-depotdownloader.sh" "${DD_OUT}" \
        || die "DepotDownloader fork build failed"
    info "DepotDownloader: $(stat -f%z "${DD_OUT}") bytes ✓"
else
    die "dotnet not found — cannot build DepotDownloader fork (run 'brew install dotnet')"
fi

# ---------- Steamworks API emulator (gbe_fork) — DRM games without steam.exe ----------
# DRM games (those shipping steam_api64.dll) have their Valve dll replaced with
# the open-source gbe_fork emulator at launch so SteamAPI_Init() succeeds
# locally — no running steam.exe, no auth, no "Who's playing" window. Prebuilt
# Windows PE DLLs (Wine loads them as the game's import). See
# Scripts/build-steamemu.sh. Resolved at runtime by WineEngine.steamApi64EmuURL.
# The engine-wide quarantine strip covers these too (Pattern 5).
yellow "Staging Steamworks API emulator (gbe_fork)..."
SE_DEST_DIR="${STAGING}/tools/steamemu"
bash "$(dirname "${BASH_SOURCE[0]}")/build-steamemu.sh" "${SE_DEST_DIR}" \
    || die "Steamworks emulator staging failed"
info "steamemu: $(stat -f%z "${SE_DEST_DIR}/steam_api64.dll") bytes ✓"

# ---------- re-sign wine64 with allow-dyld entitlement ----------
# CrossOver's stock wine64 has hardened-runtime + library-validation-disabled
# but lacks `com.apple.security.cs.allow-dyld-environment-variables`, which
# macOS requires before it will honour `DYLD_INSERT_LIBRARIES` on a
# hardened-runtime binary. Without this entitlement dyld silently strips the
# var at launch and our accessory dylib never loads.
#
# Ad-hoc re-signing preserves all existing wine64 functionality — Meridian
# launches wine64 as a subprocess of its own Developer-ID-signed app bundle,
# so macOS Gatekeeper does not consult wine64's signature. We lose CW's
# Developer ID signature but gain `allow-dyld-environment-variables`.
yellow "Re-signing wine64 with allow-dyld-environment-variables entitlement..."
WINE64_BIN="${STAGING}/wine/bin/wine64"
ENTITLEMENTS_PLIST="${STAGING}/wine64-entitlements.plist"
cat > "${ENTITLEMENTS_PLIST}" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-executable-page-protection</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
</dict>
</plist>
PLIST_EOF
codesign --force --sign - \
    --entitlements "${ENTITLEMENTS_PLIST}" \
    --preserve-metadata=flags,runtime \
    "${WINE64_BIN}" \
    || die "wine64 re-sign failed"
rm -f "${ENTITLEMENTS_PLIST}"
info "wine64 re-signed ad-hoc with allow-dyld entitlement ✓"

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

[ -f "${STAGING}/wine/lib/dxmt/x86_64-unix/winemetal.so" ]  || die "DXMT winemetal.so missing from lib/dxmt/"
[ -f "${STAGING}/wine/lib/dxmt/x86_64-windows/d3d11.dll" ]  || die "DXMT d3d11.dll missing from lib/dxmt/"
info "DXMT DLLs verified in lib/dxmt/ (separate from Wine builtins) ✓"

if [ -f "${STAGING}/wine/lib/gptk/external/D3DMetal.framework/D3DMetal" ]; then
    [ -f "${STAGING}/wine/lib/gptk/wine/x86_64-windows/d3d12.dll" ] || die "GPTK d3d12.dll missing from gptk/wine/"
    info "GPTK D3D12 active (CX Wine has __wine_unix_call — D3D12 → D3DMetal → Metal) ✓"
else
    yellow "Warning: GPTK not bundled — D3D12 games will not work"
fi

# Critical: verify libgnutls was NOT accidentally staged in wine/lib/.
# libgnutls must be in lib64/ (not lib/). secur32.so's dlopen("libgnutls.30.dylib")
# searches DYLD in order — lib64 is appended last. If libgnutls were in lib/ it
# would load before lib64/libgmp.10.dylib is findable via @rpath.
GNUTLS_LIB=$(find "${STAGING}/wine/lib" -maxdepth 1 -name 'libgnutls*' 2>/dev/null | head -1)
[ -z "${GNUTLS_LIB}" ] || die "libgnutls found in wine/lib/ — must be in lib64/ only: ${GNUTLS_LIB}"
info "libgnutls correctly in lib64/ only ✓"

# Verify Wine ABI: check whether ntdll.dll (the Windows PE DLL) contains __wine_unix_call
# as a null-terminated export name string. This is what WineEngine.detect() does in Swift —
# it searches the PE binary for "__wine_unix_call\0" (with trailing null) to distinguish
# CX Wine (has __wine_unix_call) from Gcenx Wine (only has __wine_unix_call_dispatcher).
#
# IMPORTANT: Search ntdll.dll (PE), NOT ntdll.so (Unix .so).
# The export name lives in the Windows PE export table as a C string.
# ntdll.so only contains __wine_unix_call_dispatcher and __wine_unix_call_funcs —
# the standalone __wine_unix_call\0 string is NOT present in ntdll.so.
# CLI-verified April 2026: ntdll.dll at byte offset 673776. ntdll.so has no match.
NTDLL_DLL="${STAGING}/wine/lib/wine/x86_64-windows/ntdll.dll"
[ -f "${NTDLL_DLL}" ] || die "ntdll.dll (PE) missing"
if strings "${NTDLL_DLL}" 2>/dev/null | grep -qE "^__wine_unix_call$"; then
    info "CX Wine ABI: ntdll.dll PE exports __wine_unix_call — GPTK is ACTIVE ✓"
else
    yellow "WARNING: __wine_unix_call NOT found in ntdll.dll PE exports — GPTK will be DISABLED (expected with Gcenx Wine)"
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

**Wine:** ${STAGED_VERSION} (CrossOver Preview CX Wine — Security.framework TLS, GPTK active)
**DXMT:** CrossOver Preview builtin — DirectX 11/10 → Metal
**DXVK:** CrossOver Preview — DirectX → Vulkan fallback
**GPTK:** Apple Game Porting Toolkit ACTIVE (CX Wine has ntdll.__wine_unix_call)
**MoltenVK:** CX lib64/libMoltenVK.dylib
**Architecture:** arm64 / x86_64 (Rosetta 2)
**Archive size:** ${ARCHIVE_SIZE}
**Files:** ${FILE_COUNT}

**Engine layout:**
- \`wine/bin/wine64\` — Wine loader (CX Wine ${WINE_VERSION})
- \`wine/bin/wineserver\` — Wine server
- \`wine/lib/wine/\` — Wine DLLs (original builtins — dxgi 214KB, d3d11 416KB)
- \`wine/lib/dxmt/\` — DXMT DLLs (DirectX 11 → Metal; separate from Wine builtins)
- \`wine/lib/gptk/\` — Apple GPTK (ACTIVE — D3D12 → D3DMetal → Metal)
- \`wine/lib/dxvk/\` — DXVK DirectX → Vulkan DLLs (fallback)
- \`wine/lib64/\` — CX lib64 dylibs (MoltenVK, GnuTLS, GStreamer)
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
