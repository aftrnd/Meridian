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

    struct Platforms: Decodable, Sendable {
        let windows: Bool?
        let mac: Bool?
        let linux: Bool?
    }

    struct Genre: Decodable, Sendable {
        let id: String?
        let description: String?
    }

    enum CodingKeys: String, CodingKey {
        case steamAppID      = "steam_appid"
        case name
        case shortDescription = "short_description"
        case type
        case isFree          = "is_free"
        case developers
        case publishers
        case platforms
        case genres
    }

    var isWindowsOnly: Bool {
        guard let p = platforms else { return false }
        return (p.windows == true) && (p.mac != true) && (p.linux != true)
    }
}
