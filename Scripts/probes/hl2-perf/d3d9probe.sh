#!/bin/zsh
# D3D9 render-path discriminator. Usage: d3d9probe.sh <gl|dxvk> <32|64> [WINEDEBUG channels]
# Runs Scripts/probes/hl2-perf/d3d9probe.c (built to /tmp/d3d9probe/) under Meridian's
# exact game env. Prints ADAPTER/TEXMEM/FORMATS/PIXEL/RESULT lines; log in /tmp/d3d9probe/.
set -u
VARIANT="${1:-gl}"; BITS="${2:-64}"; DBG="${3:--all}"
APP="$HOME/Library/Application Support/com.meridian.app"
# ENGINE=/tmp/engine-gm targets a staged clone (see stage-modern-dxvk.sh) instead of the live engine.
ENG="${ENGINE:-$APP/engine/wine}"
LIB="$ENG/lib"
DIR=/tmp/d3d9probe
SRC="$(cd "$(dirname "$0")" && pwd)/d3d9probe.c"
mkdir -p "$DIR"

if [[ ! -x "$DIR/d3d9probe64.exe" || "$SRC" -nt "$DIR/d3d9probe64.exe" ]]; then
  x86_64-w64-mingw32-gcc -O1 -o "$DIR/d3d9probe64.exe" "$SRC" -ld3d9 -lgdi32 -luser32 || exit 3
  i686-w64-mingw32-gcc   -O1 -o "$DIR/d3d9probe32.exe" "$SRC" -ld3d9 -lgdi32 -luser32 || exit 3
fi

export WINEPREFIX="$APP/bottles/steam/"
export WINELOADER="$ENG/bin/wine64"
export WINESERVER="$ENG/bin/wineserver"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB/gptk/external:$LIB/gptk/wine/x86_64-unix:$LIB:$LIB/dxmt/x86_64-unix:$LIB/wine/x86_64-unix:$ENG/lib64"
export DYLD_FALLBACK_FRAMEWORK_PATH="$LIB/gptk/external"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$LIB/gptk/external/libd3dshared.dylib"
export WINEMSYNC=1 ROSETTA_ADVERTISE_AVX=1 WINE_LARGE_ADDRESS_AWARE=1 WINE_DISABLE_WINE_CRASH_DIALOG=1
export WINEDEBUG="$DBG"
export CX_ROOT="$ENG"
export WINEDLLPATH="$LIB/dxmt:$LIB/wine"

case "$VARIANT" in
  gl)   export CX_GRAPHICS_BACKEND=dxmt; export WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d10core=n,b" ;;
  dxvk) export CX_GRAPHICS_BACKEND=dxvk; export WINEDLLOVERRIDES="d3d9=b"
        export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-info}" DXVK_LOG_PATH="$DIR" ;;
  *) echo "unknown variant $VARIANT"; exit 2 ;;
esac

OUT="$DIR/run-$VARIANT-$BITS.log"
cd "$DIR"
echo "=== variant=$VARIANT bits=$BITS $(date '+%H:%M:%S')" | tee "$OUT"
perl -e 'alarm shift; exec @ARGV' 12 "$ENG/bin/wine64" "$DIR/d3d9probe$BITS.exe" >>"$OUT" 2>&1
echo "exit=$?" >>"$OUT"
grep -E "^(d3d9probe|ADAPTER|CAPS|TEXMEM|FORMATS|READBACK|CONSTANT|TEXTURE|PIXEL|FRAMES|RESULT|FAIL|exit=)" "$OUT"
echo "--- err/warn lines: $(grep -cE ':(err|warn):' "$OUT")  (log: $OUT)"
