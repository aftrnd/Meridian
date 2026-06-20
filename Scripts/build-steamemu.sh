#!/usr/bin/env bash
#
# build-steamemu.sh — stage the open-source Steamworks API emulator (gbe_fork)
# into Meridian's engine.
#
# Meridian runs DRM games (those shipping `steam_api64.dll`) WITHOUT a running
# `steam.exe`. Instead of relying on Wine's flaky steam.exe silent auto-login
# (which loads local.vdf but never authenticates — the Phase 6/7 wall), it
# replaces the game's Valve `steam_api(64).dll` with gbe_fork — an open-source
# (GPL/LGPL) Steamworks API re-implementation. `SteamAPI_Init()` then succeeds
# locally using the user's steamID + the appID, with no Steam client, no auth,
# and no "Who's playing" window. The user's ownership is already proven: the
# game was downloaded via DepotDownloader with the user's own OAuth token.
#
# Upstream: https://github.com/Detanup01/gbe_fork  (the maintained Goldberg
# successor). We stage the prebuilt **regular** Windows release DLLs (the emu
# is a Windows PE that Wine loads as the game's import — no Steam client).
#
# Output (default = live engine):
#   engine/tools/steamemu/
#     steam_api64.dll              (regular/x64)
#     steam_api.dll                (regular/x86)
#     generate_interfaces_x64.exe  (tools/generate_interfaces)
#     generate_interfaces_x86.exe
#     VERSION.txt                  (the upstream release tag)
# Pass an explicit output dir as $1 to override (release-engine.sh stages it
# into the engine tarball this way).
#
# Requires: curl, bsdtar (ships with macOS — libarchive reads .7z).

set -euo pipefail

# Pinned release for deterministic, reproducible staging. Bump intentionally.
GBE_TAG="release-2026_05_30"
ASSET="emu-win-release.7z"
ASSET_URL="https://github.com/Detanup01/gbe_fork/releases/download/${GBE_TAG}/${ASSET}"

DEFAULT_OUT="${HOME}/Library/Application Support/com.meridian.app/engine/tools/steamemu"
OUT="${1:-${DEFAULT_OUT}}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

command -v curl >/dev/null 2>&1 || die "curl not found"
command -v bsdtar >/dev/null 2>&1 || command -v tar >/dev/null 2>&1 || die "bsdtar/tar not found"
EXTRACT="$(command -v bsdtar || command -v tar)"

WORK="$(mktemp -d /tmp/meridian-steamemu.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

echo "Staging gbe_fork Steamworks emulator (${GBE_TAG})..."

info "download ${ASSET}"
curl -fsSL -o "${WORK}/${ASSET}" "${ASSET_URL}" || die "download failed: ${ASSET_URL}"

info "extract"
mkdir -p "${WORK}/x"
"${EXTRACT}" -xf "${WORK}/${ASSET}" -C "${WORK}/x" || die "extract failed (need a libarchive tar that reads .7z)"

REL="${WORK}/x/release"
[ -f "${REL}/regular/x64/steam_api64.dll" ] || die "regular/x64/steam_api64.dll missing — upstream layout changed"
[ -f "${REL}/regular/x86/steam_api.dll" ]   || die "regular/x86/steam_api.dll missing — upstream layout changed"

mkdir -p "${OUT}"
cp "${REL}/regular/x64/steam_api64.dll"                       "${OUT}/steam_api64.dll"
cp "${REL}/regular/x86/steam_api.dll"                         "${OUT}/steam_api.dll"
cp "${REL}/tools/generate_interfaces/generate_interfaces_x64.exe" "${OUT}/generate_interfaces_x64.exe"
cp "${REL}/tools/generate_interfaces/generate_interfaces_x86.exe" "${OUT}/generate_interfaces_x86.exe"
printf "%s\n" "${GBE_TAG}" > "${OUT}/VERSION.txt"

# Strip quarantine — macOS 26 blocks network/exec for quarantined files
# (engine-research-findings.mdc Pattern 5). The DLLs run inside Wine; the
# generate_interfaces exes run under Wine. Belt-and-suspenders.
xattr -rd com.apple.quarantine "${OUT}" 2>/dev/null || true

echo "✓ Steamworks emulator → ${OUT}"
echo "    steam_api64.dll       $(stat -f%z "${OUT}/steam_api64.dll") bytes"
echo "    steam_api.dll         $(stat -f%z "${OUT}/steam_api.dll") bytes"
echo "    generate_interfaces   x64 + x86"
echo "    version               ${GBE_TAG}"
