import XCTest

/// Regression guards for window positioning on app launch.
///
/// THE BUG (May 2026): `NSWindow.center()` uses Apple's "cascade" convention
/// which places the window in the upper third of the screen. It does NOT
/// account for the Dock. Users see a window that's offset toward the top.
///
/// THE FIX: Use `visibleFrame.midX/midY` to compute the centered origin
/// manually. `visibleFrame` excludes both the menu bar (top) and the Dock
/// (bottom/side), so the midpoint is the true visual center.
///
/// This test file source-greps the production code to ensure no one
/// re-introduces `NSWindow.center()` for the launch window positioning.
final class WindowCenteringTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    /// AppDelegate must use `visibleFrame.midX/midY` for the launch window
    /// position, not `NSWindow.center()`.
    func testAppDelegate_usesVisibleFrameForCentering() throws {
        let src = try readSource("Meridian/App/AppDelegate.swift")
        XCTAssertTrue(
            src.contains("visibleFrame"),
            "AppDelegate must use NSScreen.visibleFrame to account for the Dock"
        )
        XCTAssertTrue(
            src.contains("vf.midX") && src.contains("vf.midY"),
            "AppDelegate must compute the centered origin from visibleFrame.midX/midY"
        )
    }

    /// SplashView must NOT call `NSWindow.center()` — that's the
    /// Dock-unaware cascade convention. Use visibleFrame math instead.
    func testSplashView_doesNotUseNSWindowCenter() throws {
        let src = try readSource("Meridian/Views/SplashView.swift")
        XCTAssertFalse(
            src.contains("mainWindow?.center()"),
            "SplashView MUST NOT call NSWindow.center() — that uses Apple's cascade convention which is Dock-unaware. Use visibleFrame.midX/midY instead. See AppDelegate.enforceMainWindowLaunchFrame for the canonical math."
        )
        XCTAssertFalse(
            src.contains(".center()") && !src.contains("mainWindow"),
            "SplashView must not use any NSWindow.center() variant"
        )
    }

    /// SplashView must use the same visibleFrame math as AppDelegate.
    func testSplashView_usesVisibleFrameForCentering() throws {
        let src = try readSource("Meridian/Views/SplashView.swift")
        XCTAssertTrue(
            src.contains("visibleFrame"),
            "SplashView must use NSScreen.visibleFrame for Dock-aware centering"
        )
        XCTAssertTrue(
            src.contains("vf.midX") && src.contains("vf.midY"),
            "SplashView must use the same visibleFrame.midX/midY math as AppDelegate"
        )
    }
}
