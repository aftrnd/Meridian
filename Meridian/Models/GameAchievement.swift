import Foundation

/// A single Steam achievement merged from player stats + game schema.
struct GameAchievement: Identifiable, Sendable {
    var id: String { apiName }
    /// The internal Steam API name for the achievement (e.g. "ACH_WIN_ONE_GAME").
    let apiName: String
    /// Localised display name shown to the player (e.g. "First Victory").
    let displayName: String
    /// Optional flavour text / how-to hint.
    let description: String?
    /// Whether the current user has unlocked this achievement.
    let achieved: Bool
    /// When the user unlocked it, if achieved.
    let unlockDate: Date?
    /// Full-colour icon URL from the game schema (used for unlocked achievements).
    let iconURL: URL?
    /// Greyscale icon URL from the game schema (used for locked achievements).
    let iconGrayURL: URL?
    /// Whether Steam hides the name/description until unlocked.
    let isHidden: Bool
}
