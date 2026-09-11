import SwiftUI
import AppKit

struct HomeView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(Launcher.self) private var launcher
    @Environment(AppUpdateChecker.self) private var updateChecker
    @Binding var selectedGame: Game?

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.friendsPanelOpen) private var friendsPanelOpen
    /// The panel's width while open (0 closed). Only used to reconstruct the
    /// full column width when Home mounts under an already-open panel; the
    /// chrome offsets come from live geometry (`coverWidth`).
    @Environment(\.friendsPanelCoverWidth) private var panelWidth

    @State private var updateBannerDismissed = false
    /// Live visible width of the content column — tracked every frame, even
    /// through the panel slide, so `coverWidth` follows the panel edge 1:1.
    @State private var contentWidth: CGFloat = 0
    /// Width captured the instant the friends panel opens (final design after
    /// three iterations — history in FriendsPanelTests):
    /// - The HERO stays pixel-locked at this width; the panel covers its
    ///   trailing edge. It never moves or rescales.
    /// - The GAME ROWS re-fit to the visible strip (locked − panel width) via
    ///   `rowLayoutWidth` — a computed TARGET, not per-frame geometry — so
    ///   they re-layout exactly once, animated inside the toggle transaction,
    ///   showing 3 full cards with the standard trailing peek at the panel
    ///   edge ("the exact spacing it would have if it wasn't there").
    @State private var lockedWidth: CGFloat?
    /// Invalidates any pending deferred lock release when the panel is
    /// re-toggled mid-animation.
    @State private var panelTransitionGeneration = 0
    /// True from a toggle until the slide has settled. While sliding, live
    /// widths are intermediate and must not re-lock the layout.
    @State private var panelSliding = false

    /// Trailing width of the frozen layout hidden under the panel, from live
    /// geometry (locked − visible). Tracks the panel edge exactly whatever
    /// curve the inspector animates with, and is 0 whenever the layout
    /// isn't locked — the chrome can never be offset by a panel that isn't
    /// covering it (the "chevrons in the middle of the hero" bug: Home
    /// re-mounted under an open panel with no lock, but still read the
    /// panel width from the environment).
    private var coverWidth: CGFloat {
        guard let lockedWidth else { return 0 }
        return max(0, lockedWidth - contentWidth)
    }

    /// FINAL DESIGN (4th iteration — history in FriendsPanelTests): while the
    /// friends panel is open, the ENTIRE Home layout is frozen at its
    /// pre-open width. Nothing moves, nothing resizes — the panel covers the
    /// trailing edge. ContentView sizes the panel so its edge lands exactly
    /// at the row's natural 3-full-cards + peek boundary, so the covered
    /// state looks intentional, not sliced mid-card.
    private var rowLayoutWidth: CGFloat { lockedWidth ?? contentWidth }

    private var leadingInset: CGFloat {
        // Same 3…5 column clamp as the rows so insets always line up.
        CardLayoutMetrics.compute(for: rowLayoutWidth, maxCards: 5).leadingPadding
    }

    /// Hero shares the frozen layout width.
    private var heroInset: CGFloat { leadingInset }

    private static let sectionSpacing: CGFloat = 28
    private static let carouselCount = 5

    var body: some View {
        Group {
            if library.isLoading && library.games.isEmpty {
                loadingView
            } else {
                homeContent
            }
        }
        .onChange(of: updateBannerKey) { _, _ in
            updateBannerDismissed = false
        }
    }

    /// Stable key that changes only when the set of available updates changes,
    /// used to reset the dismissed state so the card re-appears for new versions.
    private var updateBannerKey: String {
        "\(updateChecker.availableVersion ?? "")-\(updateChecker.availableEngineTag ?? "")"
    }

    // MARK: - Content

    private var homeContent: some View {
        // Each access re-filters + re-sorts the whole library; during live
        // resize the body re-evaluates every frame, so compute these once.
        let recent = library.recentlyPlayedGames
        let carousel = Array(recent.prefix(Self.carouselCount))
        let favorites = library.favoriteGames

        return ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                if !carousel.isEmpty {
                    HeroCarousel(games: carousel, heroInset: heroInset, coverWidth: coverWidth) { game in
                        selectedGame = game
                    }
                }

                // Inline update notification — sits naturally within the scroll flow
                // at the top of the content area, below the hero carousel.
                if (updateChecker.hasUpdate || updateChecker.hasEngineUpdate) && !updateBannerDismissed {
                    UpdateAvailableBanner(
                        message: updateBannerMessage,
                        onDismiss: { updateBannerDismissed = true },
                        onViewUpdate: {
                            updateBannerDismissed = true
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }
                    )
                    .padding(.horizontal, leadingInset)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.spring(duration: 0.35), value: updateChecker.hasUpdate || updateChecker.hasEngineUpdate)
                }

                if !recent.isEmpty {
                    GameScrollRow(
                        title: "Recently Played",
                        games: Array(recent.prefix(20)),
                        layoutWidth: rowLayoutWidth,
                        trailingObscured: coverWidth,
                        selectedGameID: selectedGame?.id,
                        isFavorite: { library.isFavorite(appID: $0) },
                        gameState: gameState(for:),
                        onSelect: { selectedGame = $0 },
                        contextMenu: { gameContextMenu(for: $0) }
                    )
                }

                if !library.friendSummaries.isEmpty {
                    friendActivitySection
                }

                if !favorites.isEmpty {
                    GameScrollRow(
                        title: "Favorites",
                        games: favorites,
                        layoutWidth: rowLayoutWidth,
                        trailingObscured: coverWidth,
                        selectedGameID: selectedGame?.id,
                        isFavorite: { _ in true },
                        showFavoriteBadge: false,
                        gameState: gameState(for:),
                        onSelect: { selectedGame = $0 },
                        contextMenu: { gameContextMenu(for: $0) }
                    )
                }

                Spacer(minLength: Self.sectionSpacing)
            }
            // Freeze the whole layout at its pre-open width while the panel
            // is open — the panel covers the trailing edge. The outer frame's
            // EXPLICIT minWidth 0 stops the fixed width from propagating up
            // as a window minimum (AppKit grew the window without it), and
            // .leading stops the vertical ScrollView from centering the
            // oversized child (which cropped both edges equally).
            .frame(width: lockedWidth, alignment: .leading)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            contentWidth = newWidth
            // Mounted (or window-resized) under a settled open panel: no
            // toggle captured a lock, so rebuild the full column width the
            // open would have frozen — hero full-size, panel covering it.
            if friendsPanelOpen && !panelSliding && panelWidth > 0 {
                lockedWidth = newWidth + panelWidth
            }
        }
        .onChange(of: friendsPanelOpen) { _, open in
            panelTransitionGeneration += 1
            let generation = panelTransitionGeneration
            panelSliding = true
            if open, lockedWidth == nil {
                // Capture BEFORE the layout pass shrinks the column (onChange
                // fires on the env flip, while contentWidth still holds the
                // full-width measurement). A reopen mid-close keeps the
                // existing lock — contentWidth is intermediate right now.
                lockedWidth = contentWidth
            }
            // Keep the layout frozen through the close slide — it is
            // already the final full-width layout, so the panel simply
            // reveals it with zero per-frame re-layout. Release the lock
            // (a visual no-op) once the animation is done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard generation == panelTransitionGeneration else { return }
                panelSliding = false
                if !open { lockedWidth = nil }
            }
        }
    }

    // MARK: - Update Banner

    private var updateBannerMessage: String {
        if updateChecker.hasUpdate, let v = updateChecker.availableVersion {
            let clean = v.hasPrefix("v") ? String(v.dropFirst()) : v
            if updateChecker.hasEngineUpdate {
                return "Meridian \(clean) + a new Wine engine are available."
            }
            return "Meridian \(clean) is available."
        }
        if updateChecker.hasEngineUpdate, let e = updateChecker.availableEngineTag {
            var clean = e.hasPrefix("v") ? String(e.dropFirst()) : e
            if clean.hasSuffix("-engine") { clean = String(clean.dropLast(7)) }
            return "Wine Engine \(clean) is available."
        }
        return "An update is available."
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading your library…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Friend Activity

    private var friendActivitySection: some View {
        let topFriends = Array(library.friendSummaries.prefix(15))
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Friends")
                .padding(.leading, leadingInset)
                .padding(.bottom, 12)

            ScrollView(.horizontal) {
                LazyHStack(spacing: CardLayoutMetrics.spacing) {
                    ForEach(topFriends) { friend in
                        FriendCard(friend: friend)
                    }
                }
                .padding(.bottom, 4)
            }
            .contentMargins(.leading, leadingInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func gameState(for game: Game) -> GameCardState {
        guard launcher.activeAppID == game.id else {
            return game.isInstalled ? .idle : .notInstalled
        }
        switch launcher.launchState {
        case .downloading, .installing:
            return .downloading(progress: launcher.downloadProgress)
        case .launching:
            return .launching
        case .running:
            return .running
        case .stopping:
            return .stopping
        default:
            return game.isInstalled ? .idle : .notInstalled
        }
    }

    @ViewBuilder
    private func gameContextMenu(for game: Game) -> some View {
        Button {
            library.toggleFavorite(appID: game.id)
        } label: {
            Label(
                library.isFavorite(appID: game.id) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: library.isFavorite(appID: game.id) ? "heart.slash" : "heart"
            )
        }
        Divider()
        Button {
            selectedGame = game
        } label: {
            Label("View Details", systemImage: "info.circle")
        }
        Divider()
        Button(role: .destructive) {
            library.hideGame(appID: game.id)
        } label: {
            Label("Hide Game", systemImage: "eye.slash")
        }
    }
}

// MARK: - Hero Carousel

/// Horizontal, swipeable hero pager. One continuous `position` (in pages,
/// unbounded — the game is `position mod count`, so it wraps forever) drives
/// every layer through an Animatable parallax: the logo travels furthest and
/// so leaves/arrives first, then the subtitle, then the button, while the art
/// slides a fraction and crossfades — a cascade that is a function of
/// POSITION, so a trackpad swipe, an arrow click and the auto-advance all
/// produce the exact same motion. Owns its timer and gesture state so the
/// per-frame value never re-evaluates HomeView's body.
private struct HeroCarousel: View {
    let games: [Game]
    let heroInset: CGFloat
    let coverWidth: CGFloat
    let onSelect: (Game) -> Void

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(SteamAuthService.self) private var steamAuth

    /// Continuous page position. Whole numbers are resting pages.
    @State private var position: CGFloat = 0
    @State private var frame: CGRect = .zero
    @State private var timer: Timer?
    @State private var wheel = HeroWheelGesture()
    @State private var prefetch = DetailPrefetch()
    /// A cursor over the hero means the user is reading it: auto-advance
    /// waits, and gets a full interval again once the cursor leaves.
    @State private var isHovered = false

    /// Auto-advance cadence — long enough to read the hero, short enough that
    /// the row feels alive.
    private static let interval: TimeInterval = 20
    /// Page spring: flung (initial kick) with a hint of settle — snappy, not
    /// floaty. Swipe releases build their own spring from the fling velocity.
    private static let page = Animation.interpolatingSpring(duration: 0.45, bounce: 0.12, initialVelocity: 2.5)

    // Parallax rates (widths travelled per page) — the cascade order. The
    // art itself doesn't travel: two banners sliding past each other read as
    // a hard seam, and the sidebar extension went black where neither
    // covered. It dissolves in place instead.
    private static let logoRate: CGFloat = 1.25
    private static let subtitleRate: CGFloat = 0.95
    private static let buttonRate: CGFloat = 0.72

    private var count: Int { games.count }
    private var current: Int { Int(position.rounded()) }
    private var currentIndex: Int { wrapped(current) }
    /// Resting page ± 1 stay mounted so the neighbours are already loaded
    /// when a swipe starts, and the outgoing page rides out under animation.
    private var mountedPages: [Int] { count > 1 ? [current - 1, current, current + 1] : [current] }

    private func wrapped(_ page: Int) -> Int { ((page % count) + count) % count }
    private func game(at page: Int) -> Game { games[wrapped(page)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(mountedPages, id: \.self) { page in
                let g = game(at: page)
                HeroBannerImage(urls: g.newCDNHeroURLs + [g.heroURL] + g.heroURLFallbacks)
                    .id(g.id)
                    .applyBackgroundExtension()
                    .modifier(HeroPageLayer(position: position, page: page, width: frame.width, dissolve: true))
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .init(x: 0.5, y: 0.3),
                endPoint: .bottom
            )

            ForEach(mountedPages, id: \.self) { page in
                caption(for: game(at: page), page: page)
            }

            if count > 1 {
                VStack {
                    Spacer()
                    indicators
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
                // Re-center the page dots within the VISIBLE strip while the
                // friends panel covers the trailing edge (they're laid out in
                // the full locked hero width, so without this they sit
                // off-center between the sidebar and the panel).
                .offset(x: -coverWidth / 2)
            }
        }
        .overlay(alignment: .leading) {
            if count > 1 {
                ChevronNavButton(direction: .back, isVisible: true) { go(-1) }
                    // Centre the button within the leading-inset strip.
                    .padding(.leading, max(0, (heroInset - 24) / 2))
            }
        }
        .overlay(alignment: .trailing) {
            if count > 1 {
                ChevronNavButton(direction: .forward, isVisible: true) { go(1) }
                    // Shift inward past the friends panel so the chevron stays
                    // visible at the panel edge, mirroring the leading side.
                    .padding(.trailing, max(0, (heroInset - 24) / 2) + coverWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 302)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !isHovered else { return }
                isHovered = true
                timer?.invalidate()
                prefetchCurrent()
            case .ended:
                isHovered = false
                prefetch.cancel()
                restartTimer()
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onAppear {
            startTimer()
            wheel.install(.init(
                isInside: { point in frame.contains(point) },
                drag: { dx in drag(by: dx) },
                release: { velocity in settle(pointVelocity: velocity) },
                step: { dir in go(dir) }
            ))
        }
        .onDisappear {
            timer?.invalidate()
            wheel.remove()
        }
        .onChange(of: count) { _, _ in restartTimer() }
    }

    // MARK: Layers

    // ── Logo / subtitle / button ────────────────────────────────────────────────────
    // Metrics unchanged from the dissolve-era layout (user-specified):
    //   .padding(.bottom, 26.75)   button bottom from banner bottom
    //   Spacer().frame(height: 15.5)   subtitle bottom to button top
    // Each tier is its own parallax layer so the cascade can stagger them.
    @ViewBuilder
    private func caption(for g: Game, page: Int) -> some View {
        let w = frame.width

        HeroLogoImage(
            urls: g.newCDNLogoURLs + [g.logoURL] + g.logoURLFallbacks,
            fallbackName: g.name
        )
        .padding(.leading, heroInset)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .id(g.id)
        .modifier(HeroPageLayer(position: position, page: page, width: w, rate: Self.logoRate, fade: 1.6))

        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text(Self.subtitle(for: g))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .modifier(HeroPageLayer(position: position, page: page, width: w, rate: Self.subtitleRate, fade: 1.6))
            Spacer().frame(height: 15.5)
            Button {
                onSelect(g)
            } label: {
                Label("Continue Playing", systemImage: "play.fill")
                    .font(.headline)
                    .frame(minWidth: 140, minHeight: 24)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .modifier(HeroGlassCapsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(controlActiveState == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            // No hover modifier on the glass button itself: one on top of the
            // interactive glass rasterised its label (jagged text in light
            // mode). Prefetch rides the hero-level hover instead.
            .modifier(HeroPageLayer(position: position, page: page, width: w, rate: Self.buttonRate, fade: 1.6))
        }
        .padding(.leading, heroInset)
        .padding(.trailing, 24)
        .padding(.bottom, 26.75)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .id(g.id)
    }

    private var indicators: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == currentIndex ? 1.0 : 0.4))
                    .frame(width: 6, height: 6)
                    .onTapGesture { jump(to: i) }
            }
        }
        .padding(.vertical, 4)
    }

    private static func subtitle(for game: Game) -> String {
        let time = game.playtime2WeekFormatted ?? game.playtimeFormatted
        let qualifier = game.playtime2WeekFormatted != nil ? "in the last two weeks" : "recently"
        return "You've played \(game.name) for \(time) \(qualifier)."
    }

    // MARK: Navigation

    private func go(_ direction: Int) {
        guard count > 1 else { return }
        withAnimation(Self.page) { position = CGFloat(current + direction) }
        restartTimer()
    }

    /// Indicator tap: shortest wrapped path to the page.
    private func jump(to index: Int) {
        guard count > 1 else { return }
        var delta = index - currentIndex
        if delta > count / 2 { delta -= count } else if delta < -count / 2 { delta += count }
        withAnimation(Self.page) { position = CGFloat(current + delta) }
        restartTimer()
    }

    /// Trackpad finger-down: content tracks the fingers 1:1 (no animation).
    private func drag(by dx: CGFloat) {
        guard count > 1, frame.width > 0 else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { position -= dx / frame.width }
        timer?.invalidate()
    }

    /// Fingers up: snap to the nearest page, letting a fling carry into the
    /// next one; the spring inherits the release velocity so there's no seam
    /// between the finger's motion and the settle.
    private func settle(pointVelocity: CGFloat) {
        guard count > 1, frame.width > 0 else { return }
        let velocity = pointVelocity / frame.width   // pages per second
        let carry = min(max(velocity * 0.12, -0.6), 0.6)
        let nearest = position.rounded()
        var target = (position + carry).rounded()
        target = min(max(target, nearest - 1), nearest + 1)
        let distance = target - position
        // Relative initial velocity (per SwiftUI): fraction of the remaining
        // distance per second, positive toward the target.
        let kick = abs(distance) > 0.001 ? min(max(velocity / distance, 0), 8) : 0
        withAnimation(.interpolatingSpring(duration: 0.42, bounce: 0.14, initialVelocity: kick)) {
            position = target
        }
        restartTimer()
    }

    private func startTimer() {
        guard count > 1, !isHovered else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in
                guard count > 1 else { return }
                withAnimation(Self.page) { position = CGFloat(current + 1) }
            }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        startTimer()
        // Paging while hovered: the likely click target is the new page.
        if isHovered { prefetchCurrent() }
    }

    private func prefetchCurrent() {
        guard count > 0 else { return }
        prefetch.cancel()
        prefetch.begin(appID: game(at: current).id, auth: steamAuth)
    }
}

/// One hero layer's motion. `rel` = pages this layer's page sits from the
/// current position (0 = centred).
/// • Parallax: travel = rel × width × rate, so a higher rate leaves/arrives
///   first; opacity falls off per page by `fade`.
/// • Dissolve (art): no travel. The LOWER of the two pages in view stays
///   opaque underneath while the upper one fades — a true dissolve with no
///   mid-fade brightness dip, and something is always behind the sidebar
///   extension. Relies on pages being stacked in ascending order.
/// Pure compositing (offset + alpha) — no layout per frame.
private struct HeroPageLayer: ViewModifier, Animatable {
    var position: CGFloat
    let page: Int
    let width: CGFloat
    var rate: CGFloat = 0
    var fade: CGFloat = 1
    var dissolve = false

    nonisolated var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let rel = CGFloat(page) - position
        content
            .offset(x: dissolve ? 0 : rel * width * rate)
            .opacity(opacity(rel: rel))
            .allowsHitTesting(abs(rel) < 0.5)
    }

    private func opacity(rel: CGFloat) -> CGFloat {
        if dissolve {
            return page == Int(floor(position)) ? 1 : max(0, 1 - abs(rel))
        }
        return max(0, 1 - abs(rel) * fade)
    }
}

/// Horizontal scroll-wheel/trackpad handling for the hero. A local event
/// monitor (not an NSView in the hierarchy) so SwiftUI hit-testing for the
/// hero's buttons is untouched. A gesture locks to the axis of its first
/// movement; horizontal gestures over the hero are consumed (Home's vertical
/// scroll view never sees them), everything else passes straight through.
@MainActor
final class HeroWheelGesture {
    struct Handlers {
        var isInside: (CGPoint) -> Bool
        var drag: (CGFloat) -> Void
        var release: (CGFloat) -> Void
        var step: (Int) -> Void
    }

    private var monitor: Any?
    private var handlers: Handlers?
    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var startedInside = false
    private var consumeMomentum = false
    private var velocity: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0
    private var lastStep: TimeInterval = 0

    func install(_ handlers: Handlers) {
        remove()
        self.handlers = handlers
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            // Monitors run on the main thread; assumeIsolated's result must be
            // Sendable, hence the Bool round-trip rather than returning the event.
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handlers = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ e: NSEvent) -> Bool {
        guard let h = handlers, let content = e.window?.contentView else { return false }
        // SwiftUI's .global space is the window content view, y-down.
        let p = e.locationInWindow
        let inside = h.isInside(CGPoint(x: p.x, y: content.bounds.height - p.y))

        // Legacy wheel (no gesture phases): each notch is a discrete page.
        if e.phase.isEmpty && e.momentumPhase.isEmpty {
            guard inside, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), abs(e.scrollingDeltaX) >= 1 else { return false }
            if e.timestamp - lastStep > 0.35 {
                lastStep = e.timestamp
                h.step(e.scrollingDeltaX < 0 ? 1 : -1)
            }
            return true
        }

        if !e.momentumPhase.isEmpty {
            // We snap ourselves; swallow the system's momentum for our gesture.
            return consumeMomentum
        }

        if e.phase.contains(.began) {
            axis = .undecided
            velocity = 0
            startedInside = inside
            consumeMomentum = false
            lastTimestamp = e.timestamp
            // Let the outer scroll view see began/ended pairs regardless.
            return false
        }

        if e.phase.contains(.changed) {
            guard startedInside else { return false }
            if axis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                guard dx + dy > 0 else { return false }
                axis = dx > dy ? .horizontal : .vertical
            }
            guard axis == .horizontal else { return false }
            let dt = max(e.timestamp - lastTimestamp, 1.0 / 240)
            lastTimestamp = e.timestamp
            // Points/s, sign flipped: content moves against the fingers.
            let v = -e.scrollingDeltaX / dt
            velocity = velocity * 0.5 + v * 0.5
            h.drag(e.scrollingDeltaX)
            return true
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            if axis == .horizontal {
                consumeMomentum = true
                h.release(velocity)
            }
            axis = .undecided
            startedInside = false
            return false
        }
        return false
    }
}

// MARK: - Hero Glass Capsule

/// Liquid Glass capsule on macOS 26 (interactive, tracks the system
/// transparency/Reduce Transparency setting); frosted-material fallback
/// on earlier systems.
private struct HeroGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            }
        }
    }
}

// MARK: - Tahoe TV App Snap-Scroll Row

private struct GameScrollRow<MenuContent: View>: View {
    let title: String
    let games: [Game]
    /// Layout width supplied by HomeView — the frozen pre-open width while
    /// the friends panel is open, live width otherwise. NOT self-measured
    /// geometry, so the row never chases animated frames.
    let layoutWidth: CGFloat
    /// Trailing width covered by the friends panel — the forward chevron
    /// shifts inward by this amount to stay visible at the panel edge.
    var trailingObscured: CGFloat = 0
    let selectedGameID: Int?
    let isFavorite: (Int) -> Bool
    var showFavoriteBadge: Bool = true
    let gameState: (Game) -> GameCardState
    let onSelect: (Game) -> Void
    @ViewBuilder let contextMenu: (Game) -> MenuContent

    @State private var isRowHovered = false
    @State private var isBackButtonHovered = false
    @State private var isForwardButtonHovered = false
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var currentIndex = 0
    /// Records when the last programmatic scroll was triggered. Any `.idle`
    /// phase within 0.5 s of a button tap is ignored — this covers both the
    /// primary animation settling and the subsequent viewAligned micro-correction
    /// that fires a second idle, which was overwriting currentIndex with the
    /// wrong card on rapid taps.
    @State private var programmaticScrollTime: Date = .distantPast

    private var metrics: CardLayoutMetrics {
        // Home rows step 3…5 columns (user direction July 12 2026): cards
        // resize naturally within a step; the window growing adds a column
        // (5 max) with the next card's peek slice always showing.
        CardLayoutMetrics.compute(for: layoutWidth, maxCards: 5)
    }

    private var canScrollBack: Bool { currentIndex > 0 }
    private var canScrollForward: Bool { currentIndex < games.count - metrics.visibleCount }

    private var backVisible: Bool { (isRowHovered || isBackButtonHovered) && canScrollBack }
    private var forwardVisible: Bool { (isRowHovered || isForwardButtonHovered) && canScrollForward }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section title aligns with the leading edge of the first card.
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.leading, metrics.leadingPadding)
                .padding(.bottom, 14)

            // ScrollViewReader.proxy.scrollTo drives animation directly through
            // the scroll view's internal renderer — this is the only reliable
            // path for smooth programmatic scrolling on macOS. ScrollPosition
            // .scrollTo(id:) cannot be trusted to animate inside withAnimation
            // on macOS; it fires an instant jump that viewAligned then
            // corrects, producing the skip/backwards artifacts.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CardLayoutMetrics.spacing) {
                        ForEach(games) { game in
                            GameGridView(
                                game: game,
                                isSelected: selectedGameID == game.id,
                                isFavorite: isFavorite(game.id),
                                showFavoriteBadge: showFavoriteBadge,
                                gameState: gameState(game)
                            )
                            .frame(width: metrics.cardWidth)
                            .id(game.id)
                            .onTapGesture { onSelect(game) }
                            .contextMenu { contextMenu(game) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 8)
                }
                // Use contentMargins (not inner LazyHStack padding) so the
                // leading inset becomes the scroll view's snap anchor. This
                // makes scroll offset 0 a valid snap position that shows the
                // first card at leadingPadding from the left, and causes the
                // previous card to peek by exactly peekFraction×cardWidth on
                // the left edge when scrolled forward — matching TV app.
                .contentMargins(.leading, metrics.leadingPadding, for: .scrollContent)
                .contentMargins(.trailing, metrics.leadingPadding, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .scrollPosition($scrollPosition)
                // Only sync currentIndex from user drags once the scroll is
                // fully at rest AND outside the debounce window. The 0.5 s
                // guard covers both the primary animation (0.3 s) and the
                // viewAligned micro-correction idle that fires right after —
                // the old boolean flag cleared on that first idle, letting the
                // second idle overwrite currentIndex with the wrong card.
                .onScrollPhaseChange { _, new in
                    guard new == .idle else { return }
                    guard Date().timeIntervalSince(programmaticScrollTime) > 0.5 else { return }
                    if let id = scrollPosition.viewID(type: Int.self),
                       let idx = games.firstIndex(where: { $0.id == id }) {
                        currentIndex = idx
                    }
                }
                .overlay(alignment: .leading) {
                    ChevronNavButton(
                        direction: .back,
                        isVisible: backVisible,
                        action: {
                            guard !games.isEmpty else { return }
                            programmaticScrollTime = Date()
                            let target = max(0, currentIndex - 1)
                            currentIndex = target
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(games[target].id, anchor: .leading)
                            }
                        },
                        showMaterial: isRowHovered,
                        onHoverChanged: { isBackButtonHovered = $0 }
                    )
                    .padding(.leading, 10)
                    // Offset upward so the arrow is centred on the card art
                    // rather than the full card height (art + label + padding).
                    .offset(y: -22)
                }
                .overlay(alignment: .trailing) {
                    ChevronNavButton(
                        direction: .forward,
                        isVisible: forwardVisible,
                        action: {
                            guard !games.isEmpty else { return }
                            programmaticScrollTime = Date()
                            let target = min(games.count - 1, currentIndex + 1)
                            currentIndex = target
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(games[target].id, anchor: .leading)
                            }
                        },
                        showMaterial: isRowHovered,
                        onHoverChanged: { isForwardButtonHovered = $0 }
                    )
                    // Extra inset keeps the chevron visible at the friends
                    // panel edge, mirroring the leading side.
                    .padding(.trailing, 10 + trailingObscured)
                    .offset(y: -22)
                }
            }
        }
        // onContinuousHover fires ONLY on actual cursor movement, never during
        // view re-renders. onHover (NSTrackingArea) fires spurious mouseExited
        // every time a re-render occurs — and proxy.scrollTo causes one per
        // animation frame (60 fps). That cascading spurious false was setting
        // isRowHovered = false mid-animation, collapsing backVisible and
        // forwardVisible and making buttons permanently disappear.
        .onContinuousHover { phase in
            switch phase {
            case .active: isRowHovered = true
            case .ended:  isRowHovered = false
            }
        }
    }
}

// MARK: - Shared Chevron Navigation Button

/// A rounded-rect chevron button used in both the hero carousel and GameScrollRow.
/// Pass showMaterial: true (driven by row-level hover) for scroll rows so the
/// background appears the instant the row is hovered — matching the icon visibility.
/// Leave it at the default false for the hero carousel, where the material should
/// only appear when the cursor is directly over the button.
private struct ChevronNavButton: View {
    enum Direction { case back, forward }

    let direction: Direction
    let isVisible: Bool
    let action: () -> Void
    /// When true, the material background is shown whenever the button is visible,
    /// not just when the cursor is directly over the button. Used by GameScrollRow
    /// so hovering anywhere in the row shows the full button (icon + material).
    var showMaterial: Bool = false
    /// Called immediately (no animation) when the cursor enters or exits the button.
    /// Used by the parent to keep itself visible while the cursor is over an
    /// offset button that lies outside the parent's layout frame.
    var onHoverChanged: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        Button {
            // Re-assert hover so material stays visible at the moment of the
            // click, before onContinuousHover has a chance to re-evaluate.
            isHovered = true
            onHoverChanged?(true)
            action()
        } label: {
            Image(systemName: direction == .back ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                // Frame and contentShape must be INSIDE the label so the button
                // uses them for its own hit testing. When placed outside the
                // button (as view modifiers after .buttonStyle(.plain)), they
                // apply to a wrapper view — the button's internal hit area
                // remains the tiny chevron glyph (~12×16pt). Inside the label,
                // the full 24×44 rounded rect becomes the click target.
                .frame(width: 24, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                .opacity(isHovered || showMaterial ? 1 : 0)
        }
        // onContinuousHover fires .ended only on a genuine cursor exit, never
        // on view re-renders. The old onHover (NSTrackingArea) approach used a
        // debounce to suppress the spurious mouseExited AppKit fires during
        // animation, but that debounce was swallowing the real exit event too —
        // leaving the material stuck on after the cursor had already left.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
                onHoverChanged?(true)
            case .ended:
                isHovered = false
                onHoverChanged?(false)
            }
        }
        // Never block hit testing even when invisible. If allowsHitTesting were
        // tied to isVisible, a stale hover state (e.g. after switching tabs)
        // creates a deadlock: the button is non-hittable so the cursor can never
        // hover it to make isRowHovered/isBackButtonHovered true again.
        .opacity(isVisible ? 1 : 0)
    }
}

// MARK: - Friend Card

private struct FriendCard: View {
    let friend: PlayerSummary

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var avatarImage: NSImage?
    @State private var showingDetail = false

    private static let cardWidth: CGFloat = 180
    private static let cornerRadius: CGFloat = 10

    private var highlightOffset: UnitPoint {
        guard isHovered else { return .center }
        return UnitPoint(
            x: hoverLocation.x / Self.cardWidth,
            y: hoverLocation.y / 56
        )
    }

    var body: some View {
        Button { showingDetail.toggle() } label: { card }
            .buttonStyle(.pressable)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .shadow(
                color: .black.opacity(isHovered ? 0.25 : 0.0),
                radius: isHovered ? 12 : 0,
                y: isHovered ? 6 : 0
            )
            .animation(.smooth(duration: 0.15), value: isHovered)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    isHovered = true
                case .ended:
                    isHovered = false
                }
            }
            .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                FriendDetailPopover(friend: friend)
            }
            .task { await loadAvatar() }
    }

    private var card: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                avatarView
                    .frame(width: 36, height: 36)

                if friend.isOnline || friend.isInGame {
                    // Discord-style state colors: in-game green, online blue,
                    // away/snooze yellow, busy red (PlayerSummary.statusColor).
                    Circle()
                        .fill(friend.statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1.5)
                        )
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(friend.personaName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(friend.isInGame ? .green : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.cardWidth)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(isHovered ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.12), .clear],
                        center: highlightOffset,
                        startRadius: 0,
                        endRadius: Self.cardWidth * 0.8
                    )
                )
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
        }
        // Inside the button label so the whole card is the click target.
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    @ViewBuilder
    private var avatarView: some View {
        if let image = avatarImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var statusText: String {
        if let game = friend.gameExtraInfo, !game.isEmpty {
            return game
        }
        // "Online" / "Away" / "Busy" / "Snooze" etc. — real persona state.
        if friend.isOnline { return friend.personaStateText }
        if let date = friend.lastLogoffDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: .now)
        }
        return "Offline"
    }

    private func loadAvatar() async {
        guard let url = friend.avatarMediumURL else { return }

        if let cached = await ImageCache.shared.imageAsync(for: url) {
            avatarImage = cached
            return
        }

        do {
            let (data, response) = try await URLSession.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let nsImage = await ImageCache.decode(data) else { return }
            ImageCache.shared.store(nsImage, for: url, rawData: data)
            avatarImage = nsImage
        } catch {}
    }
}

#Preview {
    HomeView(selectedGame: .constant(nil))
        .environment(SteamAuthService())
        .environment(SteamLibraryStore())
        .environment(Launcher())
        .environment(AppUpdateChecker())
        .frame(width: 900, height: 800)
}
