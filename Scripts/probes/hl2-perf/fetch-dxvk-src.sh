#!/bin/zsh
# Fetch the DXVK sources that define D3D9 device requirements (for the MoltenVK shim design).
set -eu
V="${1:-3.1.1}"
D="/tmp/dl/dxvk-src-$V"
mkdir -p "$D"
for f in src/d3d9/d3d9_device.cpp src/dxvk/dxvk_adapter.cpp src/dxvk/dxvk_device_info.h src/d3d9/d3d9_adapter.cpp src/dxvk/dxvk_extensions.h; do
  out="$D/$(basename "$f")"
  [[ -s "$out" ]] || curl -sSL -o "$out" "https://raw.githubusercontent.com/doitsujin/dxvk/v$V/$f"
  printf '%-28s %6s lines\n' "$(basename "$f")" "$(wc -l < "$out" | tr -d ' ')"
done
echo '--- D3D9DeviceEx::GetDeviceFeatures body:'
awk '/D3D9DeviceEx::GetDeviceFeatures/{p=1} p{print} p&&/^  }/{exit}' "$D/d3d9_device.cpp" | grep -vE '^\s*$' | head -120
