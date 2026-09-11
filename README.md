# Meridian

**Play your Steam library on your Mac.**

Meridian is a native macOS app that runs Windows Steam games on Apple Silicon. It signs in to your real Steam account, installs games from Steam's own servers, and renders them through Metal. There is no virtual machine, no dual boot, and nothing else to install.

- macOS 15 or later, Apple Silicon
- Built with Swift 6 and SwiftUI, with zero third-party Swift dependencies
- Distributed outside the Mac App Store with a 14-day free trial

## Why Meridian

**It is your real Steam.** Meridian launches games through a genuine Steam client, so cloud saves, achievements, online multiplayer, Workshop content, and DRM all behave exactly as they do on a PC. Nothing is emulated or bypassed.

**Sign in once.** Steam authentication uses the same refresh-token flow as Steam's own clients, including QR sign-in from the Steam mobile app. After the first sign-in, every launch is silent.

**Native rendering.** DirectX calls are translated to Metal on the fly. Games draw directly to your display at full resolution with no virtual GPU in the way.

**Self-contained.** Meridian downloads its Wine-based engine on first run and manages it for you. No CrossOver purchase, no Homebrew, no terminal.

**Designed for the Mac.** A single window with a sidebar, Home and Library pages, smooth card-to-detail zoom, browser-style back and forward, and a launch experience that feels like it belongs on macOS.

## Features

### Home and Library

- **Home** with a swipeable hero carousel of your recently played games, plus Recently Played and Favorites rows
- **Library grid** with filters (All, Recent, Installed, Favorites) and sort orders (name, most played, recently played)
- **Collections** for organizing games into named groups in the sidebar
- **Search** across your whole library
- **Game detail pages** with artwork, playtime, achievements and completion progress, and a compatibility rating
- **Steam Store and Steam Profile** pages inside the app
- **Back and forward navigation** that replays the same zoom a click would, from mouse buttons 4 and 5, Command-[ and Command-], or a three-finger swipe

### Installing and playing

- **One-click installs** using a native arm64 build of DepotDownloader, with live progress based on real bytes on disk
- **Compatibility database** of per-game fixes (DLL overrides, renderer choice, engine quirks) applied automatically at launch
- **Launch loader** that shows exactly what Meridian is doing, from preparing the engine to handing off to the game
- **Metal Performance HUD** and a forced virtual desktop for games that need a fixed resolution

### Keeping up to date

- **In-app updates** for both the app and the engine. Meridian checks GitHub Releases, downloads the new build, and relaunches.
- **Automatic engine refresh** whenever the app version changes, so the newest Wine build is always in place

## How it works

```
Windows game (.exe)
  -> Wine 11 with the CodeWeavers patch set   Win32 API translation
     -> DXMT                                   Direct3D 10/11 to Metal
     -> DXVK + MoltenVK                        Direct3D 9 and Vulkan to Metal
     -> Metal                                  native GPU rendering
```

When you press Play:

1. Meridian confirms the engine is installed and healthy.
2. It creates or reuses a single Wine prefix that holds the Steam client.
3. Steam starts silently in the background using your saved sign-in.
4. The game is launched through Steam with `-applaunch`, so Steam handles ownership, DRM, cloud saves, and overlays.
5. Meridian watches the game process and returns you to your library when it exits.

## Requirements

- macOS 15 Sequoia or later (macOS 26 recommended)
- A Mac with Apple Silicon (M1 or newer)
- A Steam account
- A free Steam Web API key from [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey), used to read your library and profile

## Getting started

1. Download the latest DMG from the Releases page and drag Meridian to Applications.
2. Open Meridian. On first run it downloads the engine (a one-time step) and prepares the Steam client.
3. Sign in with your Steam account. You can scan the QR code with the Steam mobile app or use your password with Steam Guard.
4. Paste your Steam Web API key when prompted. It is stored in the macOS Keychain.
5. Pick a game and press Play.

Meridian never stores your Steam password. Sign-in happens directly against Steam's authentication service, and only the resulting refresh token is kept, encrypted inside the Wine prefix the same way the Windows Steam client stores it.

## Licensing and trial

Meridian is commercial software. Every new install includes a 14-day trial with no sign-up. After the trial, a license key unlocks Play and Install.

License keys are verified entirely offline against a public key embedded in the app. There is no activation server, no account to create, and no phone-home. Your key lives in Settings, under License.

## Privacy

- Steam sign-in goes directly from your Mac to Steam. Meridian never sees or stores your password.
- Your Steam Web API key is stored in the macOS Keychain.
- License keys are validated on device.
- Meridian does not include analytics, telemetry, or crash reporting. Logs are written locally only and can be shared with support if you choose.

## The engine

Meridian's runtime is assembled from open-source projects and installed to `~/Library/Application Support/com.meridian.app/engine/`.

| Component | Role | License |
|-----------|------|---------|
| [Wine 11](https://www.winehq.org/) with the [CodeWeavers](https://www.codeweavers.com/crossover/source) patch set | Win32 API translation, msync, Steam IPC | LGPL |
| [DXMT](https://github.com/3Shain/dxmt) | Direct3D 10/11 to Metal | MIT / LGPL |
| [DXVK](https://github.com/doitsujin/dxvk) | Direct3D 9 to Vulkan | Zlib |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Vulkan to Metal | Apache 2.0 |
| [DepotDownloader](https://github.com/SteamRE/DepotDownloader) (Meridian arm64 fork) | Game installs from Steam's CDN | GPL-2.0 |

Direct3D 12 titles currently use Apple's D3DMetal, which Apple distributes under its Game Porting Toolkit terms. Before the 1.0 release, Meridian will either ship Direct3D 12 support under an appropriate redistribution arrangement or leave it out of the default engine. See the roadmap below.

## Compatibility

Most Direct3D 11 titles run well. Some categories do not work today and are not specific to Meridian:

- **Kernel-level anti-cheat** (Easy Anti-Cheat, BattlEye) does not run under Wine on macOS.
- **Denuvo-protected titles** are hit or miss.
- A small number of games need per-title tuning. Meridian ships those fixes in its compatibility database and applies them automatically.

Each game's detail page shows its current rating: Verified, Playable, Launches, Broken, or Untested.

## Roadmap to 1.0

Meridian is in active development. The items below are what stands between the current builds and a general release.

- **Reproducible engine builds.** Build Wine, DXMT, DXVK, and MoltenVK from source in CI, and ship license texts and a software bill of materials with every engine release.
- **Direct3D 12 decision.** Ship D3DMetal under a redistribution agreement, offer a bring-your-own Game Porting Toolkit import, or ship DXMT and DXVK only.
- **Signed, notarized releases from CI.** The tag-driven release pipeline is in place; it needs the Developer ID certificate and notarization credentials configured.
- **Legal copy.** End-user license agreement, privacy policy, and a support channel.
- **Friends panel.** A Steam friends sidebar is built and currently behind a feature flag while it is finished.

## Settings

| Tab | What lives there |
|-----|------------------|
| Steam | Account, hidden games, Steam Web API key |
| Engine | msync, memory tier, Metal Performance HUD, virtual desktop, reset |
| Permissions | macOS permissions Meridian needs |
| Updates | Current app and engine versions, Check for Updates, diagnostics |
| License | Trial status and license key |
| Developer | Developer menu and feature flags (off by default in release builds) |

## Where Meridian keeps its data

Everything lives under `~/Library/Application Support/com.meridian.app/`:

```
com.meridian.app/
  engine/            Wine runtime, DXMT, DXVK, MoltenVK
  bottles/steam/     The Wine prefix that holds the Steam client and installed games
  logs/              meridian.log (current session) and meridian-previous.log
```

Cached artwork is stored in `~/Library/Caches/com.meridian.app/images/`.

## Logs and diagnostics

Meridian writes a plain-text, timestamped log for every session and rotates it on launch. Settings, then Updates, then Diagnostics has an Open Log button. From Terminal:

```bash
tail -f ~/Library/Application\ Support/com.meridian.app/logs/meridian.log
grep -E "ERROR|WARN" ~/Library/Application\ Support/com.meridian.app/logs/meridian.log
```

Each line is `<timestamp>  [LEVEL]  [Category] <message>`, and each log opens with a header recording the app version, macOS version, and architecture.

## For developers

### Building

Open `Meridian.xcodeproj` in Xcode, set your team, and run. From the command line:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build --build-system native
swift test --build-system native
```

### Project layout

```
Meridian/
  App/         Entry point, window management, bootstrap pipeline
  Engine/      Wine engine detection, prefix lifecycle, compatibility database, updates
  Launch/      Launch orchestration and DepotDownloader installs
  Steam/       Authentication, session management, library sync, Web API
  Models/      Game, settings, collections, licensing
  Views/       SwiftUI interface: Home, Library, Auth, Settings, Downloads, Friends
  Utilities/   Logging
MeridianTests/ XCTest suite
Scripts/       Engine packaging, release automation, diagnostics
```

### Contributing and releases

Branching, versioning, and the release pipeline are documented in [CONTRIBUTING.md](CONTRIBUTING.md). App releases are tagged `vX.Y.Z`; engine releases are a separate line tagged `vX.Y.Z-engine`. Pushing an app tag runs the signed, notarized release workflow and publishes the DMG.

## Acknowledgements

Meridian stands on the work of the Wine project and CodeWeavers, the DXMT, DXVK, and MoltenVK teams, and the maintainers of DepotDownloader. Thank you.
