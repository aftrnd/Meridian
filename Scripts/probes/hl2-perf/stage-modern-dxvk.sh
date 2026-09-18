#!/bin/zsh
# Stage upstream DXVK release DLLs + MoltenVK dylib into an APFS clone of the engine.
# Usage: stage-modern-dxvk.sh <dxvk-version|none> [mvk|shim|cxmvk]
#   dxvk-version: 3.1.1 | 2.7.1 | 2.6.2 | none (keep CX DXVK 1.10.3)
#   mvk (default): upstream MoltenVK 1.4.2 in lib64/libMoltenVK.dylib; cxmvk: keep CX MoltenVK
#   shim: upstream 1.4.2 renamed libMoltenVK.real.dylib behind mvkshim.c (advertises geometryShader)
# Clone lives at /tmp/engine-gm (cp -Rc = clonefile, zero extra space). Never touches the real engine.
set -eu
DXVK="${1:-3.1.1}"; MVK="${2:-mvk}"
E="$HOME/Library/Application Support/com.meridian.app/engine/wine"
CLONE=/tmp/engine-gm
DL=/tmp/dl
mkdir -p "$DL"

if [[ ! -d "$CLONE" ]]; then
  cp -Rc "$E" "$CLONE"
  echo "cloned engine → $CLONE ($(du -sh "$CLONE" | cut -f1))"
fi

fetch() { local u="$1" f="$DL/${1##*/}"; [[ -s "$f" ]] || curl -sSL -o "$f" "$u"; echo "$f"; }

if [[ "$DXVK" != none ]]; then
  if [[ "$DXVK" == gcenx ]]; then
    # Gcenx/DXVK-macOS 1.10.3 repack: resolve the asset URL from the GitHub API.
    url=$(curl -sSL https://api.github.com/repos/Gcenx/DXVK-macOS/releases/tags/v1.10.3-20230507-repack | grep -oE '"browser_download_url": *"[^"]+\.tar\.gz"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
    [[ -n "$url" ]] || { echo "could not resolve Gcenx asset URL"; exit 3; }
    tgz=$(fetch "$url")
  else
    tgz=$(fetch "https://github.com/doitsujin/dxvk/releases/download/v$DXVK/dxvk-$DXVK.tar.gz")
  fi
  dir="$DL/dxvk-$DXVK"
  if [[ ! -f "$dir/x64/d3d9.dll" ]]; then
    mkdir -p "$dir" && tar -xzf "$tgz" -C "$dir" --strip-components=1
  fi
  rm -rf "$CLONE/lib/dxvk"
  mkdir -p "$CLONE/lib/dxvk/x86_64-windows" "$CLONE/lib/dxvk/i386-windows"
  cp "$dir"/x64/*.dll "$CLONE/lib/dxvk/x86_64-windows/"
  cp "$dir"/x32/*.dll "$CLONE/lib/dxvk/i386-windows/"
  # Wine only loads DLLs from builtin dirs if the DOS stub carries the builtin
  # signature at offset 0x40 (what `winebuild --builtin` writes); upstream
  # release DLLs lack it and are silently skipped ("not a builtin, ignoring").
  python3 - "$CLONE"/lib/dxvk/*/*.dll <<'PY'
import struct, sys
for p in sys.argv[1:]:
    d = bytearray(open(p, "rb").read())
    e_lfanew = struct.unpack_from("<I", d, 0x3C)[0]
    assert e_lfanew >= 0x40 + 32, p
    d[0x40:0x40 + 17] = b"Wine builtin DLL\0"
    open(p, "wb").write(d)
PY
  echo "staged DXVK $DXVK (builtin-marked): $(ls "$CLONE/lib/dxvk/x86_64-windows" | tr '\n' ' ')"
fi

rm -f "$CLONE/lib64/libMoltenVK.real.dylib"
if [[ "$MVK" == mvk || "$MVK" == shim ]]; then
  tar=$(fetch "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar")
  if [[ ! -d "$DL/mvk" ]]; then mkdir -p "$DL/mvk" && tar -xf "$tar" -C "$DL/mvk"; fi
  dylib=$(find "$DL/mvk" -path '*macOS*' -name 'libMoltenVK.dylib' | head -1)
  [[ -n "$dylib" ]] || { echo "MoltenVK dylib not found in $DL/mvk"; exit 3; }
  if [[ "$MVK" == shim ]]; then
    cp "$dylib" "$CLONE/lib64/libMoltenVK.real.dylib"
    src="$(cd "$(dirname "$0")" && pwd)/mvkshim.c"
    clang -dynamiclib -arch x86_64 -arch arm64 -O2 -I"$DL/mvk/MoltenVK/MoltenVK/include" -o "$CLONE/lib64/libMoltenVK.dylib" "$src"
    codesign -fs - "$CLONE/lib64/libMoltenVK.dylib"
    echo "staged MoltenVK 1.4.2 behind mvkshim ($(lipo -archs "$CLONE/lib64/libMoltenVK.dylib"))"
  else
    cp "$dylib" "$CLONE/lib64/libMoltenVK.dylib"
    echo "staged MoltenVK: $(lipo -archs "$CLONE/lib64/libMoltenVK.dylib") $(strings "$CLONE/lib64/libMoltenVK.dylib" | grep -oE 'MoltenVK [0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  fi
else
  cp "$E/lib64/libMoltenVK.dylib" "$CLONE/lib64/libMoltenVK.dylib"
  echo "restored CX MoltenVK"
fi
