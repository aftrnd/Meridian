import SwiftUI
import AppKit

// MARK: - Card ↔ Detail transition (iOS / tvOS app-open)
//
// Click a card: a rounded rect grows from the card to fill the detail column.
// Inside it the card art dissolves into the LIVE detail page, which is scaled
// to cover the rect and grows with it — the page is revealed *inside* the
// zoom, never after it. Behind, the library recedes (scales down + fades)
// exactly like the iOS home screen. Close is the same motion in reverse, and
// either direction can be reversed mid-flight (click Back while still
// opening) because everything is driven by ONE animatable `progress`.
//
// Structure (see ContentView.stage): the detail column is a ZStack that keeps
// the root page mounted at all times (state — scroll offsets, search text,
// carousel index — survives), with the detail page layered on top when a
// game is selected. NavigationStack push/pop is not used: the AppKit-backed
// stack tears the root down on push, which makes a true zoom impossible on
// macOS (`NavigationTransition.zoom` is iOS-only).
//
// Every per-frame effect is a compositing op (transform, opacity, clip) —
// no layout ever depends on `progress`, so the heavy page and root are laid
// out exactly once per flight.

// MARK: Registry

/// Card art frames, in the stage's coordinate space. Plain singleton —
/// deliberately NOT observable, so per-scroll frame writes never invalidate
/// a view.
@MainActor
final class DetailTransitionRegistry {
    static let shared = DetailTransitionRegistry()

    /// Named coordinate space of the stage (the ZStack hosting root + detail).
    /// Declared on the root BEFORE its recede transform, so frames stay in
    /// resting layout coordinates even while the root is scaled.
    nonisolated static let stageSpace = "detailStage"

    struct CardSource {
        /// Art frame in stage coordinates, at layout scale.
        var artFrame: CGRect
        /// True while the card shows its hover lift (1.03 scale).
        var isHovered: Bool
        /// Exactly the image the card is drawing (nil while loading).
        var image: NSImage?

        /// The frame as the user actually sees it (hover lift applied).
        @MainActor var visualArtFrame: CGRect {
            guard isHovered else { return artFrame }
            let lift = CGFloat(DetailZoomTuning.shared.params.hoverLift)
            return artFrame.insetBy(dx: -artFrame.width * lift, dy: -artFrame.height * lift)
        }
    }

    private var cards: [Int: CardSource] = [:]

    /// Last known pointer position in stage coordinates (nil = outside the
    /// stage). Cards suppress hover for the whole flight, so no hover event
    /// tells a card the (stationary) pointer is still over it once the close
    /// has landed — it reads this instead.
    var pointer: CGPoint?

    /// Fired by the flight's source card when it scrolls away or is recycled
    /// mid-close (the root is interactive from the close's first frame). The
    /// stage cuts the return flight so no ghost/page stays pinned to the spot
    /// the card used to occupy.
    var flightSourceMoved: (() -> Void)?

    /// Hover re-records, so when a game appears in two rows the instance
    /// under the cursor (the one being clicked) wins.
    func recordCard(id: Int, artFrame: CGRect, isHovered: Bool, image: NSImage?) {
        cards[id] = CardSource(artFrame: artFrame, isHovered: isHovered, image: image)
    }

    func card(for id: Int) -> CardSource? { cards[id] }

    /// Called when a card instance leaves the screen (lazy grid/row
    /// recycling). Only drops the entry if it's THIS instance's frame, so a
    /// duplicate still on screen in another row keeps its anchor.
    func forgetCard(id: Int, artFrame: CGRect) {
        guard let stored = cards[id],
              abs(stored.artFrame.midX - artFrame.midX) < 2,
              abs(stored.artFrame.midY - artFrame.midY) < 2 else { return }
        cards[id] = nil
    }
}

// MARK: Zoom model

/// One card ↔ page zoom. Rects are in stage coordinates; the large end is
/// always the full stage, so it's derived at render time from the stage size.
struct DetailZoom {
    let gameID: Int
    /// The small end: the card art as seen on screen. For entry points with
    /// no card (hero button, popover) this is a centred inset of the stage
    /// and `poster` is nil — the page simply scales up and fades in.
    let cardRect: CGRect
    /// Card art (memory-tier hit); nil → no ghost, page fades instead.
    let poster: NSImage?
    /// The card's LAYOUT frame (hover lift excluded) — what the card itself
    /// reports, so it can recognise itself as the source and hide its art.
    let sourceLayoutFrame: CGRect?

    func source(landing: Bool) -> DetailFlightSource? {
        sourceLayoutFrame.map { DetailFlightSource(gameID: gameID, artFrame: $0, landing: landing) }
    }

    /// Rect at `progress` (0 = card, 1 = stage). Deliberately unclamped so
    /// the spring's overshoot is real: past 1 the page breathes beyond 1:1
    /// (clipped by the stage); below 0 the rect squishes about the card's
    /// centre and springs back — the close's "jello" landing.
    func rect(at progress: CGFloat, in stage: CGSize) -> CGRect {
        let a = cardRect
        if progress < 0 {
            return a.insetBy(dx: a.width * -progress / 2, dy: a.height * -progress / 2)
        }
        let p = progress
        let b = CGRect(origin: .zero, size: stage)
        return CGRect(x: a.minX + (b.minX - a.minX) * p,
                      y: a.minY + (b.minY - a.minY) * p,
                      width: a.width + (b.width - a.width) * p,
                      height: a.height + (b.height - a.height) * p)
    }

    /// Card corners are held while the rect is still card-like, then squared
    /// off as it becomes the page.
    @MainActor static func cornerRadius(at p: CGFloat) -> CGFloat {
        let t = tuning
        return CGFloat(t.cornerRadius) * (1 - CGFloat(smoothstep(unit(p), from: t.cornerHoldUntil, to: 1)))
    }

    /// Ghost alpha: the card art gives way to the live page early — as on iOS,
    /// where the icon is gone within the first third and the app's own
    /// content does the rest of the growing.
    @MainActor static func posterOpacity(at p: CGFloat) -> Double {
        1 - smoothstep(unit(p), from: tuning.posterFadeStart, to: tuning.posterFadeEnd)
    }

    /// Page alpha for the posterless fallback (nothing to dissolve from).
    @MainActor static func fallbackPageOpacity(at p: CGFloat) -> Double {
        smoothstep(unit(p), from: 0, to: tuning.fallbackPageFadeEnd)
    }

    /// Library recede. The root never transforms (a scale forces every glow
    /// blur and the hero's backgroundExtensionEffect to re-render per frame
    /// under a changing transform — visibly jerky). It stays untouched as the
    /// page comes forward and dissolves on its own eased clock (ContentView
    /// `rootFade`), not on the spring's progress.

    /// How far the page's clip extends past the stage, 0 → rest inset over
    /// the final stretch, so the ambient bleed under the toolbar fades in as
    /// the rect reaches it rather than popping in when the clip is dropped.
    @MainActor static func clipOverreach(at p: CGFloat) -> CGFloat {
        CGFloat(tuning.clipRestInset) * CGFloat(smoothstep(unit(p), from: tuning.clipOverreachStart, to: 1))
    }

    @MainActor static var tuning: DetailZoomParameters { DetailZoomTuning.shared.params }

    static func unit(_ p: CGFloat) -> CGFloat { min(max(p, 0), 1) }

    private static func smoothstep(_ x: CGFloat, from a: Double, to b: Double) -> Double {
        guard b > a else { return x >= CGFloat(b) ? 1 : 0 }
        let t = min(max((Double(x) - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Identifies the card a zoom departs from / returns to, so that card
/// (and only that instance) hides its art under the ghost.
struct DetailFlightSource: Equatable {
    let gameID: Int
    let artFrame: CGRect
    /// True once a close has settled: the card shows its own art again (the
    /// ghost is fading off it) but stays hover-free until the crossfade ends.
    let landing: Bool
}

extension EnvironmentValues {
    /// Non-nil while a zoom is departing from / returning to a card.
    @Entry var detailFlightSource: DetailFlightSource? = nil
    /// True while a game detail is presented (or in flight). Root pages use
    /// it to drop toolbar-owned chrome (the Search field) the detail page
    /// shouldn't inherit.
    @Entry var detailPresented: Bool = false
}

// MARK: Root recede

/// Library layer: dissolves as the page comes forward. Pure compositing
/// (one group alpha) — no transform, so nothing in the root re-renders.
/// Always applied (identity at fade 0) so the root keeps its identity/state.
struct DetailStageRecede: ViewModifier, Animatable {
    /// 0 = fully visible, 1 = gone.
    var fade: Double

    // ViewModifier is main-actor isolated; Animatable's requirement isn't.
    nonisolated var animatableData: Double {
        get { fade }
        set { fade = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(1 - fade)
    }
}

/// While a detail is up, the hidden root's scroll view must not feed the
/// toolbar's scroll-edge effect — two scroll views under one toolbar made
/// the glass flicker between their states mid-flight. No-op before macOS 26.
struct DetailStageEdgeEffectSuppression: ViewModifier {
    let suppressed: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(suppressed, for: .top)
        } else {
            content
        }
    }
}

// MARK: Page reveal

/// Detail-page layer: the live page is scaled to COVER the zoom rect
/// (top-aligned, horizontally centred) and clipped to it, so it grows with
/// the rect and lands at exactly 1:1 with no clip. Always applied — with no
/// zoom the clip is a rect far outside the page's bounds, which SwiftUI
/// treats as "preserve everything" (verified: an oversized `clipShape` keeps
/// overflowing content such as the ambient backdrop under the toolbar).
struct DetailZoomReveal: ViewModifier, Animatable {
    var progress: CGFloat
    /// Library dissolve (see ContentView.rootFade); the page's solid backing
    /// fades with it so there is nothing to snap off at the end.
    var rootFade: Double
    let zoom: DetailZoom?
    let stageSize: CGSize

    nonisolated var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(progress, rootFade) }
        set { progress = newValue.first; rootFade = newValue.second }
    }

    func body(content: Content) -> some View {
        let geo = geometry
        content
            // Solid backing while the library is still visible behind, so the
            // page reads as an opaque sheet coming forward (iOS apps are
            // opaque). Fades with the root → nothing to snap off at the end.
            .background { Color(nsColor: .windowBackgroundColor).opacity(geo.backing) }
            .scaleEffect(geo.scale, anchor: .topLeading)
            .offset(x: geo.offset.x, y: geo.offset.y)
            .clipShape(DetailZoomClip(rect: geo.clip, cornerRadius: geo.cornerRadius))
            .opacity(geo.opacity)
    }

    private struct Geometry {
        var scale: CGFloat = 1
        var offset: CGPoint = .zero
        var clip: CGRect
        var cornerRadius: CGFloat = 0
        var opacity: Double = 1
        var backing: Double = 0
    }

    private var geometry: Geometry {
        let bounds = CGRect(origin: .zero, size: stageSize)
        // Rest inset: generous enough to cover the page's overflow (backdrop
        // under the toolbar + blur) without a giant mask layer.
        let restInset = CGFloat(DetailZoom.tuning.clipRestInset)
        guard let zoom, stageSize.width > 0, stageSize.height > 0 else {
            return Geometry(clip: bounds.insetBy(dx: -restInset, dy: -restInset))
        }
        let rect = zoom.rect(at: progress, in: stageSize)
        let s = max(rect.width / stageSize.width, rect.height / stageSize.height)
        let over = DetailZoom.clipOverreach(at: progress)
        return Geometry(
            scale: s,
            offset: CGPoint(x: rect.midX - stageSize.width * s / 2, y: rect.minY),
            clip: rect.insetBy(dx: -over, dy: -over),
            cornerRadius: DetailZoom.cornerRadius(at: progress),
            opacity: zoom.poster == nil ? DetailZoom.fallbackPageOpacity(at: progress) : 1,
            backing: 1 - rootFade
        )
    }
}

/// Rounded rect at an explicit position, independent of the view's bounds.
private struct DetailZoomClip: Shape {
    var rect: CGRect
    var cornerRadius: CGFloat

    func path(in _: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

// MARK: Ghost (the card art)

/// Top layer: the flying card art, dissolving into the page beneath. Stays
/// mounted while idle so its Animatable modifier always interpolates from
/// the last committed progress. Inert (renders nothing) without a poster.
struct DetailZoomGhost: View {
    let zoom: DetailZoom?
    let progress: CGFloat
    let stageSize: CGSize
    /// Landing crossfade: after the close settles the card's own art is shown
    /// underneath and the ghost fades off it, so any residual difference
    /// (badges, sub-pixel placement) blends in instead of snapping.
    var opacity: Double = 1

    var body: some View {
        Color.clear
            .modifier(GhostBody(progress: progress, zoom: zoom, stageSize: stageSize))
            .opacity(opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

private struct GhostBody: ViewModifier, Animatable {
    var progress: CGFloat
    let zoom: DetailZoom?
    let stageSize: CGSize

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let zoom, let poster = zoom.poster {
                let rect = zoom.rect(at: progress, in: stageSize)
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: DetailZoom.cornerRadius(at: progress)))
                    .opacity(DetailZoom.posterOpacity(at: progress))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }
}

// MARK: Image lookup

extension DetailZoom {
    /// The image the card is actually drawing (registered by the card), so the
    /// ghost can never differ from it — the cache may hold a newer CDN variant
    /// than the one the card first loaded. Falls back to the memory tier.
    static func posterImage(for game: Game, card: DetailTransitionRegistry.CardSource?) -> NSImage? {
        if let img = card?.image { return img }
        let urls = game.newCDNCapsuleURLs + [game.verticalCapsuleURL] + game.verticalCapsuleURLFallbacks
        for url in urls {
            if let img = ImageCache.shared.memoryImage(for: url) { return img }
        }
        return nil
    }
}
