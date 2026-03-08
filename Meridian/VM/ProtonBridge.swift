import Foundation

/// Communicates with the Meridian guest via the virtio-serial socket (hvc0).
///
/// The guest runs a small meridian-bridge daemon that listens on /dev/hvc0.
/// We connect from the host side via the Unix socket at proton-bridge.sock.
///
/// Protocol (line-delimited JSON):
///   Host → Guest: { "cmd": "launch", "appid": 1091500, "steamid": "76561...", "token": "..." }
///   Guest → Host: { "event": "started",  "pid": 12345 }
///   Guest → Host: { "event": "exited",   "code": 0 }
///   Guest → Host: { "event": "log",      "line": "proton: ..." }
actor ProtonBridge {

    private var connection: Connection?
    private var logHandler: (@Sendable (String) -> Void)?
    private var exitHandler: (@Sendable (Int) -> Void)?

    private let socketURL: URL = VMImageProvider.supportDir.appending(path: "proton-bridge.sock")

    // MARK: - Public API

    func connect() async throws {
        let conn = try Connection(socketPath: socketURL.path())
        self.connection = conn
        Task { await self.readLoop() }
    }

    func disconnect() {
        connection?.close()
        connection = nil
    }

    func launchGame(appID: Int, steamID: String) async throws {
        let cmd: [String: String] = [
            "cmd":     "launch",
            "appid":   String(appID),
            "steamid": steamID,
        ]
        try await send(cmd)
    }

    func onLog(_ handler: @escaping @Sendable (String) -> Void) {
        logHandler = handler
    }

    func onExit(_ handler: @escaping @Sendable (Int) -> Void) {
        exitHandler = handler
    }

    // MARK: - Private

    private func send(_ payload: [String: String]) async throws {
        guard let conn = connection else { throw BridgeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A]) // newline
        try conn.write(data)
    }

    private func readLoop() async {
        guard let conn = connection else { return }
        for await line in conn.lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let event = json["event"] as? String ?? ""
            switch event {
            case "log":
                if let line = json["line"] as? String { logHandler?(line) }
            case "exited":
                let code = json["code"] as? Int ?? -1
                exitHandler?(code)
            default:
                break
            }
        }
    }

    enum BridgeError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Not connected to Proton bridge." }
    }
}

// MARK: - Unix socket connection helper

private final class Connection: @unchecked Sendable {
    private let fd: Int32

    init(socketPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = strlcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    src,
                    maxLen
                )
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { ptr in
            let n = send(fd, ptr.baseAddress!, data.count, 0)
            guard n == data.count else { throw POSIXError(.EIO) }
        }
    }

    func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached {
                var buffer = ""
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = recv(self.fd, &chunk, chunk.count, 0)
                    guard n > 0 else { break }
                    buffer += String(bytes: chunk.prefix(n), encoding: .utf8) ?? ""
                    while let range = buffer.range(of: "\n") {
                        let line = String(buffer[buffer.startIndex..<range.lowerBound])
                        continuation.yield(line)
                        buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                    }
                }
                continuation.finish()
            }
        }
    }

    func close() { Darwin.close(fd) }
}
