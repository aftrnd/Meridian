# Meridian

Native macOS application allowing you to run Windows games via a lightweight Ubuntu VM running Proton GE — invisibly, as if they were native Mac games.

## How it works

1. **Sign in once** — Steam OpenID auth via `ASWebAuthenticationSession`. No password ever enters the app. The same session token is forwarded to the VM so Steam inside the guest is also authenticated.
2. **Your library appears** — loaded via the Steam Web API (`IPlayerService/GetOwnedGames`) using your Steam Web API key.
3. **Click Play** — Meridian auto-starts the Meridian VM (Apple `Virtualization.framework`), connects the Proton bridge over a virtio-serial socket, and sends a launch command.
4. **Your game runs** — Proton GE inside the Ubuntu guest executes the Windows game. The display is rendered via a `VZVirtualMachineView` / `VZVirtioGraphicsDevice` back into a native macOS window.

Linux, Ubuntu, and Proton are completely invisible.

## Requirements

- macOS 15 Sequoia or later (macOS 26 Tahoe recommended)
- Apple Silicon Mac (ARM64 VM image)
- Xcode 16+ / Swift 6
- A [Steam Web API key](https://steamcommunity.com/dev/apikey)
- ~2 GB free disk space (base image) + space for game installs

## Setup

1. Open `Meridian.xcodeproj` in Xcode
2. Set your Team in Signing & Capabilities
3. Build & Run
4. Paste your Steam Web API key in the sign-in screen
5. Click **Sign in with Steam** — a browser overlay opens Steam's OpenID page
6. On first launch, click **Set Up** to download the Meridian base image

## Architecture

```
Meridian/
├── App/
│   ├── MeridianApp.swift          # @main, SwiftUI scene setup
│   └── AppDelegate.swift
├── Steam/
│   ├── SteamAuthService.swift     # OpenID via ASWebAuthenticationSession, Keychain
│   ├── SteamAPIService.swift      # Steam Web API actor (library, player summaries)
│   └── SteamLibraryStore.swift    # @Observable game list + search/filter/sort
├── VM/
│   ├── VMManager.swift            # VZVirtualMachine lifecycle (@Observable)
│   ├── VMConfiguration.swift      # VZVirtualMachineConfiguration builder
│   ├── VMImageProvider.swift      # GitHub Releases API — always fetches latest tag
│   └── ProtonBridge.swift         # Unix socket RPC to guest meridian-bridge daemon
├── Launch/
│   └── GameLauncher.swift         # Coordinates VM start → bridge connect → game launch
├── Models/
│   ├── Game.swift                 # Steam game model
│   ├── PlayerSummary.swift        # Steam profile model
│   ├── VMState.swift              # VM lifecycle enum
│   └── AppSettings.swift          # UserDefaults-backed settings singleton
└── Views/
    ├── ContentView.swift           # NavigationSplitView root
    ├── Library/
    │   ├── LibraryView.swift       # Filtered game grid
    │   ├── GameGridView.swift      # Capsule art tile
    │   └── GameDetailView.swift    # Hero art + Play button + VM view
    ├── VM/
    │   ├── VMStatusBarView.swift   # Bottom status pill
    │   └── VMProvisionView.swift   # First-run download sheet
    ├── Auth/
    │   └── AuthView.swift          # Sign-in screen
    └── Settings/
        └── SettingsView.swift      # API key, VM resources, repo slug
```

## Meridian Base Image

The VM base image is hosted on GitHub Releases at [`aftrnd/meridian`](https://github.com/aftrnd/meridian/releases).

**The download URL is never hardcoded.** `VMImageProvider` calls the GitHub REST API:

```
GET https://api.github.com/repos/{imageRepoSlug}/releases/latest
```

and downloads the `.part1` / `.part2` assets from whatever the current latest release is. When you publish a new image release (e.g. `v1.0.3-base`), all users automatically receive it on next launch.

The repo slug (`aftrnd/meridian` by default) is configurable in **Settings → Advanced** so you can self-host or use a fork.

## Guest image contents (v1.0.2-base)

- Ubuntu 24.04 ARM64
- Proton GE 9-27
- Steam (headless)
- Sway (kiosk compositor for XWayland passthrough)
- `meridian-bridge` daemon (listens on `/dev/hvc0`, accepts JSON launch commands)
