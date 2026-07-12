import XCTest

/// Guard tests for the STEPPED-PROPORTIONAL layout model (July 12 2026,
/// settled after one reversal — a fully-fixed card size was tried first and
/// walked back the same night).
///
/// User direction: cards resize naturally, spacing stays exactly like the
/// default, and the column count steps with the window — 3 minimum, 5 max
/// for Home rows — always with the peek slice of the next card showing.
/// The column step is anchored to the default-window card size so the
/// default layout is reproduced exactly.
final class CardLayoutMetricsTests: XCTestCase {

    // MARK: - Mirror of CardLayoutMetrics (production: GameGridView.swift)

    private let spacing: CGFloat = 20
    private let peek: CGFloat = 0.2
    private let defaultContentWidth: CGFloat = 810

    /// Mirror of CardLayoutMetrics.referenceCardWidth
    private var referenceCardWidth: CGFloat {
        (defaultContentWidth - 6 * spacing) / (5 + 2 * peek)
    }

    /// Mirror of CardLayoutMetrics.compute
    private func compute(
        for containerWidth: CGFloat,
        maxCards: Int = 8,
        minCards: Int = 3
    ) -> (cardWidth: CGFloat, visibleCount: Int, leadingPadding: CGFloat) {
        guard containerWidth > 0 else {
            let w = referenceCardWidth
            return (w, 5, spacing + peek * w)
        }
        let rawN = Int(floor(containerWidth / (referenceCardWidth + spacing)))
        let n = min(max(rawN, minCards), maxCards)
        let w = (containerWidth - CGFloat(n + 1) * spacing) / (CGFloat(n) + 2 * peek)
        return (w, n, spacing + peek * w)
    }

    // MARK: - Anchor: the default window layout is the identity

    func testDefaultWidth_reproducesCanonicalFiveColumnLayout() {
        let m = compute(for: defaultContentWidth, maxCards: 5)
        XCTAssertEqual(m.visibleCount, 5,
                       "The default window must show exactly 5 columns.")
        XCTAssertEqual(m.cardWidth, referenceCardWidth, accuracy: 0.001,
                       "At the default window the proportional fit lands exactly on the reference card size.")
    }

    // MARK: - Column stepping (Home rows: 3…5)

    func testColumnCountSteps3to4to5WithWindowWidth() {
        XCTAssertEqual(compute(for: 500, maxCards: 5).visibleCount, 3,
                       "Narrow windows drop to 3 columns.")
        XCTAssertEqual(compute(for: 640, maxCards: 5).visibleCount, 4,
                       "Mid widths show 4 columns.")
        XCTAssertEqual(compute(for: 810, maxCards: 5).visibleCount, 5,
                       "The default width shows 5 columns.")
    }

    func testFiveColumnsIsTheCeiling_cardsGrowBeyondIt() {
        let wide = compute(for: 1300, maxCards: 5)
        XCTAssertEqual(wide.visibleCount, 5,
                       "Home rows never exceed 5 columns — extra width grows the cards.")
        XCTAssertGreaterThan(wide.cardWidth, referenceCardWidth,
                             "Beyond the 5-column step, cards scale up proportionally.")
    }

    func testThreeColumnsIsTheFloor() {
        let narrow = compute(for: 380, maxCards: 5)
        XCTAssertEqual(narrow.visibleCount, 3,
                       "Home rows never drop below 3 columns — cards shrink instead.")
        XCTAssertLessThan(narrow.cardWidth, referenceCardWidth)
    }

    // MARK: - Constant spacing + peek at every size

    func testSpacingAndPeekTreatmentAreConstant() {
        // The proportional fit must consume the width exactly: leading inset,
        // n cards, n-1 gaps, trailing gap, and the peek slice — at any width.
        for width in stride(from: 420.0, through: 1400.0, by: 49.0) {
            let m = compute(for: width, maxCards: 5)
            let consumed = m.leadingPadding                       // inset (s + p·w)
                + CGFloat(m.visibleCount) * m.cardWidth           // full cards
                + CGFloat(m.visibleCount - 1) * spacing           // gaps
                + spacing                                          // gap before peek
                + peek * m.cardWidth                               // peek slice
            XCTAssertEqual(consumed, width, accuracy: 0.5,
                           "Width \(width) must be filled exactly by the n-cards + peek layout.")
        }
    }

    // MARK: - Production source wiring

    func testProductionSource_usesSteppedProportionalModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let grid = try String(
            contentsOf: root.appending(path: "Meridian/Views/Library/GameGridView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(grid.contains("static var referenceCardWidth"),
                      "The column step must anchor to the default-window card size.")
        XCTAssertTrue(grid.contains("static let defaultContentWidth: CGFloat = 810"),
                      "The anchor must match AppDelegate.fullFrameSize (1030) minus the sidebar (220).")
        XCTAssertTrue(grid.contains("floor(containerWidth / (referenceCardWidth + s))"),
                      "Column count must step on the reference card size, not the old 155pt target.")

        let home = try String(
            contentsOf: root.appending(path: "Meridian/Views/HomeView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(home.contains("maxCards: 5"),
                      "Home rows clamp to 5 columns max (user direction July 12 2026).")
    }
}
