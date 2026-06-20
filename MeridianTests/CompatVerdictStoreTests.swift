import XCTest

/// Tests for the developer compatibility-verdict overlay
/// (`CompatVerdictStore` + `GameCompatibilityDB.effectiveStatus` in
/// `GameCompatibilityDB.swift`, wired into `GameDetailView.swift`).
///
/// The `Meridian` target is an executableTarget; Swift cannot `@testable import`
/// it, so the pure logic (verdict precedence + Swift-snippet export) is mirrored
/// here. Source-invariant tests read the production files as text and assert the
/// wiring (DEBUG-only UI, effectiveStatus precedence) holds.
///
/// MIRROR CONTRACT: `Verdict`, `exportSwiftSnippets`, and `effectiveStatus`
/// below mirror their counterparts in `GameCompatibilityDB.swift`. Keep in sync.
final class CompatVerdictStoreTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Mirror of CompatVerdictStore.Verdict / exportSwiftSnippets

    struct Verdict: Equatable {
        var status: String
        var note: String
        var engineTag: String
    }

    /// Mirror of `CompatVerdictStore.exportSwiftSnippets(_:name:)`.
    private func exportSwiftSnippets(_ verdicts: [Int: Verdict], name: (Int) -> String) -> String {
        guard !verdicts.isEmpty else { return "// No developer verdicts recorded." }
        return verdicts
            .sorted { $0.key < $1.key }
            .map { appID, v -> String in
                let note = v.note.isEmpty ? "" : "  // \(v.note)"
                return "// \(name(appID)) (\(appID)): status: .\(v.status), verifiedWith: \"\(v.engineTag)\"\(note)"
            }
            .joined(separator: "\n")
    }

    // MARK: - Mirror of GameCompatibilityDB.effectiveStatus

    /// Mirror of the priority order in `GameCompatibilityDB.effectiveStatus`:
    /// verdict > resolved > profile > compiled > .untested.
    private func effectiveStatus(
        verdict: String?,
        resolved: String?,
        profile: String?,
        compiled: String?
    ) -> String {
        if let verdict { return verdict }
        return resolved ?? profile ?? compiled ?? "untested"
    }

    // MARK: - Export formatting

    func testExport_emptyVerdicts_returnsPlaceholder() {
        XCTAssertEqual(exportSwiftSnippets([:], name: { "App \($0)" }),
                       "// No developer verdicts recorded.")
    }

    func testExport_sortsByAppIDAndIncludesTagAndNote() {
        let verdicts: [Int: Verdict] = [
            620: Verdict(status: "verified", note: "", engineTag: "v3.0.6-engine"),
            220: Verdict(status: "playable", note: "audio crackle", engineTag: "v3.0.6-engine"),
        ]
        let out = exportSwiftSnippets(verdicts) { id in id == 220 ? "Half-Life 2" : "Portal 2" }
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        // Sorted ascending by appID: 220 before 620.
        XCTAssertTrue(lines[0].contains("(220)"))
        XCTAssertTrue(lines[0].contains("status: .playable"))
        XCTAssertTrue(lines[0].contains("verifiedWith: \"v3.0.6-engine\""))
        XCTAssertTrue(lines[0].contains("// audio crackle"))
        XCTAssertTrue(lines[1].contains("(620)"))
        XCTAssertTrue(lines[1].contains("status: .verified"))
        XCTAssertFalse(lines[1].contains("//  ")) // no empty trailing note
    }

    // MARK: - Verdict precedence

    func testEffectiveStatus_verdictWinsOverEverything() {
        XCTAssertEqual(
            effectiveStatus(verdict: "broken", resolved: "verified", profile: "verified", compiled: "verified"),
            "broken"
        )
    }

    func testEffectiveStatus_fallsBackThroughResolvedThenProfileThenCompiled() {
        XCTAssertEqual(effectiveStatus(verdict: nil, resolved: "playable", profile: "verified", compiled: "launches"), "playable")
        XCTAssertEqual(effectiveStatus(verdict: nil, resolved: nil, profile: "verified", compiled: "launches"), "verified")
        XCTAssertEqual(effectiveStatus(verdict: nil, resolved: nil, profile: nil, compiled: "launches"), "launches")
        XCTAssertEqual(effectiveStatus(verdict: nil, resolved: nil, profile: nil, compiled: nil), "untested")
    }

    // MARK: - Source wiring invariants

    func testGameCompatibilityDB_declaresVerdictStoreAndEffectiveStatus() throws {
        let src = try readSource("Meridian/Engine/GameCompatibilityDB.swift")
        XCTAssertTrue(src.contains("final class CompatVerdictStore"),
                      "CompatVerdictStore must exist as the developer verdict overlay")
        XCTAssertTrue(src.contains("func effectiveStatus("),
                      "GameCompatibilityDB must expose effectiveStatus(for:resolved:profile:)")
        XCTAssertTrue(src.contains("func exportSwiftSnippets("),
                      "CompatVerdictStore must expose exportSwiftSnippets for committing verdicts")
        XCTAssertTrue(src.contains("compat-verdicts.json"),
                      "verdicts must persist to compat-verdicts.json in Application Support")
        XCTAssertTrue(src.contains("@Observable"),
                      "CompatVerdictStore must be @Observable so the badge refreshes on a verdict change")
    }

    func testGameDetailView_usesEffectiveStatusAndDebugGatedVerdictUI() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("GameCompatibilityDB.shared.effectiveStatus("),
                      "the compat badge must resolve status via effectiveStatus (verdict overlay aware)")
        XCTAssertTrue(src.contains("#if DEBUG"),
                      "the verdict recorder UI must be compiled out of Release builds")
        XCTAssertTrue(src.contains("devVerdictCard"),
                      "GameDetailView must render the developer verdict card")
        XCTAssertTrue(src.contains("CompatVerdictStore.shared.setVerdict("),
                      "verdict buttons must persist via CompatVerdictStore.setVerdict")
    }
}
