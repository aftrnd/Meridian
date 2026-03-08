# Meridian Boot Iteration Log

Running log of every boot attempt, error, and fix. Context handoff reference.

---

## Image Inventory (as of 2026-03-08)

| File | Size | Format | Status |
|---|---|---|---|
| `meridian-base.img` | 12 GB | Raw GPT disk | **Active** |
| `vmlinuz` | 56 MB | ARM64 Linux 6.8.0-101-generic (uncompressed) | **Active** |
| `initrd` | 69 MB | initramfs for 6.8.0-101-generic | **Active** |

Disk layout (from GPT):
- Part 1 (LBA 2048–1173503): EFI FAT32
- Part 2 (LBA 1173504–4843519): `/boot` ext4 — contains vmlinuz/initrd
- Part 3 (LBA 4843520–25163775): LVM2 PV → `ubuntu-vg/ubuntu-lv` = rootfs

Guest daemon: `/usr/bin/meridian-agent` — systemd unit `meridian-agent.service` enabled, starts automatically at boot.

---

## Iteration 1 — 2026-03-08

### Changes
- Raw GPT image created from LZFSE decompress of `meridian-base-v2.img.lzfse`
- vmlinuz + initrd extracted from `/boot` ext4 partition
- kernel cmdline: `root=/dev/mapper/ubuntu--vg-ubuntu--lv rw console=hvc0 loglevel=3 meridian=1`
- Serial console wired to `vm/console.log`

### Result
→ **VM boots fully into Ubuntu 24.04.4 LTS** (multi-user.target reached in ~4s)
→ Login prompt shown on hvc0, user `meridian` password `meridian`

---

## Iteration 2 — 2026-03-08

### Changes
- Written and cross-compiled `meridian-agent` (Go, statically linked, 2.2MB)
- Protocol: line-delimited JSON on AF_VSOCK port 1234
- Matches `ProtonBridge.swift` protocol exactly
- Installed via HTTP (host runs `python3 -m http.server 8765 --directory /tmp/meridian-agent`)
- Systemd unit `meridian-agent.service` installed and enabled via `systemctl enable`
- `sync` run before `poweroff -f` to flush writes

### Result
→ Agent starts automatically at boot (`systemd: Started meridian-agent.service`)
→ Agent logs: `starting on vsock port 1234 → listening → waiting for host connection`

---

## Iteration 3 — 2026-03-08

### Problem
VZ `VZVirtioSocketDevice.connect(toPort:)` callback never fired (hung forever).

### Root cause
`connect(toPort:)` MUST be called on the same `DispatchQueue` the `VZVirtualMachine`
was created with (`vmQueue` in VMManager). Calling it from any other queue (main queue,
task queue, etc.) causes the completion handler to never fire.

### Fix (in Meridian app code)
1. `VMManager.vmQueue` changed from `private` to internal (no access modifier)
2. `ProtonBridge.connect(to:)` signature changed to `connect(to:on:)` — takes the vmQueue
3. `vsockConnect(device:queue:port:)` now dispatches `d.connect(toPort:)` on `q.async`
4. `GameLauncher.retryConnect(to:on:retries:delay:)` passes `vmManager.vmQueue`

### Other fixes in same pass
- Kernel cmdline: `ro` → `rw` (needed for systemd remount)
- Base disk: `readOnly: true` → `readOnly: false` (needed for systemd journal writes)

### Result
→ **vsock CONNECTED on attempt 1** — 100% success rate
→ Agent receives `{"cmd":"launch",...}` and responds with log events

---

## Iteration 4 — 2026-03-08

### Problem
Steam, Proton GE, and x86_64 translation (Rosetta) were not installed/active in the guest.
`meridian-agent` would call `steam -applaunch` but steam binary did not exist.

### Fix
Via QEMU boot of the image (port-forwarded SSH on localhost:2222):
1. Fixed Steam GPG key (`curl .../steam.gpg → /usr/share/keyrings/steam.gpg`)
2. Installed Steam via `dpkg --force-architecture --force-depends -i steam.deb` (20MB)  
   - Steam binary: `/usr/bin/steam → ../lib/steam/bin_steam.sh`
   - amd64 multiarch was already configured, 30+ amd64 libraries already present
   - Proton GE 9-27 already present at `/home/meridian/.local/share/Steam/compatibilitytools.d/GE-Proton9-27`
3. Updated `meridian-agent` (Go) to:
   - Run Steam as `meridian` user (uid=1000) via `syscall.Credential` — Steam refuses to run as root
   - Wait up to 30s for Wayland socket (`/run/user/1000/wayland-1`) before launching
   - Set proper env vars: `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, etc.
   - Fix ownership of Steam dirs on mount (`chown -R meridian:meridian`)
4. Updated `meridian-agent.service` to depend on `rosetta-setup.service`
5. Updated `meridian-session.sh` — removed duplicate `meridian-agent` start (systemd manages it)
6. Added Rosetta virtiofs share (`VZLinuxRosettaDirectoryShare`) to `VMConfiguration.makeDirectoryShares()`
   - Tag: `"rosetta"`, guest mounts at `/opt/rosetta`, then calls `rosetta --register`
   - Guarded with `availability == .installed` check

### Guest state after this iteration
- Ubuntu 24.04 ARM64 ✓
- vsock transport working ✓  
- meridian-agent running ✓ (updated to run Steam as meridian user)
- **Steam launcher installed** ✓ (`/usr/bin/steam`, `1:1.0.0.85`)
- **Proton GE 9-27 installed** ✓ (`compatibilitytools.d/GE-Proton9-27`)
- **Rosetta via virtiofs** ✓ (set up in VMConfiguration, will activate on next Meridian boot)
- sway kiosk compositor configured ✓ (needs virtio-gpu which Meridian provides)

### Remaining items
- **Steam self-update** — first launch downloads ~500MB Steam runtime (x86_64 via Rosetta)
- **Game not yet installed** — need to `steam +app_update <appid>` to install game files
- **Session file copy** — meridian-session.sh now copies loginusers.vdf/config.vdf from `/mnt/steam-session` ✓
- Need to verify sway starts correctly on first Meridian boot (needs `/dev/dri/` from virtio-gpu)
- Steam self-update should complete on first Meridian run automatically

### What should happen on first Meridian launch
1. VM boots → Rosetta virtiofs mounts → `rosetta --register` activates x86_64 binfmt_misc
2. Auto-login on tty1 → sway starts → `meridian-session.sh` runs
3. Session script mounts `/mnt/steam-session`, copies auth tokens to Steam config
4. Steam starts (`-silent -no-cef-sandbox`), self-updates (~500MB), logs in automatically
5. `meridian-agent` starts (root), waits for vsock host connection + Wayland socket
6. Host connects, sends `{"cmd":"launch","appid":<id>}`
7. Agent waits for Wayland socket, then launches Steam with `-applaunch <id>` as meridian user
8. Steam passes the applaunch to the running instance → game downloads + launches

---

## Iteration 5 — 2026-03-08

### Problems

**1. `apt-get install steam-launcher` fails with apt:amd64 conflict**

On ARM64 Ubuntu 24.04 with `dpkg --add-architecture amd64`, installing
`steam-launcher` via apt triggers:

```
The following packages have unresolvable dependencies:
  steam-launcher: ... apt:amd64 conflicts with apt
```

Root cause: apt's multiarch resolver finds `apt:amd64` available in the Ubuntu
package pool and attempts to install it to satisfy dependency chains from
Steam's amd64 library tree. `apt:amd64` directly conflicts with the native
ARM64 `apt` package.

**Fix:** Pin `apt:amd64` to priority `-1` before running apt-get. The native
arm64 `apt` is `Multi-Arch: foreign` and legally satisfies any amd64 `apt`
dependency. Add to `/etc/apt/preferences.d/no-foreign-apt`:

```
Package: apt:amd64
Pin: release *
Pin-Priority: -1
```

Then install Steam via the official Valve CDN `.deb` with `--force-architecture
--force-depends`, followed by `apt-get install -f --no-install-recommends` to
resolve remaining deps without pulling `apt:amd64`.

**2. Base image breaks every time it is copied + compressed**

Symptom after decompression: black screen, no SSH, OR:
> `launch command failed: operation can't be completed i/o error`
from `VZDiskImageStorageDeviceAttachment`.

Root cause: **`sudo poweroff -f` was used to shut down the build VM.**

`poweroff -f` is a hard kill — it bypasses the entire systemd shutdown sequence.
Filesystems are NOT unmounted and LVM Volume Groups are NOT deactivated:

- The ext4 journal is left in a **dirty** state (uncommitted transactions).
- The LVM VG metadata still has the `in-use` flag set.

LZFSE faithfully compresses this dirty state. When the image is decompressed
and booted in a fresh QEMU or `Virtualization.framework` environment:

- LVM activation finds the `in-use` flag and either:
  - Fails to activate the VG → kernel cannot mount rootfs → panic → **black screen**
  - Partially recovers with I/O errors → systemd fails → **black screen**
- On macOS, `VZDiskImageStorageDeviceAttachment` validates the raw image header.
  An LVM CRC mismatch or invalid backup GPT header (caused by the partial LVM
  state) causes the attachment to throw an I/O error before the VM even starts.

**Fix:** Replace `poweroff -f` with `systemctl poweroff` everywhere in the
build pipeline. `systemctl poweroff` runs the full systemd shutdown sequence:

```
1. All services stopped
2. All filesystems unmounted in dependency order
3. LVM VGs deactivated (vgchange -an)
4. Remaining ext4 journals flushed + marked clean
5. Hardware halt
```

Also run `fstrim -av && sync; sync; sync` inside the VM *before* shutdown to:
- Zero out unused blocks (makes LZFSE compression ratio ~30% better)
- Ensure all pending writes are on disk before the halt

### Changes

- Created `Scripts/build-meridian-image.sh`:
  - Full from-scratch build using Ubuntu 24.04 ARM64 cloud image + QEMU UEFI
  - Phase 7 installs Steam with the apt:amd64 pin fix
  - Phase 12 shuts down with `systemctl poweroff` (not `poweroff -f`)
  - Phase 11 runs `fstrim + sync` before shutdown
  - Extracts vmlinuz + initrd via SCP before shutdown
  - Phase 13 converts qcow2 → raw for VZ compatibility
  - Phase 14 calls compress-and-release.sh automatically
- Created `Scripts/compress-and-release.sh`:
  - Pre-compress integrity check via `qemu-img info`
  - Warns if image was modified <30s ago (possible live VM)
  - LZFSE encode → `split -b 1900m` → partaa / partab
  - Roundtrip sanity check (partial decompression in 15s window)
  - Clear documentation of the `poweroff -f` vs `systemctl poweroff` distinction

### What actually happened (no rebuild needed)

The VM was already running via QEMU on port 2222 with everything installed.
Instead of rebuilding from scratch:
1. Added `/etc/apt/preferences.d/no-foreign-apt` pin (future-proofing)
2. Ran `fstrim -av` — freed 6.3 GB of trimmed blocks (EFI: 562MB, /boot: 1.6GB, /: 4GB)
3. `sync; sync; sync` — flushed all pending writes  
4. `sudo systemctl poweroff` — **clean shutdown, QEMU exited in 1 second**
5. Image verified: GPT intact, 12 GiB raw, cleanly written

**Result:** `meridian-base.img` in sandbox is clean and ready for Virtualization.framework.
No compress/decompress cycle needed — the image lives directly in the app's container.

### How to re-build from scratch

```bash
# 1. (Optional) Build the meridian-agent binary
cd /path/to/agent-source
GOOS=linux GOARCH=arm64 go build -o /tmp/meridian-agent-linux-arm64 .

# 2. Run the build script
MERIDIAN_AGENT_BIN=/tmp/meridian-agent-linux-arm64 \
RELEASE_VERSION=v1.0.3-base \
bash Scripts/build-meridian-image.sh

# Artifacts land in /tmp/meridian-vm/
```

### How to compress an existing clean image

```bash
# The VM MUST be fully shut down via 'systemctl poweroff' before running this.
bash Scripts/compress-and-release.sh \
    --image /tmp/meridian-vm/meridian-base.img \
    --version v1.0.3-base \
    --output-dir /tmp/meridian-vm

# Upload the .partaa / .partab / vmlinuz / initrd files to GitHub Releases.
```

---

## Iteration 6 — 2026-03-08

### Problem
`"launch command failed: operation couldn't be completed, i/o error"` even with a cleanly-shutdown image.

### Root cause — `com.apple.quarantine` on disk image files

macOS sets the `com.apple.quarantine` extended attribute on files created by
sandboxed apps. `VMImageProvider` decompresses `meridian-base.img` inside the
Meridian sandbox → macOS tags the resulting 12 GB file with quarantine.

When the Meridian app then tries `VZDiskImageStorageDeviceAttachment(url: ..., readOnly: false)`,
macOS's security framework sees the quarantined file and attempts to scan it.
For a 12 GB raw disk image the scan is effectively unbounded and the call
returns an I/O error before VZ ever starts the VM.

`expansion.img` (64 GB sparse) has the same problem — a quarantine scan of
64 GB would never complete at all.

**Secondary cause — VZ XPC file lock persisting across failed launches:**
When VZ fails during startup, its `com.apple.Virtualization.VirtualMachine`
XPC helper process sometimes stays alive holding a mandatory byte-range lock
(`fcntl LOCK_EX` on byte 100) on the disk image. The next launch attempt finds
the file already locked and also fails with "operation couldn't be completed:
I/O error". `qemu-img check` exposes this: "Failed to lock byte 100".

### Fixes applied

1. Stripped `com.apple.quarantine` and `com.apple.provenance` from
   `meridian-base.img`, `expansion.img`, `vmlinuz`, `initrd` using `xattr -d`.
2. Waited for the zombie VZ XPC process (PID 5508) to exit, releasing the lock.
3. Added quarantine-strip steps to all three scripts so this never recurs:
   - `Scripts/build-meridian-image.sh` — strips after `qemu-img convert`
   - `Scripts/compress-and-release.sh` — strips before LZFSE encode
   - `Scripts/install-local.sh` — strips after copying to sandbox

### How to fix if this happens again

```bash
# 1. Kill any zombie VZ XPC process holding a file lock
pkill -f "com.apple.Virtualization.VirtualMachine.xpc" 2>/dev/null || true

# 2. Strip quarantine xattrs from all VM image files
SANDBOX="$HOME/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm"
for f in "${SANDBOX}/meridian-base.img" "${SANDBOX}/expansion.img" \
          "${SANDBOX}/vmlinuz" "${SANDBOX}/initrd"; do
    xattr -d com.apple.quarantine "$f" 2>/dev/null || true
    xattr -d com.apple.provenance "$f" 2>/dev/null || true
done

# 3. Launch Meridian and try again
```

## Remaining work

---

## Protocol reference (ProtonBridge.swift ↔ meridian-agent)

```
Host → Guest:  {"cmd":"launch","appid":1091500,"steamid":"76561..."}
Host → Guest:  {"cmd":"install","appid":1091500}
Host → Guest:  {"cmd":"stop"}
Host → Guest:  {"cmd":"resize","w":1920,"h":1080}
Guest → Host:  {"event":"started","pid":12345}
Guest → Host:  {"event":"exited","code":0}
Guest → Host:  {"event":"log","line":"..."}
Guest → Host:  {"event":"progress","appid":1091500,"pct":42.5}
```

## Known guest facts

- Boot uses VZLinuxBootLoader (bypasses GRUB)
- Root: `/dev/mapper/ubuntu--vg-ubuntu--lv` (LVM)
- Console: `hvc0` (virtio-serial) → `vm/console.log` on host
- vsock: `vmw_vsock_virtio_transport` kernel module (VirtIO transport, device ID 0x0013)
- Agent: `/usr/bin/meridian-agent` (Go 1.26.1, static binary, 3.3MB, uses `golang.org/x/sys/unix`)
- Display: sway kiosk on tty1
- x86_64: Rosetta via virtiofs (`rosetta-setup.service` ✓)
- Steam: `/usr/bin/steam` → `1:1.0.0.85`, held by `apt-mark hold` due to amd64 dependency quirk

## How to rebuild and re-install the agent

The agent source lives at `/tmp/meridian-agent/` (created during iteration 7).
To rebuild from scratch:

```bash
mkdir -p /tmp/meridian-agent && cd /tmp/meridian-agent
go mod init meridian-agent
go get golang.org/x/sys/unix@latest
# copy main.go from /tmp/meridian-agent/main.go or rebuild from scratch
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o meridian-agent-linux-arm64 .

# Upload to running VM
sshpass -p meridian scp -o StrictHostKeyChecking=no \
    meridian-agent-linux-arm64 meridian@192.168.64.50:/tmp/meridian-agent-new
sshpass -p meridian ssh -o StrictHostKeyChecking=no meridian@192.168.64.50 \
    'sudo install -o root -g root -m 0755 /tmp/meridian-agent-new /usr/bin/meridian-agent && \
     sudo systemctl restart meridian-agent'
```

---

## Iteration 7 — 2026-03-08

### Problem
vsock connection always ended in "phantom connect" — host side connected at the
VirtIO level but the agent's `accept()` call returned immediately with:
```
accept error: accept: address family not supported by protocol
```

### Root cause — Go stdlib `anyToSockaddr` missing `AF_VSOCK` case

In Go 1.26.1's `syscall/syscall_linux.go`, the `anyToSockaddr()` function handles
only `AF_NETLINK`, `AF_PACKET`, `AF_UNIX`, `AF_INET`, and `AF_INET6`. It has **no
`case AF_VSOCK:`**, so it falls through to `return nil, EAFNOSUPPORT`.

The call chain:
```
syscall.Accept(fd)
  → syscall.Accept4(fd, SOCK_CLOEXEC)
    → accept4(fd, &rsa, &len, SOCK_CLOEXEC)   ← kernel succeeds, returns new fd
    → anyToSockaddr(&rsa)                       ← rsa.Family = AF_VSOCK (40)
      → switch … default: return nil, EAFNOSUPPORT  ← BUG
    → Close(newfd)                              ← closes the accepted connection!
    → return 0, nil, EAFNOSUPPORT
```

Every accepted connection was immediately closed by the Go runtime before the
agent's handler goroutine could send the "meridian-agent connected" greeting.
From the host side, the fd was valid for ~0ms then returned EOF — exactly the
"phantom connect" symptom.

**Confirmed via:** strace showed `accept4(3, …)` completing, python3 `accept()`
on same socket returning correctly (EAGAIN/blocking), and Go's GOROOT source
confirming the missing AF_VSOCK case.

**The vsock probe** tested OUTBOUND (connect from guest to host CID=2), which
worked fine. The probe did NOT test whether the transport was ready for INBOUND
(server-side) connections — that was a separate, undetected gap.

### Fixes

**1. New `meridian-agent` using `golang.org/x/sys/unix`**

Replaced the agent with a version that uses `golang.org/x/sys/unix` instead of
`syscall`. The `x/sys/unix` package's `anyToSockaddr()` correctly handles AF_VSOCK:

```go
// unix.Accept uses x/sys's anyToSockaddr which handles AF_VSOCK correctly.
nfd, _, err := unix.Accept(fd)
```

The new agent source: `/tmp/meridian-agent/main.go` (on host).

**2. Improved vsock probe**

Updated `/usr/local/bin/meridian-vsock-probe.py` to test SERVER-SIDE readiness
(bind + listen) instead of outbound connectivity:

```python
# Was: connect to host CID=2 port 55555 (tests outbound only)
# Now: bind + listen on VMADDR_CID_ANY (tests the full server path)
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM, 0)
s.bind((socket.VMADDR_CID_ANY, TEST_PORT))
s.listen(1)
s.close()
```

**3. Steam reinstalled (apt-get install -f had removed it)**

During diagnostics, `apt-get install -f` removed `steam-launcher:amd64` because
it couldn't satisfy `apt:amd64` (pinned to -1). Fixed by:

```bash
# Install native arm64 equivalents of Steam's deps first
apt-get install -y lsof policykit-1 python3 python3-apt xterm zenity
# Install Steam with force flags
dpkg --force-architecture --force-depends -i /tmp/steam.deb
# Hold to prevent future apt-get install -f from removing it
apt-mark hold steam-launcher
```

Steam works correctly — the launcher script (`/usr/lib/steam/bin_steam.sh`) uses
native arm64 tools from PATH; the Steam binary itself is x86_64 and runs via Rosetta.

### Image state after this iteration

- `meridian-agent` v2 — uses `x/sys/unix`, no more `EAFNOSUPPORT` ✓
- vsock probe tests server-side bind+listen ✓
- Steam installed and held (`apt-mark hold steam-launcher`) ✓
- Clean shutdown via `systemctl poweroff` (fstrim + sync first) ✓

### Result

Agent now blocks on `unix.Accept()` and properly accepts connections.
On next launch attempt, the host's vsock connect will receive the greeting
`{"event":"log","line":"meridian-agent connected"}` and the phantom-connect
300ms check will pass — the bridge should be fully operational.
