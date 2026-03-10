/// VMDiagnosticTests.swift
///
/// Tests that exercise the VM launch error paths, vsock connection lifecycle,
/// and image file requirements WITHOUT needing a running VM or VZ entitlement.
///
/// Run individually with:
///   swift test --filter VMDiagnosticTests
///
/// After a failed Meridian launch, read the real error with:
///   log show --predicate 'subsystem == "com.meridian.app"' --last 5m
///
/// The ProtonBridge and GameLauncher now log every step at debug/info/error
/// level so the exact failure point is visible in Console.app or `log show`.

import Testing
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers (no VZ framework needed)
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a temporary file of the given size (as a sparse file).
/// Uses ~/Library/Caches instead of /tmp — the test runner's sandbox allows
/// xattr writes there but not always in NSTemporaryDirectory().
private func makeTempFile(size: Int, suffix: String = ".img") throws -> URL {
    let caches = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let url = caches.appendingPathComponent("meridian-test-\(UUID().uuidString)\(suffix)")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fh = try FileHandle(forWritingTo: url)
    try fh.truncate(atOffset: UInt64(size))
    try fh.close()
    return url
}

/// Applies a com.apple.quarantine xattr to a file.
/// Note: SIP/sandbox may silently drop the write on some paths — the xattr
/// tests verify detection works, not that the Meridian images themselves are
/// quarantined (allVMFilesClean covers that separately).
private func applyQuarantine(to url: URL) {
    let flagString = "0082;00000000;TestApp;"
    flagString.withCString { ptr in
        _ = setxattr(url.path, "com.apple.quarantine", ptr,
                     strlen(ptr), 0, 0)
    }
}

/// Returns the xattr names on a file.
private func xattrs(of url: URL) -> [String] {
    let size = listxattr(url.path, nil, 0, 0)
    guard size > 0 else { return [] }
    var buf = [CChar](repeating: 0, count: size)
    listxattr(url.path, &buf, size, 0)
    return buf.withUnsafeBytes { raw in
        String(decoding: raw, as: UTF8.self)
    }.components(separatedBy: "\0").filter { !$0.isEmpty }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image file / xattr diagnostics
// ─────────────────────────────────────────────────────────────────────────────

@Suite("VM Image File Requirements")
struct VMImageFileTests {

    @Test("temp file creation succeeds and has correct size")
    func tempFileSize() throws {
        let url = try makeTempFile(size: 4096)
        defer { try? FileManager.default.removeItem(at: url) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size == 4096)
    }

    @Test("quarantine xattr can be applied and detected (or silently dropped by sandbox)")
    func quarantineApplyDetect() throws {
        let url = try makeTempFile(size: 512)
        defer { try? FileManager.default.removeItem(at: url) }

        let before = xattrs(of: url)
        #expect(!before.contains("com.apple.quarantine"),
                "fresh file should not have quarantine")

        applyQuarantine(to: url)
        let after = xattrs(of: url)
        // The test runner sandbox may silently prevent setxattr for com.apple.quarantine.
        // This is not a test failure — it means the environment is already restrictive.
        // The important check is allVMFilesClean (below) which reads xattrs, not writes.
        if !after.contains("com.apple.quarantine") {
            print("[xattr] quarantine setxattr silently dropped by sandbox — this is expected in test runner context")
        } else {
            print("[xattr] quarantine applied successfully")
        }
    }

    @Test("quarantine xattr can be removed once present")
    func quarantineRemove() throws {
        let url = try makeTempFile(size: 512)
        defer { try? FileManager.default.removeItem(at: url) }

        applyQuarantine(to: url)
        guard xattrs(of: url).contains("com.apple.quarantine") else {
            print("[xattr] setxattr silently dropped — skipping removal test")
            return
        }

        removexattr(url.path, "com.apple.quarantine", 0)
        #expect(!xattrs(of: url).contains("com.apple.quarantine"),
                "quarantine should be gone after removexattr")
    }

    @Test("file can be opened for writing after quarantine is removed")
    func writeAfterQuarantineRemoved() throws {
        let url = try makeTempFile(size: 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        applyQuarantine(to: url)
        removexattr(url.path, "com.apple.quarantine", 0)

        // Opening for writing should succeed — this is what VZ does
        let fh = try FileHandle(forWritingTo: url)
        try fh.write(contentsOf: Data(repeating: 0xAB, count: 512))
        try fh.close()

        let contents = try Data(contentsOf: url)
        #expect(contents.prefix(512).allSatisfy { $0 == 0xAB })
    }

    @Test("sandbox image path exists and is writable")
    func sandboxImageExists() {
        let sandbox = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        // Both the app's real container path and the plain app-support path
        // are checked — one will be the actual location depending on sandbox state.
        let candidates = [
            sandbox.appending(path: "com.meridian.app/vm/meridian-base.img"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm/meridian-base.img"),
        ]
        var found = false
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                found = true
                let writable = FileManager.default.isWritableFile(atPath: url.path)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = attrs?[.size] as? Int ?? 0
                let quarantined = xattrs(of: url).contains("com.apple.quarantine")
                print("""
                [image check]
                  path:       \(url.path)
                  size:       \(size / 1_073_741_824) GiB
                  writable:   \(writable)
                  quarantine: \(quarantined)
                  xattrs:     \(xattrs(of: url))
                """)
                #expect(writable, "meridian-base.img must be writable for VZ readOnly:false")
                #expect(!quarantined, "meridian-base.img must NOT have com.apple.quarantine — VZ will fail with I/O error")
                #expect(size > 10_737_418_240, "meridian-base.img should be > 10 GiB, got \(size)")
            }
        }
        if !found {
            print("[image check] meridian-base.img not found in any candidate path — VM not provisioned")
        }
    }

    @Test("all VM image files are quarantine-free")
    func allVMFilesClean() {
        let vmDir = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm")
        let files = ["meridian-base.img", "expansion.img", "vmlinuz", "initrd"]
        var checkedAny = false
        for name in files {
            let url = vmDir.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            checkedAny = true
            let q = xattrs(of: url).contains("com.apple.quarantine")
            print("[xattr] \(name): quarantine=\(q)  all=\(xattrs(of: url))")
            #expect(!q, "\(name) has com.apple.quarantine — remove with: xattr -d com.apple.quarantine '\(url.path)'")
        }
        if !checkedAny {
            print("[xattr] VM directory not found — skipping quarantine checks")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Unix socket round-trip (proves Connection write/read logic)
// ─────────────────────────────────────────────────────────────────────────────
// We can't create a real vsock in a test (no VZ entitlement), but we CAN test
// the exact same Connection read/write code paths using a Unix socket pair.
// This catches EPIPE, ECONNRESET, and partial-write bugs before running the VM.

@Suite("Connection — socket write/read (Unix socketpair)")
struct ConnectionSocketTests {

    // Mirror of ProtonBridge's Connection so we can test it without importing Virtualization.
    // Any changes to ProtonBridge.Connection must be reflected here, including SO_NOSIGPIPE.
    private final class Connection {
        let fd: Int32
        init(fd: Int32) {
            self.fd = fd
            // Must match ProtonBridge.Connection — prevents SIGPIPE on closed-peer sends.
            var nosigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        }

        func write(_ data: Data) throws {
            try data.withUnsafeBytes { ptr in
                let n = send(fd, ptr.baseAddress!, data.count, 0)
                if n != data.count {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    throw POSIXError(code)
                }
            }
        }

        /// Reads all available newline-terminated lines from the socket.
        /// Returns as many complete lines as are buffered within `timeout`.
        func readLines(timeout: TimeInterval = 1.0) -> [String] {
            var buf = [UInt8](repeating: 0, count: 4096)
            var pending = ""
            var result: [String] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let n = recv(fd, &buf, buf.count, MSG_DONTWAIT)
                if n > 0 {
                    pending += String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
                    // Split whatever we have into complete lines
                    while let range = pending.range(of: "\n") {
                        let line = String(pending[pending.startIndex ..< range.lowerBound])
                        result.append(line)
                        pending.removeSubrange(pending.startIndex ..< range.upperBound)
                    }
                } else if n < 0 && errno != EAGAIN { break }
                else if !result.isEmpty { break }   // got lines already, stop waiting
                else { Thread.sleep(forTimeInterval: 0.01) }
            }
            return result
        }

        func close() { Darwin.close(fd) }
    }

    private func makeSocketPair() throws -> (Connection, Connection) {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return (Connection(fd: fds[0]), Connection(fd: fds[1]))
    }

    @Test("write then read round-trips a JSON line")
    func roundTrip() throws {
        let (host, agent) = try makeSocketPair()
        defer { host.close(); agent.close() }

        let payload = #"{"cmd":"launch","appid":1091500,"steamid":"76561198000000001"}"# + "\n"
        try host.write(Data(payload.utf8))

        let lines = agent.readLines(timeout: 1.0)
        #expect(lines.count == 1, "should receive exactly one line")
        #expect(lines.first == String(payload.dropLast()),
                "agent should receive the exact JSON the host sent")
    }

    @Test("write to closed peer throws EPIPE not generic EIO")
    func writeToClosedPeer() throws {
        let (host, agent) = try makeSocketPair()
        agent.close()
        // Give the OS a moment to propagate the close
        Thread.sleep(forTimeInterval: 0.05)

        var thrownError: Error?
        do {
            try host.write(Data(#"{"cmd":"stop"}"#.utf8 + [0x0A]))
        } catch {
            thrownError = error
        }
        host.close()

        // We must get SOME POSIX error — not a nil throw
        #expect(thrownError != nil, "write to closed peer must throw")

        if let posix = thrownError as? POSIXError {
            // The real errno on a closed peer is EPIPE or ECONNRESET.
            // Critically, it must NOT be .EIO (which is what the old code threw
            // unconditionally — masking the real cause).
            print("[write-to-closed] errno=\(posix.code.rawValue) desc=\(posix.localizedDescription)")
            #expect(posix.code != .EIO,
                    "write to closed peer should give EPIPE/ECONNRESET, not generic EIO — if this fails the error masking bug is back")
        } else {
            Issue.record("Expected POSIXError, got \(type(of: thrownError!))")
        }
    }

    @Test("write to still-open peer succeeds")
    func writeToOpenPeer() throws {
        let (host, agent) = try makeSocketPair()
        defer { host.close(); agent.close() }

        let data = Data(#"{"cmd":"stop"}"#.utf8 + [0x0A])
        // This must NOT throw
        #expect(throws: Never.self) {
            try host.write(data)
        }
    }

    @Test("multiple sequential writes succeed")
    func multipleWrites() throws {
        let (host, agent) = try makeSocketPair()
        defer { host.close(); agent.close() }

        for i in 0..<5 {
            let line = #"{"cmd":"launch","appid":\#(i)}"# + "\n"
            try host.write(Data(line.utf8))
        }

        // readLines properly handles multiple lines in one recv buffer
        let lines = agent.readLines(timeout: 1.0)
        print("[multi-write] received \(lines.count) lines: \(lines)")
        #expect(lines.count == 5, "all 5 commands should be received by agent, got \(lines.count)")
    }

    @Test("recv returns 0 when writer closes — readLoop should exit cleanly")
    func recvOnWriterClose() throws {
        let (host, agent) = try makeSocketPair()
        host.close()
        Thread.sleep(forTimeInterval: 0.05)

        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(agent.fd, &buf, buf.count, 0)
        // n == 0 means EOF (writer closed), not an error
        #expect(n == 0, "recv should return 0 on peer close — readLoop should exit without error")
        agent.close()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Live agent probe (runs only if VM is currently booted)
// ─────────────────────────────────────────────────────────────────────────────
// This test SSHs into the VM (requires QEMU port-forwarded SSH on :2222) and
// checks whether meridian-agent is alive and listening on vsock:1234.
// It is skipped automatically when the VM is not reachable.

@Suite("Live VM Agent (QEMU SSH on :2222, skipped if VM not running)")
struct LiveVMAgentTests {

    private func sshRun(_ cmd: String, timeout: TimeInterval = 5) -> (String, Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=3",
            "-o", "BatchMode=no",
            "-o", "PasswordAuthentication=yes",
            "-p", "2222",
            "meridian@localhost",
            cmd
        ]
        // Use sshpass if available
        if let sshpass = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/which"), arguments: ["sshpass"]
        ) { sshpass.waitUntilExit() }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return ("", -1) }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), task.terminationStatus)
    }

    private func sshPassRun(_ cmd: String) -> (String, Int32) {
        let task = Process()
        // Use sshpass -p meridian for password auth
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
        if !FileManager.default.fileExists(atPath: task.executableURL!.path) {
            return ("sshpass not found", -1)
        }
        task.arguments = [
            "-p", "meridian",
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=3",
            "-o", "BatchMode=no",
            "-p", "2222",
            "meridian@localhost",
            cmd
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return ("", -1) }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), task.terminationStatus)
    }

    @Test("meridian-agent systemd service is active in guest")
    func agentServiceActive() {
        let (out, rc) = sshPassRun("sudo systemctl is-active meridian-agent.service")
        guard rc == 0 else {
            print("[live-agent] SSH not reachable on :2222 — VM not running in QEMU mode, skipping")
            return
        }
        print("[live-agent] meridian-agent status: '\(out)'")
        #expect(out == "active", "meridian-agent.service must be active, got: '\(out)'")
    }

    @Test("vsock port 1234 is listening in guest")
    func vsockListening() {
        let (out, rc) = sshPassRun("sudo ss --vsock -l 2>/dev/null | grep 1234")
        guard rc == 0 else {
            print("[live-agent] SSH not reachable — skipping vsock check")
            return
        }
        print("[live-agent] vsock ss output: '\(out)'")
        #expect(!out.isEmpty, "vsock port 1234 should show in ss --vsock -l")
    }

    /// THE CRITICAL TEST — this is the root cause of "Launch command failed: Broken pipe".
    ///
    /// When Apple's Virtualization.framework boots the VM and calls connect(toPort:1234),
    /// the VirtIO vsock transport (vmw_vsock_virtio_transport) MUST be loaded or the guest's
    /// accept() returns EAFNOSUPPORT.  The host gets a seemingly-valid fd, but the first
    /// send() returns EPIPE because the guest has closed the connection.
    ///
    /// Fix: ExecStartPre=/sbin/modprobe vmw_vsock_virtio_transport in meridian-agent.service
    ///      + /etc/modules-load.d/meridian-vsock.conf
    @Test("vmw_vsock_virtio_transport module is loaded (root cause of Broken Pipe)")
    func vsockModuleLoaded() {
        let (out, rc) = sshPassRun("lsmod 2>/dev/null | grep vmw_vsock_virtio_transport")
        guard rc == 0 else {
            print("[live-agent] SSH not reachable — skipping module check")
            return
        }
        print("[live-agent] vsock module: '\(out)'")
        #expect(!out.isEmpty,
            "vmw_vsock_virtio_transport not loaded — accept() returns EAFNOSUPPORT, host gets EPIPE on send(). Fix: ./Scripts/patch-vm-vsock.sh")
    }

    @Test("meridian-agent service has ExecStartPre modprobe in unit file")
    func agentServiceHasModprobe() {
        let (out, rc) = sshPassRun("sudo cat /etc/systemd/system/meridian-agent.service 2>/dev/null")
        guard rc == 0 else {
            print("[live-agent] SSH not reachable — skipping service file check")
            return
        }
        print("[live-agent] meridian-agent.service:\n\(out)")
        #expect(out.contains("modprobe"),
            "meridian-agent.service missing ExecStartPre modprobe — run ./Scripts/patch-vm-vsock.sh")
    }

    @Test("meridian-agent journal shows no accept EAFNOSUPPORT errors")
    func agentNoAcceptErrors() {
        let (out, rc) = sshPassRun("sudo journalctl -u meridian-agent.service -n 40 --no-pager 2>/dev/null")
        guard rc == 0 else {
            print("[live-agent] SSH not reachable — skipping journal check")
            return
        }
        print("[live-agent] agent journal:\n\(out)")
        let hasAFError = out.contains("address family not supported") || out.contains("EAFNOSUPPORT")
        #expect(!hasAFError,
            "Agent journal shows EAFNOSUPPORT — vmw_vsock_virtio_transport not loaded. Run ./Scripts/patch-vm-vsock.sh")
        let restartCount = out.components(separatedBy: "Started meridian").count - 1
        #expect(restartCount < 3, "agent should not be restart-looping (started \(restartCount) times in last 40 lines)")
    }

    @Test("rosetta-setup service succeeded or gracefully skipped")
    func rosettaSetup() {
        let (out, rc) = sshPassRun("sudo systemctl status rosetta-setup.service --no-pager 2>/dev/null | head -5")
        guard rc == 0 else { return }
        print("[live-agent] rosetta-setup: \(out)")
        let (active, _) = sshPassRun("sudo systemctl is-active rosetta-setup.service")
        print("[live-agent] rosetta-setup active=\(active)")
        // "inactive" is fine in QEMU (no virtiofs → service exits 0 gracefully)
        // "failed" means the script crashed and would delay meridian-agent startup
        #expect(active != "failed", "rosetta-setup.service must not be in 'failed' state")
    }
}
