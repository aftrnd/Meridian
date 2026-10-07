#!/usr/bin/env bash
#
# publish-engine.sh — build, smoke-test and publish a Meridian engine release.
#
# Usage: bash Scripts/engine/publish-engine.sh vX.Y.Z-engine [--no-upload]
#
# Runs the whole from-source pipeline, then creates the GitHub release that
# EngineDownloader installs from. --no-upload stops after the smoke test and
# leaves the tarball at $BUILD_ROOT/meridian-engine-arm64.tar.gz.
#
#   1. build-deps.sh      x86_64 libraries (stamped; finished packages skip)
#   2. build-wine.sh      Wine from CodeWeavers' published source
#   3. package-engine.sh  stage, relink, sign, prefix template, tarball
#   4. smoke/smoke-test.sh  DXMT + wined3d (32/64-bit) and HTTPS, headless
#   5. gh release create  vX.Y.Z-engine with the tarball attached
#
# Prerequisites: Xcode command line tools, and
#   brew install meson ninja cmake bison flex autoconf automake libtool mingw-w64 coreutils gh

source "$(dirname "$0")/env.sh"

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-engine$ ]] || die "usage: publish-engine.sh vX.Y.Z-engine [--no-upload]"
UPLOAD=1; [ "${2:-}" = "--no-upload" ] && UPLOAD=0
REPO="aftrnd/meridian"
HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$BUILD_ROOT/meridian-engine-arm64.tar.gz"

if [ "$UPLOAD" -eq 1 ]; then
    command -v gh >/dev/null || die "brew install gh && gh auth login"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated: gh auth login"
    ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || die "$TAG already exists — engine tags are permanent"
fi

bash "$HERE/build-deps.sh"
[ -x "$WORK/wine-install/bin/wine" ] || bash "$HERE/build-wine.sh"
bash "$HERE/package-engine.sh" "$TAG"
bash "$HERE/smoke/smoke-test.sh"

[ "$UPLOAD" -eq 1 ] || { say "Built and smoke-tested $ARCHIVE (not uploaded)"; exit 0; }

say "Publishing $TAG to $REPO"
gh release create "$TAG" --repo "$REPO" --title "Engine $TAG" "$ARCHIVE" --notes "$(cat <<EOF
Meridian engine, built from source by Scripts/engine/ (no CrossOver install involved).

- Wine $(cat "$SRC/wine/VERSION" | sed 's/Wine version //') from CodeWeavers' published CrossOver ${CX_SOURCE_VERSION} source (LGPL-2.1)
- DXMT $(sed 's/DXMT //' "$STAGE/wine/meridian-dxmt-version.txt") (D3D10/11 → Metal), selected per launch via WINEDLLPATH
- MoltenVK 1.4.2, GnuTLS, GStreamer (VideoToolbox decode)
- x86_64 under Rosetta 2, WoW64 for 32-bit games

Not included: Apple D3DMetal, CodeWeavers' cxcompatdb.so, the gbe_fork Steamworks emulator, Valve binaries.
License texts are in licenses/ inside the archive.
EOF
)"
say "Published $TAG"
