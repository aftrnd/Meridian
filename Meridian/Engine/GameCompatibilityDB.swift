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
/// 3. Add a `GameProfile` entry with the minimum required overrides
/// 4. Test in Meridian and confirm the fix works
/// 5. Update the notes field with the verified fix
///
/// ## Fix categories
/// - `dllOverrides`: WINEDLLOVERRIDES value for this game
/// - `requiresCXEngine`: game crashes on Wine 8.0.1 stubs fixed in CrossOver 24+
/// - `dxmtMode`: Metal renderer preference for this game
/// - `launchArgs`: Extra arguments to pass to -applaunch
/// - `prefixFixes`: One-time fixes to apply to the Wine prefix before launch
@MainActor
final class GameCompatibilityDB {

    static let shared = GameCompatibilityDB()

    // MARK: - Game Profile

    struct GameProfile {
        let appID: Int
        let name: String

        /// WINEDLLOVERRIDES value. nil = use engine default.
        let dllOverrides: String?

        /// Whether this game requires the CrossOver 24+ engine (CX Preview locally)
        /// to avoid abort stubs missing from Wine 8.0.1.
        /// Root cause: IsMouseInPointerEnabled and 1,000+ other missing Win8+ stubs
        /// that call abort() in Wine 8.0.1 but are properly stubbed in CX 24+.
        let requiresCXEngine: Bool

        /// Metal renderer preference.
        enum DXMTMode {
            case auto          // Use DXMT if available
            case required      // Must use DXMT or game will not render correctly
            case disabled      // Force Vulkan renderer
        }
        let dxmtMode: DXMTMode

        /// Whether to install DXMT DLLs into the Wine prefix system32 before launch.
        /// Needed when the CX engine is active (its built-in d3d11 takes priority over
        /// WINEDLLPATH, so DXMT must be physically in system32 to win).
        let requiresDXMTInSystem32: Bool

        /// Extra environment variables specific to this game.
        let extraEnv: [String: String]

        /// Human-readable notes documenting the root cause and fix.
        let notes: String

        init(
            appID: Int,
            name: String,
            dllOverrides: String? = nil,
            requiresCXEngine: Bool = false,
            dxmtMode: DXMTMode = .auto,
            requiresDXMTInSystem32: Bool = false,
            extraEnv: [String: String] = [:],
            notes: String = ""
        ) {
            self.appID = appID
            self.name = name
            self.dllOverrides = dllOverrides
            self.requiresCXEngine = requiresCXEngine
            self.dxmtMode = dxmtMode
            self.requiresDXMTInSystem32 = requiresDXMTInSystem32
            self.extraEnv = extraEnv
            self.notes = notes
        }
    }

    // MARK: - Database

    /// All known game profiles, keyed by appID.
    ///
    /// Entries are derived from CLI testing on Wine 8.0.1 (CrossOverFOSS 23.7.1).
    /// The CX engine flag indicates the game needs CrossOver 24+ stub coverage.
    private let profiles: [Int: GameProfile] = [

        // ─── Unity Games ────────────────────────────────────────────────────────
        //
        // Unity games on Wine 8.0.1 crash on IsMouseInPointerEnabled (USER32.dll).
        // Root cause: Unity calls GetProcessMitigationPolicy / IsMouseInPointerEnabled
        // for pointer input detection. Wine 8.0.1 has these as abort() stubs.
        // CrossOver 24+ properly stubs them as return-FALSE functions.
        // Fix: use CX engine. DXMT goes in system32 so CX wineloader picks it up.
        //
        3180070: GameProfile(
            appID: 3180070,
            name: "No, I'm not a Human",
            requiresCXEngine: true,
            dxmtMode: .auto,
            requiresDXMTInSystem32: true,
            notes: "Unity 2021. Crashes on IsMouseInPointerEnabled abort stub in Wine 8.0.1. " +
                   "CX engine eliminates the crash. DXMT works when placed in system32 " +
                   "(CX wineloader ignores WINEDLLPATH for d3d11). Verified: renders frames."
        ),
    ]

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
        var parts: [String] = []
        if p.requiresCXEngine { parts.append("CX engine") }
        if p.requiresDXMTInSystem32 { parts.append("DXMT→system32") }
        if let ov = p.dllOverrides { parts.append("overrides: \(ov)") }
        if !p.extraEnv.isEmpty { parts.append("\(p.extraEnv.count) env vars") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
