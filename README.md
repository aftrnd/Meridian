# Meridian

Native macOS app for running Windows Steam games through Wine + DXMT (Direct3D to Metal).

## How It Works

1. **Download Meridian** — drag to Applications and open. The app handles everything else automatically.
2. **Engine downloads silently** — on first launch, Meridian downloads the open-source Wine engine in the background with a progress bar. No user action required.
3. **Sign in with Steam** via OpenID (`ASWebAuthenticationSession`). No Steam password stored.
4. **Fetch library metadata** from Steam Web API (`IPlayerService/GetOwnedGames`).
5. **Launch games through Wine** — DirectX calls are translated to Metal via DXMT.
6. **Steam runs silently** in the background inside a Wine prefix. Authenticate once through the Steam window, then all future launches are automatic.
7. **Games render natively** through Metal — no VM, no virtual display.

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
    → Wine (Win32 API translation)
        → DXMT (DirectX 11 → Metal, direct path)
            → Metal GPU (native rendering)
```

## Wine Engine

**Meridian is fully standalone.** CrossOver is not required, not used, and not consulted at runtime. The Wine engine is downloaded automatically from GitHub releases into Application Support on first launch.

Detection: `~/Library/Application Support/com.meridian.app/engine/wine/bin/wine64` only.
If not present → auto-downloaded by `SplashView` before bootstrap starts.

### All Components Are Open Source

| Component | License | Source |
|-----------|---------|--------|
| Wine | LGPL 2.1 | [github.com/Gcenx/wine](https://github.com/Gcenx/wine) (CodeWeavers open-source fork) |
| DXMT | MIT | DirectX → Metal translation |
| DXVK | Zlib | DirectX → Vulkan (MoltenVK) |
| MoltenVK | Apache 2.0 | Vulkan → Metal |

All of the above are freely redistributable under their respective open-source licenses.

**CrossOver is a paid commercial product. Its binaries are never shipped in Meridian releases.**

## First-Launch Flow (fully automatic)

```
User opens Meridian
    ↓
SplashView: "Finding latest engine…"
SplashView: "Downloading Wine engine — 48 / 220 MB"  ← progress bar, no click needed
SplashView: "Installing Wine engine…"
SplashView: "Creating Wine environment…"
SplashView: "Downloading and installing Steam…"
SplashView: "Steam is updating…"
SplashView: "Starting Steam…"
    ↓
Sign in with Steam + provide API key (once)
    ↓
Library UI — click Play on any game
```

## Game Launch Flow

1. User clicks **Play**
2. Meridian verifies Wine engine is ready (`~/Library/Application Support/com.meridian.app/engine/`)
3. Creates or reuses Wine prefix (`~/Library/Application Support/com.meridian.app/bottles/steam/`)
4. Bootstraps Steam client if first run (downloads steamui.dll)
5. Copies macOS Steam session files for auto-login
6. Launches `steam.exe -silent -applaunch <APPID>` through Wine
7. DXMT translates DirectX → Metal for rendering
8. Monitors Wine processes for game exit

## Requirements

- macOS 15+ (macOS 26 recommended)
- Apple Silicon Mac
- Steam Web API key: [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey)
- **Nothing else** — no CrossOver, no Wine install, no Homebrew packages

## Wine Prefix

Single shared prefix for Steam and all games:

```
~/Library/Application Support/com.meridian.app/
├── engine/wine/             — Downloaded Wine runtime (auto-managed)
│   ├── bin/wine64
│   ├── bin/wineserver
│   ├── lib/wine/            — Wine DLLs
│   ├── lib/dxmt/            — DirectX → Metal
│   └── lib/dxvk/            — DirectX → Vulkan
└── bottles/steam/           — Wine prefix
    └── drive_c/
        └── Program Files (x86)/Steam/
```

## Known Limitations

- **Anti-cheat**: EasyAntiCheat and BattlEye block Wine on macOS
- **Denuvo DRM**: Poor compatibility under Wine
- **First login**: Requires one-time Steam authentication through the Wine window
- **Per-game tuning**: Some games need specific DLL overrides or renderer settings
- **Rendering**: DXMT handles most DX11 games well; some titles may have visual artifacts

## Updates

Meridian uses a **unified update model**: one Meridian release = one app version + one Wine engine snapshot.

- **App updates** — `AppUpdateChecker` polls `github.com/aftrnd/meridian/releases` (rate-limited, once per 24h), skipping tags containing `-engine`. Shows a banner in Settings → Updates with release notes and a download link.
- **Engine auto-refresh** — On every launch, if the app version changed since the last run and the engine is installed, `EngineDownloader` silently downloads the latest engine in the background.
- **Engine fetching** — `EngineDownloader` uses `/releases?per_page=20` and filters for the first release tagged with `-engine`, ensuring it always finds the correct tarball even when a newer app release exists.

## Developer Release Workflow

### 1. Publish an engine release

**Recommended (CI — no local setup):** Trigger the GitHub Actions workflow:
```
GitHub repo → Actions → "Engine Release" → Run workflow
```
Uses the Gcenx open-source Wine cask on a macOS runner. Safe to redistribute (LGPL).

**Manual (local machine):**
```bash
# Install open-source Wine cask (required — do not use CrossOver for public releases)
brew tap gcenx/wine && brew install --cask wine-crossover

# Authenticate gh CLI
brew install gh && gh auth login

# Publish — auto-increments patch version
bash Scripts/release-engine.sh

# Or explicit version:
bash Scripts/release-engine.sh v2.1.0   # publishes tag v2.1.0-engine
```

### 2. Publish an app release

```bash
bash Scripts/release-app.sh              # auto-increment patch
bash Scripts/release-app.sh --minor      # bump minor
bash Scripts/release-app.sh 2.1.0        # explicit version
```

Requires:
- Developer ID Application certificate (Xcode → Settings → Accounts)
- Notarization credentials stored once:
  ```bash
  xcrun notarytool store-credentials "meridian-notarize" \
    --apple-id YOUR@APPLE.ID \
    --team-id YOUR_TEAM_ID \
    --password APP_SPECIFIC_PASSWORD
  ```

The script builds, signs, notarizes, staples, creates a `.dmg`, and publishes a **draft** GitHub release. Edit release notes, then publish the draft.

### Tag conventions

| Tag | Meaning |
|-----|---------|
| `v1.2.3` | App release — `.dmg` asset, picked up by `AppUpdateChecker` |
| `v1.2.3-engine` | Engine release — `.tar.gz` asset, picked up by `EngineDownloader` |

### Redistribution legality

| Component | Source | License | Public release OK |
|-----------|--------|---------|:-----------------:|
| Wine binaries | Gcenx `wine-crossover` cask | LGPL 2.1 | Yes |
| DXMT | Gcenx cask | MIT | Yes |
| DXVK | Gcenx cask | Zlib | Yes |
| MoltenVK | Gcenx cask | Apache 2.0 | Yes |
| CrossOver binaries | CrossOver.app (commercial) | CodeWeavers EULA | **No** |

## Key Files

| File | Role |
|------|------|
| `Meridian/Engine/WineEngine.swift` | Engine detection (bundled only — no CrossOver fallback) |
| `Meridian/Engine/EngineDownloader.swift` | Downloads and extracts engine tarball from GitHub |
| `Meridian/Engine/AppUpdateChecker.swift` | App update checker, rate-limited 24h |
| `Meridian/Views/SplashView.swift` | Auto-downloads engine on first launch, then runs bootstrap |
| `Meridian/App/BootstrapManager.swift` | Wine prefix → Steam install → Steam start pipeline |
| `Meridian/Views/Settings/SettingsView.swift` | Engine, updates, permissions, Steam settings |
| `Scripts/release-engine.sh` | Packages Wine tarball and publishes engine release |
| `Scripts/release-app.sh` | Builds, signs, notarizes, and publishes app .dmg |
| `.github/workflows/engine-release.yml` | CI workflow for reproducible engine releases |

## Settings

| Setting | Description |
|---------|-------------|
| Metal HUD | Show GPU performance overlay during gameplay |
| Virtual Desktop | Force fixed-resolution Wine desktop |
| Engine repo slug | GitHub `owner/repo` for engine and update checks (default: `aftrnd/meridian`) |

## Development Reset

To wipe all Meridian data for a clean test:

```bash
# Remove engine and Wine prefix
rm -rf ~/Library/Application\ Support/com.meridian.app

# Clear UserDefaults
defaults delete com.meridian.app

# Clear Keychain credentials (Steam ID + API key)
security delete-generic-password -s "com.meridian.app" -a "meridian.steam.steamid" 2>/dev/null
security delete-generic-password -s "com.meridian.app" -a "meridian.steam.apikey" 2>/dev/null

echo "Meridian data cleared — next launch is a clean first install."
```
