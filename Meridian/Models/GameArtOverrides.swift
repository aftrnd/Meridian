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
///
/// Format for adding a new game:
///   // GameName (year) — hashes confirmed via SteamDB YYYY-MM-DD
///   // logo:    <full SteamDB logo URL>
///   // capsule: <full SteamDB capsule URL>
///   appID: GameArtOverride(
///       logoHash:    "<40-char hex>",
///       capsuleHash: "<40-char hex>"
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

    ]

    // MARK: - Lookups

    static func logoHash(for appID: Int) -> String? {
        registry[appID]?.logoHash
    }

    static func capsuleHash(for appID: Int) -> String? {
        registry[appID]?.capsuleHash
    }
}
