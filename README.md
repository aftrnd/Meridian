# Meridian

Native macOS launcher for Windows Steam games via Wine + DXMT (DirectX → Metal).

No virtual machine. No virtual display. Games run through Wine 11, with DirectX calls translated directly to Metal by DXMT — the same stack that powers CrossOver 26.

---

## How It Works

1. **Sign in with Steam** via OpenID (`ASWebAuthenticationSession`). Meridian never sees your password.
2. **Fetch your library** from the Steam Web API (`IPlayerService/GetOwnedGames`).
3. **Browse your library** in a native macOS UI with full 600×900 portrait art and title logos.
4. **Launch games through Wine** — DirectX calls are translated to Metal via DXMT.
5. **Steam runs silently** inside a Wine prefix. You authenticate once through the Steam window; all future launches are fully automatic (session cached for months).
6. **Games render natively** through Metal — no overhead, no emulation layer.

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 15+ | macOS 26 recommended |
| Apple Silicon | M1 or later |
| [CrossOver 26](https://www.codeweavers.com/crossover) | Provides Wine 11 + DXMT. A standalone engine download path also exists. |
| Steam Web API key | [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey) |

---

## First-Time Setup

1. Install [CrossOver](https://www.codeweavers.com/crossover) — this provides the Wine 11 binary with DXMT.
2. Open `Meridian.xcodeproj` in Xcode, set your development team, build and run.
3. Sign in with your Steam account and enter your Web API key in Settings.
4. Click **Play** on any game — Steam will prompt for login on first launch only.
5. After authenticating once, all future launches are silent and automatic.

---

## Architecture

```
MeridianApp (SwiftUI, macOS 15+)
│
├── App/
│   ├── MeridianApp.swift          — App entry point, window group, environment
│   ├── AppDelegate.swift          — NSApp lifecycle, window sizing
│   └── BootstrapManager.swift     — First-launch setup, engine detection
│
├── Steam/
│   ├── SteamAuthService.swift     — OpenID sign-in via ASWebAuthenticationSession
│   ├── SteamAPIService.swift      — Web API client (library, art hashes, app details)
│   ├── SteamLibraryStore.swift    — @Observable library state, background art fetch
│   ├── SteamSessionBridge.swift   — Copies macOS Steam session into Wine prefix
│   └── SteamLocalAuthServer.swift — Local HTTP server for OpenID callback
│
├── Engine/
│   ├── WineEngine.swift           — Wine binary detection (CrossOver / bundled)
│   ├── WinePrefix.swift           — Wine prefix creation and management
│   ├── WineSteamManager.swift     — Steam-in-Wine lifecycle
│   ├── EngineDownloader.swift     — Standalone engine download (no CrossOver required)
│   ├── GameProcess.swift          — Wine process monitoring and exit detection
│   └── TerminationCleanup.swift   — Cleanup on app/game exit
│
├── Launch/
│   └── GameLauncher.swift         — Orchestrates the full launch sequence
│
├── Models/
│   ├── Game.swift                 — Game struct, CDN URL logic, art hash resolution
│   ├── GameArtOverrides.swift     — Manual art hash registry for problematic games
│   ├── AppSettings.swift          — UserDefaults + Keychain persistence
│   ├── AppDetails.swift           — Store metadata (genres, categories)
│   ├── PlayerSummary.swift        — Steam profile and friend data
│   └── CategoryStore.swift        — Category/genre label management
│
└── Views/
    ├── HomeView.swift             — Hero carousel, recently played, favorites
    ├── ContentView.swift          — Root navigation and sidebar
    ├── SplashView.swift           — Loading screen
    ├── Library/
    │   ├── LibraryView.swift      — Full game library with search/filter/sort
    │   ├── GameGridView.swift     — 600×900 portrait card grid
    │   ├── GameDetailView.swift   — Per-game detail and launch sheet
    │   ├── CachedAsyncImage.swift — In-memory NSImage cache (500 entries)
    │   └── SearchView.swift       — Search overlay
    ├── Engine/
    │   └── EngineSetupView.swift  — Engine download / CrossOver setup UI
    ├── Settings/
    │   └── SettingsView.swift     — API key, Wine settings, preferences
    └── Auth/
        └── AuthView.swift         — Steam sign-in flow
```

---

## Translation Stack

```
Windows Game (.exe)
    → Wine 11  (Win32 / DirectX API translation)
        → DXMT  (DirectX 11 → Metal, zero-copy direct path)
            → Metal  (native GPU rendering on Apple Silicon)
```

---

## Wine Backend

Meridian detects the Wine binary in this order:

1. **CrossOver** — `/Applications/CrossOver.app/` (CrossOver 26+, recommended)
2. **Bundled engine** — `~/Library/Application Support/com.meridian.app/engine/` (downloaded via Settings)

### Why CrossOver's Wine?

CrossOver ships **Wine 11** (2026). The open-source Gcenx builds use Wine 8.0.1 (2024), which cannot render Steam's Chromium-based UI. CrossOver's Wine includes 2 extra years of upstream patches plus their own DirectX and Metal work.

### All Components Are Open Source

| Component | License | Source |
|---|---|---|
| Wine 11 | LGPL | [winehq.org](https://www.winehq.org/) |
| DXMT | MIT | [github.com/nicbarker/dxmt](https://github.com/nicbarker/dxmt) |
| DXVK | Zlib | [github.com/doitsujin/dxvk](https://github.com/doitsujin/dxvk) |
| MoltenVK | Apache 2.0 | [github.com/KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) |

### Building Your Own Wine (No CrossOver Required)

```bash
# 1. Wine 11 from source
git clone https://github.com/nicbarker/wine.git
cd wine && ./configure --enable-archs=i386,x86_64 && make

# 2. DXMT (DirectX → Metal)
git clone https://github.com/nicbarker/dxmt.git
cd dxmt && meson build && ninja -C build

# 3. MoltenVK (Vulkan → Metal, for DXVK)
git clone https://github.com/KhronosGroup/MoltenVK.git
cd MoltenVK && ./fetchDependencies --macos && make macos

# 4. Place the resulting binaries into:
#    ~/Library/Application Support/com.meridian.app/engine/
```

---

## Game Art System

Meridian loads 600×900 portrait capsule art and title logo art for every game.

### How Art Is Fetched

Steam hosts newer games (post ~2024) on a new CDN that requires a per-asset SHA-1 content hash in the URL:

```
https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/{id}/{hash}/library_600x900.jpg
https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/{id}/{hash}/logo_2x.png
```

Meridian resolves these hashes automatically via a 4-pass background process after every library refresh:

| Pass | What it does |
|---|---|
| 1 | Batch-fetches hashes for all owned games via `IStoreBrowseService/GetItems/v1` (50 at a time) |
| 2 | Individually retries any games missed by the batch call |
| 3 | For recently-played games still missing a logo hash, probes the `appdetails` API |
| 4 | For recently-played games still missing a capsule hash, probes the `appdetails` API |

Older games fall back to the legacy CDN (`cdn.akamai.steamstatic.com/steam/apps/{id}/library_600x900_2x.jpg`), which doesn't require a hash.

### Manual Art Overrides

For games where automatic hash fetching fails, `Meridian/Models/GameArtOverrides.swift` contains a hand-curated registry. Overrides take priority over automatically fetched hashes and resolve instantly with no network calls.

**To add a game:** find its asset URLs on [SteamDB](https://steamdb.info) (app page → Assets section), then add an entry:

```swift
// GameName (year) — hashes confirmed via SteamDB YYYY-MM-DD
// logo:    https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/{id}/{hash}/logo_2x.png
// capsule: https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/{id}/{hash}/library_600x900_2x.jpg
appID: GameArtOverride(
    logoHash:    "<40-char hex>",
    capsuleHash: "<40-char hex>"
),
```

The 40-character hex between `/apps/{id}/` and the filename is the hash. The app ID is the number in the Steam store URL (`store.steampowered.com/app/**3527290**/Peak/`).

---

## Game Launch Flow

1. User clicks **Play**
2. Meridian detects the Wine backend (CrossOver or bundled engine)
3. Creates or reuses the Wine prefix at `~/Library/Application Support/com.meridian.app/bottles/steam/`
4. On first run: bootstraps Steam client inside Wine (downloads `steamui.dll`, installs redistributables)
5. Copies the macOS Steam session cookies for account hint (avoids full re-login)
6. Launches `steam.exe -silent -applaunch <APPID>` through Wine
7. DXMT translates DirectX draw calls → Metal in real time
8. Monitors Wine child processes; cleans up when the game exits

---

## Wine Prefix Layout

All games share a single Wine prefix with Steam:

```
~/Library/Application Support/com.meridian.app/bottles/steam/
├── drive_c/
│   └── Program Files (x86)/Steam/   — Steam client installation
├── system.reg                        — Windows system registry
└── user.reg                          — Windows user registry
```

---

## Settings

| Setting | Description |
|---|---|
| Steam API Key | Required — used for library sync and art hash fetching |
| Metal HUD | Overlays GPU/CPU performance counters during gameplay |
| Virtual Desktop | Forces Wine to render into a fixed-resolution virtual desktop window |

---

## Known Limitations

| Issue | Detail |
|---|---|
| Anti-cheat | EasyAntiCheat and BattlEye block Wine — affected games won't launch |
| Denuvo DRM | Poor compatibility under Wine; some titles refuse to run |
| First login | One-time manual Steam login required through the Wine window |
| DX12 / Vulkan | DXMT targets DX11; DX12-only titles are not supported |
| Per-game tuning | Some games need specific DLL overrides or renderer flags |
| Art fetch | Very new games may temporarily show placeholder art until hashes propagate |

---

## Contributing

Bug reports and PRs welcome. When reporting art issues for a specific game, include the SteamDB asset URL so the hash can be added to `GameArtOverrides.swift`.
