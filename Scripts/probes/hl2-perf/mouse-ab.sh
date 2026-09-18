#!/bin/zsh
# Relative-mouse A/B for HL2 (Pattern 34 → Pattern 28 M1).
# Usage: mouse-ab.sh pin|off [gamemode]
#   pin       inject meridian_mouse_probe.dylib with MERIDIAN_MP_PIN=1 (winemac emits raw relative deltas)
#   off       plain launch through the same script (control)
#   gamemode  also apply the Game Mode bundle to the live engine first (GM_LIVE=1 prepare); reverted on exit
# Runs HL2 with Meridian's exact env via hl2probe.sh (GL path), then prints the verification lines.
set -u
MODE="${1:-pin}"; GM="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export ENGINE="${ENGINE:-$HOME/Library/Application Support/com.meridian.app/engine/wine}"

if [[ "$GM" == gamemode ]]; then
  GM_LIVE=1 "$HERE/gamemode-bundle.sh" prepare >/dev/null 2>&1 && echo "game mode bundle: ON"
  trap 'GM_LIVE=1 "$HERE/gamemode-bundle.sh" revert >/dev/null 2>&1; echo "game mode bundle: reverted"' EXIT
fi

if [[ "$MODE" == pin ]]; then
  clang -dynamiclib -arch x86_64 -arch arm64 -framework AppKit -fobjc-arc -O2 \
    -o /tmp/mouseprobe/meridian_mouse_probe.dylib "$HERE/meridian_mouse_probe.m" 2>/dev/null || { mkdir -p /tmp/mouseprobe; clang -dynamiclib -arch x86_64 -arch arm64 -framework AppKit -fobjc-arc -O2 -o /tmp/mouseprobe/meridian_mouse_probe.dylib "$HERE/meridian_mouse_probe.m" || exit 3; }
  codesign -fs - /tmp/mouseprobe/meridian_mouse_probe.dylib 2>/dev/null
  export MP_DYLIB=/tmp/mouseprobe/meridian_mouse_probe.dylib
  export MERIDIAN_MP_PIN=1
fi
export WINEDEBUG="-all"
echo "=== HL2 mouse A/B: mode=$MODE gamemode=${GM:-off}  (quit the game to finish)"
"$HERE/hl2probe.sh" gl -condebug
echo '--- probe lines from the run log:'
grep -E 'mouse-probe' /tmp/hl2probe-gl.log | tail -8
if [[ "$MODE" == pin ]]; then
  grep -q 'pin attempt.*-> 1' /tmp/hl2probe-gl.log && echo 'PIN ENGAGED: winemac was in relative-delta mode' || echo 'PIN DID NOT ENGAGE (see probe lines above)'
fi
