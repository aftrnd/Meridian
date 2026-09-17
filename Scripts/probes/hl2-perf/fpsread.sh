#!/bin/zsh
# fpsread.sh <label> [env assignments...] -- [extra hl2 args]
# Launches HL2 via hl2probe.sh gl with cl_showfps, samples the FPS corner 3x, kills the game.
set -u
LABEL="$1"; shift
ENVS=()
while [[ $# -gt 0 && "$1" != "--" ]]; do ENVS+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift
pkill -f hl2.exe 2>/dev/null; sleep 2
rm -f /tmp/hl2probe-gl.log
( env "${ENVS[@]}" WINEDEBUG=-all /tmp/hl2probe.sh gl -windowed -w 1280 -h 800 +map d1_trainstation_01 +fps_max 0 +cl_showfps 2 "$@" & )
sleep 75
WID=$(/tmp/winlist | grep "hl2.exe" | cut -f1)
[[ -n "$WID" ]] && osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$(pgrep -f 'hl2.exe -game' | tail -1)"') to true' 2>/dev/null
sleep 4
for i in 1 2 3; do
  screencapture -x -l$WID /tmp/fps-$LABEL-$i.png
  sips -c 160 1000 --cropOffset 60 1720 /tmp/fps-$LABEL-$i.png --out /tmp/fps-$LABEL-$i-crop.png >/dev/null 2>&1
  sips -Z 800 /tmp/fps-$LABEL-$i-crop.png --out /tmp/fps-$LABEL-$i-crop-s.png >/dev/null 2>&1
  sleep 3
done
PID=$(pgrep -f "hl2.exe -game" | tail -1)
ps -o %cpu,rss -p $PID | tail -1
pkill -f hl2.exe
echo "done $LABEL"
