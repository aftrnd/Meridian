# Meridian — Implementation Reference

macOS 26 / Swift 6 native app that virtualizes Windows Steam games via a lightweight Ubuntu ARM64 + Proton VM using Apple Virtualization.framework. Linux and Proton are invisible to the user.

---

## Current Status (as of last session)

**What works:**
- Steam sign-in (OpenID via ASWebAuthenticationSession + local BSD-socket loopback server)
- Steam library display (direct api.steampowered.com calls with user's API key)
- Provisioning sheet launches and starts downloading from GitHub Releases
- Asset matching updated for actual release naming (`partaa/partab` + LZFSE)
- Play button is always tappable (routes to provision sheet or launch correctly)

**What to test next:**
- Full provision: download → join parts → LZFSE decompress → `meridian-base.img`
- VM boot (requires vmlinuz + initrd in the release, or manually placed in supportDir)
- Bridge connection via vsock port 1234 (requires meridian-bridge daemon in guest image)

**Known remaining work (guest side):**
- The current `v1.0.2-base` release has no `vmlinuz` or `initrd` assets — VM cannot boot yet
- `meridian-bridge` daemon not yet built/published
- See Phase 1 in Roadmap below

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    macOS Host (Swift 6)                  │
│                                                           │
│  SteamAuthService ──→ Steam OpenID ──→ SteamID + Key    │
│  SteamLibraryStore  ──→ api.steampowered.com             │
│                                                           │
│  VMImageProvider  ──→ GitHub Releases API                │
│  VMConfiguration  ──→ VZVirtualMachineConfiguration      │
│  VMManager        ──→ VZVirtualMachine lifecycle         │
│                          │                               │
│                          │ virtio-vsock port 1234        │
│                          ▼                               │
│  ProtonBridge (actor) ◄──────────────────────────────┐  │
│  GameLauncher (@MainActor) ──────────────────────────►│  │
│                                                       │  │
│  virtio-fs shares:                                    │  │
│    meridian-games         → /mnt/games                │  │
│    meridian-steam-session → /mnt/steam-session        │  │
└───────────────────────────────────────────────────────┼──┘
                                                        │
┌───────────────────────────────────────────────────────┼──┐
│           Ubuntu ARM64 Guest (meridian-base.img)      │  │
│                                                        │  │
│  /dev/vsock port 1234  ◄──────────────────────────────┘  │
│  meridian-bridge daemon  (JSON over vsock)                │
│    → /usr/bin/steam via FEX-EMU + Proton-GE              │
│                                                           │
│  /mnt/steam-session  (read-only virtio-fs)                │
│    → auto-login via session files or credentials.env     │
│                                                           │
│  /mnt/games          (writable virtio-fs)                 │
│    → steamapps/ symlink — game installs persist here     │
└─────────────────────────────────────────────────────────┘
```

---

## Host-Side Components

### Steam Authentication — `SteamAuthService.swift`

- Steam OpenID via `ASWebAuthenticationSession` + local HTTP server (`SteamLocalAuthServer`) using raw BSD sockets (RFC 8252 loopback)
- `return_to` URL is `http://127.0.0.1:{port}/callback` — satisfies Steam's HTTPS-or-loopback requirement
- After callback: redirects to `meridian://` custom scheme which `ASWebAuthenticationSession` intercepts
- SteamID, Web API key, VM credentials stored in Keychain
- Critical Swift 6 / macOS 26 fixes applied (see History section)

### Steam Library — `SteamAPIService.swift` / `SteamLibraryStore.swift`

- Direct `api.steampowered.com` calls using user's API key (no backend proxy)
- `GetPlayerSummaries`, `GetOwnedGames`, `GetRecentlyPlayedGames`
- `SteamLibraryStore` refreshes on auth, pulls hero art URLs

### VM Image Provisioning — `VMImageProvider.swift`

Downloads from GitHub Releases API (`GET /repos/{slug}/releases/latest`):

| Asset | Description |
|---|---|
| `vmlinuz` | ARM64 Linux kernel |
| `initrd` | Initial RAM disk |
| `meridian-base.img.part1` | Rootfs part 1 (≤ 2 GiB) |
| `meridian-base.img.part2` | Rootfs part 2 (≤ 2 GiB) |

Assembly (`assembleImageAsync()`) runs on a detached background task — never blocks the main actor. Progress reporting correctly tracks combined byte totals across all four assets.

### VM Configuration — `VMConfiguration.swift`

| Device | Purpose |
|---|---|
| `VZLinuxBootLoader` | `vmlinuz` + `initrd` from support dir |
| `VZVirtioBlockDevice` (RO) | `meridian-base.img` |
| `VZVirtioBlockDevice` (RW) | `expansion.img` (game installs) |
| `VZNATNetworkDevice` | Outbound internet for Steam downloads |
| `VZVirtioGraphicsDevice` | 1920×1080 virtio-GPU (user-configurable) |
| `VZUSBKeyboard/Pointer` | Input pass-through |
| `VZVirtioEntropyDevice` | `/dev/urandom` |
| `VZVirtioConsoleSerial` | `/dev/hvc0` kernel console (→ /dev/null host) |
| `VZVirtioSocketDevice` | **ProtonBridge vsock channel** |
| `VZVirtioFileSystemDevice` `meridian-games` | `/mnt/games` writable |
| `VZVirtioFileSystemDevice` `meridian-steam-session` | `/mnt/steam-session` read-only |

RAM is clamped to `[VZVirtualMachineConfiguration.minimumAllowedMemorySize, max]` with a floor of 2 GiB. CPU count is clamped to `[min, maximumAllowedCPUCount]`.

### ProtonBridge — `ProtonBridge.swift`

Swift `actor` managing the host side of the host↔guest RPC channel.

**Why vsock instead of serial:**
- `VZVirtioSocketDevice` is Apple's purpose-built multiplexed host↔guest channel
- No external socket file to manage — the framework handles the connection
- Multiple ports available for future services (install progress, resize, screenshots)
- Guest uses standard `AF_VSOCK` Linux sockets on port 1234

**Connection flow:**
1. `VMManager` boots the VM with a `VZVirtioSocketDeviceConfiguration` in its config
2. After boot, `vmManager.socketDevice` returns `vm.socketDevices.first as? VZVirtioSocketDevice`
3. `GameLauncher.retryConnect(to:)` calls `bridge.connect(to: device)` up to 30 times × 1s
4. `ProtonBridge.connect(to:)` calls `device.connect(toPort: 1234)` via a nonisolated free function to avoid Swift 6 actor isolation inference on the VZ completion handler
5. `VZVirtioSocketConnection.fileDescriptor` is wrapped in a `Connection` for read/write

**JSON protocol:**

```
Host → Guest:  { "cmd": "launch",   "appid": 1091500, "steamid": "76561..." }
Host → Guest:  { "cmd": "install",  "appid": 1091500 }
Host → Guest:  { "cmd": "stop" }
Host → Guest:  { "cmd": "resize",   "w": 1920, "h": 1080 }
Guest → Host:  { "event": "started",  "pid": 12345 }
Guest → Host:  { "event": "exited",   "code": 0 }
Guest → Host:  { "event": "log",      "line": "proton: ..." }
Guest → Host:  { "event": "progress", "appid": 1091500, "pct": 42.5 }
```

### VMManager — `VMManager.swift`

- `@Observable @MainActor`, all VZ calls dispatched through dedicated `vmQueue`
- `socketDevice: VZVirtioSocketDevice?` — exposed for `GameLauncher`
- `vmView: VZVirtualMachineView` — **cached**, `virtualMachine` re-assigned on restart (not recreated per SwiftUI render)
- `provision()` emits `.assembling` state before calling `assembleImageAsync()`
- `didStop()` centralises teardown for both graceful and forced stops

### GameLauncher — `GameLauncher.swift`

`@Observable @MainActor` orchestrator with a `LaunchState` state machine:

```
idle → preparingVM → connectingBridge → launching → running ─→ exited
                                                    ↘ failed
```

- Retries vsock connect 30× with 1s delay (covers slow Linux boot)
- `vmObserverTask` polls VM state every 500ms; clears `bridgeConnected` on any stop/error
- Stop button in `VMGameWindow` sends `bridge.stopGame()` before dismissing

### SteamSessionBridge — `SteamSessionBridge.swift`

Before VM boot, stages Steam auth data in a virtio-fs share:

1. **Session file copy** — copies `~/Library/Application Support/Steam/ssfn*` and `config/loginusers.vdf` if macOS Steam is installed
2. **Credential injection** — writes `credentials.env` (`STEAM_USER`, `STEAM_PASS`) if session files aren't available
3. The guest init script reads the virtio-fs share at `/mnt/steam-session` before launching Steam

---

## UI Components

| View | Description |
|---|---|
| `AuthView` | Steam sign-in screen (shown when !isAuthenticated) |
| `APIKeySetupSheet` | Slide-up for API key entry (shown after first auth) |
| `LibraryView` | Grid of Steam games with search |
| `GameDetailView` | Hero art, Play/Stop/Retry buttons, info grid, auto-scrolling log console |
| `VMGameWindow` | Full-screen sheet with `VZVirtualMachineView` + Stop Game button |
| `VMDisplayView` | `NSViewRepresentable` wrapping `VZVirtualMachineView`; `updateNSView` re-assigns `virtualMachine` on restart |
| `VMStatusBarView` | Status pill (dot + label + optional progress bar) |
| `VMProvisionView` | Sheet for first-time image download |
| `SettingsView` | CPU/RAM/disk sliders, API key, repo slug, VM credentials |

---

## Critical Swift 6 / macOS 26 Fixes Applied

### 1. `ASWebAuthenticationSession` completion handler crash

**Symptom:** `_dispatch_assert_queue_fail` / `EXC_BREAKPOINT` on `com.apple.SafariLaunchAgent` queue.

**Root cause:** Swift 6.2's `withCheckedThrowingContinuation(isolation: #isolation)` embeds the calling actor's executor into the `CheckedContinuation`. Any closure capturing such a `cont` is inferred as `@MainActor`-isolated. `ASWebAuthenticationSession` fires its callback on an XPC queue, triggering `dispatch_assert_queue(main_queue)`.

**Fix:** `makeWebAuthSession(url:cont:)` is a `nonisolated` free function. The closure it creates has no actor context, so Swift 6 cannot infer `@MainActor`. `ASPresentationAnchor` is captured before `session.start()` on the main actor and stored in `nonisolated(unsafe) var capturedPresentationWindow`.

### 2. `NSApp.keyWindow` crash from `presentationAnchor(for:)`

**Root cause:** `ASWebAuthenticationPresentationContextProviding` is an ObjC protocol called via ObjC messaging, bypassing `@MainActor` dispatch. On macOS 26, `NSApp.keyWindow` enforces `dispatch_assert_queue(main_queue)`.

**Fix:** Window is captured on the main actor before `session.start()`. `presentationAnchor(for:)` returns the pre-captured window without calling `NSApp`.

### 3. `NWListener` EINVAL in sandboxed app

**Root cause:** `Network.framework`'s `NWListener` has known quirks on sandboxed macOS, failing with `EINVAL (22)` even with correct entitlements.

**Fix:** `SteamLocalAuthServer` uses raw BSD sockets (`socket`, `bind`, `listen`, `accept`). Required entitlements: `com.apple.security.network.server` + `com.apple.security.network.client`.

### 4. VZ vsock `sending` data-race warnings

**Root cause:** `VZVirtioSocketDevice` and `VZVirtioSocketConnection` are ObjC framework types without formal `Sendable` conformance.

**Fix:** `nonisolated(unsafe)` locals at the call sites in `vsockConnect()`. `ProtonBridge.connect(to:)` is `nonisolated` to avoid the actor isolation crossing entirely.

---

## App Infrastructure

- **Keychain:** SteamID, API key, VM username/password via `Security.framework`
- **UserDefaults:** `AppSettings` — CPU, RAM, disk, display size, repo slug, `apiKeyPromptDismissed`
- **Entitlements:** `com.apple.security.network.server/client`, `com.apple.security.virtualization`
- **URL scheme:** `meridian://` — registered for Steam OpenID callback interception
- **GitHub Releases API:** Dynamic image discovery; `imageRepoSlug` configurable in Settings

---

## Guest-Side Requirements (base image)

The `meridian-base.img` must contain:

### OS Layer
- Ubuntu 24.04 ARM64 minimal
- Kernel modules: `virtio_net`, `virtio_blk`, `virtio_fs`, `vsock`, `virtio_gpu`, `vfio`
- systemd for service management

### x86_64 Emulation
- **FEX-EMU** (preferred over Box64 — Valve-backed, better AVX/AVX2, deeper Wine/Proton integration)
- `binfmt_misc` configured to route x86_64 ELF binaries through FEX

### Steam + Proton
- Steam client (x86_64, runs via FEX-EMU)
- **Proton-GE** latest (better game compatibility than vanilla Proton)
- Proton installed to `/usr/share/steam/compatibilitytools.d/`

### meridian-bridge Daemon
- Listens on `AF_VSOCK` port 1234
- Line-delimited JSON protocol (see ProtonBridge section)
- Written in Go or C for minimal footprint
- Systemd unit: `meridian-bridge.service` (starts after `steam.service`)

### Init Scripts
- Mount virtio-fs shares at boot: `/mnt/games`, `/mnt/steam-session`
- Symlink `~/.steam/steam/steamapps` → `/mnt/games/steamapps`
- Read `/mnt/steam-session/credentials.env` and call `steam +login $STEAM_USER $STEAM_PASS` if no session files
- Copy session files from `/mnt/steam-session/` to `~/.steam/` if present

---

## Roadmap

### Phase 1 — First Playable (current focus)
- [ ] Build and publish `meridian-bridge` daemon (Go/C)
- [ ] Build base image with FEX-EMU + Proton-GE + bridge daemon
- [ ] Publish image + kernel + initrd to `aftrnd/meridian` GitHub Releases
- [ ] Test full flow: provision → sign-in → launch game

### Phase 2 — Display & Input
- [ ] Dynamic display resolution tied to window size (bridge `resize` command)
- [ ] Retina / HiDPI support (2× pixel density)
- [ ] Metal/VirtIO-GPU acceleration investigation
- [ ] Controller pass-through via USB device assignment

### Phase 3 — Game Management
- [ ] In-app install flow (bridge `install` command with `progress` events)
- [ ] Library "installed" badge based on steamapps presence on expansion disk
- [ ] Game-specific Proton version selection (per-game settings in bridge)
- [ ] Steam Workshop support

### Phase 4 — Lifecycle & Updates
- [ ] Base image update with preserved expansion disk (atomic swap)
- [ ] "Update Available" badge in status bar
- [ ] VM pause/resume (`VZVirtualMachine.pause()`) — `VMState.paused` already added
- [ ] `keepVMRunning` setting wired to skip VM stop between sessions

### Phase 5 — Polish
- [ ] Onboarding flow for first-time users (no API key required after first sign-in)
- [ ] Game art caching / offline mode
- [ ] Proton compatibility ratings from ProtonDB API
- [ ] Mac Menu Bar quick-access for running games
- [ ] Sparkle or in-app update for the macOS app itself

---

## Bug Fix History (post-architecture overhaul)

### Play button always greyed out
`canLaunch` required `vmManager.state == .stopped`, which excluded `.notProvisioned` (no image downloaded yet) and any error state. The button was permanently disabled and the provision sheet was unreachable.  
**Fix:** `canLaunch` now only disables during active VM transitions (starting/stopping/downloading). `handlePlayTapped()` already routes to the correct action based on state.  
**Also fixed:** `VMManager.start()` now throws `VMError.notStopped` instead of silently returning when called from the wrong state. `GameLauncher.launch()` explicitly catches `.notProvisioned` and returns a clear error instead of hanging in `.preparingVM` forever.

### "No split image assets found"
The app was looking for assets ending in `.part1`/`.part2` but the actual release uses Unix `split` convention: `meridian-base-v2.img.lzfse.partaa` and `meridian-base-v2.img.lzfse.partab`.  
**Fix:** Filter by `.contains(".part")` and sort alphabetically — handles any split naming convention. Also added LZFSE streaming decompression (Compression.framework `compression_stream`) because the image is LZFSE-compressed. Streaming with 4MB/8MB fixed buffers avoids loading 2.7GB into RAM. Updated `isImageReady` to only require the disk image (not vmlinuz, which isn't in the release yet).

### "Could not write to disk" on first provision attempt
`FileManager.createFile` returns `false` (not an error) when the destination already exists. On retry after a failed/cancelled download, leftover part files caused every subsequent attempt to fail immediately.  
**Fix:** `try? removeItem` before every `createFile` call. `downloadLatestImage` also wipes all stale partaa/partab/lzfse files at the start of each provision attempt.  
**Also fixed:** `diskWriteFailed` now carries a diagnostic message (dir path, writability). The parent directory is explicitly `createDirectory`'d before `createFile` to guard against sandbox container timing issues where `supportDir`'s lazy initializer ran before the container was ready.

### `supportDir` swallowing createDirectory errors
The `nonisolated static let supportDir` used `try? createDirectory` which silently discarded failures. If the sandbox container wasn't ready at static-initializer time, the directory would never be created and all subsequent `createFile` calls would fail with no indication why.  
**Fix:** Errors are now printed to console. The real fix is the explicit `createDirectory` call in `downloadAsset` immediately before `createFile`.
