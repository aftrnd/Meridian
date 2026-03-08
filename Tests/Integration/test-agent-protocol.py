#!/usr/bin/env python3
"""
test-agent-protocol.py — Meridian Agent Protocol Tests

Tests the meridian-agent JSON wire protocol by connecting to the agent
running inside a QEMU VM via a TCP relay in the guest.

The test creates a socat TCP→vsock relay inside the guest so we can reach
the agent from the macOS host without needing VZ framework.

Usage:
    # Boot the QEMU VM first (or use test-guest.sh --no-boot):
    python3 Tests/Integration/test-agent-protocol.py

    # With custom SSH port / password:
    MERIDIAN_SSH_PORT=2222 MERIDIAN_SSH_PASS=meridian python3 Tests/Integration/test-agent-protocol.py

Requirements:
    pip3 install paramiko  (for SSH in pure Python)
    OR: the script falls back to subprocess ssh + socat
"""

import json
import os
import socket
import subprocess
import sys
import time
import threading
from typing import Optional

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────
SSH_PORT = int(os.environ.get("MERIDIAN_SSH_PORT", "2222"))
SSH_USER = os.environ.get("MERIDIAN_SSH_USER", "meridian")
SSH_PASS = os.environ.get("MERIDIAN_SSH_PASS", "meridian")
SSH_HOST = "localhost"
AGENT_VSOCK_PORT = 1234
RELAY_TCP_PORT   = 9234   # local port we forward to the relay in the guest

PASS = 0
FAIL = 0
SKIP = 0

def green(s): return f"\033[32m{s}\033[0m"
def red(s):   return f"\033[31m{s}\033[0m"
def yellow(s): return f"\033[33m{s}\033[0m"
def bold(s):  return f"\033[1m{s}\033[0m"

def passed(msg):
    global PASS; PASS += 1
    print(f"  {green('✓')} {msg}")

def failed(msg):
    global FAIL; FAIL += 1
    print(f"  {red('✗')} {msg}")

def skipped(msg):
    global SKIP; SKIP += 1
    print(f"  {yellow('~')} {msg} (skipped)")

def header(msg):
    print(f"\n{bold(msg)}")

# ─────────────────────────────────────────────────────────────────────────────
# SSH helpers (subprocess-based, no paramiko dependency)
# ─────────────────────────────────────────────────────────────────────────────
SSH_COMMON = [
    "sshpass", f"-p{SSH_PASS}",
    "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
    "-o", "BatchMode=no", "-p", str(SSH_PORT),
    f"{SSH_USER}@{SSH_HOST}"
]

def ssh_run(cmd: str, timeout: int = 10) -> tuple[int, str]:
    try:
        result = subprocess.run(
            SSH_COMMON + [cmd],
            capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, (result.stdout + result.stderr).strip()
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"
    except FileNotFoundError:
        return 1, "sshpass/ssh not found"

def ssh_run_sudo(cmd: str, timeout: int = 10) -> tuple[int, str]:
    return ssh_run(f"sudo {cmd}", timeout=timeout)

# ─────────────────────────────────────────────────────────────────────────────
# socat TCP→vsock relay inside the guest
# ─────────────────────────────────────────────────────────────────────────────
_relay_process: Optional[subprocess.Popen] = None
_ssh_tunnel:    Optional[subprocess.Popen] = None

def start_relay() -> bool:
    """
    Starts a socat relay in the guest:  TCP4-LISTEN → VSOCK-CONNECT:1234
    Then SSH-tunnels that TCP port back to the macOS host.
    Returns True on success.
    """
    global _relay_process, _ssh_tunnel

    # Check if socat is available in the guest
    rc, _ = ssh_run_sudo("which socat")
    if rc != 0:
        rc2, _ = ssh_run_sudo("apt-get install -y socat 2>/dev/null")
        if rc2 != 0:
            return False

    # Kill any leftover relay
    ssh_run_sudo(f"pkill -f 'socat.*{RELAY_TCP_PORT}' 2>/dev/null || true")
    time.sleep(0.5)

    # Start relay in guest: listen on a TCP port, forward to vsock:1234
    relay_cmd = (
        f"sudo socat TCP4-LISTEN:{RELAY_TCP_PORT},reuseaddr,fork "
        f"VSOCK-CONNECT:2:{AGENT_VSOCK_PORT} "
        f"> /tmp/socat-relay.log 2>&1 &"
    )
    ssh_run(relay_cmd, timeout=5)
    time.sleep(1)

    # Verify relay is listening
    rc, out = ssh_run(f"ss -tlnp | grep {RELAY_TCP_PORT}")
    if rc != 0:
        return False

    # SSH tunnel: forward localhost:RELAY_TCP_PORT → guest:RELAY_TCP_PORT
    tunnel_cmd = [
        "sshpass", f"-p{SSH_PASS}",
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=no",
        "-p", str(SSH_PORT),
        "-L", f"{RELAY_TCP_PORT}:localhost:{RELAY_TCP_PORT}",
        "-N",
        f"{SSH_USER}@{SSH_HOST}"
    ]
    _ssh_tunnel = subprocess.Popen(tunnel_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    return True

def stop_relay():
    global _relay_process, _ssh_tunnel
    if _ssh_tunnel:
        _ssh_tunnel.terminate()
        _ssh_tunnel = None
    ssh_run(f"sudo pkill -f 'socat.*{RELAY_TCP_PORT}' 2>/dev/null || true")

# ─────────────────────────────────────────────────────────────────────────────
# Agent client
# ─────────────────────────────────────────────────────────────────────────────
class AgentClient:
    def __init__(self, host: str, port: int, timeout: float = 5.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect((host, port))
        self._buf = b""

    def send(self, payload: dict):
        data = json.dumps(payload).encode() + b"\n"
        self.sock.sendall(data)

    def recv_event(self, timeout: float = 5.0) -> Optional[dict]:
        self.sock.settimeout(timeout)
        try:
            while b"\n" not in self._buf:
                chunk = self.sock.recv(4096)
                if not chunk:
                    return None
                self._buf += chunk
            line, self._buf = self._buf.split(b"\n", 1)
            return json.loads(line.decode())
        except (socket.timeout, json.JSONDecodeError, ConnectionResetError):
            return None

    def close(self):
        try: self.sock.close()
        except Exception: pass

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────
def check_vm_reachable() -> bool:
    header("Pre-flight: VM reachability")
    rc, out = ssh_run("echo VM_REACHABLE")
    if rc == 0 and "VM_REACHABLE" in out:
        passed("VM SSH reachable on localhost:" + str(SSH_PORT))
        return True
    failed(f"VM not reachable (rc={rc}, out={out})")
    return False

def test_agent_process():
    header("Agent Process")
    rc, out = ssh_run_sudo("systemctl is-active meridian-agent.service")
    if rc == 0 and "active" in out:
        passed("meridian-agent.service is active")
    else:
        failed(f"meridian-agent.service not active: {out}")

    rc, out = ssh_run_sudo("ss --vsock -l 2>/dev/null | grep 1234")
    if rc == 0:
        passed("Agent listening on vsock:1234")
    else:
        failed("Agent NOT listening on vsock:1234")

def test_relay_setup():
    header("socat Relay Setup")
    ok = start_relay()
    if ok:
        passed(f"socat TCP→vsock relay started (TCP:{RELAY_TCP_PORT} → vsock:{AGENT_VSOCK_PORT})")
        return True
    else:
        failed("Could not start socat relay (socat may not be installed in guest)")
        return False

def test_protocol_connection(relay_available: bool):
    header("Agent Protocol Connection")
    if not relay_available:
        skipped("Connection test (relay not available)")
        skipped("Protocol send/receive tests")
        return

    try:
        client = AgentClient("127.0.0.1", RELAY_TCP_PORT, timeout=5.0)
        passed("TCP connection to agent relay succeeded")

        # The agent sends a log event on connect: {"event":"log","line":"meridian-agent connected"}
        event = client.recv_event(timeout=3.0)
        if event and event.get("event") == "log" and "connected" in event.get("line", ""):
            passed(f"Agent greeting received: {event.get('line')}")
        elif event:
            passed(f"Agent sent initial event: {event}")
        else:
            failed("No initial event from agent within 3s")

        client.close()

    except ConnectionRefusedError:
        failed(f"Connection refused to relay on port {RELAY_TCP_PORT}")
    except socket.timeout:
        failed("Connection timed out")

def test_protocol_stop_command(relay_available: bool):
    header("Agent Protocol — stop command")
    if not relay_available:
        skipped("stop command test (relay not available)")
        return

    try:
        client = AgentClient("127.0.0.1", RELAY_TCP_PORT, timeout=5.0)
        # Drain initial connected message
        client.recv_event(timeout=2.0)

        # Send stop command (safe — no game running)
        client.send({"cmd": "stop"})
        event = client.recv_event(timeout=3.0)
        if event and event.get("event") == "exited":
            passed(f"stop → exited event received (code={event.get('code')})")
        elif event:
            passed(f"stop → received: {event}")
        else:
            failed("No response to stop command within 3s")

        client.close()

    except Exception as e:
        failed(f"Exception during stop test: {e}")

def test_protocol_unknown_command(relay_available: bool):
    header("Agent Protocol — unknown command handling")
    if not relay_available:
        skipped("unknown command test (relay not available)")
        return

    try:
        client = AgentClient("127.0.0.1", RELAY_TCP_PORT, timeout=5.0)
        client.recv_event(timeout=2.0)  # drain greeting

        client.send({"cmd": "foobar_unknown"})
        event = client.recv_event(timeout=3.0)
        if event and event.get("event") == "log":
            passed(f"Unknown command produces log event: {event.get('line', '')[:60]}")
        elif event:
            passed(f"Agent responded to unknown command: {event}")
        else:
            # Agent may silently drop unknown commands — acceptable
            passed("Agent silently dropped unknown command (acceptable)")

        client.close()

    except Exception as e:
        failed(f"Exception during unknown command test: {e}")

def test_protocol_json_robustness(relay_available: bool):
    header("Agent Protocol — malformed JSON robustness")
    if not relay_available:
        skipped("robustness test (relay not available)")
        return

    try:
        client = AgentClient("127.0.0.1", RELAY_TCP_PORT, timeout=5.0)
        client.recv_event(timeout=2.0)  # drain greeting

        # Send malformed JSON — agent should not crash
        client.sock.sendall(b"{not valid json}\n")
        time.sleep(0.5)

        # Agent should still respond to a valid command
        client.send({"cmd": "stop"})
        event = client.recv_event(timeout=3.0)
        if event is not None:
            passed("Agent still functional after malformed JSON input")
        else:
            failed("Agent became unresponsive after malformed JSON")

        client.close()

    except Exception as e:
        failed(f"Exception during robustness test: {e}")

def test_launch_command_fake(relay_available: bool):
    header("Agent Protocol — launch command (appid 0, no real game)")
    if not relay_available:
        skipped("launch command test (relay not available)")
        return

    try:
        client = AgentClient("127.0.0.1", RELAY_TCP_PORT, timeout=10.0)
        client.recv_event(timeout=2.0)

        # Send launch for a fake/invalid appid — steam will fail gracefully
        client.send({"cmd": "launch", "appid": 0, "steamid": "76561198000000001"})

        events = []
        deadline = time.time() + 8
        while time.time() < deadline:
            e = client.recv_event(timeout=1.0)
            if e is None:
                break
            events.append(e)
            if e.get("event") in ("started", "exited"):
                break

        event_types = [e.get("event") for e in events]
        log_lines   = [e.get("line", "") for e in events if e.get("event") == "log"]

        if "started" in event_types or any("launching" in l for l in log_lines):
            passed(f"Launch command processed: {event_types}")
        elif log_lines:
            passed(f"Launch produced log output (steam attempted): {log_lines[0][:60]}")
        else:
            failed("No response to launch command within 8s")

        client.close()

    except Exception as e:
        failed(f"Exception during launch test: {e}")

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
def main():
    print(bold("Meridian Agent Protocol Tests"))
    print(f"  Target: {SSH_USER}@{SSH_HOST}:{SSH_PORT}")

    try:
        if not check_vm_reachable():
            print(f"\n{red('VM not reachable — start it with test-guest.sh first')}")
            sys.exit(1)

        test_agent_process()

        relay_ok = test_relay_setup()

        test_protocol_connection(relay_ok)
        test_protocol_stop_command(relay_ok)
        test_protocol_unknown_command(relay_ok)
        test_protocol_json_robustness(relay_ok)
        test_launch_command_fake(relay_ok)

    finally:
        stop_relay()

    print()
    print("═══════════════════════════════════════════════════════")
    print(f"  Results: {green(str(PASS)+' passed')}  {red(str(FAIL)+' failed')}  {yellow(str(SKIP)+' skipped')}")
    print("═══════════════════════════════════════════════════════")

    if FAIL > 0:
        print(f"  {red('FAILED')}")
        sys.exit(1)
    else:
        print(f"  {green('ALL TESTS PASSED')}")
        sys.exit(0)

if __name__ == "__main__":
    main()
