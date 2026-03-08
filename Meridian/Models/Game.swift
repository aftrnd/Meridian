import Foundation

/// A game in the user's Steam library.
struct Game: Identifiable, Hashable, Sendable {
    let id: Int                    // appID
    let name: String
    let playtimeMinutes: Int
    let playtime2WeekMinutes: Int?
    let iconHash: String?          // used to construct icon URL
    var isInstalled: Bool = false
    var requiresProton: Bool = false  // true = Windows-only title

    // MARK: - Computed URLs

    /// Small grid icon (32×32)
    var iconURL: URL? {
        guard let hash = iconHash, !hash.isEmpty else { return nil }
        return URL(string: "https://media.steampowered.com/steamcommunity/public/images/apps/\(id)/\(hash).jpg")
    }

    /// 460×215 library capsule art
    var capsuleURL: URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg")!
    }

    /// Full-size library hero art (optional, may 404 on older titles)
    var heroURL: URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_hero.jpg")!
    }

    /// Formatted playtime string, e.g. "127 hrs"
    var playtimeFormatted: String {
        let hours = playtimeMinutes / 60
        if hours == 0 { return "< 1 hr" }
        return "\(hours) hr\(hours == 1 ? "" : "s")"
    }

    // MARK: - Init from raw API response

    init(from raw: RawGame) {
        id                   = raw.appid
        name                 = raw.name ?? "App \(raw.appid)"
        playtimeMinutes      = raw.playtimeForever ?? 0
        playtime2WeekMinutes = raw.playtime2Weeks
        iconHash             = raw.imgIconURL
    }

    // MARK: - Manual init (for previews / tests)

    init(
        id: Int,
        name: String,
        playtimeMinutes: Int = 0,
        playtime2WeekMinutes: Int? = nil,
        iconHash: String? = nil,
        isInstalled: Bool = false,
        requiresProton: Bool = false
    ) {
        self.id                   = id
        self.name                 = name
        self.playtimeMinutes      = playtimeMinutes
        self.playtime2WeekMinutes = playtime2WeekMinutes
        self.iconHash             = iconHash
        self.isInstalled          = isInstalled
        self.requiresProton       = requiresProton
    }
}

// MARK: - Preview data

extension Game {
    static let previews: [Game] = [
        Game(id: 570,    name: "Dota 2",              playtimeMinutes: 7200,  requiresProton: false),
        Game(id: 730,    name: "Counter-Strike 2",    playtimeMinutes: 3600,  requiresProton: false),
        Game(id: 1091500, name: "Cyberpunk 2077",     playtimeMinutes: 1800,  requiresProton: true),
        Game(id: 1174180, name: "Red Dead Redemption 2", playtimeMinutes: 4200, requiresProton: true),
        Game(id: 892970, name: "Valheim",              playtimeMinutes: 960,   requiresProton: false),
        Game(id: 1245620, name: "ELDEN RING",          playtimeMinutes: 600,   requiresProton: true),
    ]
}
