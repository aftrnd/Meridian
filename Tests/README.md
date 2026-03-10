# Meridian Tests

Three tiers of tests — all runnable without the live Meridian app.

---

## Tier 1 — Swift Unit Tests (`swift test`)

Pure Swift, no Virtualization.framework, no VM required. Tests the JSON
protocol layer, VM state machine, and session bridge logic.

```bash
swift test --filter MeridianTests
```

**43 tests across 10 suites:**
- `ProtonBridgeProtocolTests` — verifies JSON wire format matches the Go agent exactly
- `VMStateTests` — state machine transitions, label text, equatability
- `SteamSessionBridgeTests` — session file copy, credential injection, file permissions
- `LaunchStateTransitionTests` — GameLauncher re-entry guards

---

## Tier 2 — Guest Image Integration Tests (`test-guest.sh`)

Boots the base image via QEMU (no entitlement needed), SSH-connects, and
verifies the full guest stack: Steam, Proton GE, Rosetta setup, kernel
modules, meridian-agent, sway kiosk, and network.

**Requirements:**
```bash
brew install qemu sshpass
```

**Usage:**
```bash
# Full run: boots VM, tests, shuts down
bash Tests/Integration/test-guest.sh

# If VM is already running on port 2222:
bash Tests/Integration/test-guest.sh --no-boot

# Custom image path:
MERIDIAN_VM_DIR=/path/to/vm bash Tests/Integration/test-guest.sh
```

**Expected output (clean image):**
```
36 passed  0 failed  3 skipped
```
The 3 skips are QEMU-only: Rosetta mount (needs VZ virtiofs) and virtio_fs
module (needs a virtiofs device). Both work correctly in the Meridian app.

---

## Tier 3 — Agent Protocol Tests (`test-agent-protocol.py`)

Connects to the running meridian-agent via a socat TCP→vsock relay, and
exercises the JSON protocol end-to-end: connection, stop command, unknown
command handling, malformed JSON robustness, and launch command response.

**Requirements:**
```bash
# VM must be running (from test-guest.sh or QEMU manually)
```

**Usage:**
```bash
# With VM running on localhost:2222:
python3 Tests/Integration/test-agent-protocol.py
```

---

## Running Everything

```bash
# 1. Unit tests (no VM needed, ~2 seconds)
swift test --filter MeridianTests

# 2. Boot VM + run integration tests (~1 minute)
bash Tests/Integration/test-guest.sh

# 3. Protocol tests (VM must be running)
python3 Tests/Integration/test-agent-protocol.py
```
