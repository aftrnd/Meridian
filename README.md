# Meridian

Native macOS app for running Windows Steam games through a lightweight Ubuntu VM with Proton GE.

## How It Works

1. **Sign in with Steam** via OpenID (`ASWebAuthenticationSession`), no Steam password stored by Meridian.
2. **Fetch library metadata** from Steam Web API (`IPlayerService/GetOwnedGames`).
3. **Boot VM on demand** using Apple `Virtualization.framework`.
4. **Connect host ↔ guest bridge** over virtio-vsock (port `1234`).
5. **Install if needed, then launch** through Steam + Proton inside the guest.
6. **Render in native window** via `VZVirtualMachineView` + virtio-gpu.

## Requirements

- macOS 15+ (macOS 26 recommended)
- Apple Silicon Mac
- Xcode 16+ / Swift 6
- Steam Web API key: [https://steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey)
- Disk: ~12 GB base image + expansion disk + game installs

## App Setup

1. Open `Meridian.xcodeproj` in Xcode.
2. Set your Team in Signing & Capabilities.
3. Build and run.
4. Sign in with Steam and provide your API key.
5. Either click **Set Up** (download image), or install a local build image (see below).

## Build A Fresh Local Base Image (No UTM Manual Steps)

Everything is scripted in-repo.

### Host dependencies

```bash
brew install qemu sshpass lzfse
```

`cloud-localds` is optional; `Scripts/build-meridian-image.sh` falls back to `hdiutil` automatically when it is not installed.

### Full local rebuild flow

```bash
# 1) Build latest guest agent
cd Agent
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/meridian-agent-linux-arm64 .

# 2) Build fresh VM image + kernel/initrd
cd ..
MERIDIAN_AGENT_BIN=/tmp/meridian-agent-linux-arm64 \
NO_COMPRESS=1 \
bash Scripts/build-meridian-image.sh

# 3) Install into local Meridian VM directory
bash Scripts/install-local.sh --vm-dir /tmp/meridian-vm
```

Artifacts are copied to:

- `~/Library/Application Support/com.meridian.app/vm/meridian-base.img`
- `~/Library/Application Support/com.meridian.app/vm/vmlinuz`
- `~/Library/Application Support/com.meridian.app/vm/initrd`

## Smoke Test A Built Image

```bash
# Boots image in QEMU and validates Steam/Proton/agent/session wiring
MERIDIAN_VM_DIR="$HOME/Library/Application Support/com.meridian.app/vm" \
bash Tests/Integration/test-guest.sh
```

If a VM is already running on port `2222`, run with `--no-boot`.

## Base Image Hosting

The default image source is GitHub Releases at
[aftrnd/meridian](https://github.com/aftrnd/meridian/releases).

`VMImageProvider` resolves latest release dynamically:

```text
GET https://api.github.com/repos/{imageRepoSlug}/releases/latest
```

The slug is configurable in Settings (`imageRepoSlug`) for forks/self-hosting.

## Guest Image Contents (Current)

- Ubuntu 24.04 ARM64
- Steam launcher/runtime
- Proton GE (`GE-Proton9-27`)
- Sway + XWayland session
- Mesa + Vulkan userspace (`libgl1-mesa-dri`, `mesa-vulkan-drivers`, `vulkan-tools`)
- `meridian-agent` systemd service (vsock bridge on port `1234`)
- Rosetta setup service mountpoint/config for Meridian VZ runs
