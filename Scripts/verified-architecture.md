# Meridian Verified Architecture

Canonical inventory of what has been confirmed working by the user through
in-app testing. Everything in this file is the stable foundation for the
steam-backend rewrite. Do not remove or re-solve these.

---

## Engine Packaging (`Scripts/release-engine.sh`)

CX Wine 11.4 + DXMT + GPTK + DXVK assembled into a self-contained tarball
on GitHub Releases. Verified working:

- CX Wine 11.4 binary from CrossOver Preview (LGPL). Has `ntdll.__wine_unix_call`
  required by GPTK d3d12.dll and dxgi.dll. Zero win32u abort stubs.
- DXMT (DirectX 11 → Metal via wiremetal.so). Builtin layout — DLLs live in
  `lib/wine/x86_64-windows/` alongside Wine's own DLLs. No WINEDLLPATH needed.
- GPTK (D3D12 → D3DMetal.framework → Metal). Via `lib/gptk/external/`.
- DXVK (DirectX 9/10/11 → Vulkan fallback). In `lib/dxvk/x86_64-windows/`.
- VKD3D-proton present but NOT usable on Apple Silicon (missing
  VK_EXT_transform_feedback in MoltenVK). Wine's integrated vkd3d works.
- lib64 on DYLD_FALLBACK_LIBRARY_PATH required: secur32.so needs libgnutls
  for all Wine TLS (Steam CDN downloads). See Pattern 5 in engine-research-findings.

Custom DLL stubs built with mingw-w64:
- `Scripts/coremessaging/` — `Windows.System.DispatcherQueue` factory stub
  for Unity 6.3+ games. Registered via `WinePrefix.registerWinRTClasses`.
- `Scripts/d3d12-bridge/` — GPTK D3D12 adapter bridge.
- `Scripts/dpapi/` — DPAPI helper (no longer in primary auth path; kept for
  reference and possible prefix-session restore).

---

## Engine Download (`Meridian/Engine/EngineDownloader.swift`)

- Downloads engine tarball from GitHub Releases via URLSession.
- Strips `com.apple.quarantine` immediately after extraction (Pattern 5:
  quarantined Wine binaries have restricted network access on macOS 26).
- `lastPrefixEngineModTime` in AppSettings detects same-tag republishes.
- Verified working end-to-end.

---

## Wine Prefix (`Meridian/Engine/WinePrefix.swift`)

All of the following have been verified working and must be preserved:

- `wineboot --init` prefix creation
- Core Windows service registration (`nsiproxy`, `RpcSs`, `EventLog`, `PlugPlay`)
  via `ensureCoreServices(engine:)` — Pattern 7 fix for WebUITransport
- WoW64 crypto provider types (Pattern 11): `writeSteamInstallPathRegistryKeys`
  writes `HKLM\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Defaults\Provider Types`.
  Without these, 32-bit DLLs that call `CryptAcquireContextA` in DllMain crash.
  Fixed HL2 Anniversary Edition `filesystem_stdio.dll` crash.
- ssfn token detection via `hasSsfnToken`
- `writeLoginUsers(steamID:accountName:personaName:)` — writes loginusers.vdf
  with `RememberPassword=1` and `AllowAutoLogin=1`. MUST be called before
  steam.exe -login so Steam sends should_remember_password=true to Valve,
  causing Valve to return persistence=1 and steam.exe to write an ssfn token.
- Library folders, ACF parsing, install detection, download progress tracking
- ssfn preservation across `resetToEngineTemplate` (Pattern 10)
- Versioned one-time setup: `winRTRegistrationAppliedVersion`,
  `steamInstallPathRegistrationVersion`, `windowsVersionAppliedVersion`

---

## Native Steam Client Bootstrap (`Meridian/Engine/SteamClientBootstrap.swift`)

- Downloads Steam client packages directly via URLSession (macOS TLS, not Wine TLS).
- Bypasses steam.exe's 32-bit bootstrapper which fails TLS on macOS 26.
- Uses Python zipfile for extraction (handles 20-byte Valve header + backslash paths).
- Downloads both `steam_client_win32` and `steam_cmd_win32` manifests.
- Must write `BootStrapperInhibitAll=enable` to steam.cfg ONLY after steamui.dll exists.
- Verified reliable. Do not replace with Wine-based bootstrap.

---

## Per-Game Compatibility (User-Verified)

All of these have been confirmed by the user running the game to the main menu
or beyond. See `GameCompatibilityDB+*.swift` for the code.

| Game | AppID | API | Notes |
|------|-------|-----|-------|
| No, I'm Not a Human | 3180070 | DX11 | DXMT. Verified. |
| Animal Well | 813230 | DX12 | Wine integrated vkd3d → MoltenVK. Steam DRM. Verified. |
| Half-Life 2 (Anniversary) | 220 | DX9 | Source Engine 32-bit. WoW64 crypto fix required. Steam DRM. Verified. |
| Portal 2 | 620 | DX9 | Source Engine 32-bit. Steam DRM. Verified. |

---

## Steam Web API (`Meridian/Steam/SteamAPIService.swift`)

- Library sync, app details, player summary, achievements — all working.
- Requires a Steam Web API key from the user.

---

## Process Cleanup (`Meridian/Engine/TerminationCleanup.swift`)

- Multi-sweep pkill: by engine path, then by Windows argv[0] names.
- `wineserver -k` with correct WINEPREFIX is the primary shutdown signal.
- Stale `/tmp/.wine-<uid>/server-*` socket cleanup prevents wineserver conflicts.
- Do not modify this. It works.

---

## What Was Deleted in the Rewrite (steam-backend-rewrite, May 2026)

The following files were **deleted** because they represented a tangled
state model where four different objects each tried to own steam.exe:

- `Meridian/Engine/WineSteamManager.swift` (1,671 lines)
- `Meridian/Engine/SteamWindowSuppressor.swift` (~700 lines)
- `Meridian/Steam/SteamExeSignIn.swift` (423 lines)
- `Meridian/Launch/GameLauncher.swift` (860 lines)

Replaced by:
- `Meridian/Steam/SteamSession.swift` — single owner of steam.exe lifecycle
- `Meridian/Steam/SteamWindow.swift` — window suppression, simple AX + timer
- `Meridian/Launch/Launcher.swift` — game launch + install, no Steam lifecycle
