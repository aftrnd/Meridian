import XCTest

/// Regression guard for game pages opening a pixel or two scrolled down.
///
/// THE BUG (Oct 2026): the open zoom scales the live page, and AppKit
/// recomputes its scroll view's top inset through that scale every frame
/// (52 pt, ~49 at the spring's overshoot, back to 52) while the offset
/// chases it in whole pixels. 7 of 17 opens rested 0.5-1.5 pt down, so the
/// page could be scrolled up a little.
///
/// THE FIX: GameDetailView's landing hook (`ScrollViewLanding`, run when
/// the zoom lands) puts the page back at its top when it rests within a few
/// points of it.
///
/// This test file source-greps GameDetailView so the return to the top
/// isn't dropped from the landing.
final class GameDetailLandingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testGamePage_returnsToItsTopWhenTheZoomLands() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("ScrollViewLanding(landed: showsAmbient)"),
                      "the page's scroll content carries the landing hook, driven by the zoom settling")
        XCTAssertTrue(src.contains("if landed { returnToTop(scrollView) }"),
                      "landing puts the page back at its top")
        XCTAssertTrue(src.contains("abs(y - top) < Self.topSnap"),
                      "only within a few points, so a scroll made mid-flight is kept")
    }
}
