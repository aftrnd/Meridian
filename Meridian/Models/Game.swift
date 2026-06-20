import Foundation

/// Steam's intended logo placement over the hero banner, from PICS appinfo
/// `library_logo.logo_position`. Pure data — the View layer maps `pinned` to a
/// SwiftUI alignment. Percentages are 0–100 of the hero box.
struct LogoPlacement: Hashable, Sendable {
    /// "BottomLeft", "CenterCenter", "UpperLeft", "BottomCenter", "UpperCenter".
    let pinned: String
    let widthPct: Double
    let heightPct: Double
}

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
    /// SHA-1 content hash for the library capsule art on Steam's new CDN.
    /// Populated in the background by SteamLibraryStore after library refresh.
    /// When set, newCDNCapsuleURLs returns valid URLs for the new CDN format
    /// used by games published after ~2024 that have no art on the legacy CDN.
    var libraryCapsuleHash: String? = nil
    /// SHA-1 content hash for logo.png on Steam's new CDN.
    /// Populated alongside libraryCapsuleHash by the background art-hash fetch.
    var logoHash: String? = nil
    /// SHA-1 content hash for library_hero.jpg on Steam's new CDN.
    /// Populated alongside libraryCapsuleHash by the background art-hash fetch.
    var heroHash: String? = nil

    // MARK: - Logo placement (Steam's library layout)

    /// Steam's intended logo placement over the hero, from PICS appinfo
    /// `common.library_assets_full.library_logo.logo_position`. Populated by the
    /// `-appinfo` resolver. Used ONLY by the game detail hero to reproduce
    /// Steam's own logo positioning; the Home carousel ignores these.
    ///
    /// `logoPinned` is the anchor corner ("BottomLeft", "CenterCenter",
    /// "UpperLeft", "BottomCenter", "UpperCenter"). `logoWidthPct`/`logoHeightPct`
    /// are the logo box size as a percentage (0–100) of the hero.
    var logoPinned: String? = nil
    var logoWidthPct: Double? = nil
    var logoHeightPct: Double? = nil

    // MARK: - Effective hashes (override registry takes priority)

    /// The logo hash to use for CDN URL construction.
    /// Returns the manually curated override hash if one exists, otherwise falls
    /// back to the hash populated by the background fetch.
    var effectiveLogoHash: String? {
        GameArtOverrides.logoHash(for: id) ?? logoHash
    }

    /// The 600×900 capsule hash to use for CDN URL construction.
    /// Returns the manually curated override hash if one exists, otherwise falls
    /// back to the hash populated by the background fetch.
    var effectiveCapsuleHash: String? {
        GameArtOverrides.capsuleHash(for: id) ?? libraryCapsuleHash
    }

    /// The library_hero hash to use for CDN URL construction.
    /// Returns the manually curated override hash if one exists, otherwise falls
    /// back to the hash populated by the background fetch.
    var effectiveHeroHash: String? {
        GameArtOverrides.heroHash(for: id) ?? heroHash
    }

    // MARK: - Effective logo placement (override registry takes priority)

    /// Resolved logo placement for the game-detail hero, preferring a manual
    /// override, then the appinfo-fetched values. Returns `nil` when no placement
    /// data is available (caller falls back to the default leading layout).
    var effectiveLogoPlacement: LogoPlacement? {
        if let o = GameArtOverrides.logoPlacement(for: id) { return o }
        guard let pinned = logoPinned, let w = logoWidthPct, let h = logoHeightPct,
              w > 0, h > 0 else { return nil }
        return LogoPlacement(pinned: pinned, widthPct: w, heightPct: h)
    }

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

    /// Game logo PNG (transparent background) used by Steam's library hero overlay.
    /// Not all games have this asset; callers should fall back to plain text on failure.
    /// Primary logo URL — tries logo_2x.png first since many newer Steam titles
    /// only publish the 2x variant. Falls through to logoURLFallbacks on failure.
    var logoURL: URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/logo_2x.png")!
    }

    var logoURLFallbacks: [URL] {
        [
            // logo_2x.png across all CDN mirrors
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/logo_2x.png"),
            URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/logo_2x.png"),
            // Standard logo.png (may be all that exists on some older titles)
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/logo.png"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/logo.png"),
            URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/logo.png"),
        ].compactMap { $0 }
    }

    /// New hash-based CDN URLs for logo.png — required for games published after ~2024.
    /// Prefers the manual override hash from GameArtOverrides, then the auto-fetched hash.
    /// The logo hash comes from assets_without_overrides in IStoreBrowseService (not from
    /// appdetails, and independent from the capsule/hero hashes — each is content-addressed).
    var newCDNLogoURLs: [URL] {
        guard let hash = effectiveLogoHash, !hash.isEmpty else { return [] }
        return [
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/logo_2x.png"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/logo_2x.png"),
            URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/logo_2x.png"),
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/logo.png"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/logo.png"),
            URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/logo.png"),
        ].compactMap { $0 }
    }

    /// New hash-based CDN URLs for the library hero banner — required for games
    /// published after ~2024 that host hero art exclusively on the new CDN.
    /// Prefers the manual override hash from GameArtOverrides, then the auto-fetched hash.
    var newCDNHeroURLs: [URL] {
        guard let hash = effectiveHeroHash, !hash.isEmpty else { return [] }
        return [
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_hero.jpg"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_hero.jpg"),
            URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_hero.jpg"),
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_hero_2x.jpg"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_hero_2x.jpg"),
        ].compactMap { $0 }
    }

    /// URLs for Steam's new hash-based CDN, required for games published after ~2024.
    /// Prefers the manual override hash from GameArtOverrides, then the auto-fetched hash.
    ///
    /// Tries both the library_600x900 naming (most games) and the library_capsule naming
    /// (some newer titles, e.g. Super Battle Golf use library_capsule_2x.jpg instead).
    var newCDNCapsuleURLs: [URL] {
        guard let hash = effectiveCapsuleHash, !hash.isEmpty else { return [] }
        return [
            // library_600x900 naming (most games)
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_600x900.jpg"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_600x900.jpg"),
            URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_600x900.jpg"),
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_600x900_2x.jpg"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_600x900_2x.jpg"),
            // library_capsule naming (some newer titles)
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_capsule_2x.jpg"),
            URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_capsule_2x.jpg"),
            URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/\(hash)/library_capsule.jpg"),
        ].compactMap { $0 }
    }

    /// Steam's portrait cover art (600×900).
    ///
    /// The true 600×900 file is the `_2x` variant — the non-2x file is often
    /// only 300×450 and may be entirely absent for newer titles. We therefore
    /// start with `_2x.jpg` on steamcdn-a (confirmed reliable by the Steam
    /// community) and work outward through CDN mirrors and format variants.
    var verticalCapsuleURL: URL {
        URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/library_600x900_2x.jpg")!
    }

    /// Ordered fallback chain for the vertical portrait cover.
    /// Only portrait-format URLs — no landscape headers — so failed lookups
    /// show the blank placeholder rather than distorting card layout.
    ///
    /// Priority:
    ///  1. _2x JPEG across CDN mirrors (true 600×900; present wherever art exists)
    ///  2. Standard (non-2x) JPEG — may be absent on newer titles
    ///  3. WebP variants — some titles only publish WebP; NSImage decodes natively on macOS 11+
    var verticalCapsuleURLFallbacks: [URL] {
        [
            // _2x JPEG — CDN mirrors
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900_2x.jpg"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900_2x.jpg"),
            // Standard JPEG — present on most older titles
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900.jpg"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg"),
            URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/library_600x900.jpg"),
            // WebP variants
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900.webp"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.webp"),
            URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(id)/library_600x900.webp"),
            URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900_2x.webp"),
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900_2x.webp"),
        ].compactMap { $0 }
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

    private static func formatPlaytime(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return "\(mins) minute\(mins == 1 ? "" : "s")" }
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    var playtimeFormatted: String {
        Self.formatPlaytime(minutes: playtimeMinutes)
    }

    var playtime2WeekFormatted: String? {
        guard let minutes = playtime2WeekMinutes, minutes > 0 else { return nil }
        return Self.formatPlaytime(minutes: minutes)
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
        windowsOnly: Bool = false,
        libraryCapsuleHash: String? = nil,
        logoHash: String? = nil,
        heroHash: String? = nil,
        logoPinned: String? = nil,
        logoWidthPct: Double? = nil,
        logoHeightPct: Double? = nil
    ) {
        self.id                   = id
        self.name                 = name
        self.playtimeMinutes      = playtimeMinutes
        self.playtime2WeekMinutes = playtime2WeekMinutes
        self.lastPlayedDate       = lastPlayedDate
        self.iconHash             = iconHash
        self.isInstalled          = isInstalled
        self.windowsOnly          = windowsOnly
        self.libraryCapsuleHash   = libraryCapsuleHash
        self.logoHash             = logoHash
        self.heroHash             = heroHash
        self.logoPinned           = logoPinned
        self.logoWidthPct         = logoWidthPct
        self.logoHeightPct        = logoHeightPct
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
