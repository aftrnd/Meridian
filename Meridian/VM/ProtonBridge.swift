@preconcurrency import Virtualization
import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "ProtonBridge")

/// Communicates with the meridian-bridge daemon running inside the VM
/// via virtio-vsock (port 1234).
///
/// Why vsock instead of a serial port Unix socket:
///   virtio-vsock gives us proper port-multiplexed bidirectional connections
///   managed entirely by Virtualization.framework. No external socket file is
///   needed; the host calls `vm.socketDevices.first.connect(toPort: 1234)` once
///   the VM is booted and the guest daemon is listening. Additional ports can be
///   used for future services (install progress, resize commands, screenshots)
///   without any plumbing changes.
///
/// Guest side:
///   meridian-bridge listens on AF_VSOCK port 1234 and speaks line-delimited
///   JSON with the host.
///
/// Protocol:
///   Host → Guest:  { "cmd": "launch",  "appid": 1091500, "steamid": "76561..." }
///   Host → Guest:  { "cmd": "install", "appid": 1091500 }
///   Host → Guest:  { "cmd": "is_installed", "appid": 1091500 }
///   Host → Guest:  { "cmd": "stop" }
///   Host → Guest:  { "cmd": "resize",  "w": 1920, "h": 1080 }
///   Guest → Host:  { "event": "started",  "pid": 12345 }
///   Guest → Host:  { "event": "exited",   "code": 0 }
///   Guest → Host:  { "event": "log",      "line": "proton: ..." }
///   Guest → Host:  { "event": "progress", "appid": 1091500, "pct": 42.5 }
///   Guest → Host:  { "event": "installed","appid": 1091500, "installed": true }
actor ProtonBridge {

    // MARK: - Port

    static let vsockPort: UInt32 = VMConfiguration.bridgeVsockPort

    // MARK: - State

    private var socketConnection: VZVirtioSocketConnection?  // retained to keep fd alive
    private var connection: Connection?
    private var logHandler: (@Sendable (String) -> Void)?
    private var exitHandler: (@Sendable (Int) -> Void)?
    private var progressHandler: (@Sendable (Int, Double) -> Void)?
    private var installedHandler: (@Sendable (Int, Bool) -> Void)?
    private var installedReplies: [Int: Bool] = [:]
    private var installProgress: [Int: Double] = [:]
    private var supportsInstallQuery: Bool? = nil

    /// True while the readLoop for the *current* connection is running.
    /// Set to true in setConnection(), cleared in readLoop() only when the loop
    /// belongs to the current generation (prevents a stale loop from a phantom
    /// connect from falsely clearing the flag after a fresh connection succeeds).
    private var connectionLive = false

    /// Monotonically increasing counter incremented on every setConnection() call.
    /// The readLoop captures its generation; it only clears connectionLive when
    /// its generation still matches the actor's current generation.
    private var connectionGeneration: Int = 0

    // MARK: - Public API

    /// Connects to the meridian-bridge daemon in the guest.
    ///
    /// Must be called after the VM is fully booted and the guest daemon is listening.
    /// GameLauncher retries this call until it succeeds or a timeout is reached.
    ///
    /// - Parameter device: The VZVirtioSocketDevice from the running VZVirtualMachine.
    /// - Parameter queue: The DispatchQueue the VM was created on (vmQueue from VMManager).
    ///                    VZVirtioSocketDevice.connect() MUST be called on this queue.
    ///
    /// Declared nonisolated so the VZVirtioSocketDevice does not need to cross
    /// an actor boundary.
    nonisolated func connect(to device: VZVirtioSocketDevice, on queue: DispatchQueue) async throws {
        nonisolated(unsafe) let d = device
        let q = queue
        log.debug("vsock connect → port \(Self.vsockPort)")
        let conn = try await vsockConnect(device: d, queue: q, port: Self.vsockPort)
        log.info("vsock connected fd=\(conn.fileDescriptor)")
        // Re-enter the actor to update isolated state.
        await setConnection(conn)

        // VZ "phantom connect" guard:
        //
        // VZVirtioSocketDevice.connect() calls its completion handler when the
        // VirtIO-level connection is established, which can happen BEFORE the
        // guest's accept() syscall runs.  If the Linux agent doesn't pick up the
        // connection quickly (e.g. vsock driver still initialising), VZ closes the
        // fd and our recv() returns 0 (EOF) almost immediately.  Without this
        // check, bridgeConnected is set to true and the first send() gets EPIPE.
        //
        // Fix: wait 300 ms, then verify the readLoop is still running.  If it has
        // already ended, the agent never accepted — throw so retryConnect retries.
        try await Task.sleep(for: .milliseconds(300))
        let alive = await connectionLive
        if !alive {
            log.warning("vsock phantom connect: readLoop ended within 300ms — agent did not accept (fd=\(conn.fileDescriptor))")
            throw BridgeError.phantomConnect
        }
        log.info("vsock connection confirmed alive after 300ms ✓")
    }

    private func setConnection(_ conn: VZVirtioSocketConnection) {
        socketConnection = conn
        connection = Connection(fileDescriptor: conn.fileDescriptor)
        connectionLive = true
        connectionGeneration += 1
        let gen = connectionGeneration
        log.debug("connection set gen=\(gen), starting read loop")
        Task { await readLoop(generation: gen) }
    }

    func disconnect() {
        connection?.close()
        connection = nil
        socketConnection?.close()
        socketConnection = nil
    }

    // MARK: - Commands

    func launchGame(appID: Int, steamID: String) async throws {
        log.info("→ launch appid=\(appID)")
        try await send(["cmd": "launch", "appid": appID, "steamid": steamID])
    }

    func installGame(appID: Int) async throws {
        log.info("→ install appid=\(appID)")
        try await send(["cmd": "install", "appid": appID])
    }

    func stopGame() async throws {
        log.info("→ stop")
        try await send(["cmd": "stop"])
    }

    func resizeDisplay(width: Int, height: Int) async throws {
        log.debug("→ resize \(width)×\(height)")
        try await send(["cmd": "resize", "w": width, "h": height])
    }

    // MARK: - Handlers

    func onLog(_ handler: @escaping @Sendable (String) -> Void) {
        logHandler = handler
    }

    func onExit(_ handler: @escaping @Sendable (Int) -> Void) {
        exitHandler = handler
    }

    func onProgress(_ handler: @escaping @Sendable (Int, Double) -> Void) {
        progressHandler = handler
    }

    func onInstalled(_ handler: @escaping @Sendable (Int, Bool) -> Void) {
        installedHandler = handler
    }

    func isGameInstalled(appID: Int) async throws -> Bool {
        if supportsInstallQuery == false {
            throw BridgeError.unsupportedCommand("is_installed")
        }
        installedReplies[appID] = nil
        try await send(["cmd": "is_installed", "appid": appID])
        return try await waitForInstalledReply(appID: appID, timeout: .seconds(5))
    }

    /// Sends install command and waits until the guest reports installed state.
    /// Returns true when installed, false when guest reports install failure.
    func installGameAndWait(appID: Int, timeout: Duration = .seconds(3600)) async throws -> Bool {
        installedReplies[appID] = nil
        installProgress[appID] = 0
        try await installGame(appID: appID)
        return try await waitForInstallCompletion(appID: appID, timeout: timeout)
    }

    // MARK: - Private

    private func send(_ payload: [String: any Sendable]) async throws {
        guard let conn = connection else {
            log.error("send failed: not connected (connection is nil)")
            throw BridgeError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A]) // newline
        log.debug("send \(data.count) bytes to fd=\(conn.fileDescriptor)")
        try conn.write(data)
        log.debug("send OK")
    }

    private func readLoop(generation: Int) async {
        guard let conn = connection else { return }
        log.debug("readLoop started on fd=\(conn.fileDescriptor) gen=\(generation)")
        for await line in conn.lines() {
            log.debug("← \(line)")
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch json["event"] as? String ?? "" {
            case "log":
                if let text = json["line"] as? String {
                    if text.contains("unknown command: is_installed") {
                        supportsInstallQuery = false
                    }
                    logHandler?(text)
                }
            case "exited":
                // Older guest agents may omit `code` when it is 0 because of
                // Go `omitempty`; treat missing code as a normal exit.
                exitHandler?(json["code"] as? Int ?? 0)
            case "progress":
                if let appid = json["appid"] as? Int, let pct = json["pct"] as? Double {
                    installProgress[appid] = pct
                    progressHandler?(appid, pct)
                }
            case "installed":
                if let appid = json["appid"] as? Int, let installed = json["installed"] as? Bool {
                    supportsInstallQuery = true
                    installedReplies[appid] = installed
                    installedHandler?(appid, installed)
                }
            default:
                break
            }
        }
        // Only clear connectionLive if this is still the current generation.
        // A phantom connect's readLoop must not override a successful connection.
        if connectionGeneration == generation {
            connectionLive = false
        }
        log.info("readLoop gen=\(generation) ended (peer closed or VM stopped)")
    }

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case notConnected
        /// VZVirtioSocketDevice returned a connection fd but the guest's accept()
        /// never ran — the readLoop ended within 300ms.  retryConnect will retry.
        case phantomConnect
        case installStatusTimeout(appID: Int)
        case installCompletionTimeout(appID: Int)
        case unsupportedCommand(String)
        var errorDescription: String? {
            switch self {
            case .notConnected:    return "Not connected to Proton bridge."
            case .phantomConnect:  return "vsock connection was not accepted by the guest agent (phantom connect)."
            case .installStatusTimeout(let appID):
                return "Timed out waiting for install status for app \(appID)."
            case .installCompletionTimeout(let appID):
                return "Timed out waiting for install completion for app \(appID)."
            case .unsupportedCommand(let cmd):
                return "Guest agent does not support command '\(cmd)'."
            }
        }
    }

    private func waitForInstalledReply(appID: Int, timeout: Duration) async throws -> Bool {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if supportsInstallQuery == false {
                throw BridgeError.unsupportedCommand("is_installed")
            }
            if let installed = installedReplies.removeValue(forKey: appID) {
                return installed
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        throw BridgeError.installStatusTimeout(appID: appID)
    }

    private func waitForInstallCompletion(appID: Int, timeout: Duration) async throws -> Bool {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if let installed = installedReplies.removeValue(forKey: appID) {
                return installed
            }
            if let pct = installProgress[appID], pct >= 100 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw BridgeError.installCompletionTimeout(appID: appID)
    }
}

// MARK: - Nonisolated vsock connection factory
//
// Keeps the VZVirtioSocketDevice completion handler in a nonisolated scope so
// Swift 6 cannot infer actor isolation on the closure (same defensive pattern
// used for ASWebAuthenticationSession in SteamAuthService).

private func vsockConnect(device: sending VZVirtioSocketDevice, queue: DispatchQueue, port: UInt32) async throws -> VZVirtioSocketConnection {
    // VZVirtioSocketDevice.connect() MUST be called on the same DispatchQueue the
    // VZVirtualMachine was created with (vmQueue). Calling it from any other queue
    // causes the completion handler to never fire.
    nonisolated(unsafe) let d = device
    let q = queue
    return try await withCheckedThrowingContinuation { cont in
        q.async {
            d.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    nonisolated(unsafe) let c = connection
                    cont.resume(returning: c)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Unix fd connection helper

private final class Connection: @unchecked Sendable {
    let fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        // Prevent SIGPIPE when the peer closes the connection while we send.
        // Without SO_NOSIGPIPE, send() raises SIGPIPE (which is ignored in a
        // normal Mac app process but can kill test runners and causes the errno
        // to be hidden). With it, send() returns -1 and errno is EPIPE/ECONNRESET
        // so we get a proper, diagnosable error instead of signal 13.
        var nosigpipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE,
                   &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes `data` to the vsock fd.
    ///
    /// Throws the real POSIX error (EPIPE, ECONNRESET, ENOTCONN, etc.) rather
    /// than always masking as .EIO.  This makes the error message shown in the
    /// UI and in os.Logger actually useful for diagnosing what went wrong with
    /// the vsock connection.
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { ptr in
            let n = send(fileDescriptor, ptr.baseAddress!, data.count, 0)
            if n != data.count {
                // Capture errno immediately — any subsequent call could clear it.
                let captured = errno
                let code = POSIXErrorCode(rawValue: captured) ?? .EIO
                let err = POSIXError(code)
                // Log the raw errno so it appears in the unified log even if
                // the caller only logs localizedDescription.
                log.error("vsock send failed: fd=\(self.fileDescriptor) sent=\(n)/\(data.count) errno=\(captured) (\(err.localizedDescription))")
                throw err
            }
        }
    }

    /// Returns an AsyncStream of newline-terminated lines read from the fd.
    func lines() -> AsyncStream<String> {
        let fd = fileDescriptor
        return AsyncStream { continuation in
            Task.detached {
                var buffer = ""
                var chunk  = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let n = recv(fd, &chunk, chunk.count, 0)
                    if n <= 0 {
                        let captured = errno
                        if n < 0 {
                            log.warning("vsock recv returned \(n) errno=\(captured)")
                        }
                        break
                    }
                    buffer += String(bytes: chunk.prefix(n), encoding: .utf8) ?? ""
                    while let range = buffer.range(of: "\n") {
                        let line = String(buffer[buffer.startIndex ..< range.lowerBound])
                        continuation.yield(line)
                        buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
                    }
                }
                continuation.finish()
            }
        }
    }

    func close() { Darwin.close(fileDescriptor) }
}
