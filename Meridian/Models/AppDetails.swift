import Foundation

/// Store data returned by the Steam Store API (no API key required).
struct AppDetails: Decodable, Sendable {
    let steamAppID: Int?
    let name: String?
    let shortDescription: String?
    let type: String?         // "game", "dlc", "demo", etc.
    let isFree: Bool?
    let developers: [String]?
    let publishers: [String]?
    let platforms: Platforms?
    let genres: [Genre]?
    let categories: [Category]?
    let releaseDate: ReleaseDate?
    let metacritic: Metacritic?
    /// Total achievement count for this game, from the store page.
    let achievementsSummary: AchievementsSummary?

    struct Platforms: Decodable, Sendable {
        let windows: Bool?
        let mac: Bool?
        let linux: Bool?
    }

    struct Genre: Decodable, Sendable {
        let id: String?
        let description: String?
    }

    struct Category: Decodable, Sendable {
        let id: Int?
        let description: String?
    }

    enum ControllerSupport { case full, partial }

    struct ReleaseDate: Decodable, Sendable {
        let comingSoon: Bool?
        /// Human-readable string returned by Steam, e.g. "12 Nov, 2011".
        let date: String?
        enum CodingKeys: String, CodingKey {
            case comingSoon = "coming_soon"
            case date
        }
    }

    struct Metacritic: Decodable, Sendable {
        let score: Int?
        let url: String?
    }

    struct AchievementsSummary: Decodable, Sendable {
        let total: Int?
    }

    enum CodingKeys: String, CodingKey {
        case steamAppID           = "steam_appid"
        case name
        case shortDescription     = "short_description"
        case type
        case isFree               = "is_free"
        case developers
        case publishers
        case platforms
        case genres
        case categories
        case releaseDate          = "release_date"
        case metacritic
        case achievementsSummary  = "achievements"
    }

    /// Store categories 28 "Full controller support" and 18 "Partial
    /// Controller Support": the same ids as Steam's app info `category_28` /
    /// `category_18` (checked against both, Oct 22 2026).
    var controllerSupport: ControllerSupport? {
        let ids = categories?.compactMap(\.id) ?? []
        if ids.contains(28) { return .full }
        if ids.contains(18) { return .partial }
        return nil
    }

    /// Store category 23 "Steam Cloud" (Noita's appdetails, Oct 22 2026).
    var supportsSteamCloud: Bool {
        categories?.contains { $0.id == 23 } == true
    }

    var isWindowsOnly: Bool {
        guard let p = platforms else { return false }
        return (p.windows == true) && (p.mac != true) && (p.linux != true)
    }
}
