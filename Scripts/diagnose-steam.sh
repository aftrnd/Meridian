#!/usr/bin/env bash
#
# diagnose-steam.sh — capture a full, self-contained diagnostic bundle of what
# steam.exe does inside Meridian's Wine prefix. Built for AI/agent debugging:
# instead of describing what you see, run this and point the agent at the
# bundle file it prints.
#
# TWO MODES:
#   (default, "collect")  — gather every relevant log that already exists into
#                           one timestamped bundle. Safe to run any time, even
#                           with Meridian running.
#   --run                 — RUN steam.exe -silent directly with verbose CEF +
#                           Wine logging for N seconds, then capture everything.
#                           Meridian MUST be closed first (competing wineserver
#                           processes corrupt the result). This is the mode that
#                           reveals WHY the webhelper IPC fails (Pattern 7).
#
# Usage:
#   bash Scripts/diagnose-steam.sh                 # collect existing logs
#   bash Scripts/diagnose-steam.sh --run           # run steam.exe 35s + capture
#   bash Scripts/diagnose-steam.sh --run --secs 60 # custom run duration
#
# Output: a single bundle file under /tmp/meridian-steam-diag-<timestamp>/.
# The script prints its path at the end — share that path with the agent.

set -uo pipefail   # NOT -e: wineserver -k / empty greps return non-zero by design

APP_SUPPORT="${HOME}/Library/Application Support/com.meridian.app"
ENGINE="${APP_SUPPORT}/engine"
PREFIX="${APP_SUPPORT}/bottles/steam"
STEAM_DIR="${PREFIX}/drive_c/Program Files/Steam"
WINE64="${ENGINE}/wine/bin/wine64"
WINESERVER="${ENGINE}/wine/bin/wineserver"
LIB="${ENGINE}/wine/lib"

MODE="collect"
RUN_SECS=35
while [ $# -gt 0 ]; do
    case "$1" in
        --run)  MODE="run" ;;
        --secs) shift; RUN_SECS="${1:-35}" ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/meridian-steam-diag-${STAMP}"
mkdir -p "${OUT}"
BUNDLE="${OUT}/bundle.txt"

section() { echo ""; echo "================================================================================"; echo "## $*"; echo "================================================================================"; } >> "${BUNDLE}"
copy_if() { if [ -f "$1" ]; then cp "$1" "${OUT}/$(basename "$1")" 2>/dev/null; echo "  captured $(basename "$1") ($(wc -l < "$1" | tr -d ' ') lines)"; else echo "  (absent) $1"; fi; }

{
echo "Meridian steam.exe diagnostic bundle"
echo "Generated: $(date)"
echo "Mode: ${MODE}"
echo "macOS: $(sw_vers -productVersion) ($(uname -m))"
echo "Engine: $(cat "${ENGINE}/wine/meridian-engine-version.txt" 2>/dev/null || echo unknown)"
} > "${BUNDLE}"

# ---------- environment snapshot ----------
section "Environment"
{
    echo "PREFIX=${PREFIX}"
    echo "steam.exe present: $([ -f "${STEAM_DIR}/steam.exe" ] && echo yes || echo NO)"
    if [ -f "${STEAM_DIR}/steam.exe" ]; then
        echo "steam.exe size: $(stat -f%z "${STEAM_DIR}/steam.exe") bytes"
        echo "steam.exe arch: $(file "${STEAM_DIR}/steam.exe" | sed 's/.*: //')"
    fi
    echo "steamui.dll present: $([ -f "${STEAM_DIR}/steamui.dll" ] && echo yes || echo NO)"
    echo "local.vdf present: $([ -f "${PREFIX}/drive_c/users/crossover/AppData/Local/Steam/local.vdf" ] && echo yes || echo NO)"
    echo "loginusers.vdf present: $([ -f "${STEAM_DIR}/config/loginusers.vdf" ] && echo yes || echo NO)"
    echo "ssfn files: $(ls "${STEAM_DIR}"/ssfn* 2>/dev/null | wc -l | tr -d ' ')"
    echo "wine64 quarantine: $(xattr "${WINE64}" 2>/dev/null | grep -c quarantine) (should be 0)"
} >> "${BUNDLE}"

# ---------- running processes ----------
section "Running Meridian/Wine/Steam processes"
ps aux | grep -iE "meridian|steam|wine" | grep -v grep >> "${BUNDLE}" 2>/dev/null || echo "  (none)" >> "${BUNDLE}"

if [ "${MODE}" = "run" ]; then
    # ---------- guard: app must be closed ----------
    if pgrep -f "Meridian.app" >/dev/null 2>&1; then
        echo ""
        echo "ERROR: Meridian.app is running. Quit it first (its wineserver competes" >&2
        echo "       with this diagnostic and corrupts the result), then re-run." >&2
        exit 1
    fi

    section "Pre-run cleanup (kill stale Wine/Steam)"
    ( pkill -9 -f "steam.exe" 2>/dev/null; pkill -9 -f "steamwebhelper" 2>/dev/null
      "${WINESERVER}" -k -w 2>/dev/null; true ) >> "${BUNDLE}" 2>&1
    sleep 2

    # Clear stale crash marker so steam.exe doesn't short-circuit.
    rm -f "${STEAM_DIR}/.crash" 2>/dev/null

    section "Running steam.exe -silent for ${RUN_SECS}s with verbose logging"
    echo "  launching… (CEF logging on, WINEDEBUG=+module,+process for IPC visibility)"

    # steamCMDEnvironment-equivalent (NOT GPTK — admin/non-game env).
    export WINEPREFIX="${PREFIX}/"
    export WINESERVER WINELOADER="${WINE64}"
    export WINEDLLPATH="${ENGINE}/wine/lib/wine"
    export DYLD_FALLBACK_LIBRARY_PATH="${LIB}:${LIB}/wine/x86_64-unix:${ENGINE}/wine/lib64"
    # -cef-enable-logging + -cef-in-process-gpu surface webhelper/CEF IPC detail;
    # vgui logging shows the WebUITransport handshake.
    export WINEDEBUG="+module,+process,err+all"

    WINE_STDERR="${OUT}/wine-stderr.txt"
    ( "${WINE64}" "${STEAM_DIR}/steam.exe" -silent -nofriendsui -cef-enable-logging -cef-force-enable-logging \
        > "${OUT}/steam-stdout.txt" 2> "${WINE_STDERR}" ) &
    STEAM_BG=$!
    echo "  steam.exe launched (bg pid ${STEAM_BG}); waiting ${RUN_SECS}s…"
    sleep "${RUN_SECS}"

    section "Post-run process snapshot"
    ps aux | grep -iE "steam|wine" | grep -v grep >> "${BUNDLE}" 2>/dev/null || echo "  (none)" >> "${BUNDLE}"

    section "Teardown"
    ( pkill -9 -f "steam.exe" 2>/dev/null; pkill -9 -f "steamwebhelper" 2>/dev/null
      "${WINESERVER}" -k 2>/dev/null; true ) >> "${BUNDLE}" 2>&1
    echo "  wine-stderr captured ($(wc -l < "${WINE_STDERR}" 2>/dev/null | tr -d ' ') lines)"
fi

# ---------- capture all Steam-side logs ----------
section "Captured Steam log files (copied into bundle dir)"
copy_if "${APP_SUPPORT}/logs/meridian.log"
copy_if "${STEAM_DIR}/logs/bootstrap_log.txt"
copy_if "${STEAM_DIR}/logs/connection_log.txt"
copy_if "${STEAM_DIR}/logs/webhelper_js.txt"
copy_if "${STEAM_DIR}/logs/transport_steamui.txt"
copy_if "${STEAM_DIR}/logs/transport_client.txt"
copy_if "${STEAM_DIR}/logs/cloud_log.txt"
# CEF / webhelper crash + assert dumps (Pattern 7 signature lives here).
if [ -d "${STEAM_DIR}/dumps" ]; then
    cp -R "${STEAM_DIR}/dumps" "${OUT}/dumps" 2>/dev/null
    echo "  captured dumps/ ($(ls "${STEAM_DIR}/dumps" 2>/dev/null | wc -l | tr -d ' ') files)"
fi

# ---------- quick verdict ----------
section "Quick verdict (heuristic)"
{
    CONN="${STEAM_DIR}/logs/connection_log.txt"
    if [ -f "${CONN}" ]; then
        # Scope to the MOST RECENT steam.exe session only. Each launch writes a
        # "Client version:" header; older sessions' lines must not pollute the
        # verdict (CLI-confirmed June 19 2026: a stale 'Using JWT' from a prior
        # run made the heuristic report a logon attempt that didn't happen this
        # session).
        LAST_START=$(grep -n "Client version:" "${CONN}" | tail -1 | cut -d: -f1)
        if [ -n "${LAST_START}" ]; then
            SESSION=$(tail -n "+${LAST_START}" "${CONN}")
        else
            SESSION=$(cat "${CONN}")
        fi
        echo "${SESSION}" > "${OUT}/connection_log_last_session.txt"
        if echo "${SESSION}" | grep -q "Using JWT"; then
            echo "• steam.exe DID attempt a token logon this session (found 'Using JWT'):"
            echo "${SESSION}" | grep -E "Using JWT|RecvMsgClientLogOnResponse|Logged On|Invalid Password" | tail -5 | sed 's/^/    /'
        else
            echo "• steam.exe did NOT attempt a logon THIS session (no 'Using JWT' after"
            echo "  the last 'Client version:' marker). It reached:"
            echo "${SESSION}" | grep -E "Connectivity test: result|Logged Off|Logging on" | tail -3 | sed 's/^/    /'
            echo "  → auto-login from local.vdf did not fire. Steam is sitting at the"
            echo "    account picker ('Who's playing' / '?'). Either the webhelper IPC"
            echo "    stalled (Pattern 7) or local.vdf was not consumed. Cross-check"
            echo "    webhelper_js.txt 'OnLoginStateChange' + 'connect attempt failed'."
        fi
    fi
    WJS="${STEAM_DIR}/logs/webhelper_js.txt"
    if [ -f "${WJS}" ]; then
        FAILS=$(grep -c "connect attempt failed" "${WJS}" 2>/dev/null || echo 0)
        echo "• webhelper 'connect attempt failed' count: ${FAILS}"
    fi
    if ls "${STEAM_DIR}/dumps"/assert_* >/dev/null 2>&1; then
        echo "• ASSERT dumps present — extracting assert strings:"
        for d in "${STEAM_DIR}/dumps"/assert_*; do
            strings "$d" 2>/dev/null | grep -iE "Assert\(|webuitransport|\.cpp:" | head -3 | sed 's/^/    /'
        done
    fi
} >> "${BUNDLE}"

echo ""
echo "✓ Diagnostic bundle written to:"
echo "    ${OUT}/"
echo "  Main summary: ${BUNDLE}"
echo ""
echo "Share that directory path with the agent — it will read bundle.txt +"
echo "the captured log files directly."
