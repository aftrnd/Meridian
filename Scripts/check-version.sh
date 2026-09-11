#!/usr/bin/env bash
#
# check-version.sh — Versioning guard for Meridian.
#
#   bash Scripts/check-version.sh            # lint: 3-part semver, both configs agree
#   bash Scripts/check-version.sh v1.2.3     # additionally: tag == MARKETING_VERSION
#
# The Xcode project is the single source of truth for the version
# (Info.plist reads $(MARKETING_VERSION)). Run by CI on every push and by the
# Release workflow before it signs anything.
set -euo pipefail

PBXPROJ="$(dirname "${BASH_SOURCE[0]}")/../Meridian.xcodeproj/project.pbxproj"
[ -f "${PBXPROJ}" ] || { echo "::error::${PBXPROJ} not found"; exit 1; }

versions=$(grep -oE 'MARKETING_VERSION = [^;]+' "${PBXPROJ}" | awk '{print $3}' | sort -u)
builds=$(grep -oE 'CURRENT_PROJECT_VERSION = [^;]+' "${PBXPROJ}" | awk '{print $3}' | sort -u)

fail() { echo "::error::$*" >&2; exit 1; }

[ "$(echo "${versions}" | wc -l | tr -d ' ')" = "1" ] || fail "MARKETING_VERSION differs between build configurations: $(echo "${versions}" | tr '\n' ' ')"
[ "$(echo "${builds}"   | wc -l | tr -d ' ')" = "1" ] || fail "CURRENT_PROJECT_VERSION differs between build configurations: $(echo "${builds}" | tr '\n' ' ')"

version="${versions}"
build="${builds}"

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION '${version}' must be 3-part semver (X.Y.Z)"
[[ "${build}" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION '${build}' must be an integer"

if [ -n "${1:-}" ]; then
    tag="${1}"
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Tag '${tag}' is not a canonical app tag (vX.Y.Z; engine tags use -engine)"
    [ "${tag#v}" = "${version}" ] || fail "Tag ${tag} does not match MARKETING_VERSION ${version} — bump the project before tagging (Scripts/release-app.sh)"
fi

echo "version ${version} (build ${build}) OK${1:+ — matches ${1}}"
