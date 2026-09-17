#!/bin/zsh
# dx11probe.sh <default|dxmt> — launches Big Walk (64-bit Unity DX11) with Meridian's env and either
# today's routing (WINEDLLPATH + n,b) or CX_GRAPHICS_BACKEND=dxmt, then reports which d3d11 mapped.
set -u
VARIANT="${1:-default}"
APP="$HOME/Library/Application Support/com.meridian.app"
ENG="$APP/engine/wine"; LIB="$ENG/lib"
GAME="$APP/bottles/steam/drive_c/Program Files (x86)/Steam/steamapps/common/Big Walk"
OUT="/tmp/dx11probe-$VARIANT.log"
export WINEPREFIX="$APP/bottles/steam/" WINELOADER="$ENG/bin/wine64" WINESERVER="$ENG/bin/wineserver"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB/gptk/external:$LIB/gptk/wine/x86_64-unix:$LIB:$LIB/dxmt/x86_64-unix:$LIB/wine/x86_64-unix:$ENG/lib64"
export DYLD_FALLBACK_FRAMEWORK_PATH="$LIB/gptk/external"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$LIB/gptk/external/libd3dshared.dylib"
export GST_PLUGIN_SYSTEM_PATH_1_0="$ENG/lib64/gstreamer-1.0"
export WINEMSYNC=1 MTL_HUD_ENABLED=0 ROSETTA_ADVERTISE_AVX=1 DOTNET_EnableWriteXorExecute=0 WINE_LARGE_ADDRESS_AWARE=1 WINE_DISABLE_WINE_CRASH_DIALOG=1
export WINEDEBUG="-all,+winediag"
export WINEDLLPATH="$LIB/dxmt:$LIB/wine"
export WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d10core=n,b"
if [[ "$VARIANT" == "dxmt" ]]; then
  export CX_ROOT="$ENG"
  export CX_GRAPHICS_BACKEND=dxmt
fi
pkill -f "Big Walk.exe" 2>/dev/null; sleep 1
cd "$GAME"
( "$ENG/bin/wine64" "$GAME/Big Walk.exe" -screen-fullscreen 0 -screen-width 1280 -screen-height 800 >"$OUT" 2>&1 & )
sleep ${WAIT:-45}
PID=$(pgrep -f "Big Walk.exe" | tail -1)
WID=$(/tmp/winlist | grep -i "big walk" | head -1 | cut -f1)
if [[ -n "$WID" ]]; then
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" 2>/dev/null
  sleep 3
  screencapture -x -l$WID /tmp/bigwalk-$VARIANT.png && sips -Z 800 /tmp/bigwalk-$VARIANT.png --out /tmp/bigwalk-$VARIANT-s.png >/dev/null
fi
echo "--- $VARIANT mapped:"
lsof -p "$PID" 2>/dev/null | awk '{print $NF}' | grep -iE "d3d11.dll|dxgi.dll|winemetal|MoltenVK|OpenGLRenderer" | grep -v "\.aot" | sed "s|$ENG/||; s|.*Extensions/||" | sort -u
echo "--- winediag/wined3d lines:"
grep -iE "winediag|wined3d|dxmt" "$OUT" | grep -v cxcompatdb | cut -c1-140 | sort | uniq -c | sort -rn | head -5
ps -o %cpu,rss -p "$PID" | tail -1
pkill -f "Big Walk.exe"
