import Foundation

/// Meridian's proprietary game compatibility database.
///
/// Each entry encodes what we've learned about running a specific game through
/// CLI testing and research. Fixes are applied automatically at install time
/// (prefix configuration) and at launch time (environment variables, DLL overrides).
///
/// ## Adding a new game
/// 1. Test the game from CLI (see Scripts/test-game-cli.sh pattern)
/// 2. Document the root cause of any failure
/// 3. Pick the right factory: `.unity()`, `.unreal()`, `.custom()`
/// 4. Add the entry to the matching extension file (e.g. `GameCompatibilityDB+Unity.swift`)
/// 5. Run `swift test` to verify no regressions
/// 6. Set `status` to `.verified` once confirmed working end-to-end
///
/// ## Fix categories
/// - `dllOverrides`: WINEDLLOVERRIDES value for this game (merged at launch)
/// - `requiresCXEngine`: game crashes on Wine 8.0.1 stubs fixed in CrossOver 24+
/// - `dxmtMode`: Metal renderer preference (.auto / .required / .disabled)
/// - `requiresDXMTInSystem32`: DXMT DLLs must be in prefix system32 for CX engine
/// - `extraEnv`: per-game environment variables (merged at launch)
/// - `graphicsAPI`: which DirectX/Vulkan API the game renders with
/// - `status`: verification state (.verified / .playable / .launches / .broken / .untested)
///
/// ## Architecture
/// Game entries live in per-engine extension files:
/// - `GameCompatibilityDB+Unity.swift`   → all Unity games
/// - `GameCompatibilityDB+Custom.swift`  → custom/proprietary engine games
/// - Future: `+Unreal.swift`, `+Godot.swift`, etc.
///
/// Factory methods on `GameProfile` encode engine-specific defaults. Changing
/// a factory (e.g. `.unity()`) updates every game of that engine type at once.
@MainActor
final class GameCompatibilityDB {

    static let shared = GameCompatibilityDB()

    // MARK: - Profile assembly

    /// Merges all per-engine extension arrays into a single list.
    /// Add new engine categories here as a single additional term.
    private static var allProfiles: [GameProfile] {
        unityProfiles + customEngineProfiles
    }

    /// All known game profiles, keyed by appID for O(1) lookup at launch time.
    private let profiles: [Int: GameProfile] = {
        var db: [Int: GameProfile] = [:]
        for p in GameCompatibilityDB.allProfiles { db[p.appID] = p }
        return db
    }()

    // MARK: - Public API

    /// Returns the profile for a given appID, or nil if no specific profile exists.
    func profile(for appID: Int) -> GameProfile? {
        profiles[appID]
    }

    /// Whether this game requires the CrossOver engine for correct operation.
    func requiresCXEngine(appID: Int) -> Bool {
        profiles[appID]?.requiresCXEngine ?? false
    }

    /// Whether DXMT DLLs must be installed into system32 for this game.
    /// True when: the CX engine is active AND the game uses D3D11/DXGI.
    func requiresDXMTInSystem32(appID: Int) -> Bool {
        profiles[appID]?.requiresDXMTInSystem32 ?? false
    }

    /// Returns the WINEDLLOVERRIDES string for this game, if any.
    func dllOverrides(for appID: Int) -> String? {
        profiles[appID]?.dllOverrides
    }

    /// Returns extra environment variables for this game.
    func extraEnv(for appID: Int) -> [String: String] {
        profiles[appID]?.extraEnv ?? [:]
    }

    /// A one-line description of what fixes are applied for a game.
    func fixSummary(for appID: Int) -> String {
        guard let p = profiles[appID] else { return "none" }
        var parts: [String] = ["[\(p.status.rawValue)]"]
        if p.graphicsAPI != .unknown { parts.append(p.graphicsAPI.rawValue.uppercased()) }
        if p.requiresCXEngine { parts.append("CX engine") }
        if p.requiresDXMTInSystem32 { parts.append("DXMT→system32") }
        if let ov = p.dllOverrides { parts.append("overrides: \(ov)") }
        if !p.extraEnv.isEmpty { parts.append("\(p.extraEnv.count) env vars") }
        return parts.joined(separator: ", ")
    }

    /// Total number of game profiles in the database.
    var count: Int { profiles.count }
}
