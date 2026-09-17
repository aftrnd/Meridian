#!/bin/zsh
# HL2 render-path probe. Usage: hl2probe.sh <gl|dxvk|vulkan> [extra hl2 args...]
# Mirrors Meridian's launchDirect env (from logs/games/220.log header) so results transfer 1:1.
set -u
VARIANT="${1:-gl}"; shift || true
APP="$HOME/Library/Application Support/com.meridian.app"
ENG="$APP/engine/wine"
LIB="$ENG/lib"
PREFIX="$APP/bottles/steam/"
HL2="$APP/bottles/steam/drive_c/Program Files (x86)/Steam/steamapps/common/Half-Life 2"
OUT="/tmp/hl2probe-$VARIANT.log"

export WINEPREFIX="$PREFIX"
export WINELOADER="${WINE_BIN:-$ENG/bin/wine64}"
export WINESERVER="$ENG/bin/wineserver"
export DYLD_FALLBACK_LIBRARY_PATH="${MVK_DIR:+$MVK_DIR:}$LIB/gptk/external:$LIB/gptk/wine/x86_64-unix:$LIB:$LIB/dxmt/x86_64-unix:$LIB/wine/x86_64-unix:$ENG/lib64"
export DYLD_FALLBACK_FRAMEWORK_PATH="$LIB/gptk/external"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$LIB/gptk/external/libd3dshared.dylib"
export GST_PLUGIN_SYSTEM_PATH_1_0="$ENG/lib64/gstreamer-1.0"
export WINEMSYNC=1
export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-0}"
export ROSETTA_ADVERTISE_AVX=1
export DOTNET_EnableWriteXorExecute=0
export WINE_LARGE_ADDRESS_AWARE=1
export WINE_DISABLE_WINE_CRASH_DIALOG=1
[[ -n "${MP_DYLIB:-}" ]] && export DYLD_INSERT_LIBRARIES="$MP_DYLIB"
export WINEDEBUG="${WINEDEBUG:--all,+loaddll}"

ARGS=(-game hl2_complete -condebug -novid)
case "$VARIANT" in
  gl)
    export WINEDLLPATH="$LIB/dxmt:$LIB/wine"
    export WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d10core=n,b"
    ;;
  dxvk)
    export CX_ROOT="$ENG"
    export CX_GRAPHICS_BACKEND=dxvk
    export WINEDLLPATH="$LIB/wine"
    export WINEDLLOVERRIDES="d3d9=b"
    export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-info}"
    export DXVK_LOG_PATH="/tmp"
    export DXVK_STATE_CACHE_PATH="$APP/shader-cache/220"
    mkdir -p "$DXVK_STATE_CACHE_PATH"
    ;;
  vulkan)
    export WINEDLLPATH="$LIB/dxmt:$LIB/wine"
    export WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d10core=n,b"
    export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-info}"
    export DXVK_LOG_PATH="/tmp"
    export DXVK_STATE_CACHE_PATH="$APP/shader-cache/220-vk"
    mkdir -p "$DXVK_STATE_CACHE_PATH"
    ARGS+=(-vulkan)
    ;;
  *) echo "unknown variant $VARIANT"; exit 2;;
esac
ARGS+=("$@")

echo "=== variant=$VARIANT args=${ARGS[*]}" | tee "$OUT"
cd "$HL2"
exec "${WINE_BIN:-$ENG/bin/wine64}" "$HL2/hl2.exe" "${ARGS[@]}" >>"$OUT" 2>&1
