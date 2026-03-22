#!/usr/bin/env bash
#
# release-app.sh — Build, sign, notarize, and publish a new Meridian release.
#
# Usage (run from the repository root):
#   bash Scripts/release-app.sh              # auto-increment patch (1.0.0 → 1.0.1)
#   bash Scripts/release-app.sh 1.2.0        # explicit version
#   bash Scripts/release-app.sh --minor      # bump minor  (1.0.0 → 1.1.0)
#   bash Scripts/release-app.sh --major      # bump major  (1.0.0 → 2.0.0)
#
# What it does:
#   1. Validates prerequisites and git state
#   2. Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION in the Xcode project
#   3. Archives and exports the app (Release config, macOS)
#   4. Creates a .dmg installer (drag-to-Applications layout)
#   5. Notarizes and staples with Apple (when Developer ID cert + keychain profile exist)
#   6. Publishes to GitHub Releases tagged vX.Y.Z
#   7. Commits the version bump and pushes the tag
#
# One-time prerequisites:
#   - gh CLI authenticated:   brew install gh && gh auth login
#   - Xcode installed:        xcode-select --install
#
# For notarized / Gatekeeper-trusted builds (strongly recommended for public releases):
#   1. Enroll in Apple Developer Program (developer.apple.com)
#   2. Create a "Developer ID Application" certificate in Xcode → Settings → Accounts
#   3. Store notarization credentials in Keychain (run once):
#        xcrun notarytool store-credentials "meridian-notarize" \
#          --apple-id YOUR@APPLE.ID \
#          --team-id V5448GT345 \
#          --password APP_SPECIFIC_PASSWORD   ← generate at appleid.apple.com
#
# Without a Developer ID cert, the script still produces a .dmg and GitHub release,
# but Gatekeeper will block it on other Macs (users must right-click → Open).
#
set -euo pipefail

# ---------- config ----------

REPO="aftrnd/meridian"
SCHEME="Meridian"
PROJECT="Meridian.xcodeproj"
TEAM_ID="V5448GT345"
BUNDLE_ID="com.meridian.app"
NOTARIZE_PROFILE="meridian-notarize"

BUILD_ROOT="/tmp/meridian-build"
ARCHIVE_PATH="${BUILD_ROOT}/Meridian.xcarchive"
EXPORT_DIR="${BUILD_ROOT}/export"
EXPORT_PLIST="${BUILD_ROOT}/ExportOptions.plist"
STAGING_DIR="${BUILD_ROOT}/dmg-staging"
DMG_UNSIGNED="${BUILD_ROOT}/Meridian-unsigned.dmg"
DMG_FINAL="${BUILD_ROOT}/Meridian.dmg"

# ---------- colours ----------

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
info()   { printf '    %s\n' "$*"; }
step()   { echo ""; yellow "▸ $*"; }
die()    { echo ""; red "  ERROR: $*" >&2; exit 1; }

# ---------- helpers ----------

xcode_build_setting() {
    xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -showBuildSettings 2>/dev/null \
        | grep -w "$1" | awk '{print $3}'
}

bump_semver() {
    local version="$1" mode="$2"
    version="${version#v}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "${version}.0.0.0"
    major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
    case "${mode}" in
        --major) echo "$((major + 1)).0.0" ;;
        --minor) echo "${major}.$((minor + 1)).0" ;;
        --patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *)       echo "${mode#v}" ;;
    esac
}

has_cert() {
    security find-identity -v -p codesigning 2>/dev/null | grep -q "$1"
}

has_notarize_profile() {
    # Try to list history — exits 0 only when the profile exists and creds are valid.
    xcrun notarytool history --keychain-profile "${NOTARIZE_PROFILE}" &>/dev/null
}

# ---------- preflight ----------

echo ""
bold "═══════════════════════════════════════════"
bold "  Meridian Release Builder"
bold "═══════════════════════════════════════════"
echo ""

# Must be run from the repo root.
[ -f "${PROJECT}" ] || die "Run this script from the repository root: bash Scripts/release-app.sh"

command -v gh >/dev/null 2>&1        || die "gh CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1       || die "gh CLI not authenticated. Run: gh auth login"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode."
command -v xcrun >/dev/null 2>&1      || die "xcrun not found. Install Xcode Command Line Tools."

# Require a clean working tree so the version-bump commit is unambiguous.
git diff --quiet          || die "Uncommitted changes detected. Commit or stash first."
git diff --staged --quiet || die "Staged changes detected. Commit them first."

# ---------- determine version ----------

ARG="${1:---patch}"

CURRENT_VERSION="$(xcode_build_setting MARKETING_VERSION)"
CURRENT_BUILD="$(xcode_build_setting CURRENT_PROJECT_VERSION)"
[ -n "${CURRENT_VERSION}" ] || die "Could not read MARKETING_VERSION from ${PROJECT}"

if [[ "${ARG}" == --major || "${ARG}" == --minor || "${ARG}" == --patch ]]; then
    NEW_VERSION="$(bump_semver "${CURRENT_VERSION}" "${ARG}")"
elif [[ "${ARG}" =~ ^v?[0-9]+\.[0-9]+ ]]; then
    NEW_VERSION="${ARG#v}"
else
    die "Unknown argument '${ARG}'. Use --major, --minor, --patch, or an explicit version like 1.2.0"
fi

NEW_BUILD="$((CURRENT_BUILD + 1))"
TAG="v${NEW_VERSION}"

info "Current: ${CURRENT_VERSION} (build ${CURRENT_BUILD})"
info "New:     ${NEW_VERSION} (build ${NEW_BUILD})"
info "Tag:     ${TAG}"
info "Repo:    ${REPO}"

# ---------- detect signing / notarization capability ----------

SIGN_MODE="development"
NOTARIZE=false

if has_cert "Developer ID Application"; then
    DEVELOPER_ID_CERT="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
    SIGN_MODE="developer-id"
    info "Cert:    ${DEVELOPER_ID_CERT}"
    if has_notarize_profile; then
        NOTARIZE=true
        info "Notarize: yes (profile: ${NOTARIZE_PROFILE})"
    else
        info "Notarize: no  (keychain profile '${NOTARIZE_PROFILE}' not found — see script header)"
    fi
else
    echo ""
    yellow "  ⚠  No 'Developer ID Application' certificate found."
    yellow "     Building with 'Apple Development' cert (dev-only — Gatekeeper will block"
    yellow "     this .dmg on other Macs). See script header for setup instructions."
    info "Cert:    Apple Development ($(has_cert "Apple Development" && security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo 'none'))"
fi

echo ""
read -rp "  Continue with release ${NEW_VERSION}? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }

# ---------- bump version ----------

step "Bumping version → ${NEW_VERSION} (build ${NEW_BUILD})"
xcrun agvtool new-marketing-version "${NEW_VERSION}"
xcrun agvtool new-version -all "${NEW_BUILD}"
info "MARKETING_VERSION = ${NEW_VERSION}"
info "CURRENT_PROJECT_VERSION = ${NEW_BUILD}"

# ---------- archive ----------

step "Archiving (Release)"
rm -rf "${BUILD_ROOT}"
mkdir -p "${BUILD_ROOT}"

xcodebuild archive \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    -sdk macosx \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | tee "${BUILD_ROOT}/archive.log" \
         | grep -E "^(=== BUILD|error:|Archive Succeeded|Archive FAILED|BUILD SUCCEEDED|BUILD FAILED)" || true

[ -d "${ARCHIVE_PATH}" ] || {
    red "Archive failed. Full log:"
    cat "${BUILD_ROOT}/archive.log"
    die "xcodebuild archive failed. See above."
}
info "Archive: ${ARCHIVE_PATH}"

# ---------- export ----------

step "Exporting .app (method: ${SIGN_MODE})"
mkdir -p "${EXPORT_DIR}"

cat > "${EXPORT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${SIGN_MODE}</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_PLIST}" \
    2>&1 | tee "${BUILD_ROOT}/export.log" \
         | grep -E "^(=== |error:|Export Succeeded|Export FAILED|BUILD SUCCEEDED|BUILD FAILED)" || true

APP_PATH="${EXPORT_DIR}/Meridian.app"
[ -d "${APP_PATH}" ] || {
    red "Export failed. Full log:"
    cat "${BUILD_ROOT}/export.log"
    die "xcodebuild -exportArchive failed. See above."
}
info "Exported: ${APP_PATH}"

# ---------- DMG ----------

step "Building .dmg"
rm -rf "${STAGING_DIR}" "${DMG_UNSIGNED}" "${DMG_FINAL}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/Meridian.app"
ln -sf /Applications "${STAGING_DIR}/Applications"

hdiutil create \
    -volname "Meridian ${NEW_VERSION}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${DMG_FINAL}" \
    > /dev/null

DMG_SIZE="$(du -sh "${DMG_FINAL}" | cut -f1)"
info "DMG: ${DMG_FINAL} (${DMG_SIZE})"

# ---------- notarize ----------

if ${NOTARIZE}; then
    step "Notarizing"

    # Notarize the app bundle (zip required by notarytool)
    APP_ZIP="${BUILD_ROOT}/Meridian-${NEW_VERSION}.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${APP_ZIP}"

    xcrun notarytool submit "${APP_ZIP}" \
        --keychain-profile "${NOTARIZE_PROFILE}" \
        --wait \
        --timeout 15m

    xcrun stapler staple "${APP_PATH}"
    rm -f "${APP_ZIP}"
    info "App stapled ✓"

    # Rebuild the DMG from the stapled app, then notarize the DMG too.
    step "Rebuilding .dmg with stapled app"
    rm -rf "${STAGING_DIR}" "${DMG_FINAL}"
    mkdir -p "${STAGING_DIR}"
    cp -R "${APP_PATH}" "${STAGING_DIR}/Meridian.app"
    ln -sf /Applications "${STAGING_DIR}/Applications"

    hdiutil create \
        -volname "Meridian ${NEW_VERSION}" \
        -srcfolder "${STAGING_DIR}" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "${DMG_FINAL}" \
        > /dev/null

    step "Notarizing .dmg"
    xcrun notarytool submit "${DMG_FINAL}" \
        --keychain-profile "${NOTARIZE_PROFILE}" \
        --wait \
        --timeout 15m

    xcrun stapler staple "${DMG_FINAL}"
    info "DMG stapled ✓"
else
    yellow ""
    yellow "  ⚠  Skipping notarization (no Developer ID cert or keychain profile)."
fi

# ---------- checksums ----------

SHA256="$(shasum -a 256 "${DMG_FINAL}" | awk '{print $1}')"
info "SHA-256: ${SHA256}"

# ---------- commit + tag ----------

step "Committing version bump"
git add "${PROJECT}/project.pbxproj"
git commit -m "chore: release ${NEW_VERSION} (build ${NEW_BUILD})"

step "Tagging ${TAG}"
git tag -a "${TAG}" -m "Meridian ${NEW_VERSION}"

step "Pushing to origin"
git push origin HEAD
git push origin "${TAG}"
info "Tag ${TAG} pushed."

# ---------- release notes template ----------

WINE_VERSION="unknown"
ENGINE_NOTES_FILE="${HOME}/Library/Application Support/com.meridian.app/engine/wine/meridian-engine-version.txt"
[ -f "${ENGINE_NOTES_FILE}" ] && WINE_VERSION="$(cat "${ENGINE_NOTES_FILE}")"

NOTES_FILE="${BUILD_ROOT}/release-notes.md"
cat > "${NOTES_FILE}" <<EOF
## What's New

<!-- Edit these release notes before publishing the draft on GitHub. -->

## Installation

1. Download **Meridian-${NEW_VERSION}.dmg**
2. Open the .dmg and drag Meridian to Applications
3. Launch Meridian — the Wine engine downloads automatically on first run

## Wine Engine

Engine snapshot: \`${WINE_VERSION}\`
Bundled components: Wine (LGPL) · DXMT · DXVK · MoltenVK (Apache 2.0)

## Checksums

\`\`\`
${SHA256}  Meridian-${NEW_VERSION}.dmg
\`\`\`
EOF

# ---------- publish ----------

step "Publishing GitHub release ${TAG} (draft)"
gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "Meridian ${NEW_VERSION}" \
    --notes-file "${NOTES_FILE}" \
    --draft \
    "${DMG_FINAL}#Meridian-${NEW_VERSION}.dmg"

# Published as a draft so you can edit the release notes before making it public.
RELEASE_URL="$(gh release view "${TAG}" --repo "${REPO}" --json url -q '.url')"

# ---------- done ----------

echo ""
green "═══════════════════════════════════════════"
green "  ✓ Meridian ${NEW_VERSION} release draft created"
green "═══════════════════════════════════════════"
info "Draft URL: ${RELEASE_URL}"
info ""
info "Next steps:"
info "  1. Edit the release notes at the URL above"
info "  2. Publish the release when ready"
if ! ${NOTARIZE}; then
    info ""
    info "  ⚠  This release is NOT notarized."
    info "     Users will see a Gatekeeper warning on first launch."
    info "     Get a Developer ID cert and set up xcrun notarytool credentials to fix this."
fi
echo ""
