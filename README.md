# Meridian

Native macOS app for running Windows Steam games through Wine + DXMT (Direct3D to Metal).

## How It Works

1. **Sign in with Steam** via OpenID (`ASWebAuthenticationSession`), no Steam password stored by Meridian.
2. **Fetch library metadata** from Steam Web API (`IPlayerService/GetOwnedGames`).
3. **Launch games through Wine** — DirectX calls are translated to Metal via DXMT.
4. **Steam runs silently** in the background inside a Wine prefix. User authenticates once through the Steam window, then all future launches are automatic (JWT cached for months).
5. **Games render natively** through Metal — no VM, no virtual display.

## Architecture

```
MeridianApp (SwiftUI)
├── Steam/           — OpenID auth, Web API, library sync, session bridge
├── Engine/          — Wine detection, prefix management, Steam lifecycle
├── Launch/          — Game launch orchestration
├── Models/          — Game, AppSettings, PlayerSummary, AppDetails
├── Views/           — Library, game detail, settings, auth, engine setup
└── Utilities/       — MeridianLog (file + console logging)
```

### Translation Stack

```
Windows Game (.exe)
    → Wine 11 (Win32 API translation)
        → DXMT (DirectX 11 → Metal, direct path)
            → Metal GPU (native rendering)
```

## Wine Backend

**Meridian is fully standalone — no CrossOver required.** The only supported runtime is the open-source Wine engine downloaded from Meridian's GitHub releases into Application Support.

**Engine install location:** `~/Library/Application Support/com.meridian.app/engine/`

Downloaded automatically on first launch, or manually via Settings → Engine. `WineEngine.detect()` validates that `wine64`, `wineserver`, and required NLS data files are all present. If any are missing, the bootstrap pipeline auto-downloads a fresh engine.

### Engine quality (maintainers)

When **you** run `Scripts/release-engine.sh`, it packages Wine from either **CrossOver.app** on your Mac (if installed, provides Wine 11+) or the **Gcenx** `wine-crossover` cask. That only affects what goes into the `.tar.gz` you upload — **end users never install CrossOver; they just download the engine tarball.**

### All Components Are Open Source

| Component | License | Source |
|-----------|---------|--------|
| Wine 11 | LGPL | [winehq.org](https://www.winehq.org/) |
| DXMT | Open source | [github.com/nicbarker/dxmt](https://github.com/nicbarker/dxmt) |
| DXVK | Zlib | [github.com/doitsujin/dxvk](https://github.com/doitsujin/dxvk) |
| MoltenVK | Apache 2.0 | [github.com/KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) |

## Game Launch Flow

1. User clicks **Play** in the library
2. Meridian validates the Wine engine is ready (`WineEngine.isReady`)
3. Creates or reuses Wine prefix (`~/Library/Application Support/com.meridian.app/bottles/steam/`)
4. Bootstraps Steam client if first run (downloads `steamui.dll`)
5. Copies macOS Steam session files for account hint
6. Launches `steam.exe -silent -applaunch <APPID>` through Wine
7. DXMT translates DirectX → Metal for game rendering
8. Monitors Wine processes for game exit

## Requirements

- macOS 15+ (macOS 26 recommended)
- Apple Silicon Mac
- **No paid CrossOver required** — Meridian downloads the Wine engine on first run (or from Settings → Engine)
- Steam Web API key: [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey)

## First-Time Setup

1. Open `Meridian.xcodeproj` in Xcode, set your Team, build and run
2. If prompted, download the Wine engine (Settings → Engine) — one-time, open-source runtime
3. Sign in with Steam and provide your API key
4. Click **Play** on any game — Steam will prompt for login on first launch
5. After authenticating once, all future launches are silent

## Application Support Layout

All Meridian data lives under `~/Library/Application Support/com.meridian.app/`:

```
com.meridian.app/
├── engine/                    — Wine runtime (wine64, wineserver, DXMT, NLS data)
│   └── wine/
│       ├── bin/               — wine64, wineserver executables
│       ├── lib/               — Wine libraries, DXMT/DXVK DLLs
│       └── share/             — NLS tables, registry files
│           └── wine/meridian-engine-version.txt   — installed engine tag (e.g. v1.0.3-engine)
├── bottles/
│   └── steam/                 — Wine prefix (virtual Windows environment)
│       ├── drive_c/
│       │   └── Program Files/Steam/              — Steam installation
│       ├── system.reg         — Windows registry
│       └── user.reg           — User registry
└── logs/
    ├── meridian.log           — Current session log (plain text, timestamped)
    └── meridian-previous.log  — Previous session log (rotated at each launch)
```

## Logging

Meridian writes structured logs to plain text files in addition to the Xcode console. This enables debugging without Xcode attached.

### Log Files

| File | Path |
|------|------|
| **Current session** | `~/Library/Application Support/com.meridian.app/logs/meridian.log` |
| **Previous session** | `~/Library/Application Support/com.meridian.app/logs/meridian-previous.log` |

Logs rotate at every launch: the previous `meridian.log` becomes `meridian-previous.log`. Files are flushed after every write so they survive crashes.

### Reading Logs

**In Settings:** Settings → Updates → Diagnostics → "Open Log" button opens `meridian.log` in your default text editor.

**In Terminal:**
```bash
# Tail the live log while the app runs
tail -f ~/Library/Application\ Support/com.meridian.app/logs/meridian.log

# Show only errors and warnings
grep -E "ERROR|WARN" ~/Library/Application\ Support/com.meridian.app/logs/meridian.log

# Debug Steam startup failures
grep -E "healthMonitor|waitUntilReady|BOOTSTRAP" ~/Library/Application\ Support/com.meridian.app/logs/meridian.log
```

### Log Format

```
2026-03-27 14:32:05 CDT  [INFO]  [WineSteamManager] [startPersistent] pid=47788
2026-03-27 14:32:06 CDT  [WARN]  [BootstrapManager] [bootstrap] Steam failed to start
2026-03-27 14:32:06 CDT  [ERROR] [WineSteamManager] [healthMonitor] Steam died — uptime=4s exitCode=1 reason=normal-exit retry=1/5
```

Format: `<ISO-8601 timestamp>  [LEVEL]  [Category] <message>`

Each log begins with a startup header:
```
================================================================================
Meridian v1.0.3 (Build 42)  —  started 2026-03-27 14:32:05 CDT
macOS 15.4.0 | arm64
Application Support: /Users/nick/Library/Application Support/com.meridian.app/
================================================================================
```

### Implementation

`Meridian/Utilities/MeridianLog.swift` — `MeridianLog` struct wraps `os.Logger` and `LogFileWriter` singleton. All 16 engine/app/Steam/launch source files use `MeridianLog(category:)` as their module-level `log`.

## Updates

Meridian uses a **unified update model**: one Meridian release = one app version + one Wine engine snapshot. Users never manage app and engine updates separately.

### How updates work

Settings → Updates shows the current Meridian version, installed engine tag, and a "Check for Updates" button. When a newer release is found on GitHub:
- **App update**: downloads the `.dmg`, mounts it, replaces the running `.app`, and relaunches automatically.
- **Engine update**: downloads the `.tar.gz` archive directly in-app and extracts it to Application Support.

On every app launch, Meridian silently checks whether the app version changed since the last run. If it has, it automatically downloads the latest engine in the background so the next session always uses the freshest Wine build.

### Developer release workflow

```bash
# 1. Update Wine locally (brew update wine-crossover, or use CrossOver.app)

# 2. Package and publish the new engine snapshot to GitHub Releases
bash Scripts/release-engine.sh           # auto-increments patch version
# or with explicit version:
bash Scripts/release-engine.sh v2.1.0   # publishes v2.1.0-engine tag

# 3. Bump MARKETING_VERSION in Xcode (Build Settings → Versioning)
#    This is the version users see in Settings → Updates

# 4. Build, sign, notarize, then publish the .dmg to GitHub Releases
#    Tag: v2.1.0  (no -engine suffix — the update checker filters by this)
```

`release-engine.sh` embeds `wine/meridian-engine-version.txt` in the archive containing the release tag. The app reads this file to display the installed engine version in Settings → Updates.

### GitHub Release Tags

| Tag format | Example | Purpose |
|------------|---------|---------|
| `vX.Y.Z` | `v1.0.3` | App release — triggers in-app DMG update |
| `vX.Y.Z-engine` | `v1.0.3-engine` | Engine release — triggers in-app engine download |

The update checker distinguishes them by the `-engine` suffix.

### Key update files

| File | Role |
|------|------|
| `Meridian/Engine/AppUpdateChecker.swift` | GitHub Releases API checker, rate-limited (24h), `@Observable` |
| `Meridian/Engine/EngineDownloader.swift` | Downloads and extracts engine archives |
| `Meridian/Views/Settings/SettingsView.swift` | Updates tab UI, diagnostics section |
| `Scripts/release-engine.sh` | Developer script — packages Wine and publishes engine release |

## Settings

| Setting | Description |
|---------|-------------|
| Metal HUD | Show GPU performance overlay |
| Virtual Desktop | Force fixed-resolution Wine desktop |

## Known Limitations

- **Anti-cheat**: EasyAntiCheat and BattlEye block Wine on macOS
- **Denuvo DRM**: Poor compatibility under Wine
- **First login**: Requires one-time Steam authentication through the Wine window
- **Per-game tuning**: Some games need specific DLL overrides or renderer settings
- **Rendering**: DXMT handles most DX11 games well; some titles may have visual artifacts
