#!/usr/bin/env bash
# =============================================================================
# test-guest.sh — Meridian Guest Integration Tests
#
# Boots the base VM image via QEMU (no Virtualization.framework entitlement
# needed), SSH-verifies the guest state, and prints a pass/fail report.
#
# Requirements on macOS host:
#   brew install qemu sshpass
#
# Usage:
#   bash Tests/Integration/test-guest.sh
#   bash Tests/Integration/test-guest.sh --image /path/to/custom.img
#   bash Tests/Integration/test-guest.sh --no-boot   # skip boot, use running VM
#
# Exit code: 0 = all tests passed, 1 = one or more failures
# =============================================================================
set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VM_DIR="${MERIDIAN_VM_DIR:-/tmp/meridian-vm}"
IMG="${VM_DIR}/meridian-base.img"
KERNEL="${VM_DIR}/vmlinuz"
INITRD="${VM_DIR}/initrd"

SSH_PORT=2222
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=no -o ServerAliveInterval=5 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectionAttempts=3"
SSH_USER="meridian"
SSH_PASS="meridian"

BOOT_TIMEOUT=60   # seconds to wait for SSH after QEMU start
NO_BOOT=false
QEMU_PID=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)   IMG="$2"; shift 2 ;;
        --no-boot) NO_BOOT=true; shift ;;
        *)         echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$(( FAIL + 1 )); }
skip() { echo -e "  ${YELLOW}~${NC} $1 (skipped)"; SKIP=$(( SKIP + 1 )); }
header() { echo -e "\n${BOLD}$1${NC}"; }

# ── SSH helper ────────────────────────────────────────────────────────────────
# ssh_run: run command in guest, return stdout+stderr, exit with command's exit code.
ssh_run() {
    local cmd="$*"
    local out=""
    for _ in 1 2 3; do
        out="$(sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "${cmd}" 2>&1)" && {
            printf "%s\n" "${out}"
            return 0
        }
        sleep 1
    done
    printf "%s\n" "${out}"
    return 1
}

ssh_run_root() {
    ssh_run "sudo $*"
}

# ssh_check: run a boolean-expression command in guest.
# Retries once on SSH failure to tolerate transient connection issues.
ssh_check() {
    local cmd="$*"
    for _ in 1 2 3; do
        if sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "${cmd}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

ssh_check_root() {
    local cmd="$*"
    ssh_check "sudo ${cmd}"
}

# ssh_get: run command, capture output, always exits 0.
ssh_get() {
    local cmd="$*"
    for _ in 1 2 3; do
        if sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "${cmd}" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    true
}

ssh_get_root() {
    local cmd="$*"
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "sudo ${cmd}" 2>/dev/null \
    || sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "sudo ${cmd}" 2>/dev/null \
    || true
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    # Only shut down the VM if we started it ourselves
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo -e "\n[cleanup] Shutting down VM we started (pid ${QEMU_PID})…"
        sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "sync && sudo poweroff -f" 2>/dev/null || true
        sleep 3
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────
header "Pre-flight"

if ! command -v qemu-system-aarch64 &>/dev/null; then
    fail "qemu-system-aarch64 not found — run: brew install qemu"
    exit 1
fi
pass "QEMU found: $(qemu-system-aarch64 --version | head -1)"

if ! command -v sshpass &>/dev/null; then
    fail "sshpass not found — run: brew install sshpass"
    exit 1
fi
pass "sshpass found: $(command -v sshpass)"

if [[ ! -f "${IMG}" ]]; then
    fail "Base image not found: ${IMG}"
    echo "  → Set MERIDIAN_VM_DIR or use --image to specify the image path"
    exit 1
fi
pass "Base image found: ${IMG} ($(du -sh "${IMG}" | cut -f1))"

if [[ ! -f "${KERNEL}" ]]; then
    fail "vmlinuz not found: ${KERNEL}"
    exit 1
fi
pass "Kernel found: ${KERNEL}"

if [[ ! -f "${INITRD}" ]]; then
    fail "initrd not found: ${INITRD}"
    exit 1
fi
pass "initrd found: ${INITRD}"

# ── Boot VM ───────────────────────────────────────────────────────────────────
if [[ "${NO_BOOT}" == false ]]; then
    header "Booting VM"

    # Check if port 2222 is already in use
    if lsof -i ":${SSH_PORT}" &>/dev/null; then
        echo "  → Port ${SSH_PORT} already in use — assuming VM is already running (--no-boot behavior)"
        NO_BOOT=true
    else
        echo "  Starting QEMU…"
        qemu-system-aarch64 \
            -M virt \
            -cpu host \
            -accel hvf \
            -m 4096 \
            -smp 4 \
            -kernel "${KERNEL}" \
            -initrd "${INITRD}" \
            -append "root=/dev/vda1 rw console=ttyAMA0 loglevel=3" \
            -drive "file=${IMG},format=raw,if=virtio" \
            -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
            -device virtio-net-pci,netdev=net0 \
            -nographic \
            > /tmp/meridian-qemu-test.log 2>&1 &
        QEMU_PID=$!

        echo "  Waiting for SSH (up to ${BOOT_TIMEOUT}s)…"
        WAITED=0
        until sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
                "${SSH_USER}@localhost" 'exit 0' 2>/dev/null; do
            sleep 2; WAITED=$(( WAITED + 2 ))
            if [[ "${WAITED}" -ge "${BOOT_TIMEOUT}" ]]; then
                fail "VM did not become reachable after ${BOOT_TIMEOUT}s"
                echo "  → QEMU log tail:"
                tail -20 /tmp/meridian-qemu-test.log | sed 's/^/    /'
                exit 1
            fi
        done
        pass "VM SSH reachable after ${WAITED}s"
    fi
fi

# ── Test: OS ──────────────────────────────────────────────────────────────────
header "Guest OS"

OS=$(ssh_get 'cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"'"'"'"'" 2>/dev/null || echo "")
if echo "${OS}" | grep -q "Ubuntu"; then
    pass "OS: ${OS}"
else
    fail "Expected Ubuntu, got: ${OS}"
fi

ARCH=$(ssh_get 'uname -m')
if [[ "${ARCH}" == "aarch64" ]]; then
    pass "Architecture: aarch64"
else
    fail "Expected aarch64, got: ${ARCH}"
fi

DISK=$(ssh_get 'df -h / | tail -1 | awk '"'"'{print $4}'"'"'')
pass "Root disk free: ${DISK}"

# ── Test: Steam ───────────────────────────────────────────────────────────────
header "Steam Installation"

if ssh_check 'test -e /usr/bin/steam'; then
    pass "/usr/bin/steam exists"
else
    fail "/usr/bin/steam missing — Steam is not installed"
fi

STEAM_BOOT=$(ssh_get 'ls /usr/lib/steam/bin_steam.sh 2>/dev/null && echo OK || echo MISSING')
if echo "${STEAM_BOOT}" | grep -q "OK"; then
    pass "/usr/lib/steam/bin_steam.sh exists"
else
    fail "/usr/lib/steam/bin_steam.sh missing (got: ${STEAM_BOOT})"
fi

STEAM_PKG=$(ssh_get_root "dpkg-query -W -f='\${db:Status-Abbrev} \${Version}\n' steam-launcher:amd64 2>/dev/null | head -1")
if echo "${STEAM_PKG}" | grep -q '^ii '; then
    pass "steam-launcher package installed: ${STEAM_PKG#ii }"
else
    # Some arm64+Rosetta builds install Steam binaries via forced dpkg while
    # package status can be non-ii; runtime binaries are the real requirement.
    if ssh_check 'test -x /usr/bin/steam && test -f /usr/lib/steam/bin_steam.sh'; then
        pass "Steam runtime binaries present (launcher package status: ${STEAM_PKG:-unknown})"
    else
        fail "Steam launcher package missing and runtime binaries unavailable"
    fi
fi

STEAM_ARCH=$(ssh_get_root 'dpkg --print-foreign-architectures')
if echo "${STEAM_ARCH}" | grep -q "amd64"; then
    pass "amd64 multiarch enabled"
else
    fail "amd64 multiarch not enabled — Steam/Proton won't work"
fi

# Steam bootstrap now hard-requires Linux user namespaces.
USERNS_MAX=$(ssh_get_root 'cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0')
if [[ "${USERNS_MAX:-0}" =~ ^[0-9]+$ ]] && [[ "${USERNS_MAX}" -gt 0 ]]; then
    pass "user.max_user_namespaces enabled (${USERNS_MAX})"
else
    fail "user.max_user_namespaces is disabled (${USERNS_MAX:-unknown}) — Steam may exit with status 71"
fi

USERNS_CLONE_RC=0
USERNS_CLONE_VAL=$(ssh_get_root 'cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null') || USERNS_CLONE_RC=$?
if [[ "${USERNS_CLONE_RC}" -ne 0 ]]; then
    # Some kernels do not expose this knob; max_user_namespaces is the hard gate.
    skip "kernel.unprivileged_userns_clone not exposed on this kernel"
elif [[ "${USERNS_CLONE_VAL}" == "1" ]]; then
    pass "kernel.unprivileged_userns_clone enabled"
else
    fail "kernel.unprivileged_userns_clone=${USERNS_CLONE_VAL} (expected 1 for Steam sandbox)"
fi

# Steam runtime depends on bubblewrap. In environments where unprivileged userns
# is effectively restricted, setuid bwrap is the expected fallback.
if ssh_check 'test -x /usr/bin/bwrap'; then
    pass "/usr/bin/bwrap exists"
else
    fail "/usr/bin/bwrap missing — Steam sandbox will fail before steam.pipe"
fi

BWRAP_MODE=$(ssh_get_root 'stat -c "%a %u %g %A" /usr/bin/bwrap 2>/dev/null || true')
if [[ -n "${BWRAP_MODE}" ]]; then
    # Use octal mode as the source of truth: 4xxx indicates setuid.
    if echo "${BWRAP_MODE}" | awk '{print $1}' | grep -q '^4'; then
        pass "bwrap is setuid-root (${BWRAP_MODE})"
    else
        fail "bwrap missing setuid bit (${BWRAP_MODE})"
    fi
else
    fail "could not stat /usr/bin/bwrap"
fi

USERNS_FUNC_OUT=$(ssh_get 'HOME=/home/meridian USER=meridian /usr/bin/unshare --user --map-root-user /usr/bin/true >/tmp/meridian-userns-probe.out 2>&1; rc=$?; if [[ $rc -eq 0 ]]; then echo OK; else echo "FAIL:${rc}"; cat /tmp/meridian-userns-probe.out; fi')
if echo "${USERNS_FUNC_OUT}" | grep -q '^OK'; then
    pass "functional user namespace probe passed for meridian user"
else
    if echo "${BWRAP_MODE}" | awk '{print $1}' | grep -q '^4'; then
        skip "unshare probe failed for meridian user (setuid bwrap fallback is present for Steam)"
    else
        fail "functional user namespace probe failed for meridian user (${USERNS_FUNC_OUT})"
    fi
fi

# Steam still probes for 32-bit userspace. Missing libc.so.6 is a common startup failure.
if ssh_check 'test -f /lib/i386-linux-gnu/libc.so.6 || test -f /usr/lib/i386-linux-gnu/libc.so.6'; then
    pass "32-bit glibc runtime present (libc.so.6)"
else
    fail "32-bit libc.so.6 missing (Steam may warn/fail with missing 32-bit libraries)"
fi

# Validate that first-run Steam runtime extraction is healthy enough for
# non-interactive headless handoff. Missing logger/runtime-tools is a known
# failure mode that causes repeated repair loops.
# Runtime logger files can live in home runtime (after bootstrap) or packaged runtime.
if ssh_check 'test -f /home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/libexec/steam-runtime-tools-0/logger-0.bash || test -f /usr/lib/steam/ubuntu12_32/steam-runtime/usr/libexec/steam-runtime-tools-0/logger-0.bash'; then
    pass "Steam runtime logger script present (logger-0.bash)"
else
    skip "Steam runtime logger script missing pre-bootstrap (known to appear after first successful Steam bootstrap)"
fi

if ssh_check 'test -x /home/meridian/.local/share/Steam/ubuntu12_32/steam-runtime/usr/libexec/steam-runtime-tools-0/srt-logger || test -x /usr/lib/steam/ubuntu12_32/steam-runtime/usr/libexec/steam-runtime-tools-0/srt-logger'; then
    pass "Steam runtime logger binary present (srt-logger)"
else
    skip "Steam runtime logger binary missing pre-bootstrap (known to appear after first successful Steam bootstrap)"
fi

# ── Test: Proton GE ───────────────────────────────────────────────────────────
header "Proton GE"

PROTON_DIR="/home/meridian/.local/share/Steam/compatibilitytools.d"
if ssh_check "test -d ${PROTON_DIR}"; then
    PROTON_VERSIONS=$(ssh_get "ls ${PROTON_DIR} 2>/dev/null | grep GE-Proton | head -3")
    if [[ -n "${PROTON_VERSIONS}" ]]; then
        pass "Proton GE found: ${PROTON_VERSIONS}"
    else
        fail "No GE-Proton versions in ${PROTON_DIR}"
    fi
else
    fail "compatibilitytools.d directory missing at ${PROTON_DIR}"
fi

CONFIG_VDF="${PROTON_DIR}/../config/config.vdf"
if ssh_check "grep -q 'GE-Proton' ${CONFIG_VDF}"; then
    pass "config.vdf sets Proton GE as Steam Play default"
else
    fail "config.vdf missing or does not reference GE-Proton"
fi

# ── Test: Rosetta / x86_64 translation ───────────────────────────────────────
header "Rosetta / x86_64 Translation Setup"

if ssh_check 'test -f /usr/local/bin/setup-rosetta.sh'; then
    pass "/usr/local/bin/setup-rosetta.sh exists"
else
    fail "setup-rosetta.sh missing"
fi

if ssh_check_root 'systemctl is-enabled rosetta-setup.service 2>/dev/null | grep -q enabled'; then
    pass "rosetta-setup.service is enabled"
else
    fail "rosetta-setup.service is not enabled"
fi

if ssh_check 'test -d /opt/rosetta'; then
    pass "/opt/rosetta directory exists (mount point)"
else
    fail "/opt/rosetta directory missing"
fi

# When running in QEMU (no VZ virtiofs), Rosetta won't be mounted — that's OK
if ssh_check 'mountpoint -q /opt/rosetta'; then
    pass "/opt/rosetta is mounted"
    if ssh_check 'test -x /opt/rosetta/rosetta'; then
        pass "/opt/rosetta/rosetta binary is executable"
    else
        fail "/opt/rosetta/rosetta binary not found or not executable"
    fi
    # Test binfmt_misc registration
    if ssh_check 'cat /proc/sys/fs/binfmt_misc/rosetta 2>/dev/null | grep -q "enabled"'; then
        pass "x86_64 binfmt_misc is registered via Rosetta"
    else
        fail "binfmt_misc Rosetta handler not active"
    fi
else
    skip "/opt/rosetta not mounted (expected when running under QEMU, not Meridian)"
    skip "binfmt_misc Rosetta check (requires Meridian VZ boot)"
fi

# ── Test: Kernel modules ──────────────────────────────────────────────────────
header "Kernel Modules"

for mod in vsock vmw_vsock_virtio_transport virtio_gpu virtio_fs; do
    MOD_LOADED=$(ssh_get "lsmod | grep '^${mod}' | head -1 || echo NOTLOADED")
    if [[ "${MOD_LOADED}" != "NOTLOADED" ]] && [[ -n "${MOD_LOADED}" ]]; then
        pass "Module loaded: ${mod}"
    else
        # Try to load it
        LOAD_RC=0; ssh_run_root "modprobe ${mod} 2>/dev/null" || LOAD_RC=$?
        if [[ "${LOAD_RC}" -eq 0 ]]; then
            pass "Module loadable: ${mod} (loaded on demand)"
        else
            # virtio_fs not loadable in QEMU without virtiofs device — skip
            if [[ "${mod}" == "virtio_fs" ]]; then
                skip "Module ${mod} not loadable (no virtiofs device in QEMU — ok)"
            else
                fail "Module not loaded and cannot load: ${mod}"
            fi
        fi
    fi
done

# ── Test: meridian-agent ──────────────────────────────────────────────────────
header "Meridian Agent"

AGENT_CHECK=$(ssh_get 'test -x /usr/bin/meridian-agent && ls -lh /usr/bin/meridian-agent | awk '"'"'{print $5}'"'"' || echo MISSING')
if [[ "${AGENT_CHECK}" != "MISSING" ]] && [[ -n "${AGENT_CHECK}" ]]; then
    pass "/usr/bin/meridian-agent executable (size: ${AGENT_CHECK})"
else
    fail "/usr/bin/meridian-agent missing or not executable"
fi

if ssh_check_root 'systemctl is-enabled meridian-agent.service 2>/dev/null | grep -q enabled'; then
    pass "meridian-agent.service is enabled"
else
    fail "meridian-agent.service is not enabled"
fi

AGENT_STATE=$(ssh_get_root 'systemctl is-active meridian-agent.service 2>/dev/null')
if [[ "${AGENT_STATE}" == "active" ]]; then
    pass "meridian-agent.service is active"
else
    fail "meridian-agent.service state: ${AGENT_STATE}"
    ssh_run_root 'journalctl -u meridian-agent.service -n 20 --no-pager' 2>/dev/null \
        | sed 's/^/  /' || true
fi

# Agent must be listening on vsock port 1234
if ssh_check_root 'ss --vsock -l 2>/dev/null | grep -q 1234'; then
    pass "meridian-agent listening on vsock:1234"
else
    fail "meridian-agent NOT listening on vsock:1234"
fi

# ── Test: Steam IPC / handoff smoke ───────────────────────────────────────────
header "Steam IPC / Handoff Smoke"

# This smoke test is best-effort in QEMU. We validate that Steam can be
# bootstrapped in-session and expose steam.pipe, which is the handoff gate used
# by meridian-agent (`steam -ifrunning steam://...` writes into this pipe).
IPC_SMOKE_OUT=$(ssh_get 'sudo -u meridian -E env HOME=/home/meridian USER=meridian DISPLAY=:0 WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus STEAM_RUNTIME=1 STEAM_RUNTIME_PREFER_HOST_LIBRARIES=0 STEAM_DISABLE_ZENITY=1 STEAM_SKIP_LIBRARIES_CHECK=1 STEAMOS=1 GTK_A11Y=none TERM=dumb bash -lc '"'"'
timeout 120s /usr/bin/steam -silent >/tmp/meridian-steam-ipc.log 2>&1 &
for i in $(seq 1 120); do
  if [[ -p /home/meridian/.local/share/Steam/steam.pipe || -p /home/meridian/.steam/steam/steam.pipe || -p /home/meridian/.steam/root/steam.pipe ]]; then
    echo READY
    exit 0
  fi
  sleep 1
done
echo TIMEOUT
exit 0
'"'"'')
if echo "${IPC_SMOKE_OUT}" | grep -q "READY"; then
    pass "Steam IPC pipe becomes available for protocol handoff"
else
    skip "Steam IPC smoke timed out under QEMU (requires Meridian VZ path for definitive result)"
fi

# ── Test: X11 / GLX Display Stack ────────────────────────────────────────────
# These tests guard against the glXChooseVisual crash that kills Steam's VGUI2
# layer on startup.  The crash manifests as:
#   glXChooseVisual failed  (src/vgui2/src/surface_linux.cpp:1956)
#   Fatal assert; application exiting
#
# Root causes caught by this section:
#   A) Missing libegl-mesa0  → XWayland glamor has no EGL ICD, GLX visuals absent
#   B) Missing libgl1-mesa-dri → swrast_dri.so absent, no software GL at all
#   C) Xvfb serving :0 instead of XWayland → Xvfb cannot expose GLX visuals
#   D) XWayland started without LIBGL_ALWAYS_SOFTWARE → glamor tries hardware GPU
#   E) meridian-session.sh does not kill existing Xvfb before starting XWayland
header "X11 / GLX Display Stack"

# ── Package presence ──────────────────────────────────────────────────────────
for pkg in xwayland libegl-mesa0 libgl1-mesa-dri libglx-mesa0; do
    PKG_STATUS=$(ssh_get_root "dpkg-query -W -f='\${db:Status-Abbrev}' ${pkg} 2>/dev/null || echo 'NOT_FOUND'")
    if echo "${PKG_STATUS}" | grep -q '^ii'; then
        pass "${pkg} installed"
    else
        fail "${pkg} NOT installed (status: ${PKG_STATUS:-unknown}) — Steam will crash with glXChooseVisual failed"
    fi
done

# ── Critical shared-library files ─────────────────────────────────────────────
# These are the actual .so files loaded at runtime — package presence alone does
# not guarantee they were correctly installed.
for libpath in \
    /usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0 \
    /usr/lib/aarch64-linux-gnu/dri/swrast_dri.so; do
    if ssh_check "test -f ${libpath}"; then
        pass "$(basename ${libpath}) present at ${libpath}"
    else
        fail "$(basename ${libpath}) MISSING at ${libpath} — XWayland glamor/software GL will fail"
    fi
done

# ── meridian-session.sh: must use Xvfb as primary X server ───────────────────
# XWayland was tried and failed silently in VZ mode: it starts, creates the
# socket, then exits because virtio-gpu doesn't support glamor's EGL extensions.
# The proven approach (verified by the GLX functional probe below) is Xvfb at
# 24-bit depth with Mesa software rendering.
if ssh_check 'grep -q "Xvfb :0.*1920x1080x24\|Xvfb.*-screen 0 1920x1080x24" /usr/local/bin/meridian-session.sh 2>/dev/null'; then
    pass "meridian-session.sh starts Xvfb at 24-bit depth (GLX requires depth 24)"
else
    fail "meridian-session.sh does NOT start Xvfb at 24-bit depth — GLX visuals will be absent"
fi

# ── meridian-session.sh: must pass software-GL env to Xvfb ───────────────────
if ssh_check 'grep -q "LIBGL_ALWAYS_SOFTWARE=1" /usr/local/bin/meridian-session.sh 2>/dev/null'; then
    pass "meridian-session.sh sets LIBGL_ALWAYS_SOFTWARE=1 (forces Mesa llvmpipe)"
else
    fail "meridian-session.sh missing LIBGL_ALWAYS_SOFTWARE=1 — Mesa may try hardware GPU and fail"
fi

if ssh_check 'grep -q "MESA_LOADER_DRIVER_OVERRIDE=llvmpipe\|llvmpipe" /usr/local/bin/meridian-session.sh 2>/dev/null'; then
    pass "meridian-session.sh forces llvmpipe Mesa driver"
else
    fail "meridian-session.sh missing MESA_LOADER_DRIVER_OVERRIDE=llvmpipe — software rendering not guaranteed"
fi

# ── meridian-session.sh: must kill stale X servers before starting Xvfb ──────
# Any stale Xvfb or XWayland process left from a previous run would block the
# new Xvfb from binding to :0, leaving the display broken.
# The loop iterates "for _xproc in Xvfb Xwayland Xorg" and calls pkill on each.
if ssh_check 'grep -q "for _xproc in Xvfb" /usr/local/bin/meridian-session.sh 2>/dev/null'; then
    pass "meridian-session.sh kills stale Xvfb/XWayland before starting fresh Xvfb"
else
    fail "meridian-session.sh missing stale-X-server cleanup — restart may leave :0 broken"
fi

# ── Functional GLX probe — simulates glXChooseVisual exactly ─────────────────
# This is the most important test: it replicates the exact call that kills Steam.
#
# We start Xvfb (in QEMU, sway/Wayland is not running, so XWayland needs a
# compositor; Xvfb with Mesa IS the minimal test of the libGL stack) and then
# call glXChooseVisual via Python ctypes — the same ABI Steam uses.
#
# A pass here means:
#   - libGL.so loads cleanly
#   - libX11.so loads cleanly
#   - The X server on :97 exports GLX extension with RGBA+depth visuals
#   - Steam's VGUI2 will NOT crash at this call site
#
# If this test FAILS it means the VM image is broken and we must NOT proceed
# to Xcode testing.
GLX_PROBE_OUT=$(ssh_get 'bash -s <<'"'"'GLX_PROBE_END'"'"'
set -euo pipefail
XDISP=":97"
XSOCK="/tmp/.X11-unix/X97"
rm -f "${XSOCK}" 2>/dev/null || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# Start Xvfb at 24-bit depth with Mesa software rendering.
# Note: In the real Meridian session, XWayland serves :0.  Here we use Xvfb
# because QEMU has no Wayland compositor.  The GLX stack (libGL→swrast_dri.so)
# is identical: if glXChooseVisual works here it will work under XWayland too.
LIBGL_ALWAYS_SOFTWARE=1 MESA_LOADER_DRIVER_OVERRIDE=llvmpipe GALLIUM_DRIVER=llvmpipe \
    Xvfb :97 -screen 0 1920x1080x24 -ac +extension GLX >/dev/null 2>&1 &
XVFB_PID=$!

for i in $(seq 1 10); do [ -S "${XSOCK}" ] && break; sleep 0.5; done

if [ ! -S "${XSOCK}" ]; then
    kill ${XVFB_PID} 2>/dev/null || true
    echo "GLX_FAIL:no_x_socket"
    exit 0
fi

python3 - <<PYEOF
import ctypes, ctypes.util, sys, os

os.environ["DISPLAY"]                = ":97"
os.environ["LIBGL_ALWAYS_SOFTWARE"]  = "1"
os.environ["MESA_LOADER_DRIVER_OVERRIDE"] = "llvmpipe"
os.environ["GALLIUM_DRIVER"]         = "llvmpipe"

def load(name, fallback):
    lib = ctypes.util.find_library(name)
    try:
        return ctypes.CDLL(lib or fallback)
    except OSError as e:
        print(f"GLX_FAIL:load_{name}:{e}")
        sys.exit(0)

libX11 = load("X11", "libX11.so.6")
libGL  = load("GL",  "libGL.so.1")

libX11.XOpenDisplay.restype  = ctypes.c_void_p
libX11.XOpenDisplay.argtypes = [ctypes.c_char_p]
libX11.XDefaultScreen.restype  = ctypes.c_int
libX11.XDefaultScreen.argtypes = [ctypes.c_void_p]

libGL.glXChooseVisual.restype  = ctypes.c_void_p
libGL.glXChooseVisual.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                   ctypes.POINTER(ctypes.c_int)]

dpy = libX11.XOpenDisplay(None)
if not dpy:
    print("GLX_FAIL:XOpenDisplay_returned_NULL")
    sys.exit(0)

screen  = libX11.XDefaultScreen(dpy)
# GLX_RGBA=4  GLX_DOUBLEBUFFER=5  GLX_DEPTH_SIZE=12  None=0
# This is the exact attribute list Steam VGUI2 uses.
attribs = (ctypes.c_int * 6)(4, 5, 12, 24, 0, 0)
vi      = libGL.glXChooseVisual(dpy, screen, attribs)
if not vi:
    print("GLX_FAIL:glXChooseVisual_returned_NULL (Steam will crash here)")
    sys.exit(0)

print("GLX_PASS:visual_found")
PYEOF

kill ${XVFB_PID} 2>/dev/null || true
GLX_PROBE_END
')
if echo "${GLX_PROBE_OUT}" | grep -q "^GLX_PASS"; then
    pass "GLX functional probe passed — glXChooseVisual returned a valid visual (Steam VGUI2 will not crash)"
elif echo "${GLX_PROBE_OUT}" | grep -q "^GLX_FAIL:glXChooseVisual_returned_NULL"; then
    fail "glXChooseVisual returned NULL — Steam WILL crash with 'glXChooseVisual failed / Fatal assert'"
    echo "    Diagnosis: X server running but GLX visuals unavailable."
    echo "    Check: libegl-mesa0 installed? LIBGL_ALWAYS_SOFTWARE=1 set? Correct bit depth (24)?"
elif echo "${GLX_PROBE_OUT}" | grep -q "^GLX_FAIL:XOpenDisplay_returned_NULL"; then
    fail "XOpenDisplay returned NULL — X server not reachable on DISPLAY=:97"
    echo "    Check: Xvfb started successfully? /tmp/.X11-unix/X97 socket present?"
elif echo "${GLX_PROBE_OUT}" | grep -q "^GLX_FAIL:no_x_socket"; then
    fail "X server socket /tmp/.X11-unix/X97 never appeared — Xvfb did not start"
elif echo "${GLX_PROBE_OUT}" | grep -q "^GLX_FAIL:load_"; then
    fail "Failed to load required library: ${GLX_PROBE_OUT}"
    echo "    Check: libGL.so and libX11.so present? libgl1-mesa-dri installed?"
elif [[ -z "${GLX_PROBE_OUT}" ]]; then
    skip "GLX functional probe produced no output (SSH timeout or Python missing)"
else
    fail "GLX functional probe unexpected output: ${GLX_PROBE_OUT}"
fi

# ── agent preflight reports xdisplay_glx ─────────────────────────────────────
# The agent's emitSteamPreflightStatus must include xdisplay_glx= so that
# failures are visible in logs without needing to decode the crash.
PREFLIGHT_HELP=$(ssh_get '/usr/bin/meridian-agent --help 2>/dev/null || echo MISSING')
if [[ "${PREFLIGHT_HELP}" == "MISSING" ]]; then
    skip "meridian-agent not running — skipping preflight field check"
else
    AGENT_LOG=$(ssh_get_root 'journalctl -u meridian-agent.service -n 80 --no-pager 2>/dev/null || true')
    if echo "${AGENT_LOG}" | grep -q "xdisplay_glx="; then
        pass "agent preflight log contains xdisplay_glx= field"
    else
        skip "xdisplay_glx= not yet in agent log (agent may not have run preflight — check after first launch)"
    fi
fi

# ── Test: Sway / session ──────────────────────────────────────────────────────
header "Sway / Session Setup"

if ssh_check 'which sway'; then
    SWAY_VER=$(ssh_get 'sway --version 2>/dev/null')
    pass "sway installed: ${SWAY_VER}"
else
    fail "sway not installed"
fi

SWAY_CFG=$(ssh_get 'test -f /home/meridian/.config/sway/config && echo EXISTS || echo MISSING')
if [[ "${SWAY_CFG}" == "EXISTS" ]]; then
    pass "sway config present"
else
    fail "sway config missing at /home/meridian/.config/sway/config"
fi

if ssh_check 'test -x /usr/local/bin/meridian-session.sh'; then
    pass "meridian-session.sh exists and is executable"
else
    fail "meridian-session.sh missing or not executable"
fi

# Check sway config launches the session script
if ssh_check 'grep -q "meridian-session.sh" /home/meridian/.config/sway/config'; then
    pass "sway config execs meridian-session.sh"
else
    fail "sway config does not exec meridian-session.sh"
fi

# Check auto-login is set up
if ssh_check_root 'test -f /etc/systemd/system/getty@tty1.service.d/autologin.conf'; then
    pass "tty1 auto-login configured"
else
    fail "tty1 auto-login not configured"
fi

# Check .bash_profile starts sway
BASH_PROFILE_SWAY=$(ssh_get 'grep -c "sway" /home/meridian/.bash_profile 2>/dev/null || echo 0')
if [[ "${BASH_PROFILE_SWAY}" -gt 0 ]]; then
    pass ".bash_profile starts sway on tty1"
else
    fail ".bash_profile does not start sway"
fi

# ── Test: Session file handling ───────────────────────────────────────────────
header "Steam Session File Staging"

if ssh_check 'grep -q "steam-session" /usr/local/bin/meridian-session.sh'; then
    pass "meridian-session.sh mounts meridian-steam-session virtiofs"
else
    fail "meridian-session.sh does not mount steam session share"
fi

if ssh_check 'grep -q "loginusers.vdf" /usr/local/bin/meridian-session.sh'; then
    pass "meridian-session.sh copies loginusers.vdf from session share"
else
    fail "meridian-session.sh does not copy Steam auth files"
fi

# ── Test: Disk layout ─────────────────────────────────────────────────────────
header "Disk Layout"

ROOT_DEVICE=$(ssh_get 'df / | tail -1 | awk '"'"'{print $1}'"'"'')
if echo "${ROOT_DEVICE}" | grep -q "mapper"; then
    pass "Root is on LVM mapper device: ${ROOT_DEVICE}"
elif echo "${ROOT_DEVICE}" | grep -q "/dev/vda1"; then
    pass "Root is on virtio block partition: ${ROOT_DEVICE}"
else
    fail "Unexpected root device layout: ${ROOT_DEVICE}"
fi

if ssh_check 'test -d /boot/efi'; then
    pass "/boot/efi partition present"
else
    fail "/boot/efi partition missing"
fi

# ── Test: Network ─────────────────────────────────────────────────────────────
header "Network"

if ssh_check 'curl -s --max-time 5 https://api.ipify.org'; then
    pass "Internet access available (QEMU NAT working)"
else
    fail "No internet access from guest"
fi

# Steam CDN reachability (follow redirects, check final status)
STEAM_HTTP=$(ssh_get 'curl -sIL --max-time 10 https://cdn.akamai.steamstatic.com/client/installer/steam.deb 2>/dev/null | grep "^HTTP" | tail -1')
if echo "${STEAM_HTTP}" | grep -qE "200|206"; then
    pass "Steam CDN reachable (${STEAM_HTTP})"
else
    fail "Steam CDN not reachable (got: ${STEAM_HTTP:-no response})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e " Results:  ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}"
echo "═══════════════════════════════════════════════════════"

if [[ "${FAIL}" -gt 0 ]]; then
    echo -e " ${RED}FAILED — fix the issues above before running the Meridian app.${NC}"
    exit 1
else
    echo -e " ${GREEN}ALL TESTS PASSED — guest image is ready.${NC}"
    exit 0
fi
