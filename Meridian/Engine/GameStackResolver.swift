import Foundation
import Observation

private let log = MeridianLog(category: "GameStack")

// MARK: - DetectedGameStack (local fingerprinting result)

/// What Meridian can determine about a game purely from its installed files —
/// no network, no DB. Authoritative for the things that are knowable from the
/// bytes on disk (bitness, DRM, engine), and a best-effort baseline for the
/// graphics API (the engine's default; refined by PCGamingWiki when available).
struct DetectedGameStack: Sendable {
    var engine: GameEngine
    /// The engine's DEFAULT graphics API — a baseline, not ground truth. A
    /// Unity game *can* run DX12, but defaults to DX11; PCGamingWiki's tested
    /// `Direct3D_versions` is the authority when present.
    var graphicsAPI: GraphicsAPI
    /// 32 or 64 — read from the main executable's PE header. Authoritative.
    var bitness: Int?
    var requiresSteamAPI: Bool
    var mainExecutable: String?
}

// MARK: - GameStackDetector (local, offline, files-on-disk)

/// Fingerprints an installed game's tech stack from its files. Pure functions
/// over the install directory — safe to run on a background task.
enum GameStackDetector {

    /// Detects engine, default graphics API, bitness, and DRM from the install
    /// directory. Everything is best-effort; unknowns are returned as `.unknown`
    /// / `nil` rather than guessed.
    static func detect(installDir: URL) -> DetectedGameStack {
        let fm = FileManager.default
        let dirPath = installDir.path(percentEncoded: false)
        let top = (try? fm.contentsOfDirectory(atPath: dirPath)) ?? []

        let engine = fingerprintEngine(installDir: installDir, top: top, fm: fm)
        let mainExe = mainExecutable(in: top)
        let bitness = mainExe
            .map { installDir.appending(path: $0) }
            .flatMap { peBitness(of: $0) }
        let drm = hasSteamAPI(installDir: installDir, fm: fm)

        let detected = DetectedGameStack(
            engine: engine,
            graphicsAPI: defaultAPI(for: engine),
            bitness: bitness,
            requiresSteamAPI: drm,
            mainExecutable: mainExe
        )
        log.info("[detect] \(installDir.lastPathComponent): engine=\(engine.rawValue) apiDefault=\(detected.graphicsAPI.rawValue) bitness=\(bitness.map(String.init) ?? "?") drm=\(drm) exe=\(mainExe ?? "?")")
        return detected
    }

    // MARK: Engine fingerprint

    static func fingerprintEngine(installDir: URL, top: [String], fm: FileManager) -> GameEngine {
        let lower = Set(top.map { $0.lowercased() })
        let dirPath = installDir.path(percentEncoded: false)

        func isDir(_ name: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: "\(dirPath)/\(name)", isDirectory: &d) && d.boolValue
        }

        // Unity — *_Data folder, UnityPlayer.dll, or UnityCrashHandler.
        if lower.contains("unityplayer.dll")
            || lower.contains("unitycrashhandler64.exe")
            || lower.contains("unitycrashhandler32.exe")
            || top.contains(where: { $0.hasSuffix("_Data") && isDir($0) }) {
            return .unity
        }

        // Unreal — an `Engine/` dir, a *-Shipping.exe, or any top dir holding
        // `Binaries/Win64`. The shallow `Binaries/Win64` probe covers the
        // common `<Game>/Binaries/Win64/<Game>-Win64-Shipping.exe` layout.
        if isDir("Engine")
            || top.contains(where: { $0.lowercased().hasSuffix("-shipping.exe") }) {
            return .unreal
        }
        for entry in top where isDir(entry) {
            if fm.fileExists(atPath: "\(dirPath)/\(entry)/Binaries/Win64") { return .unreal }
        }

        // Source — `bin/` plus a Source-flavoured sibling (a *_complete /
        // content folder, a .vpk, or a known Source launcher exe).
        if isDir("bin") {
            let sourceish = top.contains { name in
                let l = name.lowercased()
                return l.hasSuffix(".vpk")
                    || l.hasSuffix("_complete")
                    || l == "platform"
                    || l == "hl2.exe" || l == "portal2.exe" || l == "left4dead2.exe"
            }
            if sourceish { return .source }
        }

        // Godot — a top-level `.pck` pack file (Godot exported games ship one
        // next to the binary unless embedded).
        if top.contains(where: { $0.lowercased().hasSuffix(".pck") }) {
            return .godot
        }

        // Has an exe but matched nothing → a custom/uncommon engine.
        if top.contains(where: { $0.lowercased().hasSuffix(".exe") }) {
            return .custom
        }
        return .unknown
    }

    /// The engine's default graphics API. A baseline only — PCGamingWiki's
    /// tested `Direct3D_versions` overrides this when available.
    static func defaultAPI(for engine: GameEngine) -> GraphicsAPI {
        switch engine {
        case .source:  return .dx9
        case .unity:   return .dx11   // Unity defaults to DX11 unless forced
        case .unreal:  return .dx11   // conservative; UE5 can DX12 but DX11 is safe + matches global default
        case .godot:   return .vulkan
        // Gamebryo isn't fingerprinted (Bethesda's .esm/.bsa layout is
        // Creation Engine's too), so detection never returns it.
        case .gamebryo, .custom, .unknown: return .unknown
        }
    }

    // MARK: Main executable

    /// Picks the most likely game executable using the same filter the
    /// launcher uses (skip crash handlers / redists / uninstallers, prefer a
    /// non-Unity-helper exe). Used for the PE bitness read.
    static func mainExecutable(in top: [String]) -> String? {
        let exes = top.filter { $0.lowercased().hasSuffix(".exe") }
            .filter {
                let l = $0.lowercased()
                return !l.contains("crash") && !l.contains("redist") && !l.contains("unins")
            }
        return exes.first(where: { !$0.lowercased().contains("unity") }) ?? exes.first
    }

    // MARK: SteamStub DRM (exe encryption)

    /// Detects the SteamStub DRM wrapper by the `.bind` PE section it injects
    /// into the game's executable. SteamStub encrypts the exe's real entry
    /// point; only a running, signed-in Steam client can decrypt it at launch.
    /// The gbe_fork API shim can satisfy `SteamAPI_Init()` but can NOT decrypt
    /// a SteamStub exe — these games genuinely require Online mode.
    ///
    /// PE walk: MZ → e_lfanew(0x3C) → "PE\0\0" → COFF header (NumberOfSections
    /// at +6, SizeOfOptionalHeader at +20) → section table (40-byte entries,
    /// first 8 bytes = name). Returns true when any section is named ".bind".
    ///
    /// MIRROR CONTRACT: mirrored in GameInstallTests.hasSteamStub.
    static func hasSteamStub(exe: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? fh.close() }

        guard let dosData = try? fh.read(upToCount: 0x40), dosData.count >= 0x40 else { return false }
        let dos = [UInt8](dosData)
        guard dos[0] == 0x4D, dos[1] == 0x5A else { return false } // "MZ"
        let eLfanew = Int(dos[0x3C]) | Int(dos[0x3D]) << 8 | Int(dos[0x3E]) << 16 | Int(dos[0x3F]) << 24
        guard eLfanew > 0, eLfanew < 4_000_000 else { return false }

        try? fh.seek(toOffset: UInt64(eLfanew))
        guard let coffData = try? fh.read(upToCount: 24), coffData.count >= 24 else { return false }
        let coff = [UInt8](coffData)
        guard coff[0] == 0x50, coff[1] == 0x45, coff[2] == 0, coff[3] == 0 else { return false } // "PE\0\0"
        let numberOfSections     = Int(coff[6])  | Int(coff[7])  << 8
        let sizeOfOptionalHeader = Int(coff[20]) | Int(coff[21]) << 8

        try? fh.seek(toOffset: UInt64(eLfanew + 24 + sizeOfOptionalHeader))
        let tableSize = min(numberOfSections, 96) * 40
        guard tableSize > 0, let table = try? fh.read(upToCount: tableSize), table.count >= 40 else { return false }
        let bytes = [UInt8](table)
        let bind: [UInt8] = [0x2E, 0x62, 0x69, 0x6E, 0x64] // ".bind"
        for i in stride(from: 0, to: bytes.count - 39, by: 40) {
            if Array(bytes[i..<(i + 5)]) == bind, bytes[i + 5] == 0 { return true }
        }
        return false
    }

    // MARK: PE bitness

    /// Reads the COFF Machine field from a Windows PE executable and maps it to
    /// 32 or 64. Returns nil for non-PE files or unrecognised machines.
    /// MZ → e_lfanew(0x3C) → "PE\0\0" → Machine(UInt16 LE).
    static func peBitness(of exe: URL) -> Int? {
        guard let fh = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? fh.close() }
        guard let dosData = try? fh.read(upToCount: 0x40), dosData.count >= 0x40 else { return nil }
        let dos = [UInt8](dosData)
        guard dos[0] == 0x4D, dos[1] == 0x5A else { return nil } // "MZ"
        let eLfanew = UInt32(dos[0x3C]) | (UInt32(dos[0x3D]) << 8)
            | (UInt32(dos[0x3E]) << 16) | (UInt32(dos[0x3F]) << 24)
        // Sanity bound — a corrupt offset shouldn't send us seeking into the void.
        guard eLfanew < 0x1000_0000 else { return nil }
        try? fh.seek(toOffset: UInt64(eLfanew))
        guard let peData = try? fh.read(upToCount: 6), peData.count >= 6 else { return nil }
        let pe = [UInt8](peData)
        guard pe[0] == 0x50, pe[1] == 0x45, pe[2] == 0, pe[3] == 0 else { return nil } // "PE\0\0"
        let machine = UInt16(pe[4]) | (UInt16(pe[5]) << 8)
        switch machine {
        case 0x8664, 0xAA64: return 64   // AMD64, ARM64
        case 0x014C:         return 32   // i386
        default:             return nil
        }
    }

    // MARK: DRM

    /// True when a `steam_api64.dll` / `steam_api.dll` exists anywhere under the
    /// install dir. Mirrors `WinePrefix.gameRequiresSteamAPI`'s file probe (kept
    /// local so detection has no WinePrefix dependency).
    static func hasSteamAPI(installDir: URL, fm: FileManager) -> Bool {
        let dirPath = installDir.path(percentEncoded: false)
        guard let e = fm.enumerator(atPath: dirPath) else { return false }
        while let f = e.nextObject() as? String {
            let name = (f as NSString).lastPathComponent.lowercased()
            if name == "steam_api64.dll" || name == "steam_api.dll" { return true }
        }
        return false
    }
}

// MARK: - PCGamingWiki enrichment

/// Tech metadata for one game pulled from PCGamingWiki's Cargo API. Cached to
/// disk; tech specs change rarely so a long TTL is fine.
struct PCGamingWikiInfo: Codable, Sendable {
    var found: Bool
    var engine: GameEngineCodable?
    var graphicsAPI: GraphicsAPICodable?
    var bitness: Int?
    var vulkan: Bool
    var metal: Bool
    /// Raw strings for display / debugging.
    var engineRaw: String?
    var direct3dRaw: String?
    var fetchedAt: Date

    // GameEngine / GraphicsAPI aren't Codable, so store rawValue and bridge.
    enum GameEngineCodable: String, Codable { case unity, unreal, godot, source, gamebryo, custom, unknown }
    enum GraphicsAPICodable: String, Codable { case dx9, dx11, dx12, vulkan, unknown }

    var resolvedEngine: GameEngine? {
        guard let e = engine else { return nil }
        return GameEngine(rawValue: e.rawValue)
    }
    var resolvedAPI: GraphicsAPI? {
        guard let a = graphicsAPI else { return nil }
        return GraphicsAPI(rawValue: a.rawValue)
    }
}

/// Fetches + caches a game's PCGamingWiki tech facts. Network is off the
/// launch hot path: callers fetch lazily (library load / detail view /
/// install) and the result is cached on disk. Respects PCGW's rate-limit
/// guidance: a few requests per game at most (its page, else a search and up
/// to three candidates), long TTL, descriptive User-Agent.
actor PCGamingWikiService {
    static let shared = PCGamingWikiService()
    private init() {}

    /// Tech specs rarely change; 30 days avoids re-hitting a rate-limited API.
    private static let ttl: TimeInterval = 60 * 60 * 24 * 30

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = [
            "Accept": "application/json",
            // PCGamingWiki asks API consumers to identify themselves.
            "User-Agent": "Meridian-Mac-Game-Launcher/1.0 (game compatibility metadata)",
        ]
        return URLSession(configuration: c)
    }()

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/cache/pcgw", directoryHint: .isDirectory)
    }

    private static func cacheURL(for appID: Int) -> URL {
        cacheDir.appending(path: "\(appID).json")
    }

    /// Returns PCGW info for an app, from disk cache when fresh, otherwise
    /// fetched + cached. Returns nil only on a network/parse failure (a
    /// "game not on PCGW" result is cached with `found == false`).
    func info(for appID: Int, name: String) async -> PCGamingWikiInfo? {
        if let cached = readCache(appID: appID),
           Date().timeIntervalSince(cached.fetchedAt) < Self.ttl {
            return cached
        }
        guard let fetched = await fetch(appID: appID, name: name) else { return readCache(appID: appID) }
        writeCache(fetched, appID: appID)
        return fetched
    }

    // MARK: Fetch

    /// PCGamingWiki no longer answers anonymous Cargo queries: HTTP 200 with
    /// `{"error":{"code":"permissiondenied","info":"You don't have permission
    /// to run arbitrary Cargo queries."}}` (CLI-verified Oct 14 2026), so the
    /// old lookup failed to decode for every game and none got PCGW data.
    /// Special:CargoExport sits behind a Cloudflare challenge and
    /// `api/appid.php` answers 403. The MediaWiki parse API still serves a
    /// page's wikitext, whose templates carry the same fields. App IDs are
    /// not searchable, so the page is found by the game's name (then a
    /// search) and kept only when its `steam appid` lists this app.
    private func fetch(appID: Int, name: String) async -> PCGamingWikiInfo? {
        let title = name.filter { !"™®©".contains($0) }.trimmingCharacters(in: .whitespaces)
        do {
            if let info = try await pageInfo(title: title, appID: appID) { return info }
            for other in try await search(title) where other != title {
                if let info = try await pageInfo(title: other, appID: appID) { return info }
            }
            log.info("[pcgw] appID=\(appID) not found on PCGamingWiki (\"\(title)\")")
            return PCGamingWikiInfo(found: false, engine: nil, graphicsAPI: nil, bitness: nil,
                                    vulkan: false, metal: false, engineRaw: nil, direct3dRaw: nil,
                                    fetchedAt: Date())
        } catch {
            log.warning("[pcgw] appID=\(appID) fetch/parse failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The tech facts on the page titled `title`, or nil when there is no
    /// such page or it is another game's.
    private func pageInfo(title: String, appID: Int) async throws -> PCGamingWikiInfo? {
        let reply = try await request(ParseReply.self, [
            .init(name: "action", value: "parse"),
            .init(name: "page", value: title),
            .init(name: "prop", value: "wikitext"),
            .init(name: "redirects", value: "1"),
        ])
        if reply.error?.code == "missingtitle" { return nil }
        if let code = reply.error?.code { throw PCGamingWikiError.api(code) }
        guard let wikitext = reply.parse?.wikitext.text else { throw PCGamingWikiError.api("no wikitext") }
        return Self.info(fromWikitext: wikitext, appID: appID)
    }

    /// Up to three page titles PCGamingWiki's search finds for `title`.
    private func search(_ title: String) async throws -> [String] {
        let reply = try await request(SearchReply.self, [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: title),
            .init(name: "srlimit", value: "3"),
            .init(name: "srprop", value: ""),
        ])
        if let code = reply.error?.code { throw PCGamingWikiError.api(code) }
        return reply.query?.search.map(\.title) ?? []
    }

    private func request<Reply: Decodable>(_ type: Reply.Type, _ query: [URLQueryItem]) async throws -> Reply {
        var comps = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        comps.queryItems = query + [.init(name: "format", value: "json")]
        guard let url = comps.url else { throw PCGamingWikiError.api("bad query") }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PCGamingWikiError.http(http.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: Parse helpers

    /// The tech facts in a page's wikitext, or nil when the page is another
    /// game's (its `steam appid` and `steam appid side` don't list `appID`).
    /// Reads the templates' `|key = value` lines, the first of each key.
    static func info(fromWikitext text: String, appID: Int) -> PCGamingWikiInfo? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("|") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.index(after: line.startIndex)..<equals]
                .trimmingCharacters(in: .whitespaces).lowercased()
            // A reference's digits (`<ref>{{Refcheck|date=2022-11-30`) would
            // read as Direct3D versions.
            var value = line[line.index(after: equals)...]
            if let note = value.firstRange(of: /<ref|<!--/) { value = value[..<note.lowerBound] }
            if fields[key] == nil { fields[key] = value.trimmingCharacters(in: .whitespaces) }
        }
        let appIDs = [fields["steam appid"], fields["steam appid side"]]
            .compactMap { $0 }
            .flatMap { $0.split { !$0.isNumber } }
            .compactMap { Int($0) }
        guard appIDs.contains(appID) else { return nil }

        // `{{Infobox game/row/engine|Gamebryo (TES Engine)}}`, one per engine.
        let engines = text.matches(of: /\{\{Infobox game\/row\/engine\|([^|}]+)/)
            .map { $0.1.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " • ")
        let engineRaw = engines.isEmpty ? nil : engines
        let direct3D = fields["direct3d versions"].flatMap { $0.isEmpty ? nil : $0 }
        // Versions ("1.1"), or "true"; empty or "false" when it has none.
        let vulkanVersions = fields["vulkan versions"] ?? ""
        let vulkan = vulkanVersions.lowercased() == "true" || vulkanVersions.contains(where: \.isNumber)
        let bitness: Int? = {
            // Prefer 64-bit when the game ships a 64-bit exe.
            if boolish(fields["windows 64-bit exe"]) { return 64 }
            if boolish(fields["windows 32-bit exe"]) { return 32 }
            return nil
        }()
        // If no Direct3D but Vulkan is supported, report Vulkan.
        let api: PCGamingWikiInfo.GraphicsAPICodable? = parseDirect3D(direct3D) ?? (vulkan ? .vulkan : nil)
        return PCGamingWikiInfo(
            found: true,
            engine: parseEngine(engineRaw),
            graphicsAPI: api,
            bitness: bitness,
            vulkan: vulkan,
            metal: boolish(fields["metal support"]),
            engineRaw: engineRaw,
            direct3dRaw: direct3D,
            fetchedAt: Date()
        )
    }

    /// PCGW engine names (`Gamebryo (TES Engine)`, several joined with " • ").
    /// Map by substring.
    static func parseEngine(_ raw: String?) -> PCGamingWikiInfo.GameEngineCodable? {
        guard let raw, !raw.isEmpty else { return nil }
        let l = raw.lowercased()
        if l.contains("unreal") { return .unreal }
        if l.contains("unity")  { return .unity }
        if l.contains("source") { return .source }
        if l.contains("godot")  { return .godot }
        if l.contains("gamebryo") { return .gamebryo }
        return .custom
    }

    /// PCGW `Direct3D_versions` is a list like "11", "9.0c", "9.0 • 11", "11 • 12".
    /// Pick the most capable version present.
    static func parseDirect3D(_ raw: String?) -> PCGamingWikiInfo.GraphicsAPICodable? {
        guard let raw, !raw.isEmpty else { return nil }
        let l = raw.lowercased()
        if l.contains("12") { return .dx12 }
        if l.contains("11") || l.contains("10") { return .dx11 }
        // Any 7/8/9.x Direct3D version → DX9-class.
        if l.contains("9") || l.contains("8") || l.contains("7") { return .dx9 }
        return nil
    }

    private static func boolish(_ s: String?) -> Bool {
        (s ?? "").lowercased() == "true"
    }

    // MARK: Disk cache

    private func readCache(appID: Int) -> PCGamingWikiInfo? {
        guard let data = try? Data(contentsOf: Self.cacheURL(for: appID)) else { return nil }
        return try? JSONDecoder().decode(PCGamingWikiInfo.self, from: data)
    }

    private func writeCache(_ info: PCGamingWikiInfo, appID: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: Self.cacheURL(for: appID), options: .atomic)
        }
    }

    // MARK: API reply shapes

    private struct APIError: Decodable { let code: String }

    /// `action=parse`: `{"parse":{"wikitext":{"*":"…"}}}`, or
    /// `{"error":{"code":"missingtitle"}}` for a page that doesn't exist.
    private struct ParseReply: Decodable {
        struct Parse: Decodable { let wikitext: Wikitext }
        struct Wikitext: Decodable {
            let text: String
            enum CodingKeys: String, CodingKey { case text = "*" }
        }
        let parse: Parse?
        let error: APIError?
    }

    /// `list=search`: `{"query":{"search":[{"title":"…"}]}}`.
    private struct SearchReply: Decodable {
        struct Query: Decodable { let search: [Hit] }
        struct Hit: Decodable { let title: String }
        let query: Query?
        let error: APIError?
    }
}

enum PCGamingWikiError: LocalizedError {
    case http(Int)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .http(let status): return "HTTP \(status)"
        case .api(let code):    return "API error \(code)"
        }
    }
}

// MARK: - ResolvedGameStack (merged view used by the launcher + UI)

/// The effective tech stack for a game after merging, in priority order:
///   1. explicit `GameCompatibilityDB` profile (a hand-verified override)
///   2. PCGamingWiki tested data (for graphics API especially)
///   3. local file detection (authoritative for bitness + DRM, baseline for API)
struct ResolvedGameStack: Sendable {
    enum Source: String, Sendable { case explicit, pcgw, detected, unknown }

    var engine: GameEngine
    /// The engine as the game page names it: PCGamingWiki's name for one
    /// without a case of its own ("Divinity Engine", "MonoGame • The Forge"),
    /// otherwise `engine.displayName`.
    var engineName: String
    var graphicsAPI: GraphicsAPI
    var bitness: Int?
    var requiresSteamAPI: Bool
    var status: CompatStatus
    var hasExplicitProfile: Bool
    /// Where `graphicsAPI` came from — surfaced in logs + UI so a wrong stack
    /// is easy to attribute.
    var apiSource: Source
    var engineSource: Source

    var bitnessDescription: String {
        switch bitness {
        case 32: return "32-bit"
        case 64: return "64-bit"
        default: return "unknown"
        }
    }
}

// MARK: - GameStackResolver (orchestration + cache)

/// Merges local detection + PCGamingWiki + the explicit compat DB into a single
/// `ResolvedGameStack`, cached per app. The launcher warms the cache before a
/// launch (`resolve`), and the env builder reads it synchronously (`cached`).
@Observable
@MainActor
final class GameStackResolver {
    static let shared = GameStackResolver()
    private init() {}

    private var cache: [Int: ResolvedGameStack] = [:]

    /// Synchronous, non-blocking read for the launch env builder. Returns nil
    /// when the cache hasn't been warmed yet — callers fall back to the
    /// explicit profile / global defaults (i.e. prior behaviour).
    func cached(appID: Int) -> ResolvedGameStack? { cache[appID] }

    /// Resolves (and caches) the effective stack. Local detection runs on a
    /// background task; PCGW is fetched (cached) via its actor. Safe to call
    /// repeatedly — cheap on a cache hit.
    @discardableResult
    func resolve(appID: Int, name: String, installDir: URL?) async -> ResolvedGameStack {
        let explicit = GameCompatibilityDB.shared.profile(for: appID)

        // Local detection (off-main; small file reads).
        var detected: DetectedGameStack?
        if let installDir {
            detected = await Task.detached(priority: .utility) {
                GameStackDetector.detect(installDir: installDir)
            }.value
        }

        // PCGW enrichment (cached; nil on failure / offline).
        let pcgw = await PCGamingWikiService.shared.info(for: appID, name: name)

        let resolved = Self.merge(appID: appID, explicit: explicit, detected: detected, pcgw: pcgw)
        cache[appID] = resolved
        log.info("[resolve] appID=\(appID) engine=\(resolved.engine.rawValue)(\(resolved.engineSource.rawValue)) api=\(resolved.graphicsAPI.rawValue)(\(resolved.apiSource.rawValue)) bitness=\(resolved.bitnessDescription) drm=\(resolved.requiresSteamAPI)")
        return resolved
    }

    // MARK: Merge

    static func merge(
        appID: Int,
        explicit: GameProfile?,
        detected: DetectedGameStack?,
        pcgw: PCGamingWikiInfo?
    ) -> ResolvedGameStack {
        // Engine: explicit > detected > pcgw > detected "custom". Detection's
        // `.custom` only means "an exe no fingerprint matched", which said
        // Custom Engine for Fallout: New Vegas over PCGW's Gamebryo.
        let engine: GameEngine
        let engineSource: ResolvedGameStack.Source
        if let e = explicit?.gameEngine, e != .unknown {
            engine = e; engineSource = .explicit
        } else if let d = detected?.engine, d != .unknown, d != .custom {
            engine = d; engineSource = .detected
        } else if let p = pcgw?.resolvedEngine, p != .unknown {
            engine = p; engineSource = .pcgw
        } else if detected?.engine == .custom {
            engine = .custom; engineSource = .detected
        } else {
            engine = .unknown; engineSource = .unknown
        }
        let engineName = (engine == .custom ? pcgw?.engineRaw : nil) ?? engine.displayName

        // Graphics API: explicit > pcgw (tested) > detected (engine default).
        let api: GraphicsAPI
        let apiSource: ResolvedGameStack.Source
        if let a = explicit?.graphicsAPI, a != .unknown {
            api = a; apiSource = .explicit
        } else if let p = pcgw?.resolvedAPI, p != .unknown {
            api = p; apiSource = .pcgw
        } else if let d = detected?.graphicsAPI, d != .unknown {
            api = d; apiSource = .detected
        } else {
            api = .unknown; apiSource = .unknown
        }

        // Bitness: local PE read is authoritative for the actual build; PCGW
        // is a fallback when detection couldn't read the exe.
        let bitness = detected?.bitness ?? pcgw?.bitness

        // DRM: local file probe is authoritative (it's the installed build).
        let drm = detected?.requiresSteamAPI ?? false

        return ResolvedGameStack(
            engine: engine,
            engineName: engineName,
            graphicsAPI: api,
            bitness: bitness,
            requiresSteamAPI: drm,
            status: explicit?.status ?? .untested,
            hasExplicitProfile: explicit != nil,
            apiSource: apiSource,
            engineSource: engineSource
        )
    }
}
