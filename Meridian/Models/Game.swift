import Foundation

/// A game in the user's Steam library.
struct Game: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let playtimeMinutes: Int
    let playtime2WeekMinutes: Int?
    let lastPlayedDate: Date?
    let iconHash: String?
    var isInstalled: Bool = false
    var windowsOnly: Bool = false

    // MARK: - Computed URLs

    var iconURL: URL? {
        guard let hash = iconHash, !hash.isEmpty else { return nil }
        return URL(string: "https://media.steampowered.com/steamcommunity/public/images/apps/\(id)/\(hash).jpg")
    }

    var capsuleURL: URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg")!
    }

    var heroURL: URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_hero.jpg")!
    }

    /// Fallback CDN URLs tried in order when the primary Akamai URL fails or returns non-200.
    var capsuleURLFallbacks: [URL] {
        [
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/header.jpg"),
            URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/header.jpg"),
            // Some games don't have header.jpg — try the wider capsule format
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/capsule_616x353.jpg"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/capsule_616x353.jpg"),
        ].compactMap { $0 }
    }

    var heroURLFallbacks: [URL] {
        [
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_hero.jpg"),
            URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/library_hero.jpg"),
            // If no hero, fall through to capsule as a last resort
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/header.jpg"),
        ].compactMap { $0 }
    }

    var playtimeFormatted: String {
        let hours = playtimeMinutes / 60
        if hours == 0 { return "< 1 hr" }
        return "\(hours) hr\(hours == 1 ? "" : "s")"
    }

    var lastPlayedFormatted: String? {
        guard let date = lastPlayedDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - Init from raw API response

    init(from raw: RawGame) {
        id                   = raw.appid
        name                 = raw.name ?? "App \(raw.appid)"
        playtimeMinutes      = raw.playtimeForever ?? 0
        playtime2WeekMinutes = raw.playtime2Weeks
        iconHash             = raw.imgIconURL

        if let ts = raw.rtimeLastPlayed, ts > 0 {
            lastPlayedDate = Date(timeIntervalSince1970: TimeInterval(ts))
        } else {
            lastPlayedDate = nil
        }
    }

    init(
        id: Int,
        name: String,
        playtimeMinutes: Int = 0,
        playtime2WeekMinutes: Int? = nil,
        lastPlayedDate: Date? = nil,
        iconHash: String? = nil,
        isInstalled: Bool = false,
        windowsOnly: Bool = false
    ) {
        self.id                   = id
        self.name                 = name
        self.playtimeMinutes      = playtimeMinutes
        self.playtime2WeekMinutes = playtime2WeekMinutes
        self.lastPlayedDate       = lastPlayedDate
        self.iconHash             = iconHash
        self.isInstalled          = isInstalled
        self.windowsOnly          = windowsOnly
    }
}

// MARK: - Preview data

extension Game {
    static let previews: [Game] = [
        Game(id: 570,     name: "Dota 2",                    playtimeMinutes: 7200,  windowsOnly: false),
        Game(id: 730,     name: "Counter-Strike 2",          playtimeMinutes: 3600,  windowsOnly: false),
        Game(id: 1091500, name: "Cyberpunk 2077",            playtimeMinutes: 1800,  windowsOnly: true),
        Game(id: 1174180, name: "Red Dead Redemption 2",     playtimeMinutes: 4200,  windowsOnly: true),
        Game(id: 892970,  name: "Valheim",                   playtimeMinutes: 960,   windowsOnly: false),
        Game(id: 1245620, name: "ELDEN RING",                playtimeMinutes: 600,   windowsOnly: true),
    ]
}
