import XCTest

/// Architectural-invariant guard for the Wine core-service registration that
/// keeps Steam from crashing in `CalcUnIPThisBox` and `WebUITransportController`
/// on a fresh prefix (engine-research-findings.mdc Pattern 7).
///
/// CLI-confirmed root cause (April 25 2026): Wine's `nsiproxy`, `RpcSs`,
/// `EventLog`, and `PlugPlay` services are missing from the prefix template
/// `Scripts/release-engine.sh` ships, because that script's
/// `wineboot --init` step is killed by its 180 s timeout
/// (`rundll32 setupapi InstallHinfSection` runaway recursion in `ntdll.so`).
///
/// The previous self-heal — `ensureNsiproxyService()` writing the service
/// section directly to `system.reg` via `FileHandle` under
/// `[System\\CurrentControlSet\\Services\\nsiproxy]` — was unreliable
/// because `wineserver` resolves the `CurrentControlSet` symlink to
/// `ControlSet001` on the next save and discards the orphan section. The
/// fix is to register the four services through `wine64 reg add`, which
/// resolves the symlink correctly.
///
/// These tests grep the production source files at known paths so a future
/// refactor that reverts to `FileHandle` writes or drops the bootstrap
/// callsite trips immediately during `swift test`.
final class EnsureCoreServicesTests: XCTestCase {

    // Repo root derived from this test file's location: MeridianTests/<this>.swift
    // → ../ is the repo root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MeridianTests/
            .deletingLastPathComponent()  // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = repoRoot.appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - WinePrefix.swift invariants

    func testWinePrefixDeclaresEnsureCoreServices() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(
            src.contains("func ensureCoreServices(engine: WineEngine) async"),
            "WinePrefix must declare `func ensureCoreServices(engine: WineEngine) async` — required by BootstrapManager Pattern-7 self-heal"
        )
    }

    func testWinePrefixNoLongerHasFileHandleServiceSurgery() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        // The legacy implementation appended a `[System\\CurrentControlSet\\Services\\nsiproxy]`
        // block via FileHandle. The CurrentControlSet path is a registry symlink — direct
        // file writes under it are silently dropped on the next wineserver save. If this
        // marker reappears, someone reintroduced the broken self-heal.
        XCTAssertFalse(
            src.contains(#"[System\\\\CurrentControlSet\\\\Services\\\\nsiproxy]"#),
            "WinePrefix.swift contains direct system.reg surgery for nsiproxy — wineserver discards entries written under the CurrentControlSet symlink. Use `engine.run(args: [\"reg\", \"add\", ...])` instead."
        )
        XCTAssertFalse(
            src.contains("func ensureNsiproxyService("),
            "Legacy `ensureNsiproxyService` (file-surgery) must not be reintroduced — replaced by `ensureCoreServices(engine:)` which uses `wine64 reg add`."
        )
    }

    func testEnsureCoreServicesRegistersAllFourServices() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        // Locate the function body and assert the four service names appear inside it.
        guard let funcRange = src.range(of: "func ensureCoreServices(engine: WineEngine) async"),
              let bodyStart = src.range(of: "{", range: funcRange.upperBound..<src.endIndex)
        else {
            XCTFail("Could not locate ensureCoreServices function body in WinePrefix.swift")
            return
        }

        // Take a generous tail slice — the function is the only one with these markers
        // and we only need to know the names appear within it.
        let body = String(src[bodyStart.lowerBound...])

        for service in ["nsiproxy", "RpcSs", "EventLog", "PlugPlay"] {
            XCTAssertTrue(
                body.contains("\"\(service)\""),
                "ensureCoreServices must register `\(service)` — without it Steam either asserts in CalcUnIPThisBox (no nsiproxy), fails OLE class registration (no RpcSs), can't write asserts (no EventLog), or breaks dependent services (no PlugPlay)"
            )
        }

        // The body must dispatch via `engine.run(args:` with reg add — never via FileHandle.
        XCTAssertTrue(
            body.contains("engine.run(args: args"),
            "ensureCoreServices must execute `engine.run(args: [\"reg\", \"add\", ...])` to persist services through wineserver's symlink resolution"
        )
        XCTAssertFalse(
            body.contains("FileHandle"),
            "ensureCoreServices must not write to system.reg via FileHandle — wineserver discards entries written under the CurrentControlSet symlink"
        )
    }

    // MARK: - BootstrapManager.swift invariants

    func testBootstrapAwaitsEnsureCoreServices() throws {
        let src = try readSource("Meridian/App/BootstrapManager.swift")
        XCTAssertTrue(
            src.contains("await prefix.ensureCoreServices(engine: engine)"),
            "BootstrapManager must `await prefix.ensureCoreServices(engine: engine)` before installing/launching Steam — required by Pattern-7 fix"
        )
        XCTAssertFalse(
            src.contains("prefix.ensureNsiproxyService()"),
            "BootstrapManager still calls the legacy `ensureNsiproxyService()` — replace with `await prefix.ensureCoreServices(engine: engine)`"
        )
    }
}
