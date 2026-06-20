import Foundation
import Observation

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
/// - `dxmtMode`: Metal renderer preference (.auto / .required / .disabled)
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
        unityProfiles + sourceEngineProfiles + customEngineProfiles
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
        if let ov = p.dllOverrides { parts.append("overrides: \(ov)") }
        if !p.extraEnv.isEmpty { parts.append("\(p.extraEnv.count) env vars") }
        return parts.joined(separator: ", ")
    }

    /// Total number of game profiles in the database.
    var count: Int { profiles.count }

    /// The compatibility status to display for a game, in priority order:
    /// 1. A developer verdict recorded in this build (DEBUG verdict overlay)
    /// 2. The resolved stack status (local detection + PCGamingWiki + profile)
    /// 3. The compiled profile status
    /// 4. `.untested`
    ///
    /// In Release builds the verdict overlay is always empty (the verdict UI is
    /// `#if DEBUG`-only and the JSON file is never written), so users see the
    /// curated database. On a developer's machine a recorded verdict wins so the
    /// badge reflects what was just confirmed by hand.
    func effectiveStatus(
        for appID: Int,
        resolved: CompatStatus? = nil,
        profile: CompatStatus? = nil
    ) -> CompatStatus {
        if let v = CompatVerdictStore.shared.verdict(for: appID),
           let s = CompatStatus(rawValue: v.status) {
            return s
        }
        return resolved ?? profile ?? profiles[appID]?.status ?? .untested
    }
}

// MARK: - Developer compatibility verdicts (DEBUG overlay)

/// A lightweight, developer-facing overlay over the curated `GameCompatibilityDB`.
///
/// The compiled database is the source of truth shipped to users. While testing
/// a game in the **Debug** build you can record a one-tap status verdict
/// ("Runs Great / Some Issues / Doesn't Run / Untested") which is persisted to
/// `~/Library/Application Support/com.meridian.app/compat-verdicts.json` and
/// overlaid on the badge immediately — no Swift source edit, no rebuild.
///
/// At release time the recorded verdicts are exported (`exportSwiftSnippets()`)
/// and folded into the per-engine extension files, then the JSON can be cleared.
/// Release builds never write this file (the verdict UI is `#if DEBUG`), so end
/// users always see the curated database.
@MainActor
@Observable
final class CompatVerdictStore {
    static let shared = CompatVerdictStore()

    /// One developer verdict. `status` stores `CompatStatus.rawValue` so the
    /// JSON stays stable even if the enum gains display helpers.
    struct Verdict: Codable, Equatable {
        var status: String
        var note: String
        var engineTag: String
        var date: Date
    }

    private(set) var verdicts: [Int: Verdict] = [:]

    nonisolated static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/compat-verdicts.json")
    }()

    init() { load() }

    func verdict(for appID: Int) -> Verdict? { verdicts[appID] }

    /// Records (or replaces) the verdict for a game and persists immediately.
    func setVerdict(_ status: CompatStatus, note: String = "", engineTag: String, for appID: Int) {
        verdicts[appID] = Verdict(status: status.rawValue, note: note, engineTag: engineTag, date: .now)
        save()
    }

    func clearVerdict(for appID: Int) {
        guard verdicts[appID] != nil else { return }
        verdicts[appID] = nil
        save()
    }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? decoder.decode([String: Verdict].self, from: data)
        else { return }
        verdicts = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    private func save() {
        let keyed = Dictionary(uniqueKeysWithValues: verdicts.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(keyed) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Generates ready-to-paste `// appID: status` lines for committing recorded
    /// verdicts into the per-engine extension files. Pure formatting so it can be
    /// unit-tested without touching disk.
    static func exportSwiftSnippets(
        _ verdicts: [Int: Verdict],
        name: (Int) -> String
    ) -> String {
        guard !verdicts.isEmpty else { return "// No developer verdicts recorded." }
        let lines = verdicts
            .sorted { $0.key < $1.key }
            .map { appID, v -> String in
                let note = v.note.isEmpty ? "" : "  // \(v.note)"
                return "// \(name(appID)) (\(appID)): status: .\(v.status), verifiedWith: \"\(v.engineTag)\"\(note)"
            }
        return lines.joined(separator: "\n")
    }

    func exportSwiftSnippets(name: @escaping (Int) -> String) -> String {
        Self.exportSwiftSnippets(verdicts, name: name)
    }
}
