import Foundation

private let log = MeridianLog(category: "SteamAppInfo")

/// Resolves Steam **library art hashes** (logo / capsule / hero) from PICS
/// appinfo via Meridian's patched DepotDownloader fork (`-appinfo` mode).
///
/// **Why this exists:** Steam's public `IStoreBrowseService/GetItems/v1` API —
/// the source used by `SteamAPIService.fetchLibraryCapsuleHashes` — returns
/// capsule/hero/header/icon assets but **never** the library LOGO, for any game
/// (CLI-verified 2026-06-19 across Bogos Binted, Pratfall, Portal 2, Stardew,
/// Hades, HL2, Balatro). The legacy `/steam/apps/{id}/logo.png` path only 200s
/// for older titles and 404s for newer ones, so newer games' title logos fell
/// back to plain SF-font text. The logo hash lives ONLY in PICS appinfo at
/// `common.library_assets_full.library_logo` — reachable via the Steam CM
/// protocol (SteamKit2), which the DepotDownloader fork speaks.
///
/// The fork's `-appinfo` mode logs on **anonymously** (the appinfo `common`
/// section is public — no license, no token, no user data sent beyond the app
/// ids), requests appinfo for each id, and emits one NDJSON line per app:
/// ```
/// {"type":"appinfo","appid":N,"logo":"<40-hex>","capsule":"<40-hex>","hero":"<40-hex>"}
/// ```
/// CLI-verified 2026-06-19: returns logo `4037b4ea…` for Bogos Binted (3588490),
/// `6b0b4b03…` for Pratfall (4244510), `a5bf0704…` for Super Battle Golf.
enum SteamAppInfoResolver {

    /// Library art hashes for a single app. Empty fields mean the app does not
    /// publish that asset on Steam's CDN.
    struct Hashes: Equatable, Sendable {
        var logo: String?
        var capsule: String?
        var hero: String?
        /// Steam's logo placement on the hero (from `logo_position`), or nil when
        /// the app publishes no logo / no position.
        var logoPlacement: LogoPlacement?
    }

    /// Parses one stdout line. Returns `(appID, Hashes)` only for a well-formed
    /// `appinfo` JSON object; `nil` for the fork's human-readable status lines.
    ///
    /// Mirrored in `MeridianTests/SteamAppInfoResolverTests.swift` — keep in sync.
    static func parse(_ line: String) -> (appID: Int, hashes: Hashes)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "appinfo"
        else { return nil }

        let appID: Int
        if let n = obj["appid"] as? Int { appID = n }
        else if let n = obj["appid"] as? Double { appID = Int(n) }
        else if let s = obj["appid"] as? String, let n = Int(s) { appID = n }
        else { return nil }

        func nonEmpty(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        func double(_ key: String) -> Double {
            if let n = obj[key] as? Double { return n }
            if let n = obj[key] as? Int { return Double(n) }
            if let s = obj[key] as? String, let n = Double(s) { return n }
            return 0
        }

        // logo_position applies to whatever logo source the game uses — a
        // new-CDN hash OR (for older titles whose `logo` field is empty) the
        // legacy-CDN logo. Steam only writes logo_position when a logo exists,
        // so honour the placement whenever a pinned corner + box size are
        // present, independent of the hash.
        var placement: LogoPlacement?
        let logo = nonEmpty("logo")
        if let pinned = nonEmpty("logoPinned") {
            let w = double("logoWidthPct"), h = double("logoHeightPct")
            if w > 0, h > 0 { placement = LogoPlacement(pinned: pinned, widthPct: w, heightPct: h) }
        }

        return (appID, Hashes(logo: logo,
                              capsule: nonEmpty("capsule"),
                              hero: nonEmpty("hero"),
                              logoPlacement: placement))
    }

    /// Path to the DepotDownloader fork in the live engine, or nil if absent /
    /// not executable (caller skips silently — logos just keep the legacy
    /// fallback). Same location as `WineEngine.depotDownloaderURL`, resolved
    /// statically so this can run off the main actor.
    static var binaryURL: URL? {
        let url = WineEngine.engineDir.appending(path: "tools/depotdownloader/DepotDownloader")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Resolves art hashes for the given app IDs by invoking the fork once with
    /// `-appinfo <comma-ids>`. Anonymous — no username/token. Returns a partial
    /// dictionary (apps the fork couldn't resolve are simply absent). Never
    /// throws: any failure (binary missing, non-zero exit, parse miss) yields an
    /// empty/partial result so the caller degrades gracefully to legacy CDN art.
    static func resolve(appIDs: [Int]) async -> [Int: Hashes] {
        guard !appIDs.isEmpty, let binary = binaryURL else { return [:] }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = runBlocking(binary: binary, appIDs: appIDs)
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous worker (runs on a background queue). A native arm64 process
    /// (NOT Wine) that exits cleanly and closes its stdout, so reading to EOF
    /// after launch does not hit the wineserver pipe-inheritance hang
    /// (engine-research-findings.mdc Pattern 1) — there is no wineserver.
    private static func runBlocking(binary: URL, appIDs: [Int]) -> [Int: Hashes] {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-appinfo", appIDs.map(String.init).joined(separator: ",")]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.warning("[resolve] could not launch DepotDownloader: \(error.localizedDescription)")
            return [:]
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var out: [Int: Hashes] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let (appID, hashes) = parse(String(line)) {
                out[appID] = hashes
            }
        }
        log.info("[resolve] requested \(appIDs.count) ids, resolved \(out.count) from appinfo (exit=\(process.terminationStatus))")
        return out
    }
}
