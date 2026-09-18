#!/bin/zsh
# Game Mode identity experiment (Pattern 30 follow-up). Uses the /tmp/engine-gm clone only.
#
# Idea: CX Wine execs every Windows process from a hard-link dir whose name is
# deterministic — winetemp-<ino>-<size>-<mtime_s>-<mtime_ns> of lib/wine/x86_64-unix/wine.
# If Meridian pre-creates that dir as a SYMLINK into <Bundle>.app/Contents/MacOS, the
# kernel's executable path for hl2.exe resolves inside a bundle, which is the one thing
# gamepolicyd requires. The loader's embedded __info_plist must be byte-identical to
# the bundle's Contents/Info.plist (code signature seals it) AND carry the games category,
# so we rewrite the plist inside its fixed-size __TEXT,__info_plist section and re-sign
# the clone's loader ad hoc, preserving entitlements.
#
# Usage: gamemode-bundle.sh prepare   # patch loader, build bundle, place symlink (backs up the loader first)
#        gamemode-bundle.sh run       # run d3d9probe (GL, hidden) through the engine
#        gamemode-bundle.sh check     # gamepolicyd / runningboard identity since the last run/prepare
#        gamemode-bundle.sh revert    # restore the original loader, remove bundle + symlink
#
# Targets the /tmp/engine-gm clone by default. GM_LIVE=1 targets the REAL engine at
# ~/Library/Application Support/com.meridian.app/engine/wine (backup kept beside it as
# wine.cx-original; `revert` restores it). Every Wine process then runs from inside
# ~/Library/Application Support/com.meridian.app/games/Meridian Game.app.
set -eu
APP="$HOME/Library/Application Support/com.meridian.app"
if [[ "${GM_LIVE:-0}" == 1 ]]; then
  ENGINE="$APP/engine/wine"
  BUNDLE="$APP/games/Meridian Game.app"
else
  ENGINE=/tmp/engine-gm
  BUNDLE="/tmp/gamemode/Meridian Game.app"
fi
LOADER="$ENGINE/lib/wine/x86_64-unix/wine"
BACKUP="$LOADER.cx-original"
STATE="$(dirname "$BUNDLE")/.gamemode-last-run"
T="$(getconf DARWIN_USER_TEMP_DIR)"
cmd="${1:-prepare}"

winetemp_name() {
  python3 -c "import os,sys;s=os.stat(sys.argv[1]);print(f'winetemp-{s.st_ino}-{s.st_size}-{int(s.st_mtime)}-{s.st_mtime_ns%1000000000}')" "$LOADER"
}

case "$cmd" in
prepare)
  mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$(dirname "$STATE")"
  if [[ ! -f "$BACKUP" ]]; then cp -p "$LOADER" "$BACKUP"; echo "backed up loader -> $BACKUP"; fi
  cp -p "$BACKUP" "$LOADER"   # always patch from the pristine copy so prepare is idempotent
  if [[ -f /Applications/Meridian.app/Contents/Resources/AppIcon.icns ]]; then
    cp /Applications/Meridian.app/Contents/Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
  fi
  date '+%Y-%m-%d %H:%M:%S' > "$STATE"
  python3 - "$LOADER" "$BUNDLE/Contents/Info.plist" <<'PY'
import struct, sys, subprocess
loader, plist_out = sys.argv[1], sys.argv[2]
data = bytearray(open(loader, "rb").read())
# locate __TEXT,__info_plist via otool -l
out = subprocess.check_output(["otool", "-l", loader], text=True).splitlines()
off = size = None
for i, line in enumerate(out):
    if "sectname __info_plist" in line:
        for l in out[i:i+8]:
            if l.strip().startswith("size"): size = int(l.split()[1], 16)
            if l.strip().startswith("offset"): off = int(l.split()[1])
        break
assert off and size, "no __info_plist section"
new = b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>wineloader</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>com.meridian.game</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Meridian Game</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>11.10</string>
<key>CFBundleVersion</key><string>11.10</string>
<key>NSPrincipalClass</key><string>WineApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>GCSupportsGameMode</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
"""
assert len(new) <= size, f"plist {len(new)} bytes > section {size}"
new = new + b"\n" * (size - len(new))   # whitespace padding keeps the XML valid and the section size unchanged
data[off:off+size] = new
open(loader, "wb").write(data)
open(plist_out, "wb").write(new)
print(f"patched __info_plist: {len(new)} bytes at offset {off} (section {size})")
PY
  codesign --force --sign - --preserve-metadata=entitlements,flags,runtime --identifier com.meridian.game "$LOADER" 2>&1 | grep -v 'replacing existing' || true
  codesign -dv "$LOADER" 2>&1 | grep -E '^(Identifier|Signature|Info.plist)'
  plutil -lint "$BUNDLE/Contents/Info.plist"
  name=$(winetemp_name)
  echo "winetemp dir: $T/$name"
  if [[ -e "$T/$name" && ! -L "$T/$name" ]]; then rm -rf "$T/$name"; fi
  ln -sfn "$BUNDLE/Contents/MacOS" "$T/$name"
  ls -la "$T/$name"
  echo "Meridian launches now run inside: $BUNDLE"
  echo "After a fullscreen game session, check:  $0 check   (look for 'Game mode status is now on')"
  ;;
run)
  date '+%Y-%m-%d %H:%M:%S' > "$STATE"
  ENGINE="$ENGINE" "$(cd "$(dirname "$0")" && pwd)/d3d9probe.sh" gl 64 | grep -E 'ADAPTER|RESULT|exit='
  echo '--- bundle MacOS after run:'; ls -la "$BUNDLE/Contents/MacOS" | head -12
  ;;
check)
  since=$(cat "$STATE")
  echo "--- gamepolicyd since $since:"
  log show --start "$since" --style compact --predicate 'process == "gamepolicyd"' 2>/dev/null | grep -E 'Found game|Game mode status|Gaming session|gaming session|labelReason' | head -20
  echo "--- amfid / taskgated kills:"
  log show --start "$since" --style compact --predicate 'process == "taskgated" OR process == "amfid"' 2>/dev/null | grep -iE 'wine|Invalid|signature' | head -10
  ;;
revert)
  name=$(winetemp_name); rm -f "$T/$name"; echo "removed $T/$name"
  if [[ -f "$BACKUP" ]]; then cp -p "$BACKUP" "$LOADER" && rm -f "$BACKUP" && echo "restored original loader"; fi
  rm -rf "$BUNDLE"; echo "removed $BUNDLE"
  codesign -dv "$LOADER" 2>&1 | grep -E '^(Identifier|Authority)' | head -2
  ;;
*) echo "usage: $0 prepare|run|check|revert"; exit 2;;
esac
