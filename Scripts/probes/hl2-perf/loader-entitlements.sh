#!/bin/zsh
# Give CX Wine's REAL loader (lib/wine/x86_64-unix/wine) the allow-dyld entitlement.
#
# Meridian's ensureDyld re-signs only the bin/wine64 stub. The stub posix_spawns
# lib/wine/x86_64-unix/wine, which is hardened-runtime WITHOUT
# com.apple.security.cs.allow-dyld-environment-variables, so dyld drops
# DYLD_INSERT_LIBRARIES there and in every Wine process it spawns. Verified
# 2026-09-17: meridian_mouse_probe logged only from the stub pid; no injected
# dylib has ever reached a Wine GUI process.
#
# Usage: loader-entitlements.sh apply|revert|status   (GM_LIVE=1 for the real engine, else /tmp/engine-gm)
#        loader-entitlements.sh emit <binary> <out.plist>   (write augmented entitlements; used by gamemode-bundle.sh)
set -eu
APP="$HOME/Library/Application Support/com.meridian.app"
if [[ "${GM_LIVE:-0}" == 1 ]]; then ENGINE="$APP/engine/wine"; else ENGINE=/tmp/engine-gm; fi
LOADER="$ENGINE/lib/wine/x86_64-unix/wine"
BACKUP="$LOADER.pre-entitlements"
KEY=com.apple.security.cs.allow-dyld-environment-variables

emit() {
  local bin="$1" out="$2"
  codesign -d --entitlements :- "$bin" 2>/dev/null > "$out.orig" || true
  python3 - "$out.orig" "$out" <<'PY'
import plistlib, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read()
try:
    ents = plistlib.loads(raw) if raw.strip() else {}
except Exception:
    ents = {}
ents["com.apple.security.cs.allow-dyld-environment-variables"] = True
ents.setdefault("com.apple.security.cs.allow-unsigned-executable-memory", True)
ents.setdefault("com.apple.security.cs.disable-library-validation", True)
with open(dst, "wb") as f:
    plistlib.dump(ents, f)
print("entitlements:", ", ".join(k.rsplit(".", 1)[-1] for k in sorted(ents)))
PY
  rm -f "$out.orig"
}

case "${1:-status}" in
emit) emit "$2" "$3" ;;
apply)
  [[ -f "$BACKUP" ]] || cp -p "$LOADER" "$BACKUP"
  tmp=$(mktemp /tmp/loader-ents.XXXXXX.plist)
  emit "$LOADER" "$tmp"
  # team-identifier must NOT be preserved with an ad-hoc signature (kernel SIGKILLs the contradiction).
  codesign --force --sign - --entitlements "$tmp" --preserve-metadata=flags,runtime "$LOADER" 2>&1 | grep -v 'replacing existing' || true
  rm -f "$tmp"
  codesign -d --entitlements :- "$LOADER" 2>/dev/null | grep -c "$KEY" | sed 's/^/allow-dyld present: /'
  ;;
revert)
  if [[ -f "$BACKUP" ]]; then cp -p "$BACKUP" "$LOADER" && rm -f "$BACKUP" && echo "restored $LOADER"; else echo "no backup — nothing to revert"; fi
  ;;
status)
  codesign -dv "$LOADER" 2>&1 | grep -E '^(Identifier|Authority|Signature)' | head -2
  codesign -d --entitlements :- "$LOADER" 2>/dev/null | grep -q "$KEY" && echo "allow-dyld: yes" || echo "allow-dyld: NO"
  ;;
*) echo "usage: $0 apply|revert|status | emit <binary> <out.plist>"; exit 2 ;;
esac
