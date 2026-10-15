import XCTest

/// Regression guard for Search's scroll blur.
///
/// THE BUG (Oct 2026): scrolled, Search drew a blurred band under the
/// toolbar and the genre row, with a hard line at its foot: AppKit's top
/// scroll edge effect (an NSScrollPocket on SwiftUI's scroll view). SwiftUI's
/// `scrollEdgeEffectHidden(true)` looks like the fix but never reaches it on
/// macOS 27.0.1, and standalone probes only lacked the blur because their
/// scroll view existed from the window's first frame.
///
/// THE FIX: `NoTopScrollEdgeEffect`, inside the results' scroll content,
/// clears the top bit of NSScrollView's private `allowedPocketEdges`, only
/// while the setter exists.
///
/// This test file source-greps SearchView so the switch isn't traded back
/// for the public modifier.
final class ScrollEdgeEffectTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testSearchResults_turnOffTopScrollEdgeEffectThroughAppKit() throws {
        let src = try readSource("Meridian/Views/Library/SearchView.swift")
        XCTAssertTrue(src.contains("NoTopScrollEdgeEffect().frame(width: 0, height: 0)"),
                      "the results' scroll content carries the hook; it finds its NSScrollView from inside")
        XCTAssertTrue(src.contains("forKey: \"allowedPocketEdges\""),
                      "the hook clears the top pocket edge")
        XCTAssertTrue(src.contains("responds(to: NSSelectorFromString(\"setAllowedPocketEdges:\"))"),
                      "private AppKit: used only while the setter exists")
        XCTAssertFalse(src.contains(".scrollEdgeEffectHidden("),
                       "scrollEdgeEffectHidden doesn't reach this effect on macOS 27.0.1")
    }

    /// The fade that took the blur's place (TopFade) draws its variable blur
    /// with private Core Animation classes, only while they exist, so a
    /// macOS without them gets the darkening alone.
    func testSearchTopFade_variableBlurStaysGuarded() throws {
        let src = try readSource("Meridian/Views/Library/SearchView.swift")
        XCTAssertTrue(src.contains("TopFade(blurClearance:"),
                      "the genre row carries the top fade")
        XCTAssertTrue(src.contains("NSClassFromString(\"CABackdropLayer\") as? CALayer.Type"),
                      "the backdrop layer class is looked up, never assumed")
        XCTAssertTrue(src.contains("filterType.responds(to: factory)"),
                      "the variableBlur filter factory is checked before use")
    }
}
