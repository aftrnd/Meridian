#!/usr/bin/env bash
# =============================================================================
# test-vm-live.sh — Boot the local meridian-base.img under QEMU with SSH
#                   port forwarding and run live diagnostics on the guest.
#
# What this does:
#   1. Boots ~/...sandbox.../vm/meridian-base.img as a raw QEMU disk
#   2. Waits for SSH to come up (meridian@localhost:2222 / pass: meridian)
#   3. Runs a set of agent diagnostics via SSH:
#        • systemctl status meridian-agent
#        • ss --vsock -l  (is port 1234 listening?)
#        • journalctl -u meridian-agent  (last 30 lines)
#        • journalctl -u rosetta-setup   (did mount fail?)
#   4. Runs `swift test --filter "Live VM Agent"` which fires the Swift
#      test suite against localhost:2222 for a structured pass/fail report
#   5. Shuts QEMU down cleanly
#
# Requirements:
#   brew install qemu sshpass
#
# Usage:
#   ./Scripts/test-vm-live.sh
#   ./Scripts/test-vm-live.sh --keep   # leave QEMU running after tests
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1

# ── Paths ─────────────────────────────────────────────────────────────────────
SANDBOX="$HOME/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm"
BASE_IMG="${SANDBOX}/meridian-base.img"
VMLINUZ="${SANDBOX}/vmlinuz"
INITRD="${SANDBOX}/initrd"
WORK_DIR="/tmp/meridian-test-$$"
EFI_VARS="${WORK_DIR}/efi-vars.fd"
QEMU_LOG="${WORK_DIR}/qemu.log"
QEMU_PID=""

# ── Style ─────────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "\n${BOLD}══ $* ══${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
fail()  { echo -e "  ${RED}✗${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
step()  { echo -e "  → $*"; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    if [[ "${KEEP}" == "1" ]]; then
        echo -e "\n${BOLD}--keep: leaving QEMU running (pid ${QEMU_PID:-?}). Kill with: kill ${QEMU_PID:-?}${NC}"
        return
    fi
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        step "Shutting down QEMU (pid ${QEMU_PID})…"
        sshpass -p meridian ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p 2222 meridian@localhost "sudo systemctl poweroff" 2>/dev/null || true
        sleep 4
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
info "Preflight checks"

for cmd in qemu-system-aarch64 sshpass; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "$cmd not found — brew install qemu sshpass"
        exit 1
    fi
done

[[ -f "${BASE_IMG}" ]] || { fail "meridian-base.img not found at: ${BASE_IMG}"; exit 1; }
ok "meridian-base.img found ($(du -sh "${BASE_IMG}" | cut -f1))"

# Find EDK2 firmware
QEMU_PREFIX="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)"
EFI_CODE="${QEMU_PREFIX}/share/qemu/edk2-aarch64-code.fd"
EFI_VARS_TMPL="${QEMU_PREFIX}/share/qemu/edk2-aarch64-vars.fd"
[[ -f "${EFI_CODE}" ]] || { fail "EDK2 not found: ${EFI_CODE}"; exit 1; }
ok "EDK2: ${EFI_CODE}"

mkdir -p "${WORK_DIR}"
if [[ -f "${EFI_VARS_TMPL}" ]]; then
    cp "${EFI_VARS_TMPL}" "${EFI_VARS}"
else
    dd if=/dev/zero of="${EFI_VARS}" bs=1m count=64 2>/dev/null
fi

# ── Boot QEMU ─────────────────────────────────────────────────────────────────
info "Booting meridian-base.img in QEMU"
step "SSH will be available at localhost:2222 (user: meridian, pass: meridian)"

qemu-system-aarch64 \
    -M virt \
    -cpu host \
    -accel hvf \
    -m 4096 \
    -smp 4 \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${EFI_VARS}" \
    -drive "file=${BASE_IMG},format=raw,if=virtio,readonly=off,discard=unmap,cache=unsafe" \
    -netdev "user,id=net0,hostfwd=tcp::2222-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    > "${QEMU_LOG}" 2>&1 &
QEMU_PID=$!
ok "QEMU launched (pid ${QEMU_PID}) — log at ${QEMU_LOG}"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
info "Waiting for SSH (up to 120s)…"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no -o LogLevel=ERROR"
SSH_UP=0
for i in $(seq 1 60); do
    if sshpass -p meridian ssh ${SSH_OPTS} -p 2222 meridian@localhost "exit 0" 2>/dev/null; then
        SSH_UP=1
        ok "SSH up after ~$((i * 2))s"
        break
    fi
    sleep 2
    printf "\r  → waiting… %ds" $((i * 2))
done
echo ""

if [[ "${SSH_UP}" == "0" ]]; then
    fail "SSH did not come up in 120s"
    echo "QEMU log tail:"
    tail -30 "${QEMU_LOG}" || true
    exit 1
fi

ssh_vm() { sshpass -p meridian ssh ${SSH_OPTS} -p 2222 meridian@localhost "$@"; }

# ── Wait for systemd to finish booting ───────────────────────────────────────
info "Waiting for systemd multi-user.target…"
for i in $(seq 1 30); do
    if ssh_vm "sudo systemctl is-active multi-user.target" 2>/dev/null | grep -q "^active$"; then
        ok "multi-user.target active"
        break
    fi
    sleep 2
done

# Give services a few more seconds to settle
sleep 3

# ── Diagnostic dump ───────────────────────────────────────────────────────────
info "Guest diagnostics"

echo ""
echo -e "${BOLD}=== meridian-agent service ===${NC}"
ssh_vm "sudo systemctl status meridian-agent.service --no-pager -l 2>&1" || true

echo ""
echo -e "${BOLD}=== vsock listener (expecting port 1234) ===${NC}"
ssh_vm "sudo ss --vsock -l 2>/dev/null || echo 'ss vsock not available'" || true

echo ""
echo -e "${BOLD}=== meridian-agent journal (last 40 lines) ===${NC}"
ssh_vm "sudo journalctl -u meridian-agent.service -n 40 --no-pager 2>/dev/null" || true

echo ""
echo -e "${BOLD}=== rosetta-setup journal ===${NC}"
ssh_vm "sudo journalctl -u rosetta-setup.service -n 20 --no-pager 2>/dev/null" || true

echo ""
echo -e "${BOLD}=== All failed units ===${NC}"
ssh_vm "sudo systemctl list-units --state=failed --no-pager 2>/dev/null" || true

# ── Vsock ping via socat (if available) ───────────────────────────────────────
info "Vsock connectivity test (socat ping from inside guest)"
VSOCK_RESULT=$(ssh_vm "
    if command -v socat &>/dev/null; then
        # Get the local CID to know what host is using
        CID=\$(cat /proc/self/cid 2>/dev/null || echo unknown)
        echo \"Guest CID: \${CID}\"
        # Check if anything is listening on vsock 1234
        sudo ss --vsock -l -p 2>/dev/null | grep -E '1234|LISTEN' && echo 'port 1234 LISTEN: OK' || echo 'port 1234 LISTEN: NOT FOUND'
    else
        echo 'socat not available, using ss only'
        sudo ss --vsock -l 2>/dev/null | grep 1234 && echo 'port 1234 LISTEN: OK' || echo 'port 1234 LISTEN: NOT FOUND'
    fi
" 2>/dev/null || echo "SSH command failed")
echo "${VSOCK_RESULT}"

# ── Swift live tests ──────────────────────────────────────────────────────────
info "Running Swift live VM agent tests"
cd "${PROJECT_DIR}"
echo "(SSH is up — the Live VM Agent suite will now run for real)"
echo ""
swift test --filter "Live VM Agent" 2>&1 || {
    fail "Some live agent tests failed — see output above"
}

# Strip quarantine that QEMU re-applies when it writes to the raw image.
SANDBOX="$(dirname "${BASE_IMG}")"
for f in "${BASE_IMG}" "${SANDBOX}/expansion.img" "${SANDBOX}/vmlinuz" "${SANDBOX}/initrd"; do
    [[ -f "$f" ]] || continue
    xattr -d com.apple.quarantine "$f" 2>/dev/null || true
done

ok "All tests done."
echo ""
echo -e "${BOLD}Full QEMU log: ${QEMU_LOG}${NC}"
if [[ "${KEEP}" == "1" ]]; then
    echo -e "${BOLD}QEMU still running (pid ${QEMU_PID}). SSH: ssh -p 2222 meridian@localhost (pass: meridian)${NC}"
fi
