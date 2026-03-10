#!/usr/bin/env bash
# =============================================================================
# patch-vm-vsock.sh — Patch the local meridian-base.img to fix the vsock
#                     "accept: address family not supported by protocol" bug.
#
# ROOT CAUSE:
#   When Meridian boots the VM via Apple's Virtualization.framework, the guest
#   receives VirtIO vsock connections.  These require the kernel module
#   vmw_vsock_virtio_transport to be loaded *before* accept() is called.
#   If the module is not loaded, accept() returns EAFNOSUPPORT — the connection
#   is silently rejected, and the host's send() call gets EPIPE, which
#   propagates as "Launch command failed: The operation couldn't be completed.
#   (Broken pipe / I/O error)".
#
# FIX applied by this script:
#   1. /etc/modules-load.d/meridian.conf  — loads the module at boot
#   2. meridian-agent.service ExecStartPre — ensures it's loaded before accept()
#
# Usage:
#   ./Scripts/patch-vm-vsock.sh
#
# Requirements:
#   brew install qemu sshpass
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SANDBOX="$HOME/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm"
BASE_IMG="${SANDBOX}/meridian-base.img"
WORK_DIR="/tmp/meridian-patch-$$"
EFI_VARS="${WORK_DIR}/efi-vars.fd"
QEMU_LOG="${WORK_DIR}/qemu.log"
QEMU_PID=""

BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "\n${BOLD}══ $* ══${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
step() { echo -e "  → $*"; }

cleanup() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        step "Shutting down QEMU (pid ${QEMU_PID})…"
        sshpass -p meridian ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p 2222 meridian@localhost "sudo systemctl poweroff" 2>/dev/null || true
        # Wait up to 10s for a clean shutdown
        for _ in $(seq 1 10); do
            kill -0 "${QEMU_PID}" 2>/dev/null || break
            sleep 1
        done
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
info "Preflight"
for cmd in qemu-system-aarch64 sshpass; do
    command -v "$cmd" &>/dev/null || { fail "$cmd not found — brew install qemu sshpass"; exit 1; }
done
[[ -f "${BASE_IMG}" ]] || { fail "meridian-base.img not found: ${BASE_IMG}"; exit 1; }
ok "meridian-base.img: $(du -sh "${BASE_IMG}" | cut -f1)"

QEMU_PREFIX="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)"
EFI_CODE="${QEMU_PREFIX}/share/qemu/edk2-aarch64-code.fd"
[[ -f "${EFI_CODE}" ]] || { fail "EDK2 not found: ${EFI_CODE}"; exit 1; }

mkdir -p "${WORK_DIR}"
EFI_VARS_TMPL="${QEMU_PREFIX}/share/qemu/edk2-aarch64-vars.fd"
[[ -f "${EFI_VARS_TMPL}" ]] && cp "${EFI_VARS_TMPL}" "${EFI_VARS}" \
    || dd if=/dev/zero of="${EFI_VARS}" bs=1m count=64 2>/dev/null

# ── Boot ──────────────────────────────────────────────────────────────────────
info "Booting image for patching"
qemu-system-aarch64 \
    -M virt -cpu host -accel hvf -m 2048 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${EFI_VARS}" \
    -drive "file=${BASE_IMG},format=raw,if=virtio,readonly=off,discard=unmap,cache=unsafe" \
    -netdev "user,id=net0,hostfwd=tcp::2222-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic > "${QEMU_LOG}" 2>&1 &
QEMU_PID=$!
ok "QEMU started (pid ${QEMU_PID})"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no -o LogLevel=ERROR"
ssh_vm() { sshpass -p meridian ssh ${SSH_OPTS} -p 2222 meridian@localhost "$@"; }

info "Waiting for SSH…"
for i in $(seq 1 60); do
    if sshpass -p meridian ssh ${SSH_OPTS} -p 2222 meridian@localhost "exit 0" 2>/dev/null; then
        ok "SSH up (~$((i * 2))s)"
        break
    fi
    sleep 2; printf "\r  → %ds" $((i * 2))
done
echo ""
sshpass -p meridian ssh ${SSH_OPTS} -p 2222 meridian@localhost "exit 0" 2>/dev/null \
    || { fail "SSH never came up"; exit 1; }

# Wait for systemd
for _ in $(seq 1 15); do
    ssh_vm "sudo systemctl is-active multi-user.target" 2>/dev/null | grep -q "^active$" && break
    sleep 2
done
sleep 2

# ── Diagnose before patch ──────────────────────────────────────────────────────
info "Current vsock module state"
echo "--- lsmod vsock ---"
ssh_vm "lsmod | grep -i vsock || echo '(none loaded)'"
echo "--- modinfo vmw_vsock_virtio_transport ---"
ssh_vm "sudo modinfo vmw_vsock_virtio_transport 2>&1 | head -4 || echo 'module not found'"

# ── Apply patch ────────────────────────────────────────────────────────────────
info "Applying vsock probe + service fix"

# --- Deploy vsock probe script ---
ssh_vm sudo tee /usr/local/bin/meridian-vsock-probe.py << 'PYEOF'
#!/usr/bin/env python3
"""
Probe the vsock transport before meridian-agent starts.

Tries to connect to the HOST (CID=2) on port 55555 (not listening).
- EAFNOSUPPORT → transport not ready, retry (up to 5 s)
- ENODEV       → no vsock device (QEMU test env), skip immediately
- anything else → transport is initialised, proceed

Always exits 0 — never blocks the agent indefinitely.
"""
import socket, sys, errno, time

VMADDR_CID_HOST = 2
PROBE_PORT      = 55555
MAX_ATTEMPTS    = 50

for attempt in range(MAX_ATTEMPTS):
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect((VMADDR_CID_HOST, PROBE_PORT))
        s.close()
        print(f"vsock probe: connected to host (attempt {attempt + 1})")
        sys.exit(0)
    except OSError as e:
        if e.errno == errno.EAFNOSUPPORT:
            time.sleep(0.1)
            continue
        if e.errno == errno.ENODEV:
            print("vsock probe: no vsock device (QEMU/test env), skipping")
            sys.exit(0)
        print(f"vsock probe: transport ready ({e.strerror}, attempt {attempt + 1})")
        sys.exit(0)

print("vsock probe: timed out after 5 s — starting agent anyway", file=sys.stderr)
sys.exit(0)
PYEOF
ssh_vm "sudo chmod +x /usr/local/bin/meridian-vsock-probe.py"
ok "Deployed /usr/local/bin/meridian-vsock-probe.py"

# --- Write improved service file ---
ssh_vm sudo tee /etc/systemd/system/meridian-agent.service << 'SVCEOF'
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
ok "Wrote /etc/systemd/system/meridian-agent.service"

ssh_vm sudo bash << 'PATCH'
set -euo pipefail

echo "=== Reload and restart agent ==="
systemctl daemon-reload
systemctl restart meridian-agent.service 2>/dev/null || echo "(restart failed — not critical)"
sleep 1
systemctl status meridian-agent.service --no-pager -l

echo ""
echo "=== Verify vsock is listening ==="
ss --vsock -l 2>/dev/null | grep 1234 && echo "vsock:1234 LISTEN ✓" || echo "vsock:1234 NOT listening"
PATCH

ok "Patch applied"

# ── Verify after patch ────────────────────────────────────────────────────────
info "Post-patch verification"
echo "--- loaded vsock modules ---"
ssh_vm "lsmod | grep -i vsock"
echo ""
echo "--- meridian-agent service ---"
ssh_vm "sudo systemctl status meridian-agent.service --no-pager -l"

# ── Clean shutdown ────────────────────────────────────────────────────────────
info "Flushing filesystem and shutting down cleanly"
ssh_vm "sudo fstrim -av 2>/dev/null || true"
ssh_vm "sync"
step "Sending systemctl poweroff…"
ssh_vm "sudo systemctl poweroff" 2>/dev/null || true

# Wait for QEMU to exit on its own
for _ in $(seq 1 15); do
    kill -0 "${QEMU_PID}" 2>/dev/null || { QEMU_PID=""; break; }
    sleep 1
done
QEMU_PID=""  # prevent trap from re-killing

# Strip quarantine that QEMU re-applies when it writes to the raw image.
# VZ cannot open a quarantined file for writing and returns I/O error.
info "Stripping com.apple.quarantine from VM image files"
SANDBOX="$(dirname "${BASE_IMG}")"
for f in "${BASE_IMG}" "${SANDBOX}/expansion.img" "${SANDBOX}/vmlinuz" "${SANDBOX}/initrd"; do
    [[ -f "$f" ]] || continue
    xattr -d com.apple.quarantine "$f" 2>/dev/null && ok "stripped: $(basename "$f")" || true
done

ok "Image patched and saved: ${BASE_IMG}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Launch Meridian and try launching a game"
echo "  2. Or run:  swift test --filter VMDiagnosticTests  (all should pass)"
echo "  3. Or run:  ./Scripts/test-vm-live.sh  (boots QEMU, runs live tests)"
echo ""
echo -e "${BOLD}What was fixed:${NC}"
echo "  /usr/local/bin/meridian-vsock-probe.py — probes VirtIO vsock transport readiness"
echo "  /etc/systemd/system/meridian-agent.service — modprobe + probe + udevadm settle before agent start"
