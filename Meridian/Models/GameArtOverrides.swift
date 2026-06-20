import Foundation

/// A manually curated art override for a single game.
///
/// Use this when the automatic CDN hash fetching fails for a game and you have
/// confirmed working hashes from SteamDB or direct inspection of Steam's CDN.
///
/// To find hashes: go to steamdb.info/app/{appid}/info/ and look at the
/// "Assets" section — the hash is the 40-character hex segment in each URL.
/// e.g. .../steam/apps/3527290/7df31d9d967539cfcb161cea0a69edca82f04cdb/logo_2x.png
///                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
struct GameArtOverride {
    /// SHA-1 content hash for logo_2x.png on Steam's new CDN.
    /// Used by the hero carousel in the Home tab.
    let logoHash: String?

    /// SHA-1 content hash for library_600x900_2x.jpg on Steam's new CDN.
    /// Used by the 600×900 portrait card in the Library grid.
    let capsuleHash: String?

    /// SHA-1 content hash for library_hero.jpg on Steam's new CDN.
    /// Used by the hero banner in the Home carousel and game detail view.
    let heroHash: String?

    /// Steam's logo placement on the hero (from appinfo `logo_position`). Drives
    /// the game-detail hero's Steam-accurate logo positioning. Optional — when
    /// nil the appinfo-fetched placement (if any) is used.
    let logoPlacement: LogoPlacement?

    init(logoHash: String? = nil, capsuleHash: String? = nil, heroHash: String? = nil,
         logoPlacement: LogoPlacement? = nil) {
        self.logoHash      = logoHash
        self.capsuleHash   = capsuleHash
        self.heroHash      = heroHash
        self.logoPlacement = logoPlacement
    }
}

/// Static registry of manually curated art overrides.
///
/// Overrides take priority over automatically fetched hashes. Add a new entry
/// whenever the automatic fetching fails for a game and you have confirmed URLs
/// from SteamDB (steamdb.info/app/{appid}/info/ → Assets section).
///
/// The key is the Steam App ID — the number in the Steam store URL:
///   store.steampowered.com/app/3527290/Peak/  →  appID = 3527290
///
/// Given a SteamDB direct asset URL like:
///   https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/3527290/7df31d9d967539cfcb161cea0a69edca82f04cdb/logo_2x.png
///
/// Extract the 40-char hex between /apps/{appid}/ and /logo_2x.png → that is the logoHash.
/// Extract the 40-char hex between /apps/{appid}/ and /library_600x900 → that is the capsuleHash.
/// Extract the 40-char hex between /apps/{appid}/ and /library_hero → that is the heroHash.
///
/// Format for adding a new game:
///   // GameName (year) — hashes confirmed via SteamDB YYYY-MM-DD
///   // logo:    <full SteamDB logo URL>
///   // capsule: <full SteamDB capsule URL>
///   // hero:    <full SteamDB hero URL>
///   appID: GameArtOverride(
///       logoHash:    "<40-char hex>",
///       capsuleHash: "<40-char hex>",
///       heroHash:    "<40-char hex>"
///   ),
enum GameArtOverrides {

    // MARK: - Override Registry

    static let registry: [Int: GameArtOverride] = [

        // Peak (2024) — hashes confirmed via SteamDB 2026-03-18
        // logo:    https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/3527290/7df31d9d967539cfcb161cea0a69edca82f04cdb/logo_2x.png
        // capsule: https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/3527290/480bd879ac737921bfa2529a6fea15961267ad21/library_600x900_2x.jpg
        3527290: GameArtOverride(
            logoHash:    "7df31d9d967539cfcb161cea0a69edca82f04cdb",
            capsuleHash: "480bd879ac737921bfa2529a6fea15961267ad21"
        ),

        // Super Battle Golf (2024) — hashes confirmed via SteamDB 2026-03-18
        // logo:    https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/4069520/a5bf0704312c45ce5af99b6fb7fc7c08b1828806/logo_2x.png
        // capsule: https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/4069520/2fc1510d6b70cf26a95252290633b6cfd8e4bff1/library_capsule_2x.jpg
        // hero:    https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/4069520/81ccebfda24722ce39d61462a406e186b166b06e/library_hero_2x.jpg
        4069520: GameArtOverride(
            logoHash:    "a5bf0704312c45ce5af99b6fb7fc7c08b1828806",
            capsuleHash: "2fc1510d6b70cf26a95252290633b6cfd8e4bff1",
            heroHash:    "81ccebfda24722ce39d61462a406e186b166b06e"
        ),

        // Bogos Binted (3588490) — logo confirmed via Steam appinfo
        // (common.library_assets_full.library_logo.image.english), CLI-verified
        // 2026-06-19. Only the LOGO is overridden: GetItems already resolves the
        // capsule (0827d5a4) + hero (b1f7f916) but NEVER returns the logo for any
        // game, and the legacy /steam/apps/3588490/logo.png 404s (new-CDN-only
        // title). logo URL verified 200:
        //   https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/3588490/4037b4ea74455653c6c369d098fbb26dd54c988b/logo_2x.png
        3588490: GameArtOverride(
            logoHash: "4037b4ea74455653c6c369d098fbb26dd54c988b",
            logoPlacement: LogoPlacement(pinned: "BottomLeft", widthPct: 50.794144220416385, heightPct: 50)
        ),

        // Pratfall (4244510) — logo confirmed via Steam appinfo, CLI-verified
        // 2026-06-19. Same situation: GetItems gives capsule (950ae75b) + hero
        // (ff53ff26) but no logo; legacy path 404s. logo URL verified 200:
        //   https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/4244510/6b0b4b03d09d8d0c8e5369e1623d116f6b23d6a1/logo_2x.png
        4244510: GameArtOverride(
            logoHash: "6b0b4b03d09d8d0c8e5369e1623d116f6b23d6a1",
            logoPlacement: LogoPlacement(pinned: "CenterCenter", widthPct: 100, heightPct: 100)
        ),

    ]

    // MARK: - Lookups

    static func logoHash(for appID: Int) -> String? {
        registry[appID]?.logoHash
    }

    static func capsuleHash(for appID: Int) -> String? {
        registry[appID]?.capsuleHash
    }

    static func heroHash(for appID: Int) -> String? {
        registry[appID]?.heroHash
    }

    static func logoPlacement(for appID: Int) -> LogoPlacement? {
        registry[appID]?.logoPlacement
    }
}
