import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "SteamAPI")

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
        log.info("[fetchAppDetails] appID=\(appID)")
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,categories,genres") else {
            log.error("[fetchAppDetails] bad URL for appID=\(appID)")
            throw APIError.badURL
        }
        let raw: [String: AppDetailsWrapper] = try await get(url)
        guard let wrapper = raw[String(appID)], wrapper.success, let data = wrapper.data else {
            log.error("[fetchAppDetails] no data for appID=\(appID) (success=\(raw[String(appID)]?.success ?? false))")
            throw APIError.notFound("App \(appID)")
        }
        log.info("[fetchAppDetails] appID=\(appID) name=\(data.name ?? "unknown")")
        return data
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
