import Foundation

/// A minimal single-request HTTP server that acts as a localhost OpenID broker.
///
/// Why this exists:
/// Steam's OpenID endpoint performs a server-side protocol check and rejects any
/// `return_to` URL whose scheme is not `http` or `https`. Custom URI schemes
/// (e.g. `meridian://`) are rejected with "Invalid return protocol". This is
/// a hard Steam constraint — there is no client-side workaround.
///
/// The pattern (a temporary localhost HTTP server as loopback broker) is the same
/// one used by VS Code (GitHub auth), Spotify, and is codified in RFC 8252 §7.3
/// "Loopback Interface Redirection".
///
/// Flow:
///   1. A random available TCP port is bound on 127.0.0.1 using BSD sockets.
///   2. `return_to` is set to `http://127.0.0.1:{port}/openid/callback`.
///   3. Steam redirects the embedded browser to our localhost URL after sign-in.
///   4. We receive the OpenID params, extract the SteamID from `openid.claimed_id`,
///      then respond with a 302 redirect to `meridian://auth/callback?steamid=<id>`.
///   5. `ASWebAuthenticationSession` intercepts the `meridian://` redirect.
///   6. The server shuts itself down after handling the single request.
///
/// Implementation note: We use raw BSD sockets instead of Network.framework's
/// NWListener because NWListener has path-validation quirks that can produce
/// EINVAL on sandboxed macOS even with the correct entitlements.
final class SteamLocalAuthServer: @unchecked Sendable {

    private var serverFD: Int32 = -1
    private(set) var callbackURL: URL?

    // MARK: - Public API

    /// Binds a listening socket on 127.0.0.1 and returns the `return_to` URL.
    func start() throws -> URL {
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTSOCK)
        }

        // Allow rapid re-use of the port if the process restarts quickly.
        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind to 127.0.0.1 on an OS-assigned port (port 0).
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // OS picks a free port

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            Darwin.close(serverFD)
            serverFD = -1
            throw POSIXError(code)
        }

        guard listen(serverFD, 1) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            Darwin.close(serverFD)
            serverFD = -1
            throw POSIXError(code)
        }

        // Discover which port the OS assigned.
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFD, $0, &addrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        let url = URL(string: "http://127.0.0.1:\(port)/openid/callback")!
        callbackURL = url
        return url
    }

    /// Starts accepting one connection in the background (fire-and-forget).
    ///
    /// The server's only job is to:
    ///   1. Accept the single HTTP GET that Steam's browser redirect produces.
    ///   2. Extract the SteamID from `openid.claimed_id`.
    ///   3. Send a 302 → `meridian://auth/callback?steamid=<id>`.
    ///
    /// There is intentionally no continuation here. ASWebAuthenticationSession
    /// is the sole driver of the sign-in continuation in SteamAuthService —
    /// it intercepts the `meridian://` redirect the server issues. Having a
    /// second concurrent continuation was the source of EXC_BREAKPOINT crashes.
    func startListening() {
        guard serverFD >= 0 else { return }
        let fd = serverFD

        DispatchQueue.global(qos: .userInteractive).async { [self] in
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var buffer = [UInt8](repeating: 0, count: 16_384)
            let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
            guard bytesRead > 0 else { return }

            let requestText = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""

            guard let steamID = self.extractSteamID(from: requestText) else {
                let body = "<html><body><h2>Authentication failed.</h2>" +
                           "<p>Could not read Steam ID from callback.</p></body></html>"
                self.sendHTTP(fd: clientFD, status: 400, headers: "", body: body)
                return
            }

            let redirectURL = URL(string: "meridian://auth/callback?steamid=\(steamID)")!
            let body = "<html><head><meta http-equiv='refresh' content='0;url=\(redirectURL)'></head>" +
                       "<body><p>Signing you in to Meridian…</p></body></html>"
            self.sendHTTP(fd: clientFD, status: 302,
                          headers: "Location: \(redirectURL.absoluteString)\r\n",
                          body: body)
            self.stop()
        }
    }

    /// Closes the server socket. Safe to call multiple times.
    func stop() {
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
    }

    // MARK: - Private helpers

    /// Extracts the Steam64 ID from the raw HTTP request text.
    ///
    /// Steam sends:
    ///   GET /openid/callback?openid.claimed_id=https://steamcommunity.com/openid/id/76561198... HTTP/1.1
    private func extractSteamID(from requestText: String) -> String? {
        // Pull the request path out of the first line.
        guard
            let requestLine = requestText.components(separatedBy: "\r\n").first,
            let pathPart = requestLine.components(separatedBy: " ").dropFirst().first
        else { return nil }

        // Parse the query string.
        guard
            let components = URLComponents(string: "http://localhost\(pathPart)"),
            let claimedID = components.queryItems?.first(where: { $0.name == "openid.claimed_id" })?.value,
            let idURL = URL(string: claimedID),
            let id = idURL.pathComponents.last,
            id.count >= 17,
            id.allSatisfy(\.isNumber)
        else { return nil }

        return id
    }

    private func sendHTTP(fd: Int32, status: Int, headers: String, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let statusText = status == 302 ? "Found" : status == 200 ? "OK" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(statusText)\r\n" +
                       "Content-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(bodyData.count)\r\n" +
                       "Connection: close\r\n" +
                       headers +
                       "\r\n"
        var packet = response.data(using: .utf8)!
        packet.append(bodyData)
        packet.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, packet.count, 0)
        }
    }

    // MARK: - Errors (retained for callers of start())

    enum ServerError: LocalizedError {
        case bindFailed

        var errorDescription: String? {
            "Could not bind to a local port for Steam authentication."
        }
    }
}
