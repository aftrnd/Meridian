# HL2 performance probes (2026-09-16/17)

Research tooling from the HL2 / Apple Silicon performance program. Everything here
was run by hand against the live engine and prefix; nothing is wired into the app.
Full narrative: `docs/HL2-PERFORMANCE.md` (gitignored) and
`.cursor/rules/engine-research-findings.mdc` Patterns 26–30.

| File | Purpose |
|---|---|
| `hl2probe.sh <gl\|dxvk\|vulkan> [hl2 args]` | Launches HL2 with Meridian's exact game env. `dxvk` = `CX_GRAPHICS_BACKEND=dxvk`; `vulkan` = Valve `-vulkan`. Honours `MP_DYLIB` (DYLD_INSERT_LIBRARIES), `WINE_BIN`, `WINEDEBUG`. Log: `/tmp/hl2probe-<variant>.log`. |
| `dx11probe.sh <default\|dxmt>` | Launches Big Walk (64-bit Unity DX11) and `lsof`s which d3d11 actually mapped. Proved WINEDLLPATH never selected DXMT. |
| `fpsread.sh <label> [ENV=..] -- [args]` | GL run with `cl_showfps 2`, captures the counter 3× via `screencapture -l`. Only works for NON-captured displays. |
| `winlist.swift` | `CGWindowListCopyWindowInfo` dump → window IDs for `screencapture -l`. Captured (exclusive) displays are NOT listed. |
| `mousewiggle.swift <cx> <cy> <n>` | Posts HID-level mouse-moved events (CGEvent) for input-path tracing with `WINEDEBUG=+cursor,+rawinput`. |
| `meridian_mouse_probe.m` | DYLD-injected ObjC probe: `MERIDIAN_MP_CLIP` (force winemac clipping/relative mode via `startClippingCursor:`), `MERIDIAN_MP_NOCOALESCE`, `MERIDIAN_MP_DISASSOC`. Not needed after Pattern 28. |
| `meridian_game_bundle.c` | DYLD-injected execve/execv/posix_spawn interposer that redirects CX's `winetemp-*` loader copy into a generated `<Name>.app` (games category) and re-signs it. Works for the intermediate hops; the final `hl2.exe` hop is un-interposable (Pattern 30). |
| `gmprobe.swift` + `gmprobe-Info.plist` | Minimal fullscreen AppKit app proving Game Mode engages only for an executable inside an .app (embedded `__info_plist` alone is not enough). |
| `meridian-game-wrapper.sh` | The `Meridian Game.app` launcher script used to test LaunchServices-launched Wine. |

Build snippets:
```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swiftc -O winlist.swift -o winlist
clang -dynamiclib -arch x86_64 -arch arm64 -framework AppKit -fobjc-arc -O2 -o meridian_mouse_probe.dylib meridian_mouse_probe.m && codesign -fs - meridian_mouse_probe.dylib
clang -dynamiclib -arch x86_64 -arch arm64 -O2 -o meridian_game_bundle.dylib meridian_game_bundle.c && codesign -fs - meridian_game_bundle.dylib
swiftc -O gmprobe.swift -o gmprobe -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker gmprobe-Info.plist
```
