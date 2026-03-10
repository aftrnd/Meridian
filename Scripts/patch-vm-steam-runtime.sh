#!/usr/bin/env bash
set -euo pipefail

# Boot local meridian-base.img in QEMU, patch Steam runtime prerequisites,
# then cleanly shut down and strip quarantine xattrs.

SANDBOX="${HOME}/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm"
BASE_IMG="${SANDBOX}/meridian-base.img"
KERNEL="${SANDBOX}/vmlinuz"
INITRD="${SANDBOX}/initrd"
WORK_DIR="/tmp/meridian-steam-patch-$$"
EFI_VARS="${WORK_DIR}/efi-vars.fd"
QEMU_LOG="${WORK_DIR}/qemu.log"
QEMU_PID=""

SSH_PORT=2222
SSH_USER="meridian"
SSH_PASS="meridian"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR"
MERIDIAN_AGENT_BIN="${MERIDIAN_AGENT_BIN:-}"

cleanup() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "sudo systemctl poweroff" 2>/dev/null || true
        sleep 5
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
    # Print QEMU log on exit so failures (e.g. image-locked, boot errors) are visible.
    if [[ -f "${QEMU_LOG}" ]] && [[ -s "${QEMU_LOG}" ]]; then
        echo "--- QEMU log ---"
        cat "${QEMU_LOG}"
        echo "--- end QEMU log ---"
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

command -v qemu-system-aarch64 >/dev/null || { echo "qemu-system-aarch64 missing"; exit 1; }
command -v sshpass >/dev/null || { echo "sshpass missing"; exit 1; }
[[ -f "${BASE_IMG}" ]] || { echo "missing ${BASE_IMG}"; exit 1; }
[[ -f "${KERNEL}" ]] || { echo "missing ${KERNEL}"; exit 1; }
[[ -f "${INITRD}" ]] || { echo "missing ${INITRD}"; exit 1; }

# Abort early if the base image is already locked (VM is running).
# QEMU will silently fail to open a write-locked file, causing a 2-minute timeout.
if lsof "${BASE_IMG}" 2>/dev/null | grep -q .; then
    echo "ERROR: meridian-base.img is held open by another process (stop the Meridian VM before patching):"
    lsof "${BASE_IMG}" 2>/dev/null
    exit 1
fi

QEMU_PREFIX="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)"
EFI_CODE="${QEMU_PREFIX}/share/qemu/edk2-aarch64-code.fd"
[[ -f "${EFI_CODE}" ]] || { echo "missing ${EFI_CODE}"; exit 1; }

mkdir -p "${WORK_DIR}"
EFI_VARS_TMPL="${QEMU_PREFIX}/share/qemu/edk2-aarch64-vars.fd"
[[ -f "${EFI_VARS_TMPL}" ]] && cp "${EFI_VARS_TMPL}" "${EFI_VARS}" \
    || dd if=/dev/zero of="${EFI_VARS}" bs=1m count=64 2>/dev/null

qemu-system-aarch64 \
    -M virt -cpu host -accel hvf -m 3072 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${EFI_VARS}" \
    -kernel "${KERNEL}" \
    -initrd "${INITRD}" \
    -append "root=/dev/vda1 rw console=ttyAMA0 loglevel=3" \
    -drive "file=${BASE_IMG},format=raw,if=virtio,readonly=off,discard=unmap,cache=unsafe" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic > "${QEMU_LOG}" 2>&1 &
QEMU_PID=$!

for _ in $(seq 1 60); do
    if sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "exit 0" 2>/dev/null; then
        break
    fi
    sleep 2
done

sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
    "sudo bash -s" <<'REMOTE_PATCH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# Stop background package managers before touching dpkg to avoid lock contention.
# unattended-upgrades holds /var/lib/dpkg/lock-frontend and causes silent failures.
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
# Wait up to 60s for any running dpkg/apt lock holder to finish.
for _i in $(seq 1 30); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 2
done

dpkg --add-architecture amd64
dpkg --add-architecture i386

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

# Keep ports mirror arm64-only, and route x86 arches to archive/security.
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  sed -i "s/^Architectures:.*/Architectures: arm64/" /etc/apt/sources.list.d/ubuntu.sources
  grep -q "^Architectures:" /etc/apt/sources.list.d/ubuntu.sources \
    || sed -i "/^Suites:/a Architectures: arm64" /etc/apt/sources.list.d/ubuntu.sources
fi
if [[ -f /etc/apt/sources.list ]]; then
  sed -i "s|^deb \(\[.*\] \)\?http://ports.ubuntu.com/ubuntu-ports|deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports|" /etc/apt/sources.list
fi
cat > /etc/apt/sources.list.d/ubuntu-x86.list << "EOF"
deb [arch=amd64,i386] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [arch=amd64,i386] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb [arch=amd64,i386] http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb [arch=amd64,i386] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
cat > /etc/apt/preferences.d/no-foreign-apt << "EOF"
Package: apt:amd64
Pin: release *
Pin-Priority: -1

Package: apt:i386
Pin: release *
Pin-Priority: -1
EOF
apt-get update -y
# If steam-launcher was force-installed earlier, apt may be in broken-deps state.
# Temporarily remove it so we can install the core amd64 runtime loader/libs.
dpkg -r steam-launcher:amd64 >/dev/null 2>&1 || dpkg -r steam-launcher >/dev/null 2>&1 || true
# Extract x86 runtimes directly to avoid dpkg-divert conflicts.
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
# Steam/Flatpak now require user namespaces. Persist the sysctls so future boots
# don't regress when Steam updates.
cat > /etc/sysctl.d/99-meridian-steam-userns.conf << "EOF"
user.max_user_namespaces=28633
kernel.unprivileged_userns_clone=1
EOF
sysctl -w user.max_user_namespaces=28633 || true
if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
  sysctl -w kernel.unprivileged_userns_clone=1 || true
fi
sysctl --system >/dev/null 2>&1 || true
# VZNAT may not provide DNS via DHCP; ensure systemd-resolved has fallback.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/meridian-dns.conf << "DNSEOF"
[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSEOF
systemctl restart systemd-resolved 2>/dev/null || true
# Install qemu-user-static (i386-on-ARM64), xvfb, xwayland, and native ARM64 Mesa
# BEFORE the force-install of steam-launcher, which leaves apt in a broken-deps
# state that blocks further apt-get installs. Must be done while apt is still in
# a consistent state.
# xwayland + libgl1-mesa-dri (ARM64) are required for glXChooseVisual to succeed:
# Steam's VGUI2 calls glXChooseVisual on the X11 display even in headless/install
# mode; Xvfb alone does not expose GLX visuals without native Mesa DRI. XWayland
# (backed by Mesa software rendering) provides proper GLX and is preferred over
# bare Xvfb when a Wayland compositor (sway) is already running.
# libgles2-mesa was renamed in Ubuntu 24.04; use libgles2 instead.
# Split into two calls so a single missing package can't abort the whole install.
apt-get install -y --no-install-recommends \
  qemu-user-static xvfb xwayland bubblewrap unzip \
  libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgles2 x11-utils || true
# xfonts-base provides the 'fixed' bitmap font that Xvfb requires at startup.
# Install separately so the above's optional failures can't block this critical dep.
apt-get install -y --no-install-recommends \
  xfonts-base xfonts-encodings xfonts-utils || true
# Wine/Proton runtime libraries — both i386 (wineserver32/wineboot) and amd64
# (wine64, the main Wine binary that runs under Rosetta on this arm64 host).
# Without the amd64 variants, wine64 cannot find libfreetype and fails on startup.
apt-get install -y --no-install-recommends \
  libfreetype6:i386 libfontconfig1:i386 \
  libglib2.0-0:i386 libdbus-1-3:i386 \
  libxcomposite1:i386 libxinerama1:i386 libxrandr2:i386 \
  libvulkan1:i386 2>/dev/null || true
apt-get install -y --no-install-recommends \
  libfreetype6:amd64 libfontconfig1:amd64 \
  libglib2.0-0:amd64 libdbus-1-3:amd64 \
  libxcomposite1:amd64 libxinerama1:amd64 libxrandr2:amd64 \
  libvulkan1:amd64 2>/dev/null || true
# mesa-vulkan-drivers:amd64 provides lavapipe (software Vulkan) and virtio
# (hardware Vulkan via virtio-gpu → Apple VZ Metal). DXVK inside Proton/Wine
# requires an x86-64 Vulkan ICD — without this, DXVK silently renders nothing.
# Install libc6:amd64 explicitly first (apt may refuse mesa-vulkan-drivers
# due to a multiarch libc version constraint if not pre-installed).
apt-get install -y libc6:amd64 2>/dev/null || true
apt-get install -y --no-install-recommends \
  mesa-vulkan-drivers:amd64 2>/dev/null || {
  # Fallback: download the deb and extract only the Vulkan ICD libraries.
  # This avoids dependency conflicts while still getting lavapipe/virtio.
  cd /tmp
  apt-get download mesa-vulkan-drivers:amd64 2>/dev/null && \
  dpkg-deb -x mesa-vulkan-drivers_*amd64*.deb /tmp/mesa-vk-extract 2>/dev/null && \
  find /tmp/mesa-vk-extract -name 'libvulkan_*.so*' -exec cp -n {} /usr/lib/x86_64-linux-gnu/ \; 2>/dev/null && \
  ldconfig 2>/dev/null && echo "mesa-vulkan-drivers: extracted ICD libs manually" || true
  rm -rf /tmp/mesa-vk-extract /tmp/mesa-vulkan-drivers_*.deb 2>/dev/null || true
  cd /
}
# Create the protonfixes config directory so Proton doesn't emit warnings
# about it missing on every launch.
mkdir -p /home/meridian/.config/protonfixes
chown -R meridian:meridian /home/meridian/.config
# Sway config: automatically fullscreen any new window so games fill the display.
# XWayland apps are matched by `class`; native Wayland apps by `app_id`.
mkdir -p /etc/sway/config.d
cat > /etc/sway/config.d/meridian-game.conf << 'SWAYEOF'
# Meridian: all windows fullscreen for immersive gaming
for_window [class="*"] fullscreen
for_window [app_id="*"] fullscreen
# Hide the status bar during gameplay
bar mode invisible
SWAYEOF
# Activate the i386 binfmt; disable qemu-x86_64 so Rosetta keeps sole ownership
# of x86_64 ELF dispatch. Remove the qemu-x86_64 binfmt config file so the
# rule stays disabled across reboots (rosetta-setup.service runs after systemd-
# binfmt, so Rosetta would re-register last regardless, but removing the file
# is the belt-and-suspenders approach).
update-binfmts --enable qemu-i386  2>/dev/null || true
update-binfmts --disable qemu-x86_64 2>/dev/null || true
rm -f /usr/share/binfmts/qemu-x86_64 2>/dev/null || true

# Re-install steam-launcher with force flags used by the base-image builder.
if [[ ! -f /tmp/steam-installer.deb ]]; then
  wget -q -O /tmp/steam-installer.deb https://cdn.akamai.steamstatic.com/client/installer/steam.deb
fi
dpkg --force-architecture --force-depends -i /tmp/steam-installer.deb || true
apt-mark hold steam-launcher >/dev/null 2>&1 || true
# Pre-seed Steam runtime assets into meridian's home so first launch does not
# fail on missing logger/runtime fragments in headless sessions.
mkdir -p /home/meridian/.local/share/Steam /home/meridian/.steam
ln -sfn /home/meridian/.local/share/Steam /home/meridian/.steam/steam
ln -sfn /home/meridian/.local/share/Steam /home/meridian/.steam/root
if [[ -d /usr/lib/steam/ubuntu12_32 ]]; then
  mkdir -p /home/meridian/.local/share/Steam/ubuntu12_32
  cp -a /usr/lib/steam/ubuntu12_32/. /home/meridian/.local/share/Steam/ubuntu12_32/
fi
chown -R meridian:meridian /home/meridian/.local /home/meridian/.steam || true
# DepotDownloader: native linux-arm64 Steam game downloader.
# No emulation (no qemu-user-static, no Rosetta), no GLX, no GUI.
# Downloads games via SteamPipe CDN using Steam credentials.
DEPOTDL_DIR="/opt/depotdownloader"
DEPOTDL_BIN="${DEPOTDL_DIR}/DepotDownloader"
DEPOTDL_VERSION="DepotDownloader_3.4.0"
DEPOTDL_URL="https://github.com/SteamRE/DepotDownloader/releases/download/${DEPOTDL_VERSION}/DepotDownloader-linux-arm64.zip"
if [[ ! -x "${DEPOTDL_BIN}" ]]; then
  mkdir -p "${DEPOTDL_DIR}"
  cd "${DEPOTDL_DIR}"
  wget -q -O depotdownloader.zip "${DEPOTDL_URL}"
  unzip -o depotdownloader.zip
  rm -f depotdownloader.zip
  chmod +x "${DEPOTDL_BIN}"
  cd /
fi
chown -R meridian:meridian "${DEPOTDL_DIR}"
# Remove broken steamcmd remnants if present.
rm -f /usr/local/bin/steamcmd 2>/dev/null || true
rm -rf /opt/steamcmd 2>/dev/null || true
# Warm steamdeps once in a non-interactive mode to avoid /dev/tty prompts later.
if [[ -x /usr/bin/steamdeps ]]; then
  timeout 90s bash -lc 'printf "\n\n\n\n" | DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none TERM=dumb /usr/bin/steamdeps' || true
fi
# Ensure Rosetta binfmt uses open-binary mode (OCF) for Steam runtime ELF execution.
if [[ -f /usr/local/bin/setup-rosetta.sh ]]; then
  sed -i "s/:CF'/:OCF'/g" /usr/local/bin/setup-rosetta.sh
  systemctl restart rosetta-setup.service >/dev/null 2>&1 || true
fi
mkdir -p /lib64
if [[ -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ]]; then
  ln -sf /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
fi
if [[ -f /lib/i386-linux-gnu/ld-linux.so.2 ]]; then
  mkdir -p /lib32
  ln -sf /lib/i386-linux-gnu/ld-linux.so.2 /lib32/ld-linux.so.2
fi
if [[ ! -f /lib/i386-linux-gnu/libc.so.6 && ! -f /usr/lib/i386-linux-gnu/libc.so.6 ]]; then
  echo "ERROR: 32-bit libc.so.6 missing after x86 runtime patch"
  exit 1
fi
if [[ ! -f /usr/lib/i386-linux-gnu/libGL.so.1 && ! -f /lib/i386-linux-gnu/libGL.so.1 ]]; then
  echo "ERROR: i386 libGL.so.1 missing after x86 runtime patch"
  exit 1
fi
if [[ ! -f /usr/lib/i386-linux-gnu/libdrm.so.2 && ! -f /lib/i386-linux-gnu/libdrm.so.2 ]]; then
  echo "ERROR: i386 libdrm.so.2 missing after x86 runtime patch"
  exit 1
fi
if [[ ! -f /usr/lib/i386-linux-gnu/libGLdispatch.so.0 && ! -f /lib/i386-linux-gnu/libGLdispatch.so.0 ]]; then
  echo "ERROR: i386 libGLdispatch.so.0 missing after x86 runtime patch"
  exit 1
fi
if [[ ! -f /lib/x86_64-linux-gnu/libcap.so.2 && ! -f /usr/lib/x86_64-linux-gnu/libcap.so.2 ]]; then
  echo "ERROR: amd64 libcap.so.2 missing after x86 runtime patch"
  exit 1
fi
# Steam's sandbox path uses bubblewrap. In some guest kernels the userns
# sysctls are enabled but unprivileged userns creation still fails unless bwrap
# is installed setuid-root. Enforce that here so runtime does not hang waiting
# for steam.pipe.
if [[ ! -x /usr/bin/bwrap ]]; then
  echo "ERROR: /usr/bin/bwrap missing after runtime patch"
  exit 1
fi
chown root:root /usr/bin/bwrap || true
chmod u+s /usr/bin/bwrap || true
# Patch steam launcher so host i386 GL/DRM come before steam-runtime pinned libs.
# The /usr/bin/steam script overwrites LD_LIBRARY_PATH; this ensures host Mesa
# is used and glXChooseVisual succeeds.
mkdir -p /etc/meridian
cat > /etc/meridian/steam-ldpath-prepend.sh << 'LDPATHEOF'
# Prepend host i386 Mesa before steam-runtime (glXChooseVisual fix)
export LD_LIBRARY_PATH="/usr/lib/i386-linux-gnu:/lib/i386-linux-gnu:${LD_LIBRARY_PATH}"
LDPATHEOF
steam_script=""
for c in /usr/lib/steam/bin_steam.sh /usr/lib/steam/steam.sh; do
  [ -f "$c" ] && steam_script="$c" && break
done
[ -z "$steam_script" ] && [ -f /usr/bin/steam ] && steam_script="/usr/lib/steam/bin_steam.sh"
if [ -n "$steam_script" ] && [ -f "$steam_script" ] && ! grep -q steam-ldpath-prepend "$steam_script" 2>/dev/null; then
  sed -i '/^[[:space:]]*exec[[:space:]]/i . /etc/meridian/steam-ldpath-prepend.sh 2>/dev/null || true' "$steam_script" || true
fi
# Unprivileged userns can fail in QEMU even with correct sysctls; Steam uses
# setuid bwrap which creates namespaces with privilege. Warn only.
if ! sudo -u meridian -E env HOME=/home/meridian USER=meridian \
    /usr/bin/unshare --user --map-root-user /usr/bin/true >/dev/null 2>&1; then
  echo "WARNING: unprivileged userns probe failed (setuid bwrap path used for Steam)"
fi
# Keep guest session-file handling aligned with SteamSessionBridge staging layout.
cat > /usr/local/bin/meridian-session.sh << 'SESSIONEOF'
#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/meridian
export USER=meridian
export XDG_RUNTIME_DIR="/run/user/1000"
export WAYLAND_DISPLAY="wayland-1"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
export DISPLAY=":0"

# Start Xvfb on :0 with Mesa software rendering and 24-bit colour depth.
#
# This provides working GLX visuals for Steam's VGUI2 layer (glXChooseVisual).
#
# WHY Xvfb and NOT XWayland:
#   The integration test (Tests/Integration/test-guest.sh "GLX functional probe")
#   proves that Xvfb + libgl1-mesa-dri + 24-bit depth satisfies glXChooseVisual.
#   XWayland was tried and failed silently in VZ mode: it starts, creates the
#   socket, then exits immediately because the glamor/EGL initialisation fails
#   (virtio-gpu does not support the EGL extensions glamor requires, and the
#   Wayland compositor is not always reachable when this script runs).
#   The agent's preflight reported "xdisplay_glx=true" from the stale socket
#   file, letting Steam proceed into a dead X server and crash at glXChooseVisual.
#
# REQUIREMENTS:
#   - libgl1-mesa-dri  (swrast_dri.so — Mesa software DRI driver)
#   - 24-bit screen depth (GLX requires depth 24; default Xvfb depth is 16)
#   - LIBGL_ALWAYS_SOFTWARE=1 + MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
_XSOCK="/tmp/.X11-unix/X0"
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# Do NOT start Xvfb on :0. Sway's XWayland owns :0 — overwriting it would
# break the sway → virtio-gpu rendering path that makes games visible in the
# host VZVirtualMachineView. Game installs use DepotDownloader (no display
# needed) so :0 can remain exclusively sway's.
#
# Wait for sway's XWayland to be ready on :0 instead.
_xwayland_ready=false
for _xw in $(seq 1 20); do
    if [ -S "${_XSOCK}" ]; then
        _xwayland_ready=true
        echo "meridian-session: sway XWayland ready on :0" >&2
        break
    fi
    sleep 0.5
done
if ! ${_xwayland_ready}; then
    echo "meridian-session: WARNING :0 not ready after 10s — sway/XWayland may not be running" >&2
fi

mkdir -p /mnt/steam-session
if ! mountpoint -q /mnt/steam-session 2>/dev/null; then
    mount -t virtiofs meridian-steam-session /mnt/steam-session 2>/dev/null || true
fi

STEAM_CFG="/home/meridian/.local/share/Steam/config"
mkdir -p "${STEAM_CFG}"
for f in loginusers.vdf config.vdf; do
    src=""
    if [[ -f "/mnt/steam-session/config/${f}" ]]; then
        src="/mnt/steam-session/config/${f}"
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

STEAM_LOGIN_ARGS=()
if [[ ! -f "${STEAM_CFG}/loginusers.vdf" && -f "/mnt/steam-session/credentials.env" ]]; then
    # shellcheck disable=SC1091
    source "/mnt/steam-session/credentials.env" || true
    if [[ -n "${STEAM_USER:-}" && -n "${STEAM_PASS:-}" ]]; then
        STEAM_LOGIN_ARGS=(+login "${STEAM_USER}" "${STEAM_PASS}")
    fi
fi

exec sudo -u meridian -E \
    env HOME=/home/meridian \
        DISPLAY="${DISPLAY}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
        XDG_SESSION_TYPE=wayland \
        STEAM_RUNTIME=1 \
        STEAM_RUNTIME_PREFER_HOST_LIBRARIES=1 \
        STEAM_DISABLE_ZENITY=1 \
        STEAM_SKIP_LIBRARIES_CHECK=1 \
        STEAMOS=1 \
        GTK_A11Y=none \
        LIBGL_ALWAYS_SOFTWARE=1 \
        MESA_LOADER_DRIVER_OVERRIDE=llvmpipe \
        GALLIUM_DRIVER=llvmpipe \
        __GLX_VENDOR_LIBRARY_NAME=mesa \
        LD_LIBRARY_PATH="/usr/lib/i386-linux-gnu:/lib/i386-linux-gnu:/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/i386-linux-gnu:/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib32:/home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/pinned_libs_32" \
        LIBGL_DRIVERS_PATH="/usr/lib/i386-linux-gnu/dri:/usr/lib/x86_64-linux-gnu/dri:/usr/lib/aarch64-linux-gnu/dri" \
        DEBIAN_FRONTEND=noninteractive \
        APT_LISTCHANGES_FRONTEND=none \
        TERM=dumb \
    /usr/bin/steam -silent "${STEAM_LOGIN_ARGS[@]}"
SESSIONEOF
chmod +x /usr/local/bin/meridian-session.sh
sync; sync; sync
REMOTE_PATCH

# Fix agent service: remove network-online.target so agent starts ASAP.
# Vsock does not need network; waiting for network-online can block indefinitely under VZ.
sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
    "sudo sed -i 's/ network-online\.target//g' /etc/systemd/system/meridian-agent.service 2>/dev/null || true"
sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
    "sudo systemctl daemon-reload 2>/dev/null || true"

# NOTE: The steam.deb ships ubuntu12_32/steam as a 32-bit i386 ELF.
# Rosetta only translates x86_64, not i386. Steam runs via qemu-i386-static
# (installed by REMOTE_PATCH). The meridian-agent detects qemu-wrapped Steam
# processes by checking for ubuntu12_32/steam in the process args, so no
# bootstrapping step is needed here.

if [[ -n "${MERIDIAN_AGENT_BIN}" ]]; then
    [[ -f "${MERIDIAN_AGENT_BIN}" ]] || { echo "missing MERIDIAN_AGENT_BIN: ${MERIDIAN_AGENT_BIN}"; exit 1; }
    sshpass -p "${SSH_PASS}" scp ${SSH_OPTS} -P "${SSH_PORT}" \
        "${MERIDIAN_AGENT_BIN}" "${SSH_USER}@localhost:/tmp/meridian-agent"
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
        "sudo bash -s" <<'REMOTE_AGENT'
set -euo pipefail
install -o root -g root -m 0755 /tmp/meridian-agent /usr/bin/meridian-agent
rm -f /tmp/meridian-agent
systemctl daemon-reload
systemctl restart meridian-agent.service || true
REMOTE_AGENT
fi

sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
    "sudo systemctl poweroff" 2>/dev/null || true

# Wait for QEMU to actually release the image file — do not just sleep 5.
# The old approach set QEMU_PID="" after a 5-second sleep, but QEMU can take
# longer to flush its write cache and exit, leaving an open fd on meridian-base.img.
# VZDiskImageStorageDeviceAttachment then fails with "storage device attachment is
# invalid" because it cannot acquire an exclusive lock on the file.
echo "Waiting for QEMU to exit…"
WAIT=0
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    sleep 2; WAIT=$(( WAIT + 2 ))
    if [[ "${WAIT}" -ge 60 ]]; then
        echo "QEMU did not exit after 60s — force-killing"
        kill -9 "${QEMU_PID}" 2>/dev/null || true
        sleep 2
        break
    fi
done
QEMU_PID=""

# Confirm the image file is no longer held open by any process.
if lsof "${BASE_IMG}" 2>/dev/null | grep -q .; then
    echo "WARNING: meridian-base.img still held open after QEMU exit — waiting 5 more seconds"
    sleep 5
fi

# scp and QEMU writes re-apply com.apple.quarantine on macOS.
# VZDiskImageStorageDeviceAttachment rejects quarantined files at runtime.
# Strip it from all VM artifacts now; VMConfiguration also strips at each boot.
for f in "${SANDBOX}/meridian-base.img" "${SANDBOX}/expansion.img" \
          "${SANDBOX}/vmlinuz" "${SANDBOX}/initrd"; do
    [[ -f "${f}" ]] || continue
    xattr -d com.apple.quarantine "${f}" 2>/dev/null || true
    xattr -d com.apple.provenance "${f}" 2>/dev/null || true
done

echo "Patched Steam runtime deps in ${BASE_IMG}"
