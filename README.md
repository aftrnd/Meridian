# Meridian

Run your Windows Steam library natively on Apple Silicon — no Windows, no virtual machines, no CrossOver required.

## What is Meridian?

Meridian translates Windows games to run on macOS by routing DirectX graphics calls directly to Metal, Apple's native GPU API. It uses open-source components (Wine, DXMT, DXVK) and manages everything automatically — download the app and it handles the rest.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 15 Sequoia or later
- Steam account
- Steam Web API key (free — [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey))

## Getting Started

1. Download and open **Meridian.dmg**, drag to Applications
2. Launch Meridian — the runtime downloads automatically in the background (~130 MB, one time)
3. Grant Accessibility permission when prompted (keeps Steam running silently)
4. Sign in with your Steam account
5. Enter your Steam Web API key
6. Click **Play** on any game — Steam authenticates once, then all future launches are silent

That's it. No other installs, no configuration.

## How It Works

Meridian runs the Windows version of Steam inside a Wine environment and translates game graphics through DXMT (DirectX → Metal). Your games render natively on the GPU — no virtualisation, no emulation.

```
Your Game (.exe)
  → Wine  (Windows API layer)
    → DXMT  (DirectX → Metal)
      → Metal  (Apple native GPU)
```

## Known Limitations

- **Anti-cheat** (EasyAntiCheat, BattlEye): not compatible with Wine on macOS
- **Denuvo DRM**: poor compatibility
- **First launch**: requires one-time sign-in through a visible Steam window
- **DX12 games**: limited support (DX11 and below works best)

## Open Source Components

Meridian bundles only freely redistributable open-source software:

| Component | License |
|-----------|---------|
| [Wine](https://www.winehq.org/) | LGPL 2.1 |
| [DXMT](https://github.com/nicbarker/dxmt) | MIT |
| [DXVK](https://github.com/doitsujin/dxvk) | Zlib |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Apache 2.0 |

Meridian is not affiliated with or endorsed by Valve Corporation, Apple Inc., or CodeWeavers.
