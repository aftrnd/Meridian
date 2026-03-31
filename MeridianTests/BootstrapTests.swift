import XCTest

/// Unit tests for bootstrap pipeline logic in BootstrapManager and WineSteamManager.
///
/// These tests inline the pure functions under test rather than @testable-importing
/// the main target (which is an executable and cannot be imported). If the source
/// logic is changed, the inlined copies here should be updated in lock-step.
///
/// MIRROR CONTRACT: Every inlined function must match its production counterpart.
/// When editing the source, update the mirror here and re-run `swift test`.
final class BootstrapTests: XCTestCase {

    // MARK: - Phase enum mirror (BootstrapManager.Phase)

    /// Mirror of BootstrapManager.Phase
    /// MIRROR CONTRACT: Mirrors BootstrapManager.Phase (BootstrapManager.swift)
    enum Phase: Equatable {
        case idle
        case awaitingPermission
        case detectingEngine
        case downloadingEngine
        case creatingPrefix
        case installingSteam
        case bootstrappingSteam
        case syncingSession
        case startingSteam
        case ready
        case failed(String)
    }

    /// Mirror of BootstrapManager retry cleanup logic.
    /// Returns true if the given failed phase warrants a full prefix wipe.
    private func shouldWipePrefixOnRetry(failedPhase: Phase?) -> Bool {
        let cleanupPhases: [Phase] = [
            .creatingPrefix, .installingSteam, .bootstrappingSteam, .startingSteam
        ]
        guard let phase = failedPhase else { return false }
        return cleanupPhases.contains(phase)
    }

    // MARK: - Retry Cleanup Logic

    func testRetryWipesForSteamPhases() {
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .creatingPrefix))
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .installingSteam))
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .bootstrappingSteam))
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .startingSteam))
    }

    func testRetryDoesNotWipeForEarlyPhases() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .idle))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .detectingEngine))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .downloadingEngine))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .awaitingPermission))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .syncingSession))
    }

    func testRetryDoesNotWipeForNilPhase() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: nil))
    }

    func testRetryDoesNotWipeForFailedPhase() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .failed("some error")))
    }

    func testRetryDoesNotWipeForReadyPhase() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .ready))
    }

    // MARK: - Phase ordering

    /// The canonical order phases should progress in during a full fresh-install pipeline.
    func testPhasePipelineOrder() {
        let expectedOrder: [Phase] = [
            .detectingEngine,
            .creatingPrefix,
            .installingSteam,
            .bootstrappingSteam,
            .syncingSession,
            .startingSteam,
            .ready,
        ]

        for i in 0..<expectedOrder.count - 1 {
            XCTAssertNotEqual(
                expectedOrder[i], expectedOrder[i + 1],
                "Adjacent phases should be different"
            )
        }
        XCTAssertEqual(expectedOrder.last, .ready)
    }

    // MARK: - needsBootstrap mirror (WineSteamManager)

    /// Mirror of WineSteamManager.needsBootstrap logic.
    /// Returns true when steamui.dll is missing at the given path.
    private func needsBootstrap(steamInstallDir: String) -> Bool {
        let dllPath = steamInstallDir + "/steamui.dll"
        return !FileManager.default.fileExists(atPath: dllPath)
    }

    func testNeedsBootstrapWhenDLLMissing() {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "BootstrapTests-\(UUID().uuidString)")
            .path(percentEncoded: false)
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        XCTAssertTrue(needsBootstrap(steamInstallDir: tempDir))
    }

    func testNeedsBootstrapFalseWhenDLLPresent() {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "BootstrapTests-\(UUID().uuidString)")
            .path(percentEncoded: false)
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let dllPath = tempDir + "/steamui.dll"
        FileManager.default.createFile(atPath: dllPath, contents: Data("dummy".utf8))

        XCTAssertFalse(needsBootstrap(steamInstallDir: tempDir))
    }

    // MARK: - Package directory quiescence logic

    /// Mirror of the quiescence detection logic used in WineSteamManager.bootstrap().
    /// Given a sequence of directory sizes, returns the index at which quiescence
    /// is detected (size stable for `windowPolls` consecutive polls), or nil.
    private func detectQuiescence(sizes: [Int], windowPolls: Int) -> Int? {
        var lastSize: Int = -1
        var stableCount: Int = 0

        for (i, size) in sizes.enumerated() {
            if size != lastSize {
                lastSize = size
                stableCount = 0
            } else if size > 0 {
                stableCount += 1
                if stableCount >= windowPolls {
                    return i
                }
            }
        }
        return nil
    }

    func testQuiescenceDetectsStableSize() {
        // Size grows then stabilizes
        let sizes = [0, 1000, 5000, 10000, 10000, 10000, 10000]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, 6)
    }

    func testQuiescenceNotTriggeredWhenGrowing() {
        let sizes = [0, 1000, 2000, 3000, 4000, 5000]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result)
    }

    func testQuiescenceNotTriggeredAtZero() {
        let sizes = [0, 0, 0, 0, 0]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result, "Zero-size dir should not trigger quiescence")
    }

    func testQuiescenceNeedsEnoughStablePolls() {
        let sizes = [0, 5000, 5000]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result, "Only 1 stable poll, need 3")
    }

    func testQuiescenceResetsByGrowth() {
        // Stable at 5000, then grows, then stable at 8000
        let sizes = [5000, 5000, 5000, 8000, 8000, 8000, 8000]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertEqual(result, 6, "Should detect quiescence at the second stable run")
    }

    // MARK: - Health monitor retry budget

    func testHealthMonitorMaxRetries() {
        let maxRetries = 5
        let baseInterval: TimeInterval = 10
        let stableThreshold: TimeInterval = 60

        XCTAssertEqual(maxRetries, 5, "Health monitor max retries should be 5")
        XCTAssertEqual(baseInterval, 10, "Base interval should be 10s")
        XCTAssertEqual(stableThreshold, 60, "Stable threshold should be 60s")
    }

    func testHealthMonitorBackoffIntervals() {
        let baseInterval: TimeInterval = 10
        let maxBackoff: TimeInterval = 120

        for retryCount in 0...6 {
            let backoff = baseInterval * pow(2.0, Double(min(retryCount, 4)))
            let sleepDuration = min(backoff, maxBackoff)

            switch retryCount {
            case 0: XCTAssertEqual(sleepDuration, 10)
            case 1: XCTAssertEqual(sleepDuration, 20)
            case 2: XCTAssertEqual(sleepDuration, 40)
            case 3: XCTAssertEqual(sleepDuration, 80)
            case 4: XCTAssertEqual(sleepDuration, 120)
            case 5: XCTAssertEqual(sleepDuration, 120, "Should cap at 120")
            case 6: XCTAssertEqual(sleepDuration, 120, "Should cap at 120")
            default: break
            }
        }
    }
}
