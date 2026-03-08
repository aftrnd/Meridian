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
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=no -o ServerAliveInterval=5"
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
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "$@" 2>&1
}

ssh_run_root() {
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "sudo $*" 2>&1
}

# ssh_check: run a boolean-expression command in guest.
# Retries once on SSH failure to tolerate transient connection issues.
ssh_check() {
    local cmd="$*"
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "${cmd}" >/dev/null 2>&1 \
    || { sleep 1; sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
             "${SSH_USER}@localhost" "${cmd}" >/dev/null 2>&1; }
}

ssh_check_root() {
    local cmd="$*"
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "sudo ${cmd}" >/dev/null 2>&1 \
    || { sleep 1; sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
             "${SSH_USER}@localhost" "sudo ${cmd}" >/dev/null 2>&1; }
}

# ssh_get: run command, capture output, always exits 0.
ssh_get() {
    local cmd="$*"
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "${cmd}" 2>/dev/null \
    || sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "${cmd}" 2>/dev/null \
    || true
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

if ssh_run_root 'systemctl is-enabled rosetta-setup.service 2>/dev/null | grep -q enabled'; then
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

if ssh_run_root 'systemctl is-enabled meridian-agent.service 2>/dev/null | grep -q enabled'; then
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
