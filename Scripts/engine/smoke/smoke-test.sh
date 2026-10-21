#!/usr/bin/env bash
#
# smoke-test.sh — headless checks of a staged or installed engine.
#
# Usage: bash Scripts/engine/smoke/smoke-test.sh [engine-dir]
#   engine-dir defaults to $BUILD_ROOT/stage (contains wine/ and prefix-template/).
#
# Runs in a throwaway copy of the engine's prefix template, never the user's
# Meridian bottle.
#   1. D3D11 device through DXMT and wined3d (64- and 32-bit), headless
#   2. D3D11 swap chain presenting 60 frames in a small window through the Mac
#      driver (DXMT's winemetal → winemac), with a pixel read-back
#   3. HTTPS through WinHTTP  (GnuTLS chain Steam networking depends on)
#   4. D3D9 drawing a sampled texture: wined3d, and on macOS 26+ DXVK through
#      the Vulkan loader and KosmicKrisp (64- and 32-bit), with a read-back

source "$(dirname "$0")/../env.sh"

ENGINE="${1:-$STAGE}"
W="$ENGINE/wine"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$WORK/smoke"
P="$WORK/smoke-prefix"
TIMEOUT="$(command -v gtimeout || command -v timeout)" || die "brew install coreutils (gtimeout)"

[ -x "$W/bin/wine64" ] || die "no engine at $ENGINE"

mkdir -p "$OUT"
x86_64-w64-mingw32-gcc -O2 -o "$OUT/d3d11probe64.exe" "$HERE/d3d11probe.c" -ld3d11 -ldxgi -luuid
i686-w64-mingw32-gcc   -O2 -o "$OUT/d3d11probe32.exe" "$HERE/d3d11probe.c" -ld3d11 -ldxgi -luuid
x86_64-w64-mingw32-gcc -O2 -o "$OUT/presentprobe64.exe" "$HERE/presentprobe.c" -ld3d11 -ldxgi -luuid -lgdi32
i686-w64-mingw32-gcc   -O2 -o "$OUT/presentprobe32.exe" "$HERE/presentprobe.c" -ld3d11 -ldxgi -luuid -lgdi32
x86_64-w64-mingw32-gcc -O2 -municode -o "$OUT/tlsprobe64.exe" "$HERE/tlsprobe.c" -lwinhttp
x86_64-w64-mingw32-gcc -O2 -o "$OUT/d3d9probe64.exe" "$HERE/d3d9probe.c" -ld3d9 -lgdi32 -luser32
i686-w64-mingw32-gcc   -O2 -o "$OUT/d3d9probe32.exe" "$HERE/d3d9probe.c" -ld3d9 -lgdi32 -luser32

rm -rf "$P"; cp -R "$ENGINE/prefix-template" "$P"
ln -sfn ../drive_c "$P/dosdevices/c:"
ln -sfn / "$P/dosdevices/z:"

FAILED=0
# run <renderer-dir> <exe> <expect-regex>...  (every regex must match; RUN_ENV
# adds variables for one run)
RUN_ENV=()
run() {
    local dir="$1" exe="$2" out re ok=1
    shift 2
    out=$(cd "$P" && env -i HOME="$HOME" PATH=/usr/bin:/bin WINEPREFIX="$P" WINEDEBUG=-all \
        WINEMSYNC=1 MVK_CONFIG_LOG_LEVEL=0 \
        WINEDLLPATH="$W/lib/$dir:$W/lib/wined3d:$W/lib/wine" \
        WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3d10core=n,b;mscoree,mshtml=" \
        ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
        "$TIMEOUT" 90 "$W/bin/wine64" "Z:$OUT/$exe" 2>&1) || true
    for re in "$@"; do grep -qE "$re" <<<"$out" || ok=0; done
    if [ "$ok" -eq 1 ]; then
        printf '  \033[1;32mPASS\033[0m %-9s %s\n' "$dir" "$exe"
    else
        printf '  \033[1;31mFAIL\033[0m %-9s %s\n%s\n' "$dir" "$exe" "$out"
        FAILED=1
    fi
}

say "Smoke-testing $(cat "$W/meridian-engine-version.txt" 2>/dev/null || echo engine) at $ENGINE"
# DXMT announces itself and offers feature level 11_x; wined3d tops out lower.
run dxmt    d3d11probe64.exe 'feature level: 0xb'
run dxmt    d3d11probe32.exe 'feature level: 0xb'
run wined3d d3d11probe64.exe 'adapter: '
run wined3d d3d11probe32.exe 'adapter: '
run dxmt    presentprobe64.exe 'presented 60/60 frames, pixel=0xffff..00'
run dxmt    presentprobe32.exe 'presented 60/60 frames, pixel=0xffff..00'
run wined3d presentprobe64.exe 'presented 60/60 frames, pixel=0xffff..00'
run wined3d tlsprobe64.exe   'HTTP [23][0-9][0-9]'
# wined3d answers as its stand-in GeForce; DXVK as a Radeon. KosmicKrisp runs
# on Metal 4, so the DXVK path exists only on macOS 26 and later.
run wined3d d3d9probe64.exe 'GeForce' 'RESULT PASS'
run wined3d d3d9probe32.exe 'GeForce' 'RESULT PASS'
if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]; then
    RUN_ENV=(WINE_VULKAN_LIBRARY="$W/lib64/libvulkan.1.dylib" VK_DRIVER_FILES="$W/lib64/kosmickrisp_icd.json")
    run dxvk d3d9probe64.exe 'Radeon' 'RESULT PASS'
    run dxvk d3d9probe32.exe 'Radeon' 'RESULT PASS'
    RUN_ENV=()
fi

env WINEPREFIX="$P" "$W/bin/wineserver" -k 2>/dev/null || true
[ "$FAILED" -eq 0 ] || die "smoke test failed"
say "All smoke tests passed"
