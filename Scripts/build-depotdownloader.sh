#!/usr/bin/env bash
#
# build-depotdownloader.sh — build Meridian's patched DepotDownloader fork.
#
# Meridian installs owned games headlessly (no steam.exe) by driving a patched
# fork of SteamRE/DepotDownloader. The fork adds:
#   • -refreshtoken <jwt>  → token-only logon (consumes Meridian's OAuth token;
#                            interactive credential/QR/Steam-Guard auth removed)
#   • -json                → newline-delimited JSON progress on stdout
#   • SIGTERM/SIGINT        → deterministic exit 130 (resume-safe via
#                            .DepotDownloader/depot.config)
#
# Upstream: https://github.com/SteamRE/DepotDownloader @ b2b7e975 (v3.4.0, GPL-2.0)
# Patch:    Scripts/depotdownloader/meridian-task1.patch
#
# Output: a self-contained single-file osx-arm64 Mach-O binary. By default it is
# written into the live engine at:
#   ~/Library/Application Support/com.meridian.app/engine/tools/depotdownloader/DepotDownloader
# Pass an explicit output path as $1 to override (release-engine.sh stages it
# into the engine tarball this way).
#
# Requires: dotnet SDK 9+ (`brew install dotnet`), git.

set -euo pipefail

UPSTREAM_REPO="https://github.com/SteamRE/DepotDownloader.git"
UPSTREAM_COMMIT="b2b7e975adb8f09f0e2592484f06d28f6c8683ed"
RID="osx-arm64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/depotdownloader/meridian-task1.patch"

DEFAULT_OUT="${HOME}/Library/Application Support/com.meridian.app/engine/tools/depotdownloader/DepotDownloader"
OUT="${1:-${DEFAULT_OUT}}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

command -v dotnet >/dev/null 2>&1 || die "dotnet not found — run 'brew install dotnet' (SDK 9+)"
command -v git >/dev/null 2>&1 || die "git not found"
[ -f "${PATCH}" ] || die "patch not found at ${PATCH}"

WORK="$(mktemp -d /tmp/meridian-dd-build.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

echo "Building DepotDownloader fork (upstream ${UPSTREAM_COMMIT:0:12}, RID ${RID})..."
info "clone"
git clone --quiet "${UPSTREAM_REPO}" "${WORK}/src"
git -C "${WORK}/src" checkout --quiet "${UPSTREAM_COMMIT}"

info "apply Meridian patch"
git -C "${WORK}/src" apply "${PATCH}" || die "patch failed to apply (upstream may have moved — re-base the patch)"

# Upstream pins the SDK to 9.0.x via global.json with rollForward=latestMinor,
# so a machine that only has a newer major (e.g. 10.x) can't build it. This is a
# throwaway clone in /tmp, so relax the pin to latestMajor — the build works with
# any installed SDK >= 9 and the self-contained publish restores the correct
# net9.0 runtime pack regardless. (We never touch the repo's global.json.)
if [ -f "${WORK}/src/global.json" ]; then
    info "relax global.json SDK pin (rollForward=latestMajor) for this build"
    /usr/bin/python3 - "${WORK}/src/global.json" <<'PY' || true
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
    d.setdefault("sdk", {})["rollForward"] = "latestMajor"
    json.dump(d, open(p, "w"), indent=2)
except Exception as e:
    print("  (could not adjust global.json: %s)" % e)
PY
fi

info "dotnet publish (self-contained single-file)"
dotnet publish "${WORK}/src/DepotDownloader/DepotDownloader.csproj" \
    -c Release \
    -r "${RID}" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -o "${WORK}/publish" \
    >/dev/null || die "dotnet publish failed"

[ -f "${WORK}/publish/DepotDownloader" ] || die "publish produced no DepotDownloader binary"

mkdir -p "$(dirname "${OUT}")"
cp "${WORK}/publish/DepotDownloader" "${OUT}"
chmod +x "${OUT}"
# Strip quarantine — macOS 26 blocks network access for quarantined binaries
# (engine-research-findings.mdc Pattern 5). DepotDownloader needs network.
xattr -rd com.apple.quarantine "${OUT}" 2>/dev/null || true

echo "✓ DepotDownloader → ${OUT} ($(stat -f%z "${OUT}") bytes)"
"${OUT}" 2>&1 | head -1 || true
