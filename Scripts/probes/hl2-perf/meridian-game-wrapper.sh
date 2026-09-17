#!/bin/zsh
# Meridian Game.app launcher (probe). LaunchServices runs this; it becomes the Wine game process via exec.
B="${0:A:h:h:h}"
APP="$HOME/Library/Application Support/com.meridian.app"
ENG="$APP/engine/wine"; LIB="$ENG/lib"
export WINEPREFIX="$APP/bottles/steam/"
export WINELOADER="$B/Contents/MacOS/wine64"
export WINESERVER="$ENG/bin/wineserver"
export WINEDLLPATH="$LIB/dxmt:$LIB/wine"
export WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d10core=n,b"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB/gptk/external:$LIB/gptk/wine/x86_64-unix:$LIB:$LIB/dxmt/x86_64-unix:$LIB/wine/x86_64-unix:$ENG/lib64"
export DYLD_FALLBACK_FRAMEWORK_PATH="$LIB/gptk/external"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$LIB/gptk/external/libd3dshared.dylib"
export GST_PLUGIN_SYSTEM_PATH_1_0="$ENG/lib64/gstreamer-1.0"
export WINEMSYNC=1 MTL_HUD_ENABLED=0 ROSETTA_ADVERTISE_AVX=1 DOTNET_EnableWriteXorExecute=0
export WINE_LARGE_ADDRESS_AWARE=1 WINE_DISABLE_WINE_CRASH_DIALOG=1 WINEDEBUG=-all
export TMPDIR="$B/Contents/MacOS"
cd "$APP/bottles/steam/drive_c/Program Files (x86)/Steam/steamapps/common/Half-Life 2"
exec "$WINELOADER" 'C:\Program Files (x86)\Steam\steamapps\common\Half-Life 2\hl2.exe' -game hl2_complete -novid "$@" >>/tmp/hl2-gamemode.log 2>&1
