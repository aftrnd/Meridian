#!/usr/bin/env bash
#
# install-local.sh — install the staged engine into this Mac's Meridian for
# testing an unpublished engine from an Xcode dev build.
#
# Usage: bash Scripts/engine/install-local.sh            install $STAGE
#        bash Scripts/engine/install-local.sh --restore  put the backup back
#
# Quit Meridian first. The current engine is moved to engine.backup (one
# backup is kept). On next launch the app sees a new engine tag and resets the
# prefix to the new template, preserving the Steam login and installed games
# (WinePrefix.resetToEngineTemplate).

source "$(dirname "$0")/env.sh"

APP_SUPPORT="$HOME/Library/Application Support/com.meridian.app"
ENGINE="$APP_SUPPORT/engine"
BACKUP="$APP_SUPPORT/engine.backup"

pgrep -xq Meridian && die "quit Meridian first"

if [ "${1:-}" = "--restore" ]; then
    [ -d "$BACKUP" ] || die "no backup at $BACKUP"
    rm -rf "$ENGINE"; mv "$BACKUP" "$ENGINE"
    say "Restored $(cat "$ENGINE/wine/meridian-engine-version.txt")"
    exit 0
fi

[ -f "$STAGE/wine/meridian-engine-version.txt" ] || die "nothing staged: run package-engine.sh first"
if [ -d "$ENGINE" ]; then
    rm -rf "$BACKUP"; mv "$ENGINE" "$BACKUP"
    say "Backed up $(cat "$BACKUP/wine/meridian-engine-version.txt" 2>/dev/null || echo engine) to $BACKUP"
fi
mkdir -p "$ENGINE"
# -p keeps modification times: Wine compares share/wine/wine.inf's mtime with a
# prefix's .update-timestamp, and a mismatch runs a full wineboot --init on every
# new bottle (which prompts for Wine Mono).
cp -Rp "$STAGE"/. "$ENGINE"/
xattr -rd com.apple.quarantine "$ENGINE" 2>/dev/null || true
say "Installed $(cat "$ENGINE/wine/meridian-engine-version.txt") — launch Meridian from Xcode"
