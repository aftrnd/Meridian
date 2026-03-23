#!/usr/bin/env bash
#
# release-engine.sh — Package and upload the Wine engine runtime.
#
# Usage:
#   bash Scripts/release-engine.sh [VERSION]
#
# Examples:
#   bash Scripts/release-engine.sh              # auto-increments patch (v1.0.1-engine)
#   bash Scripts/release-engine.sh v2.0.0       # explicit version
#
# Prerequisites:
#   - gh CLI authenticated:   brew install gh && gh auth login
#   - Wine source (preferred — open source, freely redistributable):
#       brew tap gcenx/wine && brew install --cask wine-crossover
#
# What it does:
#   1. Auto-detects Wine source (Gcenx open-source cask preferred; CrossOver local fallback)
#   2. Stages wine/bin + wine/lib (open-source components only)
#   3. Embeds wine/meridian-engine-version.txt (read by Settings → Updates)
#   4. Verifies wine64 and wineserver are present
#   5. Creates a .tar.gz archive
#   6. Uploads it as a GitHub release to aftrnd/meridian tagged vX.Y.Z-engine
#
# REDISTRIBUTION NOTICE
# ---------------------
# Public engine releases MUST be built from the Gcenx wine-crossover cask (or from
# Wine source). This cask is compiled from CodeWeavers' open-source Wine fork and is
# freely redistributable under the LGPL.
#
# CrossOver.app is a paid commercial product. Its binaries may NOT be repackaged and
# redistributed publicly even though the underlying Wine code is LGPL — doing so would
# violate CodeWeavers' End User License Agreement. CrossOver is only supported here as
# a local fallback for internal/development builds. NEVER publish a release built from
# CrossOver sources to the public GitHub releases page.
#
set -euo pipefail

REPO="aftrnd/meridian"

# Wine source paths.
# Gcenx wine-crossover cask (open-source, LGPL — preferred for public releases):
#   brew tap gcenx/wine && brew install --cask wine-crossover
GCENX_APP="/Applications/Wine Crossover.app"
GCENX_RESOURCES="${GCENX_APP}/Contents/Resources"

# CrossOver.app (commercial — local development fallback ONLY, NOT for public releases):
CX_APP="/Applications/CrossOver.app"
CX_ROOT="${CX_APP}/Contents/SharedSupport/CrossOver"

STAGING="/tmp/meridian-engine"
ARCHIVE="/tmp/meridian-engine-arm64.tar.gz"

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

command -v gh >/dev/null 2>&1 || die "gh CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run: gh auth login"

# Detect Wine source.
# Gcenx open-source cask is always preferred for public releases. CrossOver is only
# accepted as a local fallback and triggers a prominent redistribution warning.
if [ -d "${GCENX_APP}" ] && [ -f "${GCENX_RESOURCES}/wine/bin/wine64" ]; then
    WINE_SOURCE="gcenx"
    WINE_SOURCE_VERSION="Wine Crossover (Gcenx open-source cask)"
elif [ -d "${CX_APP}" ] && [ -f "${CX_ROOT}/CrossOver-Hosted Application/wineloader" ]; then
    WINE_SOURCE="crossover"
    WINE_SOURCE_VERSION="CrossOver $(defaults read "${CX_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
    echo ""
    red  "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    red  "  WARNING: CrossOver selected as Wine source"
    red  "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    yellow "  CrossOver is a commercial product. Its binaries MUST NOT"
    yellow "  be redistributed publicly. This build is for LOCAL / DEV"
    yellow "  use only. Do NOT publish it to GitHub Releases."
    red  "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    yellow "  To build a redistributable release, install the Gcenx cask:"
    yellow "    brew tap gcenx/wine && brew install --cask wine-crossover"
    echo ""
    read -rp "  Continue for LOCAL use only? [y/N] " CX_CONFIRM
    [[ "${CX_CONFIRM}" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
else
    die "No Wine installation found.
  Install the Gcenx open-source cask (required for public releases):
    brew tap gcenx/wine && brew install --cask wine-crossover"
fi
yellow "Wine source: ${WINE_SOURCE_VERSION} (${WINE_SOURCE})"

# ---------- version ----------

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

# Ensure tag has -engine suffix
[[ "${VERSION}" == *-engine ]] || VERSION="${VERSION}-engine"
TAG="${VERSION}"

info "Version:  ${VERSION}"
info "Tag:      ${TAG}"
info "Repo:     ${REPO}"
echo ""

# ---------- detect Wine version ----------

if [ "${WINE_SOURCE}" = "crossover" ]; then
    WINE_BIN="${CX_ROOT}/CrossOver-Hosted Application/wineloader"
else
    WINE_BIN="${GCENX_RESOURCES}/wine/bin/wine64"
fi
WINE_VERSION=$("${WINE_BIN}" --version 2>/dev/null || echo "unknown")
info "Wine version: ${WINE_VERSION}"

# ---------- stage ----------

yellow "Staging engine from ${WINE_SOURCE_VERSION}..."
rm -rf "${STAGING}" "${ARCHIVE}"
mkdir -p "${STAGING}/wine/bin" "${STAGING}/wine/lib"

if [ "${WINE_SOURCE}" = "crossover" ]; then
    # CrossOver layout:
    #   CrossOver-Hosted Application/wineloader  → wine/bin/wine64
    #   CrossOver-Hosted Application/wineserver  → wine/bin/wineserver
    #   lib/{wine,dxmt,dxvk}/                   → wine/lib/
    # CrossOver-specific cx* tools are intentionally excluded.
    CX_BINDIR="${CX_ROOT}/CrossOver-Hosted Application"
    cp "${CX_BINDIR}/wineloader"  "${STAGING}/wine/bin/wine64"
    cp "${CX_BINDIR}/wineserver"  "${STAGING}/wine/bin/wineserver"
    chmod +x "${STAGING}/wine/bin/wine64" "${STAGING}/wine/bin/wineserver"
    # Copy other wine* helpers (wineboot, winecfg, etc.) if present.
    for f in "${CX_BINDIR}"/wine*; do
        fname="$(basename "${f}")"
        [ "${fname}" = "wineloader" ] && continue  # already copied as wine64
        [ -f "${f}" ] && cp "${f}" "${STAGING}/wine/bin/${fname}"
    done
    # Copy open-source lib components (wine DLLs, DXMT, DXVK). Skip cx* proprietary dirs.
    for libdir in wine dxmt dxvk; do
        [ -d "${CX_ROOT}/lib/${libdir}" ] && cp -R "${CX_ROOT}/lib/${libdir}" "${STAGING}/wine/lib/"
    done
else
    # Gcenx layout: standard Wine tree at Contents/Resources/wine/
    cp -R "${GCENX_RESOURCES}/wine/"* "${STAGING}/wine/"
fi

# Embed the release tag so the app can display it in Settings → Updates.
echo "${TAG}" > "${STAGING}/wine/meridian-engine-version.txt"
info "Embedded engine version: ${TAG}"

# Verify critical binaries.
[ -x "${STAGING}/wine/bin/wine64" ]     || die "wine64 not executable in staging"
[ -x "${STAGING}/wine/bin/wineserver" ] || die "wineserver not executable in staging"

FILE_COUNT=$(find "${STAGING}" -type f | wc -l | tr -d ' ')
STAGING_SIZE=$(du -sh "${STAGING}" | cut -f1)
info "Staged ${FILE_COUNT} files (${STAGING_SIZE})"

# ---------- archive ----------

yellow "Creating archive..."
cd /tmp && tar czf "${ARCHIVE}" -C "${STAGING}" .
ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
info "Archive: ${ARCHIVE} (${ARCHIVE_SIZE})"

# Verify tarball contents
TARBALL_CHECK=$(tar tzf "${ARCHIVE}" | grep -c "wine/bin/wine64" || true)
[ "${TARBALL_CHECK}" -ge 1 ] || die "Tarball does not contain wine/bin/wine64"

# ---------- upload ----------

yellow "Uploading release ${TAG} to ${REPO}..."

NOTES="Wine engine runtime for Meridian.

**Wine version:** ${WINE_VERSION}
**Source:** ${WINE_SOURCE_VERSION}
**Architecture:** arm64 (Apple Silicon)
**Archive size:** ${ARCHIVE_SIZE}
**Files:** ${FILE_COUNT}

**Contents:**
- \`wine/bin/wine64\` — Wine 64-bit loader
- \`wine/bin/wineserver\` — Wine server process
- \`wine/lib/wine/\` — Wine DLLs
- \`wine/lib/dxmt/\` — DirectX → Metal translation
- \`wine/lib/dxvk/\` — DirectX → Vulkan (MoltenVK)
- \`wine/meridian-engine-version.txt\` — version tag (read by Settings → Updates)

**Install target:**
\`~/Library/Application Support/com.meridian.app/engine/\`

**License:** Wine LGPL 2.1 · DXMT MIT · DXVK Zlib · MoltenVK Apache 2.0
**Source code:** https://github.com/Gcenx/wine (CodeWeavers open-source Wine fork)"

gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "Wine+GPTK Engine ${VERSION}" \
    --notes "${NOTES}" \
    "${ARCHIVE}"

# ---------- cleanup ----------

rm -rf "${STAGING}" "${ARCHIVE}"

echo ""
green "Release ${TAG} published:"
gh release view "${TAG}" --repo "${REPO}" --json url -q '.url'
echo ""
green "Done."
