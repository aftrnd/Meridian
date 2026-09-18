#!/bin/zsh
# Fetch winemac.drv sources for the engine's Wine version and print the mouse-delivery facts
# relevant to relative mode (Pattern 28 M1). Usage: fetch-winemac-src.sh [wine-tag]
set -eu
TAG="${1:-wine-11.10}"
D="/tmp/dl/winemac-$TAG"
mkdir -p "$D"
for f in cocoa_app.m cocoa_cursorclipping.m macdrv_main.c mouse.c; do
  out="$D/$f"
  [[ -s "$out" ]] || curl -sSL -o "$out" "https://raw.githubusercontent.com/wine-mirror/wine/$TAG/dlls/winemac.drv/$f"
  printf '%-26s %6s lines\n' "$f" "$(wc -l < "$out" | tr -d ' ')"
done
cd "$D"
echo '--- cocoa_app.m: relative vs absolute decision in handleMouseMove:'
grep -nE 'MOUSE_MOVED_RELATIVE|MOUSE_MOVED_ABSOLUTE|clippingCursor\b|deltaX|forceNextMouseMoveAbsolute|mouseMoveDeltaX' cocoa_app.m | head -30
echo '--- which clip handler is chosen:'
grep -nE 'UseConfinementCursorClipping|use_confinement_cursor_clipping|ConfinementClipCursorHandler|EventTapClipCursorHandler|isAvailable' cocoa_app.m macdrv_main.c cocoa_cursorclipping.m | head -14
echo '--- clip handlers: APIs + permission checks:'
grep -nE 'CGSSetMouseConfinement|CGSSetConnectionProperty|CGEventTapCreate|kCGHIDEventTap|kCGEventTapOption|AXIsProcessTrusted|CGRequestListenEventAccess|CGPreflight|CGAssociateMouseAndMouseCursorPosition|warp' cocoa_cursorclipping.m | head -24
echo '--- mouse.c: how relative events become input:'
grep -nE 'MOUSEEVENTF_ABSOLUTE|MOUSE_MOVE_RELATIVE|mouse_moved_relative|macdrv_mouse_moved|send_mouse_input' mouse.c | head -12
