#!/usr/bin/env bash
#
# verify-bootstrap.sh — CLI smoke test for Steam bootstrap
#
# Verifies that Wine can launch Steam and complete the first-run client
# download without the Meridian app. This catches engine packaging issues
# and Wine/Steam compatibility regressions before you ever press Build.
#
# Usage:
#   bash Scripts/verify-bootstrap.sh          # full test (wipe + bootstrap)
#   bash Scripts/verify-bootstrap.sh --no-wipe  # skip prefix wipe
#
# Prerequisites:
#   - Engine installed at ~/Library/Application Support/com.meridian.app/engine/
#   - SteamSetup.exe will be downloaded if Steam is not already installed
#
# What it does:
#   1. Optionally wipes the Wine prefix for a clean start
#   2. Creates a prefix if needed (wineboot --init or template copy)
#   3. Installs Steam via SteamSetup.exe /S if not present
#   4. Writes steam.cfg (SteamNoSandbox=1)
#   5. Launches wine64 steam.exe and waits for steamui.dll
#   6. Reports success/failure with elapsed time
#
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/com.meridian.app"
ENGINE_DIR="$APP_SUPPORT/engine"
PREFIX_DIR="$APP_SUPPORT/bottles/steam"
WINE64="$ENGINE_DIR/wine/bin/wine64"
WINESERVER="$ENGINE_DIR/wine/bin/wineserver"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() { echo -e "${RED}FATAL: $1${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}==> $1${NC}"; }
warn() { echo -e "${YELLOW}==> $1${NC}"; }

WIPE=true
if [[ "${1:-}" == "--no-wipe" ]]; then
    WIPE=false
fi

# Validate engine
[[ -x "$WINE64" ]] || die "wine64 not found at $WINE64 — download engine first (Settings → Engine)"
[[ -x "$WINESERVER" ]] || die "wineserver not found at $WINESERVER"
info "Engine OK: $WINE64"

# Set Wine environment
export WINEPREFIX="$PREFIX_DIR"
export WINESERVER
export WINELOADER="$WINE64"
LIB_DIR="$ENGINE_DIR/wine/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB_DIR:$LIB_DIR/wine/x86_64-unix"
export WINEDLLPATH="$ENGINE_DIR/wine/lib/wine"
export WINE_LARGE_ADDRESS_AWARE=1
export MTL_HUD_ENABLED=0

# Step 1: Wipe prefix
if $WIPE; then
    info "Wiping prefix at $PREFIX_DIR"
    rm -rf "$PREFIX_DIR"
    defaults delete com.meridian.app lastPrefixEngineTag 2>/dev/null || true
    # Also clear onboarding flags so they don't bleed across test runs.
    # 'defaults delete' alone is unreliable due to cfprefsd caching — delete the plist too.
    defaults delete com.meridian.app apiKeyPromptDismissed 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/com.meridian.app.plist"
fi

# Step 2: Create prefix if needed
if [[ ! -f "$PREFIX_DIR/system.reg" ]]; then
    TEMPLATE_DIR="$ENGINE_DIR/prefix-template"
    if [[ -d "$TEMPLATE_DIR" ]]; then
        info "Creating prefix from template"
        mkdir -p "$(dirname "$PREFIX_DIR")"
        cp -R "$TEMPLATE_DIR" "$PREFIX_DIR"
        # Fix dosdevices
        rm -rf "$PREFIX_DIR/dosdevices"
        mkdir -p "$PREFIX_DIR/dosdevices"
        ln -s "../drive_c" "$PREFIX_DIR/dosdevices/c:"
        ln -s "/" "$PREFIX_DIR/dosdevices/z:"
    else
        info "Creating prefix via wineboot --init (no template found)"
        mkdir -p "$PREFIX_DIR"
        "$WINE64" wineboot --init
    fi
    info "Prefix created"
else
    info "Prefix already exists"
fi

# Step 3: Find or install Steam
find_steam_exe() {
    local x64="$PREFIX_DIR/drive_c/Program Files/Steam/steam.exe"
    local x86="$PREFIX_DIR/drive_c/Program Files (x86)/Steam/steam.exe"
    if [[ -f "$x64" ]]; then echo "$x64"
    elif [[ -f "$x86" ]]; then echo "$x86"
    fi
}

STEAM_EXE="$(find_steam_exe || true)"
if [[ -z "$STEAM_EXE" ]]; then
    info "Downloading SteamSetup.exe"
    SETUP="/tmp/SteamSetup.exe"
    curl -L --fail --retry 3 -o "$SETUP" "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
    info "Installing Steam (silent)"
    "$WINE64" "$SETUP" /S
    rm -f "$SETUP"
    STEAM_EXE="$(find_steam_exe || true)"
    [[ -n "$STEAM_EXE" ]] || die "steam.exe not found after install"
fi
info "Steam exe: $STEAM_EXE"

# Step 4: Write steam.cfg
STEAM_DIR="$(dirname "$STEAM_EXE")"
if ! grep -q "SteamNoSandbox=1" "$STEAM_DIR/steam.cfg" 2>/dev/null; then
    echo "SteamNoSandbox=1" > "$STEAM_DIR/steam.cfg"
    info "Wrote steam.cfg (SteamNoSandbox=1)"
fi

# Step 5: Bootstrap — run Steam and wait for steamui.dll
DLL_PATH="$STEAM_DIR/steamui.dll"
if [[ -f "$DLL_PATH" ]]; then
    info "steamui.dll already present — bootstrap not needed"
    exit 0
fi

info "Launching Steam for first-run bootstrap (this may take a few minutes)..."
info "Steam windows will be visible — this is expected during bootstrap"
START_TIME=$(date +%s)

"$WINE64" "$STEAM_EXE" &
STEAM_PID=$!

TIMEOUT=600
POLL_INTERVAL=5
ELAPSED=0

while (( ELAPSED < TIMEOUT )); do
    if [[ -f "$DLL_PATH" ]]; then
        END_TIME=$(date +%s)
        TOTAL=$((END_TIME - START_TIME))
        info "steamui.dll found after ${TOTAL}s — bootstrap SUCCESS"
        # Kill Steam
        "$WINESERVER" -k 2>/dev/null || true
        exit 0
    fi

    # Check wineserver is still alive
    if ! "$WINESERVER" -p 2>/dev/null; then
        warn "Wineserver died at ${ELAPSED}s — Steam may have exited"
        # Check one more time after grace period
        sleep 5
        if [[ -f "$DLL_PATH" ]]; then
            END_TIME=$(date +%s)
            TOTAL=$((END_TIME - START_TIME))
            info "steamui.dll found after ${TOTAL}s — bootstrap SUCCESS"
            exit 0
        fi
        die "Bootstrap failed — wineserver exited without producing steamui.dll (${ELAPSED}s elapsed)"
    fi

    # Progress logging
    PKG_DIR="$STEAM_DIR/package"
    if [[ -d "$PKG_DIR" ]]; then
        PKG_SIZE=$(du -sh "$PKG_DIR" 2>/dev/null | cut -f1)
        echo "  [${ELAPSED}s] Waiting for steamui.dll... package dir: ${PKG_SIZE}"
    else
        echo "  [${ELAPSED}s] Waiting for steamui.dll..."
    fi

    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Timeout
"$WINESERVER" -k 2>/dev/null || true
die "Bootstrap TIMEOUT after ${TIMEOUT}s — steamui.dll never appeared"
