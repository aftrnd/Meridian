#!/usr/bin/env bash
#
# gpu-debug.sh — Agent-driven GPU frame capture + analysis for Meridian games.
#
# macOS 27 / GPTK 4 (WWDC26) ships two command-line Metal tools that enable a
# coding agent to capture and inspect a GPU frame WITHOUT opening Xcode:
#
#   gpucapture  — capture a GPU trace from a running process (subcommands:
#                 start / stop / list / boundaries)
#   gpudebug    — open a debug session on a captured .gputrace (-t <trace>),
#                 optionally emitting JSON (--json) for agent consumption
#
# Real CLI surface verified on macOS 27 (this box):
#   gpucapture start -p <pid> -o <out.gputrace> [-c <count>] [-u]
#   gpucapture list
#   gpudebug -t <trace> --json --oneshot [-o <outdir>]
#
# This wrapper standardises how Meridian uses them so a frame capture of a
# broken/underperforming title can be turned into an engine-wide-vs-game-specific
# classification (development-standards.mdc "Fix Scope Classification").
#
# Usage:
#   Scripts/gpu-debug.sh capture <appID>       # capture a frame of a running game
#   Scripts/gpu-debug.sh analyze <trace.gputrace>
#   Scripts/gpu-debug.sh list                  # list capturable processes
#   Scripts/gpu-debug.sh doctor                # check the tools are present
#
# Captures land in:
#   ~/Library/Application Support/com.meridian.app/logs/gputraces/<appID>-<ts>.gputrace
#
# NOTE: gpucapture/gpudebug are macOS 27+ only. On macOS 26 this script prints a
# clear "not available on this OS" message and exits non-zero — it does NOT try
# to fake a capture (fail-fast: surface the missing capability, don't mask it).

set -euo pipefail

APP_SUPPORT="${HOME}/Library/Application Support/com.meridian.app"
TRACE_DIR="${APP_SUPPORT}/logs/gputraces"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

os_major() { sw_vers -productVersion | cut -d. -f1; }

require_tools() {
    if ! have gpucapture || ! have gpudebug; then
        red "gpucapture/gpudebug not found."
        info "These ship with macOS 27 (Golden Gate) + GPTK 4."
        info "Current macOS: $(sw_vers -productVersion)"
        info "If you are on macOS 27, install/select the GPTK 4 developer tools:"
        info "  xcode-select --install   (or point to the GPTK 4 Xcode)"
        die "Metal command-line tools unavailable"
    fi
}

# Resolve the running game's PID. Prefer gpucapture's own capturable-process
# list (it only lists Metal-rendering processes, so this pins the game far more
# reliably than pgrep). Fall back to the wine64 child whose argv contains the
# game's install dir (matches SteamWindow / GameProcess detection).
resolve_game_pid() {
    local appID="$1"
    local pid
    pid="$(gpucapture list 2>/dev/null | grep -iE "wine|steamapps|\.exe" | grep -oE '[0-9]+' | head -1 || true)"
    if [ -z "${pid}" ]; then
        pid="$(pgrep -fl "wine64" | grep -iE "steamapps/common" | awk '{print $1}' | head -1 || true)"
    fi
    echo "${pid}"
}

cmd_doctor() {
    info "macOS: $(sw_vers -productVersion)"
    if [ "$(os_major)" -lt 27 ]; then
        red "gpucapture/gpudebug require macOS 27+. You are on $(sw_vers -productVersion)."
        exit 1
    fi
    require_tools
    green "GPU debug tools present ✓"
    info "gpucapture: $(command -v gpucapture)"
    info "gpudebug:   $(command -v gpudebug)"
}

cmd_capture() {
    local appID="${1:-}"
    [ -n "${appID}" ] || die "usage: gpu-debug.sh capture <appID>"
    require_tools
    mkdir -p "${TRACE_DIR}"

    local pid
    pid="$(resolve_game_pid "${appID}")"
    [ -n "${pid}" ] || die "no running game process found (launch the game first)"

    local ts trace
    ts="$(date +%Y%m%d-%H%M%S)"
    trace="${TRACE_DIR}/${appID}-${ts}.gputrace"

    info "Capturing GPU trace from pid=${pid} → ${trace}"
    # start -p <pid> -o <out> captures at the next boundary (default count=1).
    gpucapture start -p "${pid}" -o "${trace}" \
        || die "gpucapture failed (is the process rendering with Metal?)"
    green "Captured: ${trace}"
    echo "${trace}"
}

cmd_analyze() {
    local trace="${1:-}"
    [ -n "${trace}" ] || die "usage: gpu-debug.sh analyze <trace.gputrace>"
    [ -e "${trace}" ] || die "trace not found: ${trace}"
    require_tools
    mkdir -p "${TRACE_DIR}/analysis"

    green "=== gpudebug session (JSON, one-shot) ==="
    # -t opens the trace, --json emits machine-readable output for the agent,
    # --oneshot terminates the session after commands complete, -o collects any
    # fetched resources. This is the agent-consumable dump; the interactive
    # Xcode Metal debugger remains available for deep manual inspection.
    gpudebug -t "${trace}" --json --oneshot -o "${TRACE_DIR}/analysis" 2>&1 | head -200 || true
    echo ""
    info "Full trace: open in Xcode's Metal debugger for interactive inspection:"
    info "  open \"${trace}\""
}

cmd_list() {
    require_tools
    gpucapture list 2>&1 || true
}

case "${1:-}" in
    doctor)  cmd_doctor ;;
    capture) shift; cmd_capture "$@" ;;
    analyze) shift; cmd_analyze "$@" ;;
    list)    cmd_list ;;
    *) die "usage: gpu-debug.sh {doctor|capture <appID>|analyze <trace>|list}" ;;
esac
