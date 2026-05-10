import Foundation

private let log = MeridianLog(category: "SteamAPI")

/// Direct Steam Web API client.
///
/// All requests go to api.steampowered.com using the user's own Steam Web API key,
/// stored securely in Keychain via SteamAuthService. No Meridian backend proxy is
/// required — this is how every major Steam third-party launcher (Heroic, Lutris,
/// Playnite) works.
actor SteamAPIService {
    static let shared = SteamAPIService()
    private init() {}

    private static let baseURL = "https://api.steampowered.com"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    /// Store metadata is static for a session; cache avoids a network round-trip every time the user opens game details.
    private var appDetailsCache: [Int: AppDetails] = [:]

    // MARK: - Player

    /// Fetches the public profile for a given Steam64 ID.
    func fetchPlayerSummary(steamID: String, apiKey: String) async throws -> PlayerSummary {
        log.info("[fetchPlayerSummary] steamID=\(steamID)")
        let url = try buildURL(
            path: "/ISteamUser/GetPlayerSummaries/v2/",
            params: ["key": apiKey, "steamids": steamID]
        )
        let envelope: PlayerSummariesEnvelope = try await get(url)
        guard let player = envelope.response.players.first else {
            log.error("[fetchPlayerSummary] no player found for steamID=\(steamID)")
            throw APIError.notFound("Player \(steamID)")
        }
        log.info("[fetchPlayerSummary] found: \(player.personaName)")
        return player
    }

    // MARK: - Library

    /// Returns the full owned game list including playtime.
    func fetchOwnedGames(steamID: String, apiKey: String) async throws -> [Game] {
        log.info("[fetchOwnedGames] steamID=\(steamID)")
        let url = try buildURL(
            path: "/IPlayerService/GetOwnedGames/v1/",
            params: [
                "key": apiKey,
                "steamid": steamID,
                "include_appinfo": "1",
                "include_played_free_games": "1",
            ]
        )
        let envelope: OwnedGamesEnvelope = try await get(url)
        let games = (envelope.response.games ?? []).map { Game(from: $0) }
        log.info("[fetchOwnedGames] returned \(games.count) games")
        return games
    }

    /// Returns recently played games (last 2 weeks).
    func fetchRecentlyPlayed(steamID: String, apiKey: String, count: Int = 10) async throws -> [Game] {
        log.info("[fetchRecentlyPlayed] steamID=\(steamID) count=\(count)")
        let url = try buildURL(
            path: "/IPlayerService/GetRecentlyPlayedGames/v1/",
            params: [
                "key": apiKey,
                "steamid": steamID,
                "count": String(count),
            ]
        )
        let envelope: RecentlyPlayedEnvelope = try await get(url)
        let games = (envelope.response.games ?? []).map { Game(from: $0) }
        log.info("[fetchRecentlyPlayed] returned \(games.count) games")
        return games
    }

    // MARK: - Friends

    /// Returns the user's friend list (requires public profile).
    func fetchFriendList(steamID: String, apiKey: String) async throws -> [SteamFriend] {
        log.info("[fetchFriendList] steamID=\(steamID)")
        let url = try buildURL(
            path: "/ISteamUser/GetFriendList/v1/",
            params: [
                "key": apiKey,
                "steamid": steamID,
                "relationship": "friend",
            ]
        )
        let envelope: FriendListEnvelope = try await get(url)
        let friends = envelope.friendslist.friends
        log.info("[fetchFriendList] returned \(friends.count) friends")
        return friends
    }

    /// Batch-fetches player summaries for up to 100 Steam IDs at once.
    func fetchPlayerSummaries(steamIDs: [String], apiKey: String) async throws -> [PlayerSummary] {
        guard !steamIDs.isEmpty else { return [] }
        log.info("[fetchPlayerSummaries] fetching \(steamIDs.count) summaries")
        let url = try buildURL(
            path: "/ISteamUser/GetPlayerSummaries/v2/",
            params: ["key": apiKey, "steamids": steamIDs.joined(separator: ",")]
        )
        let envelope: PlayerSummariesEnvelope = try await get(url)
        log.info("[fetchPlayerSummaries] returned \(envelope.response.players.count) players")
        return envelope.response.players
    }

    // MARK: - App details (no key required — public Store API)

    /// Fetches store metadata for a single appID.
    func fetchAppDetails(appID: Int) async throws -> AppDetails {
        if let cached = appDetailsCache[appID] {
            log.debug("[fetchAppDetails] cache hit appID=\(appID)")
            return cached
        }
        log.info("[fetchAppDetails] appID=\(appID)")
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,categories,genres,achievements,release_date,metacritic") else {
            log.error("[fetchAppDetails] bad URL for appID=\(appID)")
            throw APIError.badURL
        }
        let raw: [String: AppDetailsWrapper] = try await get(url)
        guard let wrapper = raw[String(appID)], wrapper.success, let data = wrapper.data else {
            log.error("[fetchAppDetails] no data for appID=\(appID) (success=\(raw[String(appID)]?.success ?? false))")
            throw APIError.notFound("App \(appID)")
        }
        log.info("[fetchAppDetails] appID=\(appID) name=\(data.name ?? "unknown")")
        appDetailsCache[appID] = data
        return data
    }

    // MARK: - Achievements

    /// Fetches the current user's achievement state for a game and merges it with the
    /// game schema to produce display names and icon URLs.
    ///
    /// Returns an empty array (not an error) when the game has no achievement system,
    /// when the user's profile is private, or when the game has no stats configured.
    func fetchPlayerAchievements(steamID: String, apiKey: String, appID: Int) async throws -> [GameAchievement] {
        log.info("[fetchPlayerAchievements] appID=\(appID)")

        // ── 1. Player stats ────────────────────────────────────────────────────
        let playerURL = try buildURL(
            path: "/ISteamUserStats/GetPlayerAchievements/v1/",
            params: ["key": apiKey, "steamid": steamID, "appid": String(appID), "l": "english"]
        )
        guard let playerEnvelope: PlayerAchievementsEnvelope = try? await get(playerURL),
              playerEnvelope.playerstats.success == true,
              let rawAchievements = playerEnvelope.playerstats.achievements,
              !rawAchievements.isEmpty else {
            log.info("[fetchPlayerAchievements] appID=\(appID) no achievements or private")
            return []
        }
        log.info("[fetchPlayerAchievements] appID=\(appID) \(rawAchievements.count) achievements")

        // ── 2. Schema (icon URLs) ──────────────────────────────────────────────
        var schemaLookup: [String: SchemaAchievement] = [:]
        if let schemaURL = try? buildURL(
            path: "/ISteamUserStats/GetSchemaForGame/v2/",
            params: ["key": apiKey, "appid": String(appID), "l": "english"]
        ), let schema: SchemaEnvelope = try? await get(schemaURL) {
            for ach in schema.game.availableGameStats?.achievements ?? [] {
                schemaLookup[ach.name] = ach
            }
            log.debug("[fetchPlayerAchievements] schema loaded \(schemaLookup.count) entries for appID=\(appID)")
        }

        // ── 3. Merge ───────────────────────────────────────────────────────────
        return rawAchievements.map { raw in
            let schema = schemaLookup[raw.apiname]
            return GameAchievement(
                apiName:     raw.apiname,
                displayName: raw.name ?? schema?.displayName ?? raw.apiname,
                description: raw.description ?? schema?.description,
                achieved:    raw.achieved == 1,
                unlockDate:  raw.unlocktime > 0
                    ? Date(timeIntervalSince1970: TimeInterval(raw.unlocktime))
                    : nil,
                iconURL:     schema?.icon.flatMap { URL(string: $0) },
                iconGrayURL: schema?.icongray.flatMap { URL(string: $0) },
                isHidden:    schema?.hidden == 1
            )
        }
    }

    // MARK: - Logo hash probe via appdetails (new Steam CDN fallback)

    /// Attempts to discover a logo hash for a game using the public appdetails API.
    /// For new-CDN games, appdetails returns asset URLs containing per-asset SHA-1 hashes.
    /// We extract every 40-char hex hash from those URLs and try each one with logo_2x.png
    /// to find the one that resolves — without needing IStoreBrowseService to expose it.
    func probeLogoHash(appID: Int) async -> String? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,header_image,capsule_image,screenshots") else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let jsonStr = String(data: data, encoding: .utf8) else { return nil }

        // Extract all 40-char hex strings from the JSON — these are asset content hashes.
        // We then probe logo_2x.png at each one; the correct hash will return HTTP 200.
        var candidateHashes: [String] = []
        let chars = Array(jsonStr)
        var i = 0
        while i < chars.count - 40 {
            let slice = String(chars[i..<i+40])
            if slice.allSatisfy(\.isHexDigit) {
                candidateHashes.append(slice)
                i += 40
            } else {
                i += 1
            }
        }
        let uniqueHashes = Array(NSOrderedSet(array: candidateHashes)) as? [String] ?? candidateHashes

        log.info("[probeLogoHash] appID=\(appID) probing \(uniqueHashes.count) candidate hashes")

        let cdns = ["https://shared.fastly.steamstatic.com", "https://shared.akamai.steamstatic.com"]
        // Try logo_2x.png first (confirmed naming for newer games), then logo.png fallback.
        let filenames = ["logo_2x.png", "logo.png"]
        for hash in uniqueHashes {
            for cdn in cdns {
                for filename in filenames {
                    let probeURLStr = "\(cdn)/store_item_assets/steam/apps/\(appID)/\(hash)/\(filename)"
                    guard let probeURL = URL(string: probeURLStr) else { continue }
                    var req = URLRequest(url: probeURL)
                    req.httpMethod = "HEAD"
                    if let (_, resp) = try? await session.data(for: req),
                       let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                        log.info("[probeLogoHash] appID=\(appID) found hash=\(hash.prefix(8))… via \(filename)")
                        return hash
                    }
                }
            }
        }
        log.warning("[probeLogoHash] appID=\(appID) no logo hash found from \(uniqueHashes.count) candidates")
        return nil
    }

    // MARK: - Capsule hash probe via appdetails (new Steam CDN fallback)

    /// Attempts to discover a 600×900 library capsule hash for a game using the public
    /// appdetails API. Works identically to `probeLogoHash` but probes for
    /// library_600x900.jpg / library_600x900_2x.jpg instead of the logo.
    /// Used as a last-resort fallback for recently-played games that pass 1 & 2 missed.
    func probeCapsuleHash(appID: Int) async -> String? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,header_image,capsule_image,screenshots") else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let jsonStr = String(data: data, encoding: .utf8) else { return nil }

        var candidateHashes: [String] = []
        let chars = Array(jsonStr)
        var i = 0
        while i < chars.count - 40 {
            let slice = String(chars[i..<i+40])
            if slice.allSatisfy(\.isHexDigit) {
                candidateHashes.append(slice)
                i += 40
            } else {
                i += 1
            }
        }
        let uniqueHashes = Array(NSOrderedSet(array: candidateHashes)) as? [String] ?? candidateHashes

        log.info("[probeCapsuleHash] appID=\(appID) probing \(uniqueHashes.count) candidate hashes")

        let cdns = ["https://shared.fastly.steamstatic.com", "https://shared.akamai.steamstatic.com"]
        let filenames = ["library_600x900.jpg", "library_600x900_2x.jpg", "library_capsule_2x.jpg", "library_capsule.jpg"]
        for hash in uniqueHashes {
            for cdn in cdns {
                for filename in filenames {
                    let probeURLStr = "\(cdn)/store_item_assets/steam/apps/\(appID)/\(hash)/\(filename)"
                    guard let probeURL = URL(string: probeURLStr) else { continue }
                    var req = URLRequest(url: probeURL)
                    req.httpMethod = "HEAD"
                    if let (_, resp) = try? await session.data(for: req),
                       let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                        log.info("[probeCapsuleHash] appID=\(appID) found hash=\(hash.prefix(8))… via \(filename)")
                        return hash
                    }
                }
            }
        }
        log.warning("[probeCapsuleHash] appID=\(appID) no capsule hash found from \(uniqueHashes.count) candidates")
        return nil
    }

    // MARK: - Library capsule art hashes (new Steam CDN)

    /// Batch-fetches library capsule content hashes for the given app IDs via
    /// IStoreBrowseService/GetItems/v1. Returns a dictionary of appID → SHA-1 hash.
    ///
    /// Newer Steam titles (post ~2024) host portrait art exclusively on a new CDN:
    ///   shared.*.steamstatic.com/store_item_assets/steam/apps/{id}/{hash}/library_600x900.jpg
    ///
    /// The hash is not returned by GetOwnedGames; this endpoint is the reliable way
    /// to retrieve it. Up to 50 app IDs can be requested in a single call.
    func fetchLibraryCapsuleHashes(appIDs: [Int], apiKey: String) async -> [Int: GameCDNHashes] {
        guard !appIDs.isEmpty else { return [:] }
        log.info("[fetchLibraryCapsuleHashes] fetching \(appIDs.count) IDs")

        // Build the protobuf-compatible JSON input for IStoreBrowseService/GetItems/v1
        struct AppIDRef: Encodable { let appid: Int }
        struct Context: Encodable {
            let language: String
            let country_code: String
            let steam_realm: Int
        }
        struct DataRequest: Encodable {
            let include_assets: Bool
            // Forces return of ALL asset variants, including the logo/hero logo
            // which is sometimes omitted when include_assets alone is used.
            let include_assets_without_overrides: Bool
        }
        struct BrowseInput: Encodable {
            let ids: [AppIDRef]
            let context: Context
            let data_request: DataRequest
        }

        let input = BrowseInput(
            ids: appIDs.map { AppIDRef(appid: $0) },
            context: Context(language: "english", country_code: "US", steam_realm: 1),
            data_request: DataRequest(include_assets: true, include_assets_without_overrides: true)
        )
        guard let inputData = try? JSONEncoder().encode(input),
              let inputString = String(data: inputData, encoding: .utf8) else {
            log.error("[fetchLibraryCapsuleHashes] failed to encode input")
            return [:]
        }
        guard let url = try? buildURL(
            path: "/IStoreBrowseService/GetItems/v1/",
            params: ["key": apiKey, "input_json": inputString]
        ) else {
            log.error("[fetchLibraryCapsuleHashes] failed to build URL")
            return [:]
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.warning("[fetchLibraryCapsuleHashes] non-2xx response")
                return [:]
            }
            // Log full response and highlight any logo-related context
            if let fullStr = String(data: data, encoding: .utf8) {
                log.debug("[fetchLibraryCapsuleHashes] response \(fullStr.count) chars")
                var searchFrom = fullStr.startIndex
                while let r = fullStr.range(of: "logo", options: .caseInsensitive, range: searchFrom..<fullStr.endIndex) {
                    let s = fullStr.index(r.lowerBound, offsetBy: -80, limitedBy: fullStr.startIndex) ?? fullStr.startIndex
                    let e = fullStr.index(r.upperBound, offsetBy: 160, limitedBy: fullStr.endIndex) ?? fullStr.endIndex
                    log.debug("[fetchLibraryCapsuleHashes] LOGO: ...\(String(fullStr[s..<e]))...")
                    searchFrom = r.upperBound
                    if searchFrom >= fullStr.endIndex { break }
                }
            }

            var result: [Int: GameCDNHashes] = [:]

            // Strategy 1: typed decode against known field names.
            if let decoded = try? JSONDecoder().decode(StoreBrowseResponse.self, from: data) {
                for item in decoded.response?.storeItems ?? [] {
                    guard let appID = item.appid ?? item.id else { continue }
                    let ch = item.assets?.libraryCapsuleHash
                    // Logo hash is often only in assets_without_overrides (locale-specific).
                    let lh = item.assets?.libraryCapsuleLogoHash
                              ?? item.assetsWithoutOverrides?.libraryCapsuleLogoHash
                    let hh = item.assets?.libraryHeroHash
                              ?? item.assetsWithoutOverrides?.libraryHeroHash
                    if ch != nil || lh != nil || hh != nil {
                        result[appID] = GameCDNHashes(capsuleHash: ch, logoHash: lh, heroHash: hh)
                        log.debug("[fetchLibraryCapsuleHashes] S1 appID=\(appID) capsule=\(ch?.prefix(8) ?? "-") logo=\(lh?.prefix(8) ?? "-") hero=\(hh?.prefix(8) ?? "-")")
                    }
                }
            }

            // Strategy 2: raw JSON scan — fills in any missing items AND supplements
            // games that Strategy 1 found a capsule hash for but missed a logo or hero hash.
            let rawHashes = extractHashesFromRaw(data)
            for (appID, hashes) in rawHashes {
                if result[appID] == nil {
                    result[appID] = hashes
                    log.debug("[fetchLibraryCapsuleHashes] S2 appID=\(appID) capsule=\(hashes.capsuleHash?.prefix(8) ?? "-") logo=\(hashes.logoHash?.prefix(8) ?? "-") hero=\(hashes.heroHash?.prefix(8) ?? "-")")
                } else {
                    let existing = result[appID]!
                    let newLogo = existing.logoHash == nil ? hashes.logoHash : existing.logoHash
                    let newHero = existing.heroHash == nil ? hashes.heroHash : existing.heroHash
                    if newLogo != existing.logoHash || newHero != existing.heroHash {
                        result[appID] = GameCDNHashes(
                            capsuleHash: existing.capsuleHash,
                            logoHash: newLogo,
                            heroHash: newHero
                        )
                        if newLogo != existing.logoHash {
                            log.debug("[fetchLibraryCapsuleHashes] S2 supplement logo appID=\(appID) logo=\(newLogo?.prefix(8) ?? "-")")
                        }
                        if newHero != existing.heroHash {
                            log.debug("[fetchLibraryCapsuleHashes] S2 supplement hero appID=\(appID) hero=\(newHero?.prefix(8) ?? "-")")
                        }
                    }
                }
            }

            log.info("[fetchLibraryCapsuleHashes] resolved \(result.count)/\(appIDs.count)")
            return result
        } catch {
            log.error("[fetchLibraryCapsuleHashes] \(error.localizedDescription)")
            return [:]
        }
    }

    /// Parses the raw `IStoreBrowseService/GetItems` JSON without relying on
    /// specific field names. Searches each item's assets for library capsule and
    /// logo hashes using filename patterns, making it robust to field renames.
    private func extractHashesFromRaw(_ data: Data) -> [Int: GameCDNHashes] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp  = json["response"] as? [String: Any],
              let items = resp["store_items"] as? [[String: Any]] else { return [:] }

        // Log the first item's raw shape on every call to make API format changes visible.
        if let firstItem = items.first {
            let keys = firstItem.keys.sorted().joined(separator: ", ")
            log.debug("[extractHashesFromRaw] first item keys: [\(keys)]")
            if let assets = firstItem["assets"] as? [String: Any] {
                let assetKeys = assets.keys.sorted().joined(separator: ", ")
                log.debug("[extractHashesFromRaw] first item assets keys: [\(assetKeys)]")
                for (k, v) in assets {
                    if let str = v as? String { log.debug("[extractHashesFromRaw]   assets.\(k)=\(str)") }
                }
            }
            // Also log assets_without_overrides so we can verify logo hashes appear here.
            if let awos = firstItem["assets_without_overrides"] as? [String: Any] {
                let awoKeys = awos.keys.sorted().joined(separator: ", ")
                log.debug("[extractHashesFromRaw] first item assets_without_overrides keys: [\(awoKeys)]")
                for (k, v) in awos {
                    if let str = v as? String {
                        log.debug("[extractHashesFromRaw]   assets_without_overrides.\(k)=\(str)")
                    } else if let nested = v as? [String: Any] {
                        for (nk, nv) in nested {
                            if let str = nv as? String {
                                log.debug("[extractHashesFromRaw]   assets_without_overrides.\(k).\(nk)=\(str)")
                            }
                        }
                    }
                }
            }

        var out: [Int: GameCDNHashes] = [:]
        for item in items {
            // Steam may return appid/id as Int or as a JSON string; try both.
            let appID: Int? = (item["appid"] as? Int)
                ?? (item["id"] as? Int)
                ?? (item["appid"] as? String).flatMap(Int.init)
                ?? (item["id"] as? String).flatMap(Int.init)
            guard let appID else { continue }

            // Merge assets + assets_without_overrides into one search target.
            // Logo hashes (image/english, image2x/english in SteamDB notation)
            // appear in assets_without_overrides, not in assets. We request
            // include_assets_without_overrides:true but previously only searched
            // assets, silently missing every logo hash on the new CDN.
            var mergedTarget: [String: Any] = [:]
            if let a  = item["assets"]                   as? [String: Any] { mergedTarget.merge(a,  uniquingKeysWith: { l, _ in l }) }
            if let ao = item["assets_without_overrides"]  as? [String: Any] { mergedTarget.merge(ao, uniquingKeysWith: { l, _ in l }) }
            let target: Any = mergedTarget.isEmpty ? item : mergedTarget
            // Eagerly compute all naming variants before combining with ??
            // so `target` (non-Sendable Any) is not captured lazily across the operator.
            let ch600 = searchForHash(matching: "library_600x900", in: target)
            let chCap = searchForHash(matching: "library_capsule", in: target)
            let ch = ch600 ?? chCap
            let lh = searchForHash(matching: "logo", in: target)
            let hh = searchForHash(matching: "library_hero", in: target)
            if ch != nil || lh != nil || hh != nil {
                out[appID] = GameCDNHashes(capsuleHash: ch, logoHash: lh, heroHash: hh)
            }
        }
        return out
    }

    /// Recursively searches a JSON value for a string where a 40-char hex path
    /// segment is followed by the given filename prefix.
    private func searchForHash(matching filename: String, in value: Any) -> String? {
        if let str = value as? String {
            let parts = str.components(separatedBy: "/")
            for (i, part) in parts.enumerated() {
                guard part.count == 40, part.allSatisfy(\.isHexDigit) else { continue }
                if i + 1 < parts.count, parts[i + 1].hasPrefix(filename) {
                    return part
                }
            }
        } else if let dict = value as? [String: Any] {
            for (_, nested) in dict {
                if let hash = searchForHash(matching: filename, in: nested) { return hash }
            }
        } else if let arr = value as? [Any] {
            // Arrays were previously skipped — the logo may live inside a nested array.
            for nested in arr {
                if let hash = searchForHash(matching: filename, in: nested) { return hash }
            }
        }
        return nil
    }

    // MARK: - Private

    private func buildURL(path: String, params: [String: String]) throws -> URL {
        guard var components = URLComponents(string: "\(Self.baseURL)\(path)") else {
            throw APIError.badURL
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.badURL }
        return url
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        log.debug("[get] \(url.path())")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            log.error("[get] non-HTTP response for \(url.path())")
            throw APIError.badResponse
        }
        log.debug("[get] HTTP \(http.statusCode) | \(data.count) bytes | \(url.path())")
        guard (200..<300).contains(http.statusCode) else {
            log.error("[get] HTTP \(http.statusCode) for \(url.path())")
            throw APIError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("[get] decode failed for \(url.path()): \(error.localizedDescription)")
            log.debug("[get] raw response: \(String(data: data.prefix(1000), encoding: .utf8) ?? "<binary>")")
            throw error
        }
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case badURL
        case badResponse
        case httpError(Int)
        case notFound(String)
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .badURL:              return "Invalid request URL."
            case .badResponse:         return "Invalid server response."
            case .httpError(let c):    return "HTTP error \(c)."
            case .notFound(let s):     return "\(s) not found."
            case .missingAPIKey:       return "Steam Web API key not set. Add it in Settings."
            }
        }
    }
}

// MARK: - Response envelopes (Steam API shapes)

private struct PlayerSummariesEnvelope: Decodable {
    struct Response: Decodable {
        let players: [PlayerSummary]
    }
    let response: Response
}

private struct FriendListEnvelope: Decodable {
    struct FriendsList: Decodable {
        let friends: [SteamFriend]
    }
    let friendslist: FriendsList
}

private struct OwnedGamesEnvelope: Decodable {
    struct Response: Decodable {
        let games: [RawGame]?
    }
    let response: Response
}

private struct RecentlyPlayedEnvelope: Decodable {
    struct Response: Decodable {
        let games: [RawGame]?
    }
    let response: Response
}

private struct AppDetailsWrapper: Decodable {
    let success: Bool
    let data: AppDetails?
}

// MARK: - IStoreBrowseService/GetItems response types

private struct StoreBrowseResponse: Decodable {
    let response: ResponseBody?
    struct ResponseBody: Decodable {
        let storeItems: [StoreBrowseItem]?
        enum CodingKeys: String, CodingKey { case storeItems = "store_items" }
    }
}

private struct StoreBrowseItem: Decodable {
    /// Some API versions return "id", others "appid".
    let id: Int?
    let appid: Int?
    let assets: StoreBrowseAssets?
    /// Per-locale unoverridden assets — logo hashes live here for many games.
    let assetsWithoutOverrides: StoreBrowseAssets?
    enum CodingKeys: String, CodingKey {
        case id, appid, assets
        case assetsWithoutOverrides = "assets_without_overrides"
    }
}

/// Art hashes returned by `fetchLibraryCapsuleHashes` for a single game.
/// Both fields are optional because not every game has every asset type.
struct GameCDNHashes {
    let capsuleHash: String?
    let logoHash: String?
    let heroHash: String?
}

private struct StoreBrowseAssets: Decodable {
    /// URL template: "https://shared.*.steamstatic.com/.../apps/{appid}/{FILENAME}?t=…"
    let assetUrlFormat: String?
    /// "{40hexchars}/library_600x900.jpg" — primary field for library portrait.
    let mainCapsule: String?
    /// Alternative field name used in some API versions.
    let libraryCapsule: String?
    let libraryCapsule2x: String?
    /// Hero banner art (1920×620).
    let libraryHero: String?
    let libraryHero2x: String?
    /// "{40hexchars}/logo.png" — logo lockup overlaid on the hero image.
    /// Steam uses several different field names across API versions.
    let libraryHeroLogo: String?
    let logo: String?
    let heroLogo: String?
    let libraryLogo: String?
    let logoSmall: String?
    /// SteamDB shows the logo under "image2x/english" which serialises as logo_2x in JSON.
    let logo2x: String?
    let libraryHeroLogo2x: String?

    enum CodingKeys: String, CodingKey {
        case assetUrlFormat    = "asset_url_format"
        case mainCapsule       = "main_capsule"
        case libraryCapsule    = "library_capsule"
        case libraryCapsule2x  = "library_capsule_2x"
        case libraryHero       = "library_hero"
        case libraryHero2x     = "library_hero_2x"
        case libraryHeroLogo   = "library_hero_logo"
        case logo
        case heroLogo          = "hero_logo"
        case libraryLogo       = "library_logo"
        case logoSmall         = "logo_small"
        case logo2x            = "logo_2x"
        case libraryHeroLogo2x = "library_hero_logo_2x"
    }

    /// Extracts the 40-char SHA-1 content hash from any library capsule field.
    var libraryCapsuleHash: String? {
        for candidate in [libraryCapsule, mainCapsule, libraryCapsule2x].compactMap({ $0 }) {
            if let hash = extractHash(from: candidate) { return hash }
        }
        return nil
    }

    /// Extracts the 40-char SHA-1 content hash from any logo field.
    /// Peak (3527290) confirmed: the logo lives at logo_2x.png under hash 7df31d9d…
    var libraryCapsuleLogoHash: String? {
        for candidate in [libraryHeroLogo, logo, logo2x, heroLogo, libraryLogo,
                          logoSmall, libraryHeroLogo2x].compactMap({ $0 }) {
            if let hash = extractHash(from: candidate) { return hash }
        }
        return nil
    }

    /// Extracts the 40-char SHA-1 content hash from the hero banner fields.
    var libraryHeroHash: String? {
        for candidate in [libraryHero, libraryHero2x].compactMap({ $0 }) {
            if let hash = extractHash(from: candidate) { return hash }
        }
        return nil
    }

    /// Scans ALL path components for a 40-char lowercase hex SHA-1 content hash.
    ///
    /// Steam's new CDN returns asset paths in the form:
    ///   store_item_assets/steam/apps/{appid}/{HASH}/library_600x900.jpg
    /// The hash is a middle component — checking only `parts.first` always fails
    /// for any path that includes a prefix before the hash segment.
    private func extractHash(from path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        for part in parts {
            if part.count == 40, part.allSatisfy(\.isHexDigit) {
                return part
            }
        }
        return nil
    }
}

// MARK: - Achievement response types

private struct PlayerAchievementsEnvelope: Decodable {
    let playerstats: PlayerStats

    struct PlayerStats: Decodable {
        let success: Bool?
        let achievements: [RawPlayerAchievement]?
    }
}

private struct RawPlayerAchievement: Decodable {
    let apiname: String
    let achieved: Int
    let unlocktime: Int
    let name: String?
    let description: String?
}

private struct SchemaEnvelope: Decodable {
    let game: SchemaGame

    struct SchemaGame: Decodable {
        let availableGameStats: SchemaStats?
        enum CodingKeys: String, CodingKey {
            case availableGameStats = "availableGameStats"
        }
    }
}

private struct SchemaStats: Decodable {
    let achievements: [SchemaAchievement]?
}

private struct SchemaAchievement: Decodable {
    let name: String
    let displayName: String?
    let hidden: Int?
    let description: String?
    let icon: String?
    let icongray: String?
}

// MARK: -

// Raw game shape returned by GetOwnedGames / GetRecentlyPlayedGames
struct RawGame: Decodable {
    let appid: Int
    let name: String?
    let playtimeForever: Int?
    let playtime2Weeks: Int?
    let rtimeLastPlayed: Int?
    let imgIconURL: String?
    let imgLogoURL: String?
    let hasCommunityVisibleStats: Bool?

    enum CodingKeys: String, CodingKey {
        case appid
        case name
        case playtimeForever          = "playtime_forever"
        case playtime2Weeks           = "playtime_2weeks"
        case rtimeLastPlayed          = "rtime_last_played"
        case imgIconURL               = "img_icon_url"
        case imgLogoURL               = "img_logo_url"
        case hasCommunityVisibleStats = "has_community_visible_stats"
    }
}
