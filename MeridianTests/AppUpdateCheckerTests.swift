import XCTest

/// Unit tests for the version comparison and tag classification logic in AppUpdateChecker.
///
/// These tests inline the pure functions under test rather than @testable-importing
/// the main target (which is an executable and cannot be imported). If the source
/// logic is changed, the inlined copies here should be updated in lock-step.
final class AppUpdateCheckerTests: XCTestCase {

    // MARK: - Inlined logic under test

    /// Mirror of AppUpdateChecker.isCanonicalAppTag(_:)
    private func isCanonicalAppTag(_ tag: String) -> Bool {
        let stripped = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { Int($0) != nil }
    }

    /// Mirror of AppUpdateChecker.semverComponents(_:)
    private func semverComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    /// Mirror of AppUpdateChecker.isNewer(_:than:)
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = semverComponents(candidate)
        let b = semverComponents(current)
        let length = max(a.count, b.count)
        for i in 0..<length {
            let ac = i < a.count ? a[i] : 0
            let bc = i < b.count ? b[i] : 0
            if ac > bc { return true }
            if ac < bc { return false }
        }
        return false
    }

    /// Mirror of AppUpdateChecker.isNewerEngine(_:than:)
    private func isNewerEngine(_ candidate: String, than current: String) -> Bool {
        let clean = { (s: String) -> String in
            s.replacingOccurrences(of: "-engine", with: "")
        }
        return isNewer(clean(candidate), than: clean(current))
    }

    // MARK: - isCanonicalAppTag

    func testCanonicalTagAcceptsVMajorMinorPatch() {
        XCTAssertTrue(isCanonicalAppTag("v1.0.0"))
        XCTAssertTrue(isCanonicalAppTag("v1.2.3"))
        XCTAssertTrue(isCanonicalAppTag("v10.20.30"))
        XCTAssertTrue(isCanonicalAppTag("v0.9.2"))
    }

    func testCanonicalTagAcceptsWithoutLeadingV() {
        XCTAssertTrue(isCanonicalAppTag("1.0.0"))
        XCTAssertTrue(isCanonicalAppTag("2.1.0"))
    }

    func testCanonicalTagRejectsEngineSuffix() {
        XCTAssertFalse(isCanonicalAppTag("v1.0.3-engine"))
        XCTAssertFalse(isCanonicalAppTag("v1.0.2-engine"))
    }

    func testCanonicalTagRejectsBaseSuffix() {
        XCTAssertFalse(isCanonicalAppTag("v1.0.2-base"))
        XCTAssertFalse(isCanonicalAppTag("v1.0.0-base"))
    }

    func testCanonicalTagRejectsPrereleaseLabels() {
        XCTAssertFalse(isCanonicalAppTag("v2.0.0-beta"))
        XCTAssertFalse(isCanonicalAppTag("v1.1.0-rc1"))
        XCTAssertFalse(isCanonicalAppTag("v1.0.0-alpha"))
    }

    func testCanonicalTagRejectsTwoPartVersion() {
        XCTAssertFalse(isCanonicalAppTag("v1.0"))
        XCTAssertFalse(isCanonicalAppTag("1.0"))
    }

    func testCanonicalTagRejectsFourPartVersion() {
        XCTAssertFalse(isCanonicalAppTag("v1.0.0.0"))
    }

    func testCanonicalTagRejectsNonNumericComponents() {
        XCTAssertFalse(isCanonicalAppTag("vX.Y.Z"))
        XCTAssertFalse(isCanonicalAppTag("v1.0.a"))
    }

    // MARK: - isNewer

    func testNewerPatchVersion() {
        XCTAssertTrue(isNewer("v1.0.3", than: "v1.0.2"))
        XCTAssertTrue(isNewer("1.0.3", than: "1.0.2"))
    }

    func testNewerMinorVersion() {
        XCTAssertTrue(isNewer("v1.1.0", than: "v1.0.9"))
    }

    func testNewerMajorVersion() {
        XCTAssertTrue(isNewer("v2.0.0", than: "v1.9.9"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(isNewer("v1.0.0", than: "v1.0.0"))
        XCTAssertFalse(isNewer("v1.2.3", than: "v1.2.3"))
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(isNewer("v1.0.1", than: "v1.0.2"))
        XCTAssertFalse(isNewer("v0.9.0", than: "v1.0.0"))
    }

    func testVersionWithoutLeadingV() {
        XCTAssertTrue(isNewer("1.0.3", than: "1.0.2"))
        XCTAssertFalse(isNewer("1.0.2", than: "1.0.3"))
    }

    // MARK: - isNewerEngine

    func testNewerEnginePatch() {
        XCTAssertTrue(isNewerEngine("v1.0.3-engine", than: "v1.0.2-engine"))
    }

    func testSameEngineIsNotNewer() {
        XCTAssertFalse(isNewerEngine("v1.0.3-engine", than: "v1.0.3-engine"))
    }

    func testOlderEngineIsNotNewer() {
        XCTAssertFalse(isNewerEngine("v1.0.2-engine", than: "v1.0.3-engine"))
    }

    func testEngineMinorVersionComparison() {
        XCTAssertTrue(isNewerEngine("v1.1.0-engine", than: "v1.0.9-engine"))
    }
}
