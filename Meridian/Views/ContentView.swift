import SwiftUI
import AppKit

// MARK: - Sidebar Navigation

enum SidebarDestination: Hashable {
    case home
    case library(SteamLibraryStore.LibraryFilter)
    case search
    case steamProfile
    case steamStore
    case category(UUID)
}

struct ContentView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(WineEngine.self) private var engine
    @Environment(SteamSession.self) private var session
    @Environment(Launcher.self) private var launcher
    @Environment(BootstrapManager.self) private var bootstrap
    @Environment(CategoryStore.self) private var categoryStore
    @Environment(SteamWindow.self) private var steamWindow
    @Environment(\.openSettings) private var openSettings
    @State private var selectedGame: Game?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarDestination: SidebarDestination = .home
    @State private var hasAnimatedToFullSize = false
    @State private var splashVisible = true
    /// Starts false so SwiftUI observes the false→true transition that triggers
    /// sheet presentation. Set to true from `.onAppear` on mainContent.
    @State private var showSetupSheet = false
    /// Guards the onAppear setup check so it runs exactly once per app session.
    @State private var hasCheckedSetup = false
    @State private var showingDownloadsPopover = false
    @State private var showFriendsPanel = false
    /// Feature flag (Developer › Feature Flags). Off: no toolbar button, the
    /// inspector can never open. Everything else about the panel stays wired
    /// so flipping it on needs no relaunch.
    @AppStorage(wrappedValue: false, FeatureFlag.friendsPanel.defaultsKey) private var friendsPanelEnabled
    /// Detail-column width measured while the panel is CLOSED (the frozen
    /// full-width layout the panel will cover).
    @State private var detailFullWidth: CGFloat = 0
    /// `friendsPanelWidth` captured at the moment the panel opens. The
    /// inspector is pinned to THIS, not the live computation: during the
    /// close slide `detailFullWidth` is re-measured every frame (the panel is
    /// already "closed"), and a per-frame retarget of the pinned column width
    /// fought the slide.
    @State private var friendsPanelOpenWidth: CGFloat = 280

    // Card ↔ detail zoom (see DetailTransition.swift).
    /// The zoom currently in flight, if any (nil once settled either way).
    @State private var zoom: DetailZoom?
    /// 0 = library at rest, 1 = detail page at rest. The ONE animated value;
    /// root recede, page reveal and ghost all derive from it.
    @State private var zoomProgress: CGFloat = 0
    /// Library dissolve, 0 = visible, 1 = gone. Driven by its own ease-in-out
    /// clock matched to the flight's duration — NOT by `zoomProgress`: the
    /// kicked spring covers most of its distance in the first frames, and a
    /// fade slaved to it snapped the library to the window background before
    /// the rect had grown enough to cover it (user: "jarring", 2026-09-10).
    @State private var rootFade: Double = 0
    /// Set by `openDetail`, consumed by the page's `onAppear`: the flight
    /// starts only once the page has committed at progress 0, so its
    /// Animatable modifier has a frame to interpolate from (and the page's
    /// mount cost lands before the motion, never inside it).
    @State private var pendingOpen = false
    /// Which page owns the toolbar + title. Flips at the START of each zoom
    /// (true on open, false on close) so the chrome hands over the instant
    /// the motion begins, as on iOS — not when the page finally unmounts.
    @State private var detailChrome = false
    /// Close landing: the card already shows its own art while the ghost
    /// fades off it (the source-hide is lifted, ghost alpha → 0).
    @State private var landing = false
    @State private var ghostOpacity: Double = 1
    /// Stage (detail column content area) size — the zoom's large end.
    @State private var stageSize: CGSize = .zero
    /// Bumped per flight so a stale completion/watchdog can't touch a newer one.
    @State private var zoomGeneration = 0
    /// Bumped per OPEN only. Identity of the page + ghost layers, so an open
    /// that interrupts a close gets fresh Animatable state and plays from the
    /// card (progress 0) — not from wherever the close's presentation value
    /// was. iOS does the same: the closing app is cut off, the new one opens
    /// in full. The root can't be re-identified (it would remount Home), so
    /// its fade simply continues from its current alpha.
    @State private var openGeneration = 0

    // Browser-style history (see the Navigation history section).
    @State private var history: [NavEntry] = [NavEntry(destination: .home, game: nil)]
    @State private var historyIndex = 0
    /// True while back/forward applies an entry, so the resulting open/close/
    /// sidebar change isn't recorded as a new visit.
    @State private var applyingHistory = false
    /// Sidebar change made by history replay; its (asynchronous) onChange
    /// must not record it.
    @State private var historyDestination: SidebarDestination?
    @State private var navButtons = NavButtonMonitor()

    /// Friends panel width, derived from the frozen Home layout: the panel's
    /// leading edge lands exactly at the row's natural "3 full cards + the
    /// standard trailing peek of the 4th" boundary — the same edge treatment
    /// the row has at the window edge when the panel is closed. Nothing in
    /// the content ever moves or resizes; the panel is sized to make the
    /// covered state look native (user direction July 12 2026).
    private var friendsPanelWidth: CGFloat {
        let w = detailFullWidth
        guard w > 400 else { return 280 }
        // Same 3…5 clamp as the Home rows so the panel edge math matches
        // the actual row layout.
        let m = CardLayoutMetrics.compute(for: w, maxCards: 5)
        let cardStep = m.cardWidth + CardLayoutMetrics.spacing
        let peek = CardLayoutMetrics.peekFraction * m.cardWidth
        let minPanel: CGFloat = 240
        // Most full cards we can keep visible while leaving >= minPanel for
        // the panel (3 at the default window size; scales up on wide windows).
        let k = max(3, Int(floor((w - minPanel - m.leadingPadding - peek) / cardStep)))
        let visible = m.leadingPadding + CGFloat(k) * cardStep + peek
        return max(w - visible, minPanel)
    }

    var body: some View {
        Group {
            // Bootstrap always runs first — engine download, prefix creation,
            // Steam installation. No pre-screen for new users; Meridian's splash
            // is the first thing they see.
            if splashVisible {
                SplashView()
                    .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
                    .overlay(alignment: .top) {
                        if let title = steamWindow.actionableDialogTitle {
                            SteamConfirmationBanner(title: title)
                                .padding(.top, 10)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.smooth(duration: 0.2), value: steamWindow.actionableDialogTitle)
                    .task {
                        await library.refresh(steamID: steamAuth.steamID, apiKey: steamAuth.apiKey)
                    }
                    .onAppear {
                        guard !hasCheckedSetup else { return }
                        hasCheckedSetup = true
                        // The sign-in sheet is for genuine missing state: no
                        // identity, or no Web API key. It is NOT gated on
                        // `session.isReady` (steam.exe silent auto-login).
                        //
                        // Steam is now DRM-only: installs run headlessly via
                        // DepotDownloader and DRM-free games launch directly,
                        // both using the persisted OAuth refresh_token — which
                        // works even when Wine's steam.exe silent auto-login
                        // does not (Pattern 6). Forcing re-auth here meant a
                        // returning user was asked to sign in on every launch
                        // despite having a perfectly valid session. DRM-game
                        // launches gate on Steam readiness at launch time with
                        // a clear message; if the refresh_token is genuinely
                        // expired, the install/launch path surfaces that and
                        // routes the user back here to re-auth.
                        if !steamAuth.isAuthenticated || steamAuth.needsAPIKey {
                            showSetupSheet = true
                        }
                    }
                    .sheet(isPresented: $showSetupSheet) {
                        SetupSheet()
                            .interactiveDismissDisabled()
                    }
            }
        }
        .onChange(of: bootstrap.isReady) { _, ready in
            if ready && !hasAnimatedToFullSize {
                hasAnimatedToFullSize = true
                NotificationCenter.default.post(name: .meridianBootstrapReady, object: nil)
                // The splash's own content has already faded (SplashView
                // `isExiting`); hand off to the main content only once the
                // window resize has landed, as a crossfade — mounting it
                // mid-resize was the hitch.
                DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.launchResizeDuration) {
                    withAnimation(.easeOut(duration: 0.35)) {
                        splashVisible = false
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meridianOpenSettings)) { _ in
            openSettings()
        }
        // Re-show the setup sheet whenever the user signs out — the .onAppear
        // check on mainContent only fires once at bootstrap. Without this,
        // signing out in Settings leaves the app with no way to sign back in
        // until a full restart.
        //
        // On sign-IN, refresh the library: mainContent's one-shot .task fired
        // before authentication completed (empty steamID → refresh skipped),
        // and the API-key step's own refresh only runs when that step is
        // actually shown. A user signing in with a key already stored would
        // otherwise land on an empty library until the next app restart.
        .onChange(of: steamAuth.isAuthenticated) { _, authenticated in
            if authenticated {
                Task { await library.refresh(steamID: steamAuth.steamID, apiKey: steamAuth.apiKey) }
            } else {
                showSetupSheet = true
            }
        }
        // NOTE: deliberately NOT re-showing the sheet when `session.isReady`
        // flips false. steam.exe silent auto-login failing (Pattern 6) is no
        // longer a re-auth trigger — the app stays usable (headless installs +
        // direct launch) on the persisted refresh_token. Re-auth is surfaced
        // by the install/launch path only when an operation actually needs a
        // token that turns out to be expired (fail-fast at the point of use).
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedDestination: $sidebarDestination)
                // Default AND minimum = 1/6 of the 1016 pt default window,
                // rounded to the nearest 8 → 168.
                .navigationSplitViewColumnWidth(min: 168, ideal: 168, max: .infinity)
        } detail: {
            NavigationStack {
                stage
                    .navigationTitle(stageTitle)
                    .environment(\.detailFlightSource, zoom?.source(landing: landing))
                    .environment(\.detailPresented, detailChrome)
                    .toolbar {
                        // Root-page chrome only; the detail page brings its own
                        // (back, favourite, more) via its own `.toolbar`.
                        // Items are added/removed by NSToolbar, which draws the
                        // glass bezels itself and doesn't animate them — content
                        // transitions inside stable items were tried (2026-09-10)
                        // and looked half-animated: glyph fading under a bezel
                        // that popped. The system morph needs a NavigationStack
                        // push, which the zoom stage deliberately doesn't do.
                        if !detailChrome {
                            // Flexible space pushes everything after it to the
                            // trailing end — same pattern as GameDetailView.
                            ToolbarItem(placement: .automatic) { Spacer() }
                            ToolbarItem(placement: .automatic) {
                                DownloadsToolbarButton(
                                    launcher: launcher,
                                    library: library,
                                    isPresented: $showingDownloadsPopover,
                                    onSelectGame: { openDetail($0) }
                                )
                            }
                            ToolbarItem(placement: .automatic) {
                                if friendsPanelEnabled {
                                    Button {
                                        // One transaction for the inspector slide AND
                                        // the friendsPanelOpen-driven row re-layout —
                                        // without this the cards snap to their new
                                        // metrics instantly while the panel is still
                                        // sliding, which reads as jank. No bounce:
                                        // a click carries no momentum to overshoot.
                                        if !showFriendsPanel {
                                            friendsPanelOpenWidth = friendsPanelWidth
                                        }
                                        withAnimation(.smooth(duration: 0.28)) {
                                            showFriendsPanel.toggle()
                                        }
                                    } label: {
                                        // Square label frame → macOS renders a perfect
                                        // circle regardless of the glyph's aspect ratio
                                        // (person.2 is wide; without this the pill
                                        // stretches). Plural glyph; outline, no fill.
                                        Image(systemName: "person.2")
                                            .frame(width: 24, height: 24)
                                    }
                                    // No buttonStyle override — macOS supplies the
                                    // toolbar circle / liquid glass, same as Downloads.
                                    .help(showFriendsPanel ? "Hide Friends" : "Show Friends")
                                }
                            }
                        }
                    }
                    // Discord-style trailing friends panel. Standard macOS
                    // inspector behaviour: the window frame never changes —
                    // content compresses in place (Apple Music lyrics-style).
                    // Home's scroll rows read \.friendsPanelOpen and drop to
                    // fewer, full-size cards instead of squeezing all five.
                    .inspector(isPresented: $showFriendsPanel) {
                        FriendsPanel()
                            // Pinned to the computed cover width so the panel
                            // edge lands exactly on the row's natural
                            // 3-cards + peek boundary.
                            .inspectorColumnWidth(
                                min: friendsPanelOpenWidth,
                                ideal: friendsPanelOpenWidth,
                                max: friendsPanelOpenWidth
                            )
                    }
                    .environment(\.friendsPanelOpen, showFriendsPanel)
                    .environment(\.friendsPanelCoverWidth, showFriendsPanel ? friendsPanelOpenWidth : 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                        // Only track while closed — this is the width the
                        // frozen layout (and thus the panel size) is based on.
                        if !showFriendsPanel { detailFullWidth = newWidth }
                    }
                    .onChange(of: friendsPanelEnabled) { _, enabled in
                        if !enabled, showFriendsPanel {
                            withAnimation(.smooth(duration: 0.28)) { showFriendsPanel = false }
                        }
                    }
            }
        }
        .onChange(of: sidebarDestination) { _, newValue in
            if case .library(let filter) = newValue {
                library.filter = filter
            }
            // Dismiss game detail when changing sections — matches standard master–detail behaviour.
            resetDetailTransition()
            if historyDestination == newValue {
                historyDestination = nil
            } else {
                recordVisit(destination: newValue, game: nil)
            }
        }
        .onAppear {
            DetailTransitionRegistry.shared.flightSourceMoved = { cutReturnFlight() }
            navButtons.onBack = { goBack() }
            navButtons.onForward = { goForward() }
        }
    }

    /// The detail column's content: the root page (always mounted, so its
    /// state survives a detail visit) with the game page zooming in over it.
    /// Layer order bottom → top: root (recedes) · page (revealed inside the
    /// zoom rect) · ghost (card art dissolving into the page).
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            StageRoot(destination: sidebarDestination, steamID: steamAuth.steamID) { game in
                if let game { openDetail(game) } else { closeDetail() }
            }
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Inside the recede transform, so card frames stay in resting
                // layout coordinates while the root is scaled.
                .coordinateSpace(name: DetailTransitionRegistry.stageSpace)
                .modifier(DetailStageRecede(fade: rootFade, blurRadius: DetailZoomTuning.shared.params.rootBlurRadius))
                // Only once the root is fully faded — toggling it at flight
                // start snapped Home's under-toolbar backdrop off in a frame.
                .modifier(DetailStageEdgeEffectSuppression(suppressed: selectedGame != nil && zoom == nil))
                // Interactive the moment a close STARTS (target 0), not when it
                // settles — the next click never waits on a spring's tail.
                .allowsHitTesting(zoomProgress == 0)
                .accessibilityHidden(selectedGame != nil)

            if let game = selectedGame {
                GameDetailView(game: game, onDismiss: { closeDetail() },
                               showsToolbar: detailChrome, showsAmbient: zoom == nil)
                    // Next run-loop pass, so the page's (heavy) first frame is
                    // committed before the clock starts — the mount cost
                    // becomes ~1 frame of click latency, never a hitch.
                    // INSIDE `.id`: when one game replaces another in a single
                    // update (open during a close) the `if let` branch persists
                    // and an outer onAppear would never fire — the open would
                    // sit at progress 0 until the watchdog forced it.
                    .onAppear { DispatchQueue.main.async { beginPendingOpen() } }
                    .id(game.id)
                    // Outside `.id(game.id)` so a same-game close → open
                    // retargets in place; inside `.id(openGeneration)` so a
                    // fresh open never inherits a running close.
                    .modifier(DetailZoomReveal(progress: zoomProgress, rootFade: rootFade, zoom: zoom, stageSize: stageSize))
                    // Likewise usable as soon as the open starts (target 1).
                    .allowsHitTesting(zoomProgress == 1)
                    .id(openGeneration)
            }

            DetailZoomGhost(zoom: zoom, progress: zoomProgress, stageSize: stageSize, opacity: ghostOpacity)
                .id(openGeneration)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        // Plain registry write — never invalidates a view.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): DetailTransitionRegistry.shared.pointer = p
            case .ended:         DetailTransitionRegistry.shared.pointer = nil
            }
        }
    }

    /// One title owner for the whole stage. Root and detail are mounted
    /// together mid-flight (and the root stays mounted, hidden, while a game
    /// is open), so per-page `.navigationTitle`s would race — none of the
    /// pages set their own.
    private var stageTitle: String {
        if detailChrome, let game = selectedGame { return game.name }
        switch sidebarDestination {
        case .search:            return "Search"
        case .category(let id):  return categoryStore.category(id: id)?.name ?? ""
        default:                 return ""
        }
    }
}

/// Root of the detail column stage. Equatable on its plain inputs so the
/// stage's own state churn at flight boundaries (zoom, selection, chrome)
/// never re-evaluates Home/Library bodies on the flight's first frame —
/// their own observed stores still update them as usual.
private struct StageRoot: View, Equatable {
    let destination: SidebarDestination
    let steamID: String
    /// nil = close. Never compared; the binding handed to pages reads nil (see
    /// the selection notes on ContentView).
    let select: (Game?) -> Void

    @Environment(SteamLibraryStore.self) private var library
    @Environment(CategoryStore.self) private var categoryStore

    nonisolated static func == (a: StageRoot, b: StageRoot) -> Bool {
        a.destination == b.destination && a.steamID == b.steamID
    }

    private var presentedGame: Binding<Game?> {
        Binding(get: { nil }, set: { select($0) })
    }

    var body: some View {
        switch destination {
        case .home:
            HomeView(selectedGame: presentedGame)
        case .library:
            LibraryView(selectedGame: presentedGame)
        case .search:
            SearchView(selectedGame: presentedGame)
        case .steamProfile:
            if !steamID.isEmpty {
                SteamWebView(url: URL(string: "https://steamcommunity.com/profiles/\(steamID)")!)
            }
        case .steamStore:
            SteamWebView(url: URL(string: "https://store.steampowered.com")!)
        case .category(let id):
            let cat = categoryStore.category(id: id)
            LibraryView(
                selectedGame: presentedGame,
                categoryID: id,
                categoryGames: categoryStore.games(in: id, from: library.games),
                categoryTitle: cat?.name
            )
            .id(id)
        }
    }
}

extension ContentView {

    // MARK: - Card ↔ detail zoom
    //
    // Every entry point (card click, hero button, downloads popover, Esc,
    // Back) routes through openDetail/closeDetail so all get the same motion.
    // The selection binding handed to root pages always reads nil: the root
    // is only ever visible with no game selected or mid-flight, when a
    // selection chevron under the departing/returning art would be wrong.

    // Timings — tuned as physics, not curves (live values: Zoom Tuning window,
    // ⌥⌘Z; defaults in DetailZoomParameters). A real spring released from rest
    // starts with zero velocity (a soft ramp that reads as stiff), so both
    // get an initial kick (in whole-distances/s) as if flung: the rect is
    // already moving on the first frame. Bounce and speed are matched — a
    // livelier wobble needs a faster approach or the landing looks fake. The
    // page breathes past 1:1 on open; on close the art squishes into the card
    // and springs back. Completions use `.removed` so the modifiers are only
    // dropped once the spring has truly settled. Both retarget mid-flight
    // with velocity preserved.
    private var openZoom: Animation {
        let t = DetailZoomTuning.shared.params
        if t.openUsesCurve {
            // Cubic Bézier: x1 pulls the start into an ease-in, (1 - x2) the
            // landing into an ease-out. No overshoot.
            return .timingCurve(t.openEaseIn, 0, 1 - t.openEaseOut, 1, duration: t.openDuration)
        }
        return .interpolatingSpring(duration: t.openDuration, bounce: t.openBounce, initialVelocity: t.openKick)
    }
    private var closeZoom: Animation {
        let t = DetailZoomTuning.shared.params
        return .interpolatingSpring(duration: t.closeDuration, bounce: t.closeBounce, initialVelocity: t.closeKick)
    }
    /// Library dissolve clock: a short ease-in-out on its own timer, so the
    /// background changes smoothly but decisively rather than at the
    /// spring's kicked first frames.
    private var rootFadeAnimation: Animation { .easeInOut(duration: DetailZoomTuning.shared.params.rootFadeDuration) }
    /// Toolbar/title hand-off, animated separately from the un-animated zoom
    /// mount so the items crossfade instead of snapping.
    private var chromeSwap: Animation { .easeInOut(duration: DetailZoomTuning.shared.params.chromeSwap) }

    /// Small end of a zoom for `game`: the on-screen card when there is one
    /// (with its art as the ghost if it's loaded), else a centred inset of
    /// the stage with no ghost — the page just scales up and fades in (hero
    /// button, downloads popover).
    private func makeZoom(for game: Game, resting: Bool = false) -> DetailZoom {
        let stage = CGRect(origin: .zero, size: stageSize)
        if let card = DetailTransitionRegistry.shared.card(for: game.id),
           card.artFrame.width > 0, card.artFrame.intersects(stage) {
            let poster = DetailZoom.posterImage(for: game, card: card)
            return DetailZoom(gameID: game.id,
                              cardRect: resting ? card.artFrame : card.visualArtFrame,
                              poster: poster,
                              sourceLayoutFrame: poster == nil ? nil : card.artFrame)
        }
        let inset = CGFloat(DetailZoomTuning.shared.params.fallbackInset)
        return DetailZoom(gameID: game.id,
                          cardRect: stage.insetBy(dx: stage.width * inset, dy: stage.height * inset),
                          poster: nil,
                          sourceLayoutFrame: nil)
    }

    /// The flight's destination: `zoomProgress` is the MODEL value, which jumps
    /// to the target the instant a flight starts (the modifiers interpolate).
    private var isClosing: Bool { zoom != nil && zoomProgress == 0 && selectedGame != nil }

    /// Open: mount the page at progress 0 (card-sized, under the opaque
    /// ghost) in one un-animated commit; the page's `onAppear` then starts
    /// the flight via `beginPendingOpen`. Never waits on a running close —
    /// that one is finalised on the spot and the new open begins at once.
    private func openDetail(_ game: Game) {
        recordVisit(destination: sidebarDestination, game: game)
        if selectedGame != nil {
            if isClosing {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { selectedGame = nil }
            } else {
                // A detail is already up (Downloads popover): swap in place —
                // the page's `.id(game.id)` re-creates it for the new game.
                if zoom == nil { selectedGame = game }
                return
            }
        }
        guard stageSize.width > 0 else {
            selectedGame = game
            detailChrome = true
            zoomProgress = 1
            rootFade = 1
            return
        }

        zoomGeneration += 1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            openGeneration += 1
            landing = false
            ghostOpacity = 1
            zoomProgress = 0
            zoom = makeZoom(for: game)
            pendingOpen = true
            selectedGame = game
        }
        withAnimation(chromeSwap) { detailChrome = true }
        armZoomWatchdog()
    }

    /// Second half of `openDetail`, run from the page's `onAppear` once it has
    /// committed at progress 0.
    private func beginPendingOpen() {
        guard pendingOpen else { return }
        pendingOpen = false
        let generation = zoomGeneration
        withAnimation(rootFadeAnimation) { rootFade = 1 }
        withAnimation(openZoom, completionCriteria: .removed) {
            zoomProgress = 1
        } completion: {
            guard generation == zoomGeneration else { return }
            zoom = nil
        }
    }

    /// Close: the same zoom in reverse — page shrinks into the card while the
    /// art dissolves back over it and the library comes forward. Works
    /// mid-open too (retargets from the current progress). Once settled, the
    /// card shows its own art and the ghost fades off it (landing crossfade).
    private func closeDetail() {
        guard let game = selectedGame, !isClosing else { return }
        recordVisit(destination: sidebarDestination, game: nil)
        zoomGeneration += 1
        let generation = zoomGeneration
        pendingOpen = false
        landing = false
        ghostOpacity = 1

        // At progress ≈ 1 every zoom renders the full stage, so swapping in
        // the return zoom (fresh card frame) is invisible. The card drops its
        // hover lift the moment it becomes the flight source, so the art must
        // land on the RESTING frame — hover eases back in after the landing.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { zoom = makeZoom(for: game, resting: true) }
        withAnimation(chromeSwap) { detailChrome = false }
        withAnimation(rootFadeAnimation) { rootFade = 0 }

        withAnimation(closeZoom, completionCriteria: .removed) {
            zoomProgress = 0
        } completion: {
            guard generation == zoomGeneration else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                selectedGame = nil
                landing = true
            }
            withAnimation(.easeOut(duration: DetailZoomTuning.shared.params.landingFade)) {
                ghostOpacity = 0
            } completion: {
                guard generation == zoomGeneration else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    zoom = nil
                    landing = false
                    ghostOpacity = 1
                }
            }
        }
        armZoomWatchdog()
    }

    /// Sidebar navigation swaps the root outright — drop any detail and
    /// in-flight motion so the new page appears in its resting state.
    private func resetDetailTransition() {
        zoomGeneration += 1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            pendingOpen = false
            zoom = nil
            zoomProgress = 0
            rootFade = 0
            detailChrome = false
            landing = false
            ghostOpacity = 1
            selectedGame = nil
        }
    }

    /// The card the art is returning to scrolled away (or was recycled) while
    /// the close was still settling/landing. Finish on the spot — the card is
    /// already showing its own art wherever it went; nothing may stay pinned
    /// to the spot it left. Never touches an open (target 1) or a pending one.
    private func cutReturnFlight() {
        guard zoom != nil, zoomProgress == 0, !pendingOpen else { return }
        zoomGeneration += 1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            zoom = nil
            landing = false
            ghostOpacity = 1
            rootFade = 0
            selectedGame = nil
        }
    }

    /// Safety net: if an animation completion ever fails to fire, force the
    /// zoom to whichever resting state it was heading for so the UI can never
    /// be locked mid-flight. Generation-guarded so a later flight is never
    /// clobbered by an earlier watchdog.
    private func armZoomWatchdog() {
        let generation = zoomGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard generation == zoomGeneration, zoom != nil else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                let opening = pendingOpen || zoomProgress > 0.5
                pendingOpen = false
                zoom = nil
                zoomProgress = opening ? 1 : 0
                rootFade = opening ? 1 : 0
                detailChrome = opening
                landing = false
                ghostOpacity = 1
                if !opening { selectedGame = nil }
            }
        }
    }
}

extension ContentView {

    // MARK: - Navigation history (browser-style back / forward)
    //
    // Every place the user can be — a sidebar page, or a game open on top of
    // one — is a history entry. Back/forward (mouse buttons 4/5, as Safari
    // and Finder honour them) walk the list and replay the SAME open/close
    // zooms a click would, so navigation never skips or fakes a motion.

    struct NavEntry {
        var destination: SidebarDestination
        var game: Game?

        func sameState(as other: NavEntry) -> Bool {
            destination == other.destination && game?.id == other.game?.id
        }
    }

    /// Called from every user-initiated navigation. Truncates the forward
    /// list like a browser; no-op while replaying history or for a repeat.
    private func recordVisit(destination: SidebarDestination, game: Game?) {
        guard !applyingHistory else { return }
        let entry = NavEntry(destination: destination, game: game)
        if history[historyIndex].sameState(as: entry) { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(entry)
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        apply(history[historyIndex])
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        apply(history[historyIndex])
    }

    private func apply(_ entry: NavEntry) {
        if entry.destination != sidebarDestination {
            historyDestination = entry.destination
            sidebarDestination = entry.destination
            if let game = entry.game {
                // Next pass: the new root has laid out and registered its
                // cards, so the zoom anchors to the game's card there (or
                // falls back to the centred zoom) — never to a frame left
                // behind by the page that was just swapped out.
                DispatchQueue.main.async {
                    applyingHistory = true
                    openDetail(game)
                    applyingHistory = false
                }
            }
            return
        }
        applyingHistory = true
        defer { applyingHistory = false }
        if let game = entry.game {
            openDetail(game)
        } else {
            closeDetail()
        }
    }
}

/// Mouse back/forward, every way macOS delivers it: raw buttons 4/5 (plain
/// mice, MX Master without Logi software), ⌘[ / ⌘] (what Logi Options+ and
/// other mouse drivers send for their "Back/Forward" actions — the Safari /
/// Finder shortcuts), and legacy swipe gestures. Local monitor: fires only
/// for events this app receives, and only for the main window so a utility
/// window (Zoom Tuning, Settings) never drives the stage. Web pages keep
/// their own ⌘[ / ⌘] (WebKit is first responder → passed through).
@MainActor
final class NavButtonMonitor {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    // Only touched in init/deinit (both effectively main-thread here).
    nonisolated(unsafe) private var token: Any?
    private let log = MeridianLog(category: "NavButtonMonitor")

    private enum Direction { case back, forward }

    init() {
        token = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp, .keyDown, .swipe]) { [weak self] event in
            // Local monitors run on the main thread; the direction check
            // reads the window's first responder, which is main-actor state.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      event.window?.isMainWindow == true,
                      let direction = Self.direction(of: event) else { return false }
                self.log.info("Navigation \(direction == .back ? "back" : "forward") via event type \(event.type.rawValue)")
                switch direction {
                case .back:    self.onBack?()
                case .forward: self.onForward?()
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private static func direction(of event: NSEvent) -> Direction? {
        switch event.type {
        case .otherMouseUp:
            switch event.buttonNumber {
            case 3: return .back
            case 4: return .forward
            default: return nil
            }
        case .keyDown:
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let responder = event.window?.firstResponder,
                  !String(describing: type(of: responder)).hasPrefix("WK") else { return nil }
            switch event.charactersIgnoringModifiers {
            case "[": return .back
            case "]": return .forward
            default:  return nil
            }
        case .swipe:
            if event.deltaX > 0 { return .back }
            if event.deltaX < 0 { return .forward }
            return nil
        default:
            return nil
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}

extension Notification.Name {
    static let meridianBootstrapReady = Notification.Name("meridianBootstrapReady")
    static let meridianOpenSettings   = Notification.Name("meridianOpenSettings")
    /// Posted when an OAuth refresh token is found to be genuinely dead
    /// (DepotDownloader exit 3 at install time). SteamAuthService observes
    /// this and calls `markSessionExpired()`, which flips `isAuthenticated`
    /// false → the sign-in sheet re-appears (API key + password preserved).
    static let meridianSteamSessionExpired = Notification.Name("meridianSteamSessionExpired")
}

// MARK: - Sidebar

/// Brand lavender sampled from the app icon (display-p3 0.788, 0.607, 1.0).
extension Color {
    static let meridianAccent = Color(.displayP3, red: 0.78809, green: 0.60742, blue: 1.0)
}

/// Sidebar icon tint: monochrome (white in dark mode) at rest, brand purple
/// when the row is selected. `.fixed` so the selection highlight can't
/// override it back to the system accent.
private func sidebarTint(selected: Bool) -> ListItemTint {
    .fixed(selected ? .meridianAccent : .primary)
}

/// Shrinks only the glyph to a clean fraction of the row's text size
/// (13 pt body → ~10 pt icon at the 0.75 ratio) while keeping the standard
/// Label icon-column layout, so titles stay aligned.
private struct SidebarLabelStyle: LabelStyle {
    static let iconRatio: CGFloat = 0.75
    private static let iconSize = (NSFont.preferredFont(forTextStyle: .body).pointSize * iconRatio).rounded()

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .font(.system(size: Self.iconSize))
        }
    }
}

private struct SidebarView: View {
    @Binding var selectedDestination: SidebarDestination
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(CategoryStore.self) private var categoryStore

    var body: some View {
        List(selection: $selectedDestination) {
            Label("Search", systemImage: "magnifyingglass")
                .tag(SidebarDestination.search)
                .listItemTint(sidebarTint(selected: selectedDestination == .search))

            Label("Home", systemImage: "house")
                .tag(SidebarDestination.home)
                .listItemTint(sidebarTint(selected: selectedDestination == .home))

            Section("Library") {
                ForEach(SteamLibraryStore.LibraryFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filterIcon(filter))
                        .tag(SidebarDestination.library(filter))
                        .listItemTint(sidebarTint(selected: selectedDestination == .library(filter)))
                }
            }

            // Only show the section when the user has at least one item
            if !categoryStore.categories.isEmpty || !categoryStore.folders.isEmpty {
                CategoriesSidebarSection(selectedDestination: $selectedDestination)
            }

            Section("Steam") {
                Label("Store", systemImage: "cart")
                    .tag(SidebarDestination.steamStore)
                    .listItemTint(sidebarTint(selected: selectedDestination == .steamStore))
                Label("Profile", systemImage: "person.crop.circle")
                    .tag(SidebarDestination.steamProfile)
                    .listItemTint(sidebarTint(selected: selectedDestination == .steamProfile))
            }
        }
        .labelStyle(SidebarLabelStyle())
        .listStyle(.sidebar)
        .navigationTitle("Meridian")
    }

    private func filterIcon(_ filter: SteamLibraryStore.LibraryFilter) -> String {
        switch filter {
        case .all:       return "square.grid.2x2"
        case .recent:    return "clock"
        case .installed: return "internaldrive"
        case .favorites: return "heart"
        }
    }
}

// MARK: - Categories Section

/// Available icons the user can choose for a playlist. Shown in the
/// right-click "Change Icon" submenu.
private let categoryIconOptions: [(symbol: String, label: String)] = [
    ("folder",         "Folder"),
    ("person.2",       "Multiplayer"),
    ("person",         "Solo"),
    ("gamecontroller", "Controller"),
    ("star",           "Star"),
    ("heart",          "Heart"),
    ("flame",          "Hot"),
    ("trophy",         "Trophy"),
    ("crown",          "Crown"),
    ("bookmark",       "Bookmark"),
    ("bolt",           "Action"),
    ("sparkles",       "Special"),
    ("moon",           "Chill"),
    ("tag",            "Tag"),
    ("map",            "Open World"),
    ("timer",          "Quick Play"),
    ("puzzlepiece",    "Puzzle"),
    ("list.bullet",    "List"),
    ("clock",          "Recent"),
    ("globe",          "Online"),
]

/// The "Categories" section in the sidebar: folders (collapsible) containing
/// playlists plus top-level playlists, inline rename, icon picker, context menus.
private struct CategoriesSidebarSection: View {
    @Binding var selectedDestination: SidebarDestination
    @Environment(CategoryStore.self) private var categoryStore

    /// ID of the item currently in inline-rename mode (folder or category).
    @State private var editingID: UUID?
    @State private var editingName: String = ""

    var body: some View {
        Section("Categories") {
            // Top-level categories (not inside any folder)
            ForEach(categoryStore.topLevelCategories()) { cat in
                categoryRow(cat)
            }

            // Folders with nested categories
            ForEach(categoryStore.sortedFolders) { folder in
                folderRow(folder)
            }
        }
    }

    // MARK: Category row

    @ViewBuilder
    private func categoryRow(_ cat: GameCategory) -> some View {
        Group {
            if editingID == cat.id {
                TextField("", text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit { commitRename(categoryID: cat.id) }
                    .onExitCommand { editingID = nil }
            } else {
                Label(cat.name, systemImage: cat.icon)
            }
        }
        .tag(SidebarDestination.category(cat.id))
        .listItemTint(sidebarTint(selected: selectedDestination == .category(cat.id)))
        .contextMenu { categoryContextMenu(cat) }
    }

    // MARK: Folder row

    @ViewBuilder
    private func folderRow(_ folder: CategoryFolder) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get:  { folder.isExpanded },
                set:  { _ in categoryStore.toggleFolderExpanded(id: folder.id) }
            )
        ) {
            ForEach(categoryStore.categories(inFolder: folder.id)) { cat in
                categoryRow(cat)
            }
        } label: {
            Group {
                if editingID == folder.id {
                    TextField("", text: $editingName)
                        .textFieldStyle(.plain)
                        .onSubmit { commitFolderRename(folderID: folder.id) }
                        .onExitCommand { editingID = nil }
                } else {
                    Label(folder.name, systemImage: "folder")
                }
            }
            .contextMenu { folderContextMenu(folder) }
        }
        .listItemTint(sidebarTint(selected: false))
    }

    // MARK: Context menus

    @ViewBuilder
    private func categoryContextMenu(_ cat: GameCategory) -> some View {
        Button("Rename") {
            beginRename(id: cat.id, currentName: cat.name)
        }

        // Icon picker — right-click to cycle through SF Symbols
        Menu("Change Icon") {
            ForEach(categoryIconOptions, id: \.symbol) { option in
                Button {
                    categoryStore.changeIcon(id: cat.id, icon: option.symbol)
                } label: {
                    Label(
                        option.label + (cat.icon == option.symbol ? " ✓" : ""),
                        systemImage: option.symbol
                    )
                }
            }
        }

        if !categoryStore.sortedFolders.isEmpty {
            Menu("Move to Folder") {
                Button("No Folder") {
                    categoryStore.moveCategory(id: cat.id, toFolder: nil)
                }
                Divider()
                ForEach(categoryStore.sortedFolders) { folder in
                    Button(folder.name) {
                        categoryStore.moveCategory(id: cat.id, toFolder: folder.id)
                    }
                }
            }
        }

        Divider()

        Button("Delete Playlist", role: .destructive) {
            if case .category(let sel) = selectedDestination, sel == cat.id {
                selectedDestination = .library(.all)
            }
            categoryStore.deleteCategory(id: cat.id)
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: CategoryFolder) -> some View {
        Button("Rename") {
            beginRename(id: folder.id, currentName: folder.name)
        }

        Divider()

        Button("Delete Folder", role: .destructive) {
            // If currently viewing a category inside this folder, navigate away
            if case .category(let sel) = selectedDestination,
               categoryStore.category(id: sel)?.folderID == folder.id {
                selectedDestination = .library(.all)
            }
            categoryStore.deleteFolder(id: folder.id)
        }
    }

    // MARK: Rename helpers

    private func beginRename(id: UUID, currentName: String) {
        editingName = currentName
        editingID   = id
    }

    private func commitRename(categoryID: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            categoryStore.renameCategory(id: categoryID, name: trimmed)
        }
        editingID = nil
    }

    private func commitFolderRename(folderID: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            categoryStore.renameFolder(id: folderID, name: trimmed)
        }
        editingID = nil
    }
}

// MARK: - Steam Confirmation Banner

/// Shown when the window suppressor surfaces a user-actionable Steam dialog
/// (EULA acceptance, subscriber agreement, purchase / family-sharing
/// confirmation) that Meridian cannot action on the user's behalf. The real
/// Steam dialog is brought on-screen; this banner explains why a Steam window
/// just appeared so the seamless illusion isn't jarring.
private struct SteamConfirmationBanner: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Steam needs your confirmation")
                    .font(.callout.weight(.semibold))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(GlassRoundedBackground(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 420)
    }
}

// MARK: - Engine Status Pill

private struct EngineStatusPill: View {
    @Environment(WineEngine.self) private var engine
    var onSetUp: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !engine.isReady {
                Button("Set Up…") { onSetUp?() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(GlassCapsuleBackground())
    }

    private var dotColor: Color {
        switch engine.state {
        case .ready:          return .green
        case .notInstalled:   return .gray
        case .error:          return .red
        }
    }

    private var statusLabel: String {
        switch engine.state {
        case .ready:          return "Meridian Engine"
        case .notInstalled:   return "Engine Not Found"
        case .error:          return "Engine Error"
        }
    }
}

// MARK: - Press Feedback

/// `.plain` plus the pointer-down cue it lacks on macOS: the label settles
/// to 0.97 for as long as the mouse is held. For custom-drawn surfaces
/// (cards, art rows) only — glass-backed controls already get press feedback
/// from `.interactive()`, and list/menu rows highlight rather than scale.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { .init() }
}

// MARK: - Glass Effect Backgrounds

struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Update Available Banner

struct UpdateAvailableBanner: View {
    let message: String
    let onDismiss: () -> Void
    let onViewUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .font(.body)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("View Update") {
                onViewUpdate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(GlassRoundedBackground(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

struct GlassRoundedBackground: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

#Preview {
    ContentView()
        .environment(SteamAuthService())
        .environment(SteamLibraryStore())
        .environment(WineEngine())
        .environment(SteamSession())
        .environment(Launcher())
        .environment(BootstrapManager())
        .environment(CategoryStore())
        .environment(SteamWindow())
        .environment(AppUpdateChecker())
}
