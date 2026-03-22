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
└── Views/           — Library, game detail, settings, auth, engine setup
```

### Translation Stack

```
Windows Game (.exe)
    → Wine 11 (Win32 API translation)
        → DXMT (DirectX 11 → Metal, direct path)
            → Metal GPU (native rendering)
```

## Wine Backend

**Meridian is standalone.** Users do **not** need paid [CrossOver](https://www.codeweavers.com/crossover). The normal path is a one-time download of the open-source Wine engine from Meridian’s GitHub releases into Application Support.

Detection order (see `WineEngine.swift`):

1. **`~/Library/Application Support/com.meridian.app/engine/`** — **Primary.** Downloaded in-app (Settings → Engine). No third-party app required.
2. **`/Applications/CrossOver.app/`** — **Optional fallback** if someone already owns CrossOver and has not installed the Meridian engine yet.

### Engine quality (maintainers)

When **you** run `Scripts/release-engine.sh`, it prefers **CrossOver.app** on your Mac as the *packaging source* (newer Wine tree) if present, otherwise the **Gcenx** `wine-crossover` cask. That only affects what goes into the `.tar.gz` you upload — **end users still just download the engine; they never install CodeWeavers CrossOver.**

CrossOver 26 bundles **wine-11.0**; the Gcenx cask currently ships **wine-8.0.1**. Newer Wine helps Steam’s Chromium UI; that’s why maintainers often package from CrossOver when they have a license.

### All Components Are Open Source

| Component | License | Source |
|-----------|---------|--------|
| Wine 11 | LGPL | [winehq.org](https://www.winehq.org/) |
| DXMT | Open source | [github.com/nicbarker/dxmt](https://github.com/nicbarker/dxmt) |
| DXVK | Zlib | [github.com/doitsujin/dxvk](https://github.com/doitsujin/dxvk) |
| MoltenVK | Apache 2.0 | [github.com/KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) |

### Building Your Own Wine (Independence Path)

To remove the CrossOver dependency, build Wine 11+ from source:

```bash
# 1. Build Wine 11 from source (CrossOver's fork is at github.com/nicbarker/wine)
git clone https://github.com/nicbarker/wine.git
cd wine && ./configure --enable-archs=i386,x86_64 && make

# 2. Build DXMT (DirectX → Metal)
git clone https://github.com/nicbarker/dxmt.git
cd dxmt && meson build && ninja -C build

# 3. Build MoltenVK
git clone https://github.com/KhronosGroup/MoltenVK.git
cd MoltenVK && ./fetchDependencies --macos && make macos

# 4. Package into engine/ directory matching Meridian's expected layout
```

## Game Launch Flow

1. User clicks **Play** in the library
2. Meridian detects Wine backend (CrossOver or bundled)
3. Creates or reuses Wine prefix (`~/Library/Application Support/com.meridian.app/bottles/steam/`)
4. Bootstraps Steam client if first run (downloads steamui.dll)
5. Copies macOS Steam session files for account hint
6. Launches `steam.exe -silent -applaunch <APPID>` through Wine
7. DXMT translates DirectX → Metal for game rendering
8. Monitors Wine processes for game exit

## Requirements

- macOS 15+ (macOS 26 recommended)
- Apple Silicon Mac
- **No paid CrossOver required** — Meridian downloads the Wine engine on first run (or from Settings → Engine)
- *(Optional)* Paid CrossOver can be used as a fallback if the downloaded engine is not installed
- Steam Web API key: [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey)

## First-Time Setup

1. Open `Meridian.xcodeproj` in Xcode, set your Team, build and run
2. If prompted, download the Wine engine (Settings → Engine) — one-time, open-source runtime
3. Sign in with Steam and provide your API key
4. Click **Play** on any game — Steam will prompt for login on first launch
5. After authenticating once, all future launches are silent

## Wine Prefix

Single shared prefix for Steam and all games:

```
~/Library/Application Support/com.meridian.app/bottles/steam/
├── drive_c/               — Virtual C:\ drive
│   └── Program Files (x86)/Steam/  — Steam installation
├── system.reg             — Windows registry
└── user.reg               — User registry
```

## Known Limitations

- **Anti-cheat**: EasyAntiCheat and BattlEye block Wine on macOS
- **Denuvo DRM**: Poor compatibility under Wine
- **First login**: Requires one-time Steam authentication through the Wine window
- **Per-game tuning**: Some games need specific DLL overrides or renderer settings
- **Rendering**: DXMT handles most DX11 games well; some titles may have visual artifacts

## Updates

Meridian uses a **unified update model**: one Meridian release = one app version + one Wine engine snapshot. Users never manage app updates and engine updates separately.

### How updates work

Settings → Updates shows the current Meridian version, the installed engine release tag, and a "Check for Updates" button. When a newer release is found on GitHub, a banner appears with release notes and a "Download →" button that opens the release page in the browser.

On every app launch, Meridian silently checks whether the app version has changed since the last run. If it has, it automatically downloads the latest engine in the background — so the next session always uses the freshest Wine build.

### Developer release workflow

```bash
# 1. Update Wine/CrossOver locally (brew update wine-crossover, etc.)

# 2. Package and publish the new engine snapshot to GitHub Releases
bash Scripts/release-engine.sh           # auto-increments patch version
# or with explicit version:
bash Scripts/release-engine.sh v2.1.0   # publishes v2.1.0-engine tag

# 3. Bump MARKETING_VERSION in Xcode (Build Settings → Versioning)
#    This is the version users see in Settings → Updates

# 4. Build, sign, notarize, then publish the .dmg to GitHub Releases
#    Tag: v2.1.0  (no -engine suffix — the update checker filters by this)
```

`release-engine.sh` embeds a `wine/meridian-engine-version.txt` file in the archive containing the release tag. The app reads this file to display the installed engine version in Settings → Updates.

### Redistribution

All bundled components are freely redistributable open source:

| Component | License |
|-----------|---------|
| Wine | LGPL |
| DXMT | Open source |
| DXVK | Zlib |
| MoltenVK | Apache 2.0 |

### Key files

| File | Role |
|------|------|
| `Meridian/Engine/AppUpdateChecker.swift` | GitHub Releases API checker, rate-limited (24h), `@Observable` |
| `Meridian/Engine/EngineDownloader.swift` | Downloads and extracts engine archives |
| `Meridian/Views/Settings/SettingsView.swift` | Updates tab UI |
| `Scripts/release-engine.sh` | Developer script — packages Wine and publishes engine release |

## Settings

| Setting | Description |
|---------|-------------|
| Metal HUD | Show GPU performance overlay |
| Virtual Desktop | Force fixed-resolution Wine desktop |
