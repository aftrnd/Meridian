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

Meridian detects and uses CrossOver's Wine binary (wine-11.0 with DXMT, DXVK, MoltenVK). Detection order:

1. `/Applications/CrossOver.app/` — CrossOver 26+ (recommended)
2. `~/Library/Application Support/com.meridian.app/engine/` — bundled fallback

### Why CrossOver's Wine?

CrossOver uses **wine-11.0** (2026). The open-source Gcenx builds use wine-8.0.1 (2024), which can't render Steam's Chromium-based UI. The difference is 2 years of upstream Wine patches.

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
- [CrossOver](https://www.codeweavers.com/crossover) installed (or custom Wine 11+ build)
- Steam Web API key: [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey)

## First-Time Setup

1. Install CrossOver from [codeweavers.com](https://www.codeweavers.com/crossover)
2. Open `Meridian.xcodeproj` in Xcode, set your Team, build and run
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

## Settings

| Setting | Description |
|---------|-------------|
| Metal HUD | Show GPU performance overlay |
| Virtual Desktop | Force fixed-resolution Wine desktop |
