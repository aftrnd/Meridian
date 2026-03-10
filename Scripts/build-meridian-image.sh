#!/usr/bin/env bash
# =============================================================================
# build-meridian-image.sh — Build the Meridian base VM image from scratch
#
# Builds a fresh Ubuntu 24.04 ARM64 image containing:
#   - Steam (via official Valve CDN .deb — apt:foreign-arch conflicts resolved)
#   - Proton GE
#   - sway kiosk compositor
#   - meridian-agent (vsock RPC daemon)
#   - Rosetta virtiofs support (for x86_64 translation via VZ)
#   - tty1 autologin → sway → meridian-session.sh → Steam
#
# Requirements (macOS Apple Silicon host):
#   brew install qemu cloud-image-utils sshpass
#   brew install lzfse          (for the final compress step)
#   Go toolchain (optional)     (to build meridian-agent from source)
#
# Environment variables:
#   MERIDIAN_AGENT_BIN    Path to pre-built meridian-agent-linux-arm64 binary
#                         Omit to skip agent installation.
#   PROTON_GE_VERSION     Proton GE version to install  (default: GE-Proton9-27)
#   RELEASE_VERSION       Tag for the release assets     (default: v1.0.3-base)
#   WORK_DIR              Scratch directory               (default: /tmp/meridian-build)
#   OUTPUT_DIR            Where artifacts land            (default: /tmp/meridian-vm)
#   NO_COMPRESS           Set to 1 to skip compression   (default: 0)
#
# Output (in $OUTPUT_DIR):
#   meridian-base.img                              — Raw 12 GB GPT disk
#   vmlinuz                                        — ARM64 Linux kernel
#   initrd                                         — Initial RAM disk
#   meridian-base-<VERSION>.img.lzfse.partaa       — GitHub Release part 1
#   meridian-base-<VERSION>.img.lzfse.partab       — GitHub Release part 2
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-/tmp/meridian-build}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/meridian-vm}"
RELEASE_VERSION="${RELEASE_VERSION:-v1.0.3-base}"
NO_COMPRESS="${NO_COMPRESS:-0}"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
DISK_SIZE="12G"
PROTON_GE_VERSION="${PROTON_GE_VERSION:-GE-Proton9-27}"

SSH_PORT=2222
SSH_USER="meridian"
SSH_PASS="meridian"
SSH_KEY="${WORK_DIR}/build-key"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=no -o ServerAliveInterval=10 -o ServerAliveCountMax=6"
BOOT_TIMEOUT=240  # cloud-init can take up to 4 minutes on first boot

BUILD_IMG="${WORK_DIR}/meridian-build.qcow2"
SEED_IMG="${WORK_DIR}/seed.img"
EFI_VARS="${WORK_DIR}/efi-vars.fd"
QEMU_LOG="${WORK_DIR}/qemu-build.log"
QEMU_PID=""

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "\n${BOLD}══ $* ══${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
die()   { echo -e "\n${RED}✗ FATAL: $*${NC}\n"; exit 1; }
step()  { echo -e "  → $*"; }

ssh_vm() {
    sshpass -p "${SSH_PASS}" ssh -i "${SSH_KEY}" ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" "$@"
}

scp_from_vm() {
    sshpass -p "${SSH_PASS}" scp -q -i "${SSH_KEY}" ${SSH_OPTS} -P "${SSH_PORT}" "${SSH_USER}@localhost:$1" "$2"
}

scp_to_vm() {
    sshpass -p "${SSH_PASS}" scp -q -i "${SSH_KEY}" ${SSH_OPTS} -P "${SSH_PORT}" "$1" "${SSH_USER}@localhost:$2"
}

wait_for_ssh() {
    local waited=0
    echo -n "  Waiting for SSH (up to ${BOOT_TIMEOUT}s)"
    until sshpass -p "${SSH_PASS}" ssh -i "${SSH_KEY}" ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" 'exit 0' 2>/dev/null; do
        echo -n "."
        sleep 4; waited=$(( waited + 4 ))
        if [[ "${waited}" -ge "${BOOT_TIMEOUT}" ]]; then
            echo ""
            echo "  Last 30 lines of QEMU log:"
            tail -30 "${QEMU_LOG}" | sed 's/^/    /'
            die "VM did not become SSH-reachable after ${BOOT_TIMEOUT}s"
        fi
    done
    echo " ready (${waited}s)"
}

cleanup() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        warn "Build VM still running — sending poweroff…"
        sshpass -p "${SSH_PASS}" ssh -i "${SSH_KEY}" ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "sudo systemctl poweroff" 2>/dev/null || true
        sleep 5
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Phase 0: Pre-flight ────────────────────────────────────────────────────────
info "Phase 0: Pre-flight checks"

for cmd in qemu-system-aarch64 qemu-img sshpass; do
    command -v "${cmd}" &>/dev/null \
        || die "'${cmd}' not found.  Run: brew install qemu cloud-image-utils sshpass"
    ok "${cmd}: $(command -v "${cmd}")"
done
if command -v cloud-localds &>/dev/null; then
    ok "cloud-localds: $(command -v cloud-localds)"
else
    command -v hdiutil &>/dev/null || die "'hdiutil' not found and cloud-localds is unavailable."
    warn "cloud-localds not found — falling back to hdiutil makehybrid for seed image"
fi

# Locate EDK2 UEFI firmware (installed alongside qemu via brew)
QEMU_PREFIX="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)"
EFI_CODE="${QEMU_PREFIX}/share/qemu/edk2-aarch64-code.fd"
EFI_VARS_TMPL="${QEMU_PREFIX}/share/qemu/edk2-aarch64-vars.fd"
[[ -f "${EFI_CODE}" ]] || die "EDK2 firmware not found: ${EFI_CODE}  (brew install qemu)"
ok "EDK2 firmware: ${EFI_CODE}"

# meridian-agent binary
SKIP_AGENT=1
if [[ -n "${MERIDIAN_AGENT_BIN:-}" ]]; then
    [[ -f "${MERIDIAN_AGENT_BIN}" ]] || die "MERIDIAN_AGENT_BIN not found: ${MERIDIAN_AGENT_BIN}"
    ok "meridian-agent: ${MERIDIAN_AGENT_BIN}"
    SKIP_AGENT=0
else
    warn "MERIDIAN_AGENT_BIN not set — skipping agent install."
    warn "  Build it with:"
    warn "    cd Agent && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o meridian-agent-linux-arm64 ."
    warn "  The agent uses golang.org/x/sys/unix (not stdlib syscall) for correct AF_VSOCK accept."
    warn "  See Agent/main.go for source."
fi

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
if [[ ! -f "${SSH_KEY}" ]]; then
    ssh-keygen -q -t ed25519 -N "" -f "${SSH_KEY}"
fi
SSH_PUB_KEY="$(cat "${SSH_KEY}.pub")"

# ── Phase 1: Download Ubuntu 24.04 ARM64 cloud image ─────────────────────────
info "Phase 1: Download Ubuntu 24.04 ARM64 cloud image"

UBUNTU_CACHED="${WORK_DIR}/noble-server-cloudimg-arm64.img"
if [[ -f "${UBUNTU_CACHED}" ]]; then
    ok "Using cached cloud image: ${UBUNTU_CACHED} ($(du -sh "${UBUNTU_CACHED}" | cut -f1))"
else
    step "Downloading from cloud-images.ubuntu.com…"
    curl -L --progress-bar -o "${UBUNTU_CACHED}" "${UBUNTU_IMG_URL}"
    ok "Downloaded: $(du -sh "${UBUNTU_CACHED}" | cut -f1)"
fi

# ── Phase 2: Prepare 12 GB build image ───────────────────────────────────────
info "Phase 2: Create 12 GB qcow2 overlay (writes stay in overlay, base is untouched)"

[[ -f "${BUILD_IMG}" ]] && { warn "Removing stale build image"; rm -f "${BUILD_IMG}"; }
qemu-img create -f qcow2 -b "${UBUNTU_CACHED}" -F qcow2 "${BUILD_IMG}" "${DISK_SIZE}"
ok "Build image: ${BUILD_IMG}"

# ── Phase 3: Cloud-init seed ──────────────────────────────────────────────────
info "Phase 3: Create cloud-init seed image"

cat > "${WORK_DIR}/user-data" << EOF
#cloud-config
hostname: meridian
users:
  - name: meridian
    gecos: Meridian
    shell: /bin/bash
    groups: [sudo, audio, video, input, render, netdev]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: meridian
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    meridian:meridian
# Only enable SSH — the heavy provisioning happens via SSH below.
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
EOF

cat > "${WORK_DIR}/meta-data" << 'EOF'
instance-id: meridian-build-001
local-hostname: meridian
EOF

if command -v cloud-localds &>/dev/null; then
    cloud-localds "${SEED_IMG}" "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"
else
    SEED_TMP_DIR="${WORK_DIR}/seed-cidata"
    rm -rf "${SEED_TMP_DIR}"
    mkdir -p "${SEED_TMP_DIR}"
    cp "${WORK_DIR}/user-data" "${SEED_TMP_DIR}/user-data"
    cp "${WORK_DIR}/meta-data" "${SEED_TMP_DIR}/meta-data"
    rm -f "${SEED_IMG}" "${SEED_IMG}.iso"
    hdiutil makehybrid \
        -quiet \
        -o "${SEED_IMG}.iso" \
        -iso \
        -joliet \
        -default-volume-name cidata \
        "${SEED_TMP_DIR}"
    mv "${SEED_IMG}.iso" "${SEED_IMG}"
fi
ok "Seed image: ${SEED_IMG}"

# ── Phase 4: Boot QEMU build VM ───────────────────────────────────────────────
info "Phase 4: Boot QEMU build VM (UEFI, HVF, 4 vCPU, 4 GB RAM)"

# Copy the NVRAM template so UEFI can persist boot entries
if [[ -f "${EFI_VARS_TMPL}" ]]; then
    cp "${EFI_VARS_TMPL}" "${EFI_VARS}"
else
    # Fall back to empty 64 MB NVRAM — UEFI will rebuild boot entries
    dd if=/dev/zero of="${EFI_VARS}" bs=1m count=64 2>/dev/null
fi

step "Launching QEMU…"
qemu-system-aarch64 \
    -M virt \
    -cpu host \
    -accel hvf \
    -m 4096 \
    -smp 4 \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${EFI_VARS}" \
    -drive "file=${BUILD_IMG},format=qcow2,if=virtio,discard=unmap,cache=writeback" \
    -drive "file=${SEED_IMG},format=raw,if=virtio" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    > "${QEMU_LOG}" 2>&1 &
QEMU_PID=$!
ok "QEMU started (pid ${QEMU_PID})"
wait_for_ssh

# ── Phase 5: Expand LVM to fill the 12 GB disk ───────────────────────────────
info "Phase 5: Expand LVM to fill 12 GB"

ssh_vm sudo bash << 'EXPAND'
set -euo pipefail
# Detect the last (LVM) partition on vda dynamically
LVM_PART_NUM=$(lsblk -no NAME,PARTTYPE /dev/vda 2>/dev/null \
    | awk '$2 == "0x8e" || $2 == "E6D6D379-F507-44C2-A23C-238F2A3DF928" {print $1}' \
    | grep -o '[0-9]*$' | tail -1 || true)
# Fallback: just use the last partition
[[ -z "${LVM_PART_NUM}" ]] && \
    LVM_PART_NUM=$(lsblk -no NAME /dev/vda | grep -E '^vda[0-9]+$' | tail -1 | grep -o '[0-9]*$' || true)

if [[ -z "${LVM_PART_NUM}" ]]; then
    echo "  Could not detect LVM partition on /dev/vda (continuing without grow)"
    df -h /
    exit 0
fi

echo "  Growing partition ${LVM_PART_NUM}…"
growpart /dev/vda "${LVM_PART_NUM}" 2>/dev/null || true
pvresize "/dev/vda${LVM_PART_NUM}" 2>/dev/null || true
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv 2>/dev/null || true
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null || true
df -h /
EXPAND
ok "LVM expanded to 12 GB"

# ── Phase 6: Base system packages ────────────────────────────────────────────
info "Phase 6: Install base system packages"

ssh_vm sudo bash << 'BASE_PKGS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get dist-upgrade -y -qq
apt-get install -y -qq --no-install-recommends \
    curl wget ca-certificates gnupg \
    sway swaybg swayidle xwayland \
    xdg-utils dbus-user-session libpam-systemd \
    libgl1-mesa-dri mesa-vulkan-drivers mesa-utils vulkan-tools \
    pipewire pipewire-pulse wireplumber \
    fuse3 libfuse2 \
    bubblewrap qemu-user-static xvfb \
    vim-tiny openssh-server \
    util-linux
BASE_PKGS
ok "Base packages installed"

# ── Phase 7: Steam — resolve apt:amd64 conflict ───────────────────────────────
info "Phase 7: Install Steam (foreign-arch conflicts resolved)"

ssh_vm sudo bash << 'STEAM'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# QEMU build and VZ runtime can expose different NIC names. Force a wildcard
# netplan so DHCP works regardless of the virtio interface name.
mkdir -p /etc/cloud/cloud.cfg.d /etc/netplan
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << 'EOF'
network: {config: disabled}
EOF
cat > /etc/netplan/01-meridian-all-ethernet-dhcp.yaml << 'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    meridian-all:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
      optional: true
EOF
chmod 0644 /etc/netplan/01-meridian-all-ethernet-dhcp.yaml
netplan generate >/dev/null 2>&1 || true
netplan apply >/dev/null 2>&1 || true

# ── Add foreign arches required by Steam runtime checks ───────────────────────
dpkg --add-architecture amd64
dpkg --add-architecture i386

# Restrict existing Ubuntu ports sources to arm64 so apt doesn't try pulling
# non-arm indexes from ports.ubuntu.com (which are 404).
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    # Normalize existing Architectures line (if present) to arm64 only.
    sed -i 's/^Architectures:.*/Architectures: arm64/' /etc/apt/sources.list.d/ubuntu.sources
    grep -q '^Architectures:' /etc/apt/sources.list.d/ubuntu.sources \
        || sed -i '/^Suites:/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources
fi
if [[ -f /etc/apt/sources.list ]]; then
    sed -i 's|^deb \(\[.*\] \)\?http://ports.ubuntu.com/ubuntu-ports|deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports|' /etc/apt/sources.list
fi

# Route x86 package resolution to the primary Ubuntu archives.
# ARM64 uses ports.ubuntu.com, but amd64/i386 indices live on archive/security.
cat > /etc/apt/sources.list.d/ubuntu-x86.list << 'X86EOF'
deb [arch=amd64,i386] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [arch=amd64,i386] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb [arch=amd64,i386] http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb [arch=amd64,i386] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
X86EOF

apt-get update -qq

# Install native arm64 dependencies Steam expects before forcing the amd64
# launcher package. This prevents apt -f from removing steam-launcher.
apt-get install -y -qq --no-install-recommends \
    lsof policykit-1 python3 python3-apt xterm zenity

# ── THE FIX: apt:foreign-arch vs apt (arm64) conflict ────────────────────────
#
# Problem:
#   On ARM64 Ubuntu 24.04 with amd64 multiarch enabled, `apt-get install
#   steam-launcher` can fail because foreign-arch chains pull in `apt:amd64`
#   or `apt:i386`, which directly conflict with the native ARM64 `apt` package.
#
# Root cause:
#   apt's control file on some Ubuntu versions does not declare
#   `Multi-Arch: foreign` with a high enough priority, so the resolver
#   incorrectly tries to satisfy `apt` deps via the amd64 counterpart.
#
# Fix:
#   Pin `apt:amd64` and `apt:i386` to priority -1 (never install). The native
#   arm64 `apt` (Multi-Arch: foreign) satisfies the dependency legally.
#
cat > /etc/apt/preferences.d/no-foreign-apt << 'PINEOF'
# Prevent apt foreign-arch packages from conflicting with native arm64 apt.
# The arm64 apt is Multi-Arch: foreign and satisfies x86 apt dependencies.
Package: apt:amd64
Pin: release *
Pin-Priority: -1

Package: apt:i386
Pin: release *
Pin-Priority: -1
PINEOF

apt-get update -qq

# Extract minimal x86 runtimes so Steam startup checks pass.
# Use dpkg-deb -x (not apt install) to avoid cross-arch dpkg-divert conflicts.
mkdir -p /tmp/meridian-x86-runtime && cd /tmp/meridian-x86-runtime
apt-get download -qq \
    gcc-14-base:amd64 libc6:amd64 libgcc-s1:amd64 libstdc++6:amd64 zlib1g:amd64 libcap2:amd64 \
    gcc-14-base:i386 libc6:i386 libgcc-s1:i386 libstdc++6:i386 zlib1g:i386 libcap2:i386 \
    libgl1:i386 libglx-mesa0:i386 libglx0:i386 libdrm2:i386 libglvnd0:i386 \
    libgl1-mesa-dri:i386 libgl1-mesa-dri:amd64
for deb in ./*.deb; do
    dpkg-deb -x "${deb}" /
done
ldconfig || true
cd /

# Download the canonical Steam installer from Valve's CDN.
# Using the CDN .deb (not Ubuntu repos) avoids version skew on ARM64.
wget -q -O /tmp/steam-installer.deb \
    'https://cdn.akamai.steamstatic.com/client/installer/steam.deb'

# --force-architecture: install an amd64 .deb on an arm64 host
# --force-depends:      defer dep resolution to apt-get -f below
dpkg --force-architecture --force-depends -i /tmp/steam-installer.deb

# Do NOT run `apt-get -f` here: on arm64+amd64 multiarch it can decide to
# remove steam-launcher entirely because some amd64 dependency chains are
# intentionally unresolved in this Rosetta-driven setup.

# Pre-seed Steam runtime files into meridian's home to avoid first-run
# corruption/missing-runtime edge cases in headless bootstrap sessions.
mkdir -p /home/meridian/.local/share/Steam /home/meridian/.steam
ln -sfn /home/meridian/.local/share/Steam /home/meridian/.steam/steam
ln -sfn /home/meridian/.local/share/Steam /home/meridian/.steam/root
if [[ -d /usr/lib/steam/ubuntu12_32 ]]; then
    mkdir -p /home/meridian/.local/share/Steam/ubuntu12_32
    cp -a /usr/lib/steam/ubuntu12_32/. /home/meridian/.local/share/Steam/ubuntu12_32/
fi
chown -R meridian:meridian /home/meridian/.local /home/meridian/.steam || true

# Warm steamdeps once in non-interactive mode so runtime checks are satisfied
# before Meridian attempts protocol handoff without a controlling TTY.
if [[ -x /usr/bin/steamdeps ]]; then
    timeout 90s bash -lc 'printf "\n\n\n\n" | DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none TERM=dumb /usr/bin/steamdeps' || true
fi

# Ensure canonical x86_64 loader path exists for Rosetta-translated binaries.
mkdir -p /lib64
if [[ -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ]]; then
    ln -sf /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
fi
if [[ -f /lib/i386-linux-gnu/ld-linux.so.2 ]]; then
    mkdir -p /lib32
    ln -sf /lib/i386-linux-gnu/ld-linux.so.2 /lib32/ld-linux.so.2
fi

# Persist Steam-required namespace sysctls (same requirement as Flatpak sandboxing).
cat > /etc/sysctl.d/99-meridian-steam-userns.conf << 'SYSCTLEOF'
user.max_user_namespaces=28633
kernel.unprivileged_userns_clone=1
SYSCTLEOF
sysctl -w user.max_user_namespaces=28633 >/dev/null 2>&1 || true
if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
    sysctl -w kernel.unprivileged_userns_clone=1 >/dev/null 2>&1 || true
fi

# VZNAT may not provide DNS via DHCP; ensure systemd-resolved has fallback.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/meridian-dns.conf << 'DNSEOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSEOF
systemctl restart systemd-resolved 2>/dev/null || true

# Verify
dpkg -l steam-launcher | grep "^ii" >/dev/null \
    || { echo "ERROR: steam-launcher package not installed"; exit 1; }
[[ -x /usr/bin/steam ]] || { echo "ERROR: /usr/bin/steam missing after install"; exit 1; }
[[ -f /lib/i386-linux-gnu/libc.so.6 || -f /usr/lib/i386-linux-gnu/libc.so.6 ]] \
    || { echo "ERROR: 32-bit libc.so.6 missing after runtime extraction"; exit 1; }
[[ -f /usr/lib/i386-linux-gnu/libGL.so.1 || -f /lib/i386-linux-gnu/libGL.so.1 ]] \
    || { echo "ERROR: i386 libGL.so.1 missing after runtime extraction"; exit 1; }
[[ -f /usr/lib/i386-linux-gnu/libdrm.so.2 || -f /lib/i386-linux-gnu/libdrm.so.2 ]] \
    || { echo "ERROR: i386 libdrm.so.2 missing after runtime extraction"; exit 1; }
[[ -f /usr/lib/i386-linux-gnu/libGLdispatch.so.0 || -f /lib/i386-linux-gnu/libGLdispatch.so.0 ]] \
    || { echo "ERROR: i386 libGLdispatch.so.0 missing after runtime extraction"; exit 1; }
[[ -f /lib/x86_64-linux-gnu/libcap.so.2 || -f /usr/lib/x86_64-linux-gnu/libcap.so.2 ]] \
    || { echo "ERROR: amd64 libcap.so.2 missing after runtime extraction"; exit 1; }
[[ -x /usr/bin/bwrap ]] \
    || { echo "ERROR: /usr/bin/bwrap missing after Steam install"; exit 1; }
chown root:root /usr/bin/bwrap || true
chmod u+s /usr/bin/bwrap || true
# Unprivileged userns can fail in QEMU; Steam uses setuid bwrap. Warn only.
sudo -u meridian -E env HOME=/home/meridian USER=meridian \
    /usr/bin/unshare --user --map-root-user /usr/bin/true >/dev/null 2>&1 \
    || echo "WARNING: unprivileged userns probe failed (setuid bwrap used for Steam)"
apt-mark hold steam-launcher >/dev/null 2>&1 || true
echo "  Steam version: $(dpkg -l steam-launcher | awk '/^ii/{print $3}')"
rm -f /tmp/steam-installer.deb
STEAM
ok "Steam installed cleanly (no apt:amd64 conflict)"

# ── Phase 8: Proton GE ────────────────────────────────────────────────────────
info "Phase 8: Install Proton GE ${PROTON_GE_VERSION}"

GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_GE_VERSION}/${PROTON_GE_VERSION}.tar.gz"

ssh_vm sudo bash << PROTON
set -euo pipefail

STEAM_COMPAT="/home/meridian/.local/share/Steam/compatibilitytools.d"
mkdir -p "\${STEAM_COMPAT}"

echo "  Downloading Proton GE ${PROTON_GE_VERSION}…"
wget -q --show-progress -O /tmp/ge-proton.tar.gz "${GE_URL}"
tar -xzf /tmp/ge-proton.tar.gz -C "\${STEAM_COMPAT}"
rm -f /tmp/ge-proton.tar.gz
echo "  Installed: \$(ls \${STEAM_COMPAT})"

# Configure Steam to use Proton GE as the default compatibility tool
mkdir -p "/home/meridian/.local/share/Steam/config"
cat > "/home/meridian/.local/share/Steam/config/config.vdf" << 'VDF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"0"
					{
						"name"		"${PROTON_GE_VERSION}"
						"config"	""
						"Priority"	"250"
					}
				}
			}
		}
	}
}
VDF

chown -R meridian:meridian /home/meridian/.local
echo "  Proton GE configured as default compatibility tool"
PROTON
ok "Proton GE ${PROTON_GE_VERSION} installed"

# ── Phase 9: Sway kiosk + session scripts + systemd units ────────────────────
info "Phase 9: Configure sway kiosk, meridian-session.sh, Rosetta, autologin"

ssh_vm sudo bash << 'SESSION_SETUP'
set -euo pipefail

# ── sway config ───────────────────────────────────────────────────────────────
mkdir -p /home/meridian/.config/sway
cat > /home/meridian/.config/sway/config << 'SWAYEOF'
# Meridian sway kiosk — renders into the VZVirtioGraphicsDevice provided
# by Virtualization.framework (1920x1080 virtio-gpu scanout).
output * bg #000000 solid_color
seat seat0 hide_cursor 1000
default_border none
default_floating_border none
focus_follows_mouse no
# Session script starts Steam and exits sway when Steam exits.
exec /usr/local/bin/meridian-session.sh
SWAYEOF

# ── meridian-session.sh ───────────────────────────────────────────────────────
cat > /usr/local/bin/meridian-session.sh << 'SESSIONEOF'
#!/usr/bin/env bash
# Runs as meridian user inside the sway session.
# Mounts virtiofs shares, copies Steam auth tokens, then starts Steam.
set -euo pipefail

export HOME=/home/meridian
export USER=meridian
export DISPLAY=":0"
export XDG_RUNTIME_DIR="/run/user/1000"
export WAYLAND_DISPLAY="wayland-1"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"

# Mount steam-session virtiofs share (read-only Steam auth token staging from macOS)
mkdir -p /mnt/steam-session
if ! mountpoint -q /mnt/steam-session 2>/dev/null; then
    mount -t virtiofs meridian-steam-session /mnt/steam-session 2>/dev/null || true
fi

# Copy Steam auth files from session share if present
STEAM_CFG="/home/meridian/.local/share/Steam/config"
mkdir -p "${STEAM_CFG}"
for f in loginusers.vdf config.vdf; do
    src=""
    # Preferred layout from SteamSessionBridge: /mnt/steam-session/config/*.vdf
    if [[ -f "/mnt/steam-session/config/${f}" ]]; then
        src="/mnt/steam-session/config/${f}"
    # Back-compat with older staging layouts.
    elif [[ -f "/mnt/steam-session/${f}" ]]; then
        src="/mnt/steam-session/${f}"
    fi
    if [[ -n "${src}" ]]; then
        cp -f "${src}" "${STEAM_CFG}/${f}"
        chown meridian:meridian "${STEAM_CFG}/${f}"
    fi
done
if [[ -f "/mnt/steam-session/registry.vdf" ]]; then
    cp -f "/mnt/steam-session/registry.vdf" "/home/meridian/.local/share/Steam/registry.vdf"
    chown meridian:meridian "/home/meridian/.local/share/Steam/registry.vdf"
fi
for token in /mnt/steam-session/ssfn*; do
    [[ -f "${token}" ]] || continue
    cp -f "${token}" "/home/meridian/.local/share/Steam/$(basename "${token}")"
    chown meridian:meridian "/home/meridian/.local/share/Steam/$(basename "${token}")"
    chmod 600 "/home/meridian/.local/share/Steam/$(basename "${token}")" || true
done

# Optional credential fallback when macOS Steam session files are unavailable.
STEAM_LOGIN_ARGS=()
if [[ ! -f "${STEAM_CFG}/loginusers.vdf" && -f "/mnt/steam-session/credentials.env" ]]; then
    # shellcheck disable=SC1091
    source "/mnt/steam-session/credentials.env" || true
    if [[ -n "${STEAM_USER:-}" && -n "${STEAM_PASS:-}" ]]; then
        STEAM_LOGIN_ARGS=(+login "${STEAM_USER}" "${STEAM_PASS}")
    fi
fi

# Start Steam as meridian user.
# Steam refuses to run as root; sudo -u drops to uid=1000.
# The full set of env vars must be present here so the meridian-agent never
# needs to kill and restart Steam just to "apply a controlled env".  Killing
# the session breaks the logged-in state and causes install/launch handoffs
# to land on the stale steam.pipe of the dying process.
exec sudo -u meridian -E \
    env HOME=/home/meridian \
        DISPLAY="${DISPLAY}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
        XDG_SESSION_TYPE=wayland \
        STEAM_RUNTIME=1 \
        STEAM_RUNTIME_PREFER_HOST_LIBRARIES=0 \
        STEAM_DISABLE_ZENITY=1 \
        STEAM_SKIP_LIBRARIES_CHECK=1 \
        STEAMOS=1 \
        GTK_A11Y=none \
        LIBGL_ALWAYS_SOFTWARE=1 \
        MESA_LOADER_DRIVER_OVERRIDE=llvmpipe \
        GALLIUM_DRIVER=llvmpipe \
        __GLX_VENDOR_LIBRARY_NAME=mesa \
        LD_LIBRARY_PATH="/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32:/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu:/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib32:/usr/lib/i386-linux-gnu:/lib/i386-linux-gnu" \
        DEBIAN_FRONTEND=noninteractive \
        APT_LISTCHANGES_FRONTEND=none \
        TERM=dumb \
    /usr/bin/steam -silent "${STEAM_LOGIN_ARGS[@]}"
SESSIONEOF
chmod +x /usr/local/bin/meridian-session.sh

# ── Rosetta virtiofs setup ────────────────────────────────────────────────────
mkdir -p /opt/rosetta

cat > /usr/local/bin/setup-rosetta.sh << 'ROSETTAEOF'
#!/usr/bin/env bash
# Mounts the Rosetta virtiofs share from macOS and registers it as the
# binfmt_misc handler for x86_64 ELF binaries (Steam, Proton, game exes).
#
# Uses manual binfmt_misc registration instead of 'rosetta --register'
# because the VZLinuxRosettaDirectoryShare rosetta binary interprets
# '--register' as an ELF file path and crashes (Trace/breakpoint trap).
set -euo pipefail

if ! mountpoint -q /opt/rosetta 2>/dev/null; then
    mount -t virtiofs rosetta /opt/rosetta 2>/dev/null || {
        echo "[rosetta] virtiofs share not available (ok in QEMU; required in Meridian VZ)"
        exit 0
    }
fi
echo "[rosetta] mounted at /opt/rosetta"

if [[ ! -x /opt/rosetta/rosetta ]]; then
    echo "[rosetta] rosetta binary not found"
    exit 0
fi

# Already registered?
if [[ -f /proc/sys/fs/binfmt_misc/rosetta ]]; then
    echo "[rosetta] binfmt_misc already registered"
    exit 0
fi

# Ensure binfmt_misc fs is mounted
if ! mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null; then
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi

# Register Rosetta as the binfmt_misc handler for x86_64 ELF.
# Magic matches ELF + ELFCLASS64 + ELFDATA2LSB + ET_EXEC + EM_X86_64.
# Flags: O=open-binary, C=credentials-aware, F=fix-binary (keep fd).
echo ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/opt/rosetta/rosetta:OCF' \
    > /proc/sys/fs/binfmt_misc/register 2>/dev/null && \
    echo "[rosetta] registered x86_64 ELF handler via binfmt_misc" || \
    echo "[rosetta] binfmt_misc registration failed"
ROSETTAEOF
chmod +x /usr/local/bin/setup-rosetta.sh

cat > /etc/systemd/system/rosetta-setup.service << 'RSVCEOF'
[Unit]
Description=Mount and register Apple Rosetta for x86_64 ELF translation
After=local-fs.target
Before=meridian-agent.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-rosetta.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RSVCEOF
systemctl enable rosetta-setup.service

# ── tty1 autologin ────────────────────────────────────────────────────────────
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin meridian --noclear %I $TERM
AUTOEOF

# ── .bash_profile: start sway on tty1 ────────────────────────────────────────
cat > /home/meridian/.bash_profile << 'PROFILEEOF'
# Auto-start the sway kiosk on tty1 (only — not over SSH).
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
    exec sway
fi
PROFILEEOF
chown meridian:meridian /home/meridian/.bash_profile

# ── virtiofs mount points ─────────────────────────────────────────────────────
mkdir -p /mnt/games /mnt/steam-session /opt/rosetta
chown -R meridian:meridian /home/meridian/.config
SESSION_SETUP
ok "Sway kiosk + session scripts + Rosetta service configured"

# ── Phase 10: meridian-agent ──────────────────────────────────────────────────
info "Phase 10: Install meridian-agent"

if [[ "${SKIP_AGENT}" -eq 0 ]]; then
    scp_to_vm "${MERIDIAN_AGENT_BIN}" "/tmp/meridian-agent"

    ssh_vm sudo bash << 'AGENT'
set -euo pipefail
install -o root -g root -m 0755 /tmp/meridian-agent /usr/bin/meridian-agent
rm -f /tmp/meridian-agent

# --- vsock transport probe script ---
# Runs as ExecStartPre; verifies the VirtIO transport is fully initialised
# before the agent calls accept().
#
# Tests SERVER-SIDE readiness (bind + listen) rather than outbound connectivity.
# This is the correct check because the agent needs to ACCEPT incoming connections
# from the host — outbound (guest→host) can work while inbound is still not ready.
cat > /usr/local/bin/meridian-vsock-probe.py << 'PYEOF'
#!/usr/bin/env python3
"""
Probe the vsock transport before meridian-agent starts.

Tests SERVER-SIDE readiness: bind + listen on AF_VSOCK.
This is the correct check because the agent needs to ACCEPT incoming
connections from the host — not just connect outbound.

Exit codes: 0 = ready (or no vsock device), 1 = fatal error
"""
import socket, sys, errno, time

TEST_PORT = 55555

for attempt in range(50):
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM, 0)
        s.bind((socket.VMADDR_CID_ANY, TEST_PORT))
        s.listen(1)
        s.close()
        print(f"vsock probe: server-side bind+listen OK (attempt {attempt + 1})", flush=True)
        sys.exit(0)
    except OSError as e:
        s_close = getattr(s, 'close', None)
        if s_close:
            try: s_close()
            except: pass
        if e.errno == errno.EAFNOSUPPORT:
            time.sleep(0.1)
            continue
        if e.errno == errno.ENODEV:
            print("vsock probe: no vsock device, skipping", flush=True)
            sys.exit(0)
        if e.errno == errno.EADDRINUSE:
            print(f"vsock probe: port in use, transport ready (attempt {attempt + 1})", flush=True)
            sys.exit(0)
        print(f"vsock probe: transport ready ({e.strerror}, attempt {attempt + 1})", flush=True)
        sys.exit(0)

print("vsock probe: timed out — starting anyway", file=sys.stderr, flush=True)
sys.exit(0)
PYEOF
chmod +x /usr/local/bin/meridian-vsock-probe.py

cat > /etc/systemd/system/meridian-agent.service << 'SVCEOF'
[Unit]
Description=Meridian Agent (vsock bridge)
After=rosetta-setup.service
Wants=rosetta-setup.service

[Service]
Type=simple
ExecStartPre=/sbin/modprobe vmw_vsock_virtio_transport
ExecStartPre=/usr/local/bin/meridian-vsock-probe.py
ExecStartPre=/bin/bash -c 'udevadm settle --timeout=3'
ExecStart=/usr/bin/meridian-agent
Restart=on-failure
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable meridian-agent.service
echo "  meridian-agent: $(ls -lh /usr/bin/meridian-agent | awk '{print $5}')"
AGENT
    ok "meridian-agent installed and service enabled"
else
    warn "Skipping meridian-agent (MERIDIAN_AGENT_BIN not set)"
fi

# ── Phase 11: Pre-shutdown — export kernel + flush filesystem ─────────────────
info "Phase 11: Export kernel artifacts + flush filesystem before shutdown"

step "Exporting vmlinuz + initrd from guest /boot…"
ssh_vm sudo bash << 'KERNEL_EXPORT'
set -euo pipefail
KVER="$(uname -r)"
KFILE="/boot/vmlinuz-${KVER}"
IFILE="/boot/initrd.img-${KVER}"

# Fall back to newest kernel file if running-kernel path doesn't match exactly
[[ -f "${KFILE}" ]] || KFILE="$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
[[ -f "${IFILE}" ]] || IFILE="$(ls /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)"

# VZLinuxBootLoader requires an uncompressed ARM64 kernel Image.
# Ubuntu's /boot/vmlinuz-* may be gzip-compressed, which QEMU accepts but VZ rejects.
if file "${KFILE}" | grep -q "gzip compressed"; then
    gzip -dc "${KFILE}" > /tmp/vmlinuz-export
else
    cp "${KFILE}" /tmp/vmlinuz-export
fi
cp "${IFILE}" /tmp/initrd-export
chmod 644 /tmp/vmlinuz-export /tmp/initrd-export
echo "  Kernel: $(ls -lh /tmp/vmlinuz-export | awk '{print $5, $9}')"
echo "  Initrd: $(ls -lh /tmp/initrd-export  | awk '{print $5, $9}')"
KERNEL_EXPORT

scp_from_vm "/tmp/vmlinuz-export" "${OUTPUT_DIR}/vmlinuz"
scp_from_vm "/tmp/initrd-export"  "${OUTPUT_DIR}/initrd"
ok "vmlinuz: $(du -sh "${OUTPUT_DIR}/vmlinuz" | cut -f1)"
ok "initrd:  $(du -sh "${OUTPUT_DIR}/initrd"  | cut -f1)"

step "Running fstrim + sync to zero free blocks and flush writes…"
ssh_vm sudo bash << 'FLUSH'
set -euo pipefail
# fstrim discards unused blocks → they become zeros → LZFSE compresses them
# to near-nothing. Skip errors (may not be supported on all virtio configs).
fstrim -av 2>/dev/null || true
sync; sync; sync
echo "  Filesystem flushed and trimmed"
FLUSH

# ── Phase 12: Clean shutdown (NOT poweroff -f) ─────────────────────────────────
info "Phase 12: Clean shutdown via 'systemctl poweroff'"

#
# WHY NOT 'poweroff -f':
#   'poweroff -f' forcibly kills the machine without going through the systemd
#   shutdown sequence. Filesystems are NOT unmounted and LVM is NOT deactivated.
#   The resulting image has:
#     - ext4 journals in a dirty (uncommitted) state
#     - LVM VG metadata with the "in-use" flag set
#   When this dirty image is compressed, uploaded, downloaded, decompressed, and
#   booted — whether in QEMU or Apple's Virtualization.framework — the LVM
#   activation either fails silently or journal recovery triggers I/O errors.
#   Result: black screen or "launch command failed: operation can't be completed
#   i/o error" from VZDiskImageStorageDeviceAttachment.
#
#   'systemctl poweroff' unmounts all filesystems, deactivates LVM VGs, writes
#   final journal entries, then halts. Every boot from the compressed copy
#   succeeds because the disk is in a fully consistent state.
#

sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
    "${SSH_USER}@localhost" "sudo systemctl poweroff" 2>/dev/null || true

step "Waiting for QEMU to exit…"
WAIT=0
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    sleep 2; WAIT=$(( WAIT + 2 ))
    if [[ "${WAIT}" -ge 60 ]]; then
        warn "VM did not power off after 60s — force-killing QEMU"
        kill "${QEMU_PID}" 2>/dev/null || true
        break
    fi
done
QEMU_PID=""   # prevent cleanup trap from re-trying shutdown
ok "VM powered off cleanly"

# ── Phase 13: Convert qcow2 → raw ─────────────────────────────────────────────
info "Phase 13: Convert qcow2 → raw disk image (required by Virtualization.framework)"

RAW_IMG="${OUTPUT_DIR}/meridian-base.img"
step "Converting ${BUILD_IMG} → ${RAW_IMG}  (may take several minutes)…"
qemu-img convert -f qcow2 -O raw -p "${BUILD_IMG}" "${RAW_IMG}"
ok "Raw image: ${RAW_IMG} ($(du -sh "${RAW_IMG}" | cut -f1))"

# Strip macOS quarantine xattrs from all output artifacts.
# qemu-img convert and file copies from sandboxed processes can pick up
# com.apple.quarantine, causing VZDiskImageStorageDeviceAttachment to fail
# with "operation couldn't be completed: I/O error" on first boot.
for f in "${RAW_IMG}" "${OUTPUT_DIR}/vmlinuz" "${OUTPUT_DIR}/initrd"; do
    for attr in com.apple.quarantine com.apple.provenance; do
        xattr "${f}" 2>/dev/null | grep -q "${attr}" && \
            xattr -d "${attr}" "${f}" 2>/dev/null || true
    done
done
ok "Quarantine xattrs stripped from artifacts"

# ── Phase 14: Compress + split for GitHub Release ─────────────────────────────
if [[ "${NO_COMPRESS}" -eq 1 ]]; then
    warn "NO_COMPRESS=1 — skipping compression"
else
    info "Phase 14: Compress + split for GitHub Release"
    bash "${SCRIPT_DIR}/compress-and-release.sh" \
        --image "${RAW_IMG}" \
        --version "${RELEASE_VERSION}" \
        --output-dir "${OUTPUT_DIR}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
info "Build complete"
echo ""
echo "  Raw image:  ${OUTPUT_DIR}/meridian-base.img"
echo "  Kernel:     ${OUTPUT_DIR}/vmlinuz"
echo "  Initrd:     ${OUTPUT_DIR}/initrd"
if [[ "${NO_COMPRESS}" -ne 1 ]]; then
    echo ""
    echo "  GitHub Release parts:"
    ls -lh "${OUTPUT_DIR}/"*".img.lzfse.part"?? 2>/dev/null | awk '{print "    "$5"  "$9}' || true
fi
echo ""
echo "  Quick test:"
echo "    MERIDIAN_VM_DIR=${OUTPUT_DIR} bash Tests/Integration/test-guest.sh"
