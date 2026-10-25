import SwiftUI
import AppKit

private enum GameDetailMetrics {
    static let launchButtonHeight: CGFloat = 24
    static let launchButtonMinWidth: CGFloat = 140
    static let horizontalPadding: CGFloat = 20
    /// Uniform inset between the window edge and each floating card.
    /// Also the gap between the two cards, so all spacing is visually identical.
    static let cardInset: CGFloat = 16
    /// Corner radius for floating cards.
    /// Concentric with the NavigationSplitView detail-column corner radius
    /// (~28 pt on macOS Tahoe): 28 − cardInset (16) = 12 pt.
    static let cardCornerRadius: CGFloat = 12
}

struct GameDetailView: View {
    let game: Game
    let onDismiss: () -> Void
    /// False from the first frame of the close zoom, so the toolbar hands
    /// back to the library page as the page starts to shrink.
    var showsToolbar: Bool = true
    /// False while the zoom is in flight. The page's blur-based colour bleeds
    /// (ambient backdrop, banner glow, info-card wash) shimmer when rendered
    /// under a changing transform, so they're not rendered at all mid-flight
    /// and fade in once the page has landed.
    var showsAmbient: Bool = true

    @Environment(SteamLibraryStore.self)  private var library
    @Environment(WineEngine.self)         private var engine
    @Environment(SteamSession.self)        private var session
    @Environment(SteamAuthService.self)   private var steamAuth
    @Environment(Launcher.self)           private var launcher
    @Environment(BootstrapManager.self)   private var bootstrap
    @Environment(EngineDownloader.self)   private var engineDownloader
    @Environment(LicenseManager.self)     private var licenseManager
    @Environment(\.openWindow)            private var openWindow
    @Environment(\.controlActiveState)    private var controlActiveState
    /// Where Back centres while the floating sidebar shows (FloatingSidebar).
    @Environment(\.toolbarBackMidX)       private var toolbarBackMidX

    @State private var showEngineSetup = false
    @State private var showLicenseRequired = false
    /// What raised the license sheet: Play or Install.
    @State private var licenseGatedAction: LicenseRequiredSheet.Action = .play
    /// Set when the player licensed Meridian and chose to carry on.
    @State private var resumeGatedAction = false
    @State private var showResetConfirm = false
    @State private var appDetails: AppDetails? = nil
    /// Width÷height from the loaded hero `NSImage` (falls back to Steam's typical 1920×622 until decode).
    @State private var heroAspectRatio: CGFloat = SteamLibraryHeroMetrics.aspectRatio
    /// Banner image loaded directly — avoids the `GeometryReader` wrapper inside
    /// `HeroBannerImage`, which introduced an internal CALayer boundary that
    /// produced a faint rounded-corner artefact at the clip boundary on macOS 15.
    @State private var bannerImage: NSImage? = nil
    @State private var bannerImageFailed = false
    /// Sampled banner colors — drives the ambient glow behind the hero card.
    @State private var bannerGlowColors: ImageCache.EdgeColors?
    /// Steam Cloud state, kept current while the page is open; nil hides the row.
    @State private var cloudStatus: SteamCloudStatus? = nil
    @State private var achievements: [GameAchievement] = []
    @State private var achievementsLoading = false
    @State private var achievementsUnavailable = false
    /// When non-nil, the achievement-detail sheet is presented for this row.
    /// Using `sheet(item:)` so each selection replaces the previous without
    /// a dismiss bounce.
    @State private var selectedAchievement: GameAchievement? = nil
    /// Resolved tech stack (engine/API/bitness/DRM, merged from local
    /// detection + PCGamingWiki + any explicit compat profile). Populated by
    /// `resolveStack()` when the game is installed; drives the compat popover.
    @State private var resolvedStack: ResolvedGameStack? = nil
    /// Flips as the open zoom is landing (timed from mount, not from the
    /// spring's `.removed` settle, which trails the visible motion by a good
    /// half second) so the achievements bar starts filling as the page arrives.
    @State private var achievementBarArmed = false
    /// Bleeds start on a timer partway through the open flight (see
    /// `bleedsVisible`); cleared the instant a close begins.
    @State private var ambientArmed = false
    /// The toolbar's leading layout as Back last measured it
    /// (`FloatingSidebar.toolbarLeadingOffset`).
    @State private var toolbarLeadingOffset = FloatingSidebar.toolbarLeadingOffset

    private func bannerHeight(contentWidth: CGFloat) -> CGFloat {
        contentWidth / heroAspectRatio
    }

    /// The art bleeds (banner glow, info-card wash, column backdrop) come in
    /// while the open spring is still settling — armed at `ambientLead` ×
    /// open duration — rather than at the `.removed` settle that gates the
    /// hairline, glass and scroller. Soft blurs tolerate the transform's tail.
    private var bleedsVisible: Bool { showsAmbient || ambientArmed }

    init(game: Game, onDismiss: @escaping () -> Void, showsToolbar: Bool = true, showsAmbient: Bool = true) {
        self.game = game
        self.onDismiss = onDismiss
        self.showsToolbar = showsToolbar
        self.showsAmbient = showsAmbient
        // Memory-tier hit → the page mounts with its banner already laid out,
        // so the zoom never re-lays the page out mid-flight when the hero
        // (and its aspect ratio) would otherwise land a few frames in.
        let urls = game.newCDNHeroURLs + [game.heroURL] + game.heroURLFallbacks
        for url in urls {
            guard let img = ImageCache.shared.memoryImage(for: url) else { continue }
            let r = img.size.width / img.size.height
            if r > 0.05, r < 20 { _heroAspectRatio = State(initialValue: r) }
            _bannerImage = State(initialValue: img)
            _bannerGlowColors = State(initialValue: ImageCache.shared.cachedEdgeColors(for: url))
            break
        }
        // Same for the info + achievements cards: cached data (hover prefetch
        // or an earlier visit) is on screen at mount, refreshed underneath.
        _appDetails = State(initialValue: SteamAPIService.shared.cachedAppDetails(appID: game.id))
        _cloudStatus = State(initialValue: SteamCloudStatus.lastRead[game.id])
        if let cached = SteamAPIService.shared.cachedAchievements(appID: game.id) {
            _achievements = State(initialValue: cached)
        } else {
            _achievementsLoading = State(initialValue: true)
        }
    }

    var body: some View {
        // Read isFavorite at body-evaluation time so SwiftUI's @Observable tracking
        // registers the dependency here, not inside the toolbar closure where macOS
        // doesn't always re-evaluate on change.
        let isFavorite = library.isFavorite(appID: currentGame.id)
        // GeometryReader fills the nav-bar-excluded content area naturally —
        // no ignoresSafeArea, no explicit frame on the ScrollView.  Those
        // approaches caused two bugs: content sliding under the toolbar (because
        // proxy.safeAreaInsets.top is always 0 inside a NavigationStack child),
        // and a phantom scrollbar on navigation (oversized ScrollView frame
        // making SwiftUI think the content needed to scroll before any gesture).
        GeometryReader { proxy in
            let inset  = GameDetailMetrics.cardInset
            let radius = GameDetailMetrics.cardCornerRadius
            // Cards are inset 16 pt on each side.
            let cardWidth = proxy.size.width - inset * 2

            ScrollView {
                VStack(alignment: .leading, spacing: inset) {

                    // ── Banner card ───────────────────────────────────────────
                    heroBanner(
                        contentWidth: cardWidth,
                        bannerFrameHeight: bannerHeight(contentWidth: cardWidth)
                    )

                    // ── Info + Achievements (two-column) ──────────────────────
                    infoColumns(cardWidth: cardWidth, radius: radius, inset: inset)
                }
                .padding(.horizontal, inset)
                .padding(.bottom, inset)
                // The scroller (always-on with a mouse, overlay flash with a
                // trackpad) would show while the page is still scaled inside
                // the zoom rect. `.scrollIndicators` isn't re-applied once the
                // NSScrollView exists, so drive the scroller's alpha directly:
                // layout never changes, it fades in after the flight settles.
                // The same landing puts the page back at its top if the
                // flight left it a pixel or two down (see ScrollViewLanding).
                .background(alignment: .topLeading) {
                    ScrollViewLanding(landed: showsAmbient).frame(width: 0, height: 0)
                }
            }
        }
        .background { ambientBackdrop }
        .task {
            // ~2/3 through the open flight: the rect has all but reached the
            // stage, the fill's ease-in overlaps the last of the landing.
            let lead = DetailZoomTuning.shared.params.openDuration * 0.65
            try? await Task.sleep(for: .seconds(lead))
            achievementBarArmed = true
        }
        .task {
            let p = DetailZoomTuning.shared.params
            try? await Task.sleep(for: .seconds(p.openDuration * p.ambientLead))
            ambientArmed = true
        }
        // The toolbar hands back at close start — the earliest signal that
        // the page is leaving, so the bleeds drop with it.
        .onChange(of: showsToolbar) { _, shown in
            if !shown { ambientArmed = false }
        }
        .animation(Self.ambientFade, value: showsAmbient)
        .animation(Self.ambientFade, value: bleedsVisible)
        // Title is set by ContentView's stage (shared with the root page).
        // The native back button is replaced with an identical toolbar button
        // (same slot, same 30×28 footprint) routed through onDismiss, where
        // ContentView plays the reverse zoom.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // Dropped the instant the close zoom starts (ContentView flips
            // `showsToolbar`) so the toolbar hands back to the library page
            // at the same moment the page begins to shrink.
            if showsToolbar {
                // Beside the floating panel, Back keeps its classic spot: an
                // invisible item first, sized so Back centres on
                // `toolbarBackMidX`. Back reads where it really landed and
                // corrects the size, since macOS changes the toolbar's
                // leading layout between releases.
                if let toolbarBackMidX, #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        Color.clear.frame(width: toolbarBackMidX - toolbarLeadingOffset, height: 1)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .navigation) {
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.backward")
                            .frame(width: 20)
                            .background {
                                if let toolbarBackMidX {
                                    ToolbarMidXReader { midX in
                                        let offset = toolbarLeadingOffset + midX - toolbarBackMidX
                                        guard abs(offset - toolbarLeadingOffset) >= 0.5 else { return }
                                        FloatingSidebar.toolbarLeadingOffset = offset
                                        toolbarLeadingOffset = offset
                                    }
                                }
                            }
                    }
                    .help("Back")
                }
                // A flexible-space item pushes everything after it to the trailing
                // end of the macOS toolbar (equivalent to NSToolbarFlexibleSpaceItem).
                // Without it, .automatic items cluster on the leading side next to
                // the back button. The ToolbarItemGroup after the spacer renders as
                // the Tahoe glass pill on the right side of the toolbar.
                ToolbarItem(placement: .automatic) {
                    Spacer()
                }
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        library.toggleFavorite(appID: currentGame.id)
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(isFavorite ? .pink : .primary)
                    }
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")

                    Menu {
                        Button {
                            openWindow(id: "launch-log")
                        } label: {
                            Label("View Launch Logs", systemImage: "terminal")
                        }

                        Button {
                            NSWorkspace.shared.open(GameLogFile.currentURL(for: currentGame.id))
                        } label: {
                            Label("Open Game Log", systemImage: "doc.text")
                        }
                        .disabled(!GameLogFile.gameLogExists(for: currentGame.id))
                        .help("Raw Wine output + the resolved graphics stack for the last launch")

                        Button {
                            NSWorkspace.shared.open(GameLogFile.engineLogURL(for: currentGame.id))
                        } label: {
                            Label("Open Engine Log", systemImage: "doc.text.magnifyingglass")
                        }
                        .disabled(!GameLogFile.engineLogExists(for: currentGame.id))
                        .help("The game engine's own log (Unity Player.log / Unreal) from the last launch")

                        Button {
                            Task {
                                if let zip = try? await DiagnosticsBundle.collect(
                                    prefix: .defaultPrefix, summary: DiagnosticsBundle.summary(engine: engine)) {
                                    NSWorkspace.shared.activateFileViewerSelecting([zip])
                                }
                            }
                        } label: {
                            Label("Collect Diagnostics", systemImage: "archivebox")
                        }
                        .help("Zip every log, Steam's logs and recent crash reports to send for debugging")

                        if currentGame.isInstalled {
                            Divider()
                            Button(role: .destructive) {
                                launcher.uninstall(game: currentGame, library: library)
                            } label: {
                                Label("Uninstall", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    // Suppress the automatic disclosure chevron that SwiftUI adds
                    // to Menu labels in toolbars — the three dots are sufficient.
                    .menuIndicator(.hidden)
                    .help("More options")
                }
            }
        }
        .onExitCommand(perform: onDismiss)
        .onChange(of: game.id) { _, newID in
            heroAspectRatio = SteamLibraryHeroMetrics.aspectRatio
            appDetails = SteamAPIService.shared.cachedAppDetails(appID: newID)
            cloudStatus = SteamCloudStatus.lastRead[newID]
            bannerImage = nil
            bannerImageFailed = false
            achievements = SteamAPIService.shared.cachedAchievements(appID: newID) ?? []
            achievementsLoading = achievements.isEmpty
            achievementsUnavailable = false
            resolvedStack = nil
        }
        .task(id: game.id) {
            // Store data is static; a cache-seeded page already has it.
            guard appDetails == nil else { return }
            appDetails = try? await SteamAPIService.shared.fetchAppDetails(appID: game.id)
        }
        .task(id: game.id) {
            await loadBannerImage()
        }
        .task(id: game.id) {
            await loadAchievements()
        }
        .task(id: game.id) {
            await resolveStack()
        }
        .task(id: game.id) {
            await watchCloudStatus()
        }
        .sheet(isPresented: $showEngineSetup) {
            EngineSetupView().environment(engine)
        }
        .sheet(isPresented: $showLicenseRequired, onDismiss: resumeAfterLicenseSheet) {
            LicenseRequiredSheet(action: licenseGatedAction) { resumeGatedAction = true }
                .environment(licenseManager)
        }
        .sheet(item: $selectedAchievement) { ach in
            AchievementDetailSheet(achievement: ach)
        }
        .alert("Reset Game Install?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                launcher.uninstall(game: currentGame, library: library)
            }
        } message: {
            Text("This removes this game's local manifest and downloaded files only. It does not reset the Wine engine, Steam, or other installed games.")
        }
        // Consent prompts raised by the launch pipeline before any Steam
        // window can appear (SteamStub DRM → Online switch; first-time Online
        // → one-time interactive Steam sign-in).
        .alert(
            steamPromptTitle,
            isPresented: Binding(
                get: { launcher.steamPrompt != nil },
                set: { if !$0 { launcher.dismissSteamPrompt() } }
            ),
            presenting: launcher.steamPrompt
        ) { prompt in
            Button(steamPromptConfirmLabel(for: prompt)) {
                launcher.confirmSteamPrompt(
                    engine: engine, session: session,
                    steamAuth: steamAuth, library: library
                )
            }
            Button("Not Now", role: .cancel) { launcher.dismissSteamPrompt() }
        } message: { prompt in
            Text(steamPromptMessage(for: prompt))
        }
        // A game's license agreement, before Steam starts it (Pattern 47).
        .sheet(item: Binding(
            get: { launcher.eulaPrompt },
            set: { if $0 == nil { launcher.declineEulas() } }
        )) { prompt in
            EulaSheet(
                prompt: prompt,
                onAccept: {
                    launcher.acceptEulas(engine: engine, session: session,
                                         steamAuth: steamAuth, library: library)
                },
                onCancel: { launcher.declineEulas() }
            )
        }
        // Steam couldn't sync the game's cloud saves (Pattern 66).
        .sheet(item: Binding(
            get: { launcher.cloudSyncPrompt },
            set: { if $0 == nil { launcher.cancelCloudSync() } }
        )) { prompt in
            CloudSyncSheet(
                prompt: prompt,
                onTryAgain: {
                    launcher.retryCloudSync(engine: engine, session: session,
                                            steamAuth: steamAuth, library: library)
                },
                onCancel: { launcher.cancelCloudSync() },
                onPlayAnyway: { launcher.decideCloudSyncInSteam() }
            )
        }
    }

    // MARK: - Body sub-sections (extracted to keep the body expression
    // type-checkable — the single chained expression exceeded the compiler's
    // budget once the theater overlay was added)

    /// The two-column Info + Achievements row under the banner.
    private func infoColumns(cardWidth: CGFloat, radius: CGFloat, inset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: inset) {

            // Left: launch controls + game info
            VStack(alignment: .leading, spacing: 12) {
                launchSection
                statsSection
            }
            .padding(GameDetailMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Color(nsColor: .windowBackgroundColor)
                if bleedsVisible, let img = bannerImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60)
                        .saturation(1.2)
                        .opacity(0.2)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )

            // Right: achievements — natural 1/4 width, minimum 250 pt.
            // At large windows the 1/4 rule applies; at small windows the
            // floor holds and the left card shrinks to whatever remains.
            achievementsCard(radius: radius)
                .frame(width: max(250, (cardWidth - inset) / 4))
        }
    }

    /// Very subtle ambient colour bleed from the game's art — fills the
    /// full column including safe areas so the tint shows in the margins
    /// and behind the navigation bar, matching the Apple Music album feel.
    @ViewBuilder
    private var ambientBackdrop: some View {
        if bleedsVisible, let img = bannerImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .blur(radius: 80)
                .saturation(1.2)
                .opacity(0.096)
                .transition(.opacity)
        }
    }

    /// Bleed fade once the zoom has landed (and out as a close begins).
    private static var ambientFade: Animation { .easeOut(duration: DetailZoomTuning.shared.params.ambientFade) }

    // MARK: - Scroll view landing

/// Zero-size probe inside a `ScrollView`'s content: finds the enclosing
/// `NSScrollView` and settles it as the zoom lands (`landed`):
/// - Fades its scrollers in (alpha, not presence — a legacy scroller takes
///   layout space, so removing it would reflow the page).
/// - Puts the page back at its top. While the page is scaled inside the zoom
///   rect, AppKit recomputes the scroll view's top inset through the scale
///   every frame (52 pt → ~49 → 52 with the spring's overshoot) and the
///   offset chases it in whole pixels. 7 of 17 opens rested 0.5–1.5 pt down
///   (meridian.log, Oct 14 2026); a probe without the scale always rested
///   at the top. Only within `topSnap` of it, so a scroll made mid-flight
///   stays where it is.
private struct ScrollViewLanding: NSViewRepresentable {
    let landed: Bool

    func makeNSView(context: Context) -> LandingProbe {
        let v = LandingProbe()
        v.landed = landed
        return v
    }

    func updateNSView(_ v: LandingProbe, context: Context) {
        v.landed = landed
    }

    final class LandingProbe: NSView {
        static let topSnap: CGFloat = 4
        private static let log = MeridianLog(category: "GameDetail")

        var landed = true { didSet { if landed != oldValue { apply(animated: true) } } }

        override var isFlipped: Bool { true }
        // An AppKit subview sits above the hosting view's SwiftUI drawing in
        // AppKit hit-testing regardless of SwiftUI z-order; never take events.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            guard let scrollView = enclosingScrollView else { return }
            if landed { returnToTop(scrollView) }
            let scrollers = [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap { $0 }
            let alpha: CGFloat = landed ? 1 : 0
            guard animated else {
                scrollers.forEach { $0.alphaValue = alpha }
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                scrollers.forEach { $0.animator().alphaValue = alpha }
            }
            // Overlay style: announce the now-visible scroller as a fresh page would.
            if landed { scrollView.flashScrollers() }
        }

        private func returnToTop(_ scrollView: NSScrollView) {
            let clip = scrollView.contentView
            let top = -scrollView.contentInsets.top
            let y = clip.bounds.origin.y
            guard y != top, abs(y - top) < Self.topSnap else { return }
            Self.log.debug("[ScrollViewLanding] back to the top from \(y - top) pt")
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

// MARK: - Steam prompt copy

    private var steamPromptTitle: String {
        switch launcher.steamPrompt {
        case .signInRequired: return "Connect Steam"
        case nil:             return ""
        }
    }

    private func steamPromptConfirmLabel(for prompt: Launcher.SteamPrompt) -> String {
        switch prompt {
        case .signInRequired: return "Connect Steam"
        }
    }

    private func steamPromptMessage(for prompt: Launcher.SteamPrompt) -> String {
        switch prompt {
        case .signInRequired(let game):
            return "\(game.name) runs through Steam. Sign in to Steam once on this Mac. After that it starts automatically and stays out of sight."
        }
    }

    // MARK: - Hero Banner

    private func heroBanner(contentWidth: CGFloat, bannerFrameHeight: CGFloat) -> some View {
        let g = currentGame
        let w = contentWidth
        let h = bannerFrameHeight

        // A concrete Color establishes the frame as a real view (not a Group),
        // which prevents the SwiftUI layout engine from implicitly clipping the
        // image to the frame's straight edges before clipShape rounds the corners.
        // The image lives entirely in .overlay so it overflows the layout frame
        // freely — the one and only clip boundary is the final clipShape below.
        // Clear once the art is in: under the zoom's fractional scale the art's
        // resampled edge blends with whatever is behind it, and an opaque black
        // backing showed as a dark fringe around the banner mid-flight.
        return (bannerImage == nil ? Color.black : Color.clear)
            .frame(width: w, height: h)
            .overlay {
                if let img = bannerImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else if bannerImageFailed {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(.tertiary)
                } else {
                    ShimmerView()
                }
            }
            .id(g.id)
            // ── overlays first, then ONE clip for everything ──────────────
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .init(x: 0.5, y: 0.3),
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay {
                // When Steam publishes a logo_position (via PICS appinfo), place
                // the logo exactly as Steam's own library does — pinned corner +
                // width/height-percent box. Otherwise fall back to the fixed
                // leading layout. (Game detail only — the Home carousel keeps the
                // fixed layout regardless.)
                Group {
                    if let placement = g.effectiveLogoPlacement {
                        HeroLogoPositioned(
                            urls: g.newCDNLogoURLs + [g.logoURL] + g.logoURLFallbacks,
                            fallbackName: g.name,
                            placement: placement,
                            containerSize: CGSize(width: w, height: h)
                        )
                    } else {
                        HeroLogoImage(
                            urls: g.newCDNLogoURLs + [g.logoURL] + g.logoURLFallbacks,
                            fallbackName: g.name
                        )
                        .padding(.leading, GameDetailMetrics.horizontalPadding)
                        .padding(.trailing, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .id(g.id)
                .allowsHitTesting(false)
            }
            // Playtime moved to the stats panel (Total Playtime row); the
            // compatibility badge moved to a dedicated premium card under the
            // Play button (`compatStatusCard`). The banner now shows only the
            // hero art + positioned logo, matching Steam's clean library look.
            .clipShape(RoundedRectangle(cornerRadius: GameDetailMetrics.cardCornerRadius, style: .continuous))
            // One rasterized layer (art + gradient + logo + clip): under the
            // flight's fractional scale the vector clip mask was re-evaluated
            // per frame and its anti-aliased edge crawled — most visible where
            // the art meets the window background at high contrast. A bitmap
            // resamples smoothly instead. Identity at 1:1.
            .drawingGroup()
            // Same hairline the info/achievement cards wear. Mounted only
            // after landing like the glow — a sub-pixel stroke shimmers under
            // the flight's fractional scale — and, unlike the glow, dropped
            // instantly when a close begins rather than fading out under it.
            .overlay {
                if showsAmbient {
                    RoundedRectangle(cornerRadius: GameDetailMetrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                        .allowsHitTesting(false)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            // Behind the clipped hero so the blur bleeds past its edges
            // (added after clipShape → the glow itself is not clipped).
            .background {
                if bleedsVisible {
                    ArtGlowBackground(colors: bannerGlowColors,
                                      cornerRadius: GameDetailMetrics.cardCornerRadius)
                        .transition(.opacity)
                }
            }
    }

    // MARK: - Banner image loading

    /// Loads the hero banner image via the cache then network, mirroring
    /// `HeroBannerImage.loadImage()` but writing directly to `@State`
    /// so the banner can render as a plain `Image` with no `GeometryReader`.
    private func loadBannerImage() async {
        let urls = currentGame.newCDNHeroURLs + [currentGame.heroURL] + currentGame.heroURLFallbacks

        // Preloaded by init from the memory tier — only the glow may be missing.
        if let img = bannerImage {
            if bannerGlowColors == nil, let url = urls.first(where: { ImageCache.shared.memoryImage(for: $0) === img }) {
                bannerGlowColors = await ImageCache.shared.edgeColors(for: img, url: url)
            }
            return
        }

        for url in urls {
            if let cached = await ImageCache.shared.imageAsync(for: url) {
                let r = cached.size.width / cached.size.height
                if r > 0.05, r < 20 { heroAspectRatio = r }
                bannerImage = cached
                bannerGlowColors = await ImageCache.shared.edgeColors(for: cached, url: url)
                return
            }
        }

        for url in urls {
            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.imageSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let img = await ImageCache.decode(data) else { continue }
                ImageCache.shared.store(img, for: url, rawData: data)
                let r = img.size.width / img.size.height
                if r > 0.05, r < 20 { heroAspectRatio = r }
                bannerImage = img
                bannerGlowColors = await ImageCache.shared.edgeColors(for: img, url: url)
                return
            } catch { continue }
        }

        bannerImageFailed = true
    }

    // MARK: - Launch section

    @ViewBuilder
    private var launchSection: some View {
        // Spacing matches the card's top inset (horizontalPadding) so the gap
        // above and below the Play button is visually equal.
        VStack(alignment: .leading, spacing: GameDetailMetrics.horizontalPadding) {
            playButton
            compatStatusCard
            // The inline StatusCard carries live status + progress for every
            // busy phase — installing / downloading / launching / running /
            // stopping. During `.launching` its bar shows the staged
            // Steam-boot progress (same look as the download flow); the Play
            // button above stays static.
            if isThisGameActive {
                StatusCard(launcher: launcher, openWindow: openWindow)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.smooth(duration: 0.2), value: isThisGameActive)
            }
        }
    }

    /// Premium compatibility badge — the reassuring "Meridian Verified /
    /// Optimized for Apple Silicon" confirmation, sitting directly under the
    /// Play button (moved out of the banner). Tap reveals the full rendering
    /// pipeline. Replaces the small banner seal icon.
    private var compatStatusCard: some View {
        let compatProfile = GameCompatibilityDB.shared.profile(for: currentGame.id)
        let status = GameCompatibilityDB.shared.effectiveStatus(
            for: currentGame.id,
            resolved: resolvedStack?.status,
            profile: compatProfile?.status
        )
        return BannerCompatBadge(
            status: status,
            profile: compatProfile,
            resolved: resolvedStack,
            style: .card
        )
    }

    // MARK: - Stats / Info section

    @ViewBuilder
    private var statsSection: some View {
        // Short description from store API
        if let desc = appDetails?.shortDescription, !desc.isEmpty {
            Text(desc.decodingHTMLEntities)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Playtime card
        playtimeCard

        // Game info card (status, platform, genres, developer)
        gameInfoCard

        // Steam Store link
        steamStoreLink

        #if DEBUG
        // Developer-only: record a compatibility verdict while testing. Compiled
        // out of Release builds — end users never see this.
        devVerdictCard
        #endif
    }

    #if DEBUG
    /// Developer compatibility-verdict recorder. Tapping a button stores the
    /// verdict (overlaying the compiled DB instantly) so we don't have to hand-
    /// edit `GameCompatibilityDB` for every game we test. "Copy for commit"
    /// yields ready-to-paste lines for folding into the curated source.
    @ViewBuilder
    private var devVerdictCard: some View {
        let current = CompatVerdictStore.shared.verdict(for: currentGame.id)
        let currentStatus = current.flatMap { CompatStatus(rawValue: $0.status) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                Text("Developer · Compatibility Verdict")
                    .font(.caption.weight(.semibold))
                Spacer()
                if current != nil {
                    Button("Clear") { CompatVerdictStore.shared.clearVerdict(for: currentGame.id) }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                verdictButton("Runs Great",  .verified, "checkmark.seal.fill",        .green,  currentStatus)
                verdictButton("Some Issues", .playable, "exclamationmark.triangle.fill", .yellow, currentStatus)
                verdictButton("Doesn't Run", .broken,   "xmark.seal.fill",            .red,    currentStatus)
                verdictButton("Untested",    .untested, "questionmark.circle.fill",   .gray,   currentStatus)
            }

            if let current {
                Text("Saved \(current.date.formatted(date: .abbreviated, time: .shortened)) · \(current.engineTag)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 14) {
                Button("Copy for commit") { copyVerdictsForCommit() }
                Button("Reveal JSON") {
                    NSWorkspace.shared.activateFileViewerSelecting([CompatVerdictStore.fileURL])
                }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.yellow.opacity(0.3), lineWidth: 0.5))
    }

    private func verdictButton(
        _ label: String,
        _ status: CompatStatus,
        _ icon: String,
        _ color: Color,
        _ current: CompatStatus?
    ) -> some View {
        let selected = current == status
        return Button {
            let tag = engine.engineVersion ?? WineEngine.installedEngineTagOnDisk() ?? "unknown"
            CompatVerdictStore.shared.setVerdict(status, engineTag: tag, for: currentGame.id)
        } label: {
            VStack(spacing: 4) {
                // Fixed icon height normalizes glyph differences (triangle vs
                // seal vs question-mark) so all four rows are exactly equal height.
                Image(systemName: icon)
                    .font(.callout)
                    .frame(height: 18)
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 8)
            .background(
                selected ? color.opacity(0.22) : Color.gray.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? color : .clear, lineWidth: 1)
            )
            .foregroundStyle(selected ? color : .secondary)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // Flex at the Button level so all four share the row equally — a plain
        // button otherwise sizes to its label and the last item absorbs the slack.
        .frame(maxWidth: .infinity)
    }

    private func copyVerdictsForCommit() {
        let text = CompatVerdictStore.shared.exportSwiftSnippets { appID in
            library.games.first { $0.id == appID }?.name
                ?? GameCompatibilityDB.shared.profile(for: appID)?.name
                ?? "App \(appID)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    #endif

    private var playtimeCard: some View {
        VStack(spacing: 0) {
            DetailRow(
                icon: "clock",
                label: "Total Playtime",
                value: currentGame.playtimeMinutes == 0 ? "No playtime recorded" : currentGame.playtimeFormatted
            )

            if let recent = currentGame.playtime2WeekMinutes, recent > 0 {
                DetailDivider()
                let value = recent >= 60 ? "\(recent / 60) hr\(recent/60 == 1 ? "" : "s")" : "\(recent) min"
                DetailRow(icon: "calendar", label: "Last 2 Weeks", value: value)
            }

            if appDetails?.supportsSteamCloud == true, let cloudStatus {
                DetailDivider()
                DetailRow(icon: cloudStatus.symbol, label: "Cloud Saves", value: cloudStatus.text,
                          valueColor: cloudStatus == .conflict ? .orange : .primary)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private var gameInfoCard: some View {
        let genres     = appDetails?.genres?.compactMap(\.description).filter { !$0.isEmpty } ?? []
        let developer  = appDetails?.developers?.first
        let publisher  = appDetails?.publishers?.first
        let metacritic = appDetails?.metacritic?.score
        let releaseStr = appDetails?.releaseDate?.date.flatMap { $0.isEmpty ? nil : $0 }
        let controller = appDetails?.controllerSupport
        let hasAnyInfo = !genres.isEmpty || developer != nil || publisher != nil
            || currentGame.windowsOnly || metacritic != nil || releaseStr != nil || controller != nil

        if hasAnyInfo {
            VStack(spacing: 0) {
                // Install status
                let installation = installationRow
                DetailRow(icon: installation.icon, label: "Installation",
                          value: installation.value, valueColor: installation.color)

                // Platform
                if currentGame.windowsOnly {
                    DetailDivider()
                    HStack {
                        Label("Platform", systemImage: "desktopcomputer")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        WindowsBadge()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }

                // Controller support: Meridian's word for Steam's "Grab a
                // controller and kick back!" screen, which it keeps closed.
                if let controller {
                    DetailDivider()
                    DetailRow(icon: "gamecontroller", label: "Controller",
                              value: controller == .full ? "Full support" : "Partial support")
                }

                // Release date
                if let date = releaseStr {
                    DetailDivider()
                    DetailRow(icon: "calendar", label: "Released", value: date)
                }

                // Metacritic score
                if let score = metacritic {
                    DetailDivider()
                    HStack {
                        Label("Metacritic", systemImage: "star.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        MetacriticBadge(score: score)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }

                // Genres
                if !genres.isEmpty {
                    DetailDivider()
                    DetailRow(icon: "tag", label: "Genre", value: genres.prefix(3).joined(separator: ", "))
                }

                // Developer
                if let dev = developer {
                    DetailDivider()
                    DetailRow(icon: "hammer", label: "Developer", value: dev)
                }

                // Publisher (only if different from developer)
                if let pub = publisher, pub != developer {
                    DetailDivider()
                    DetailRow(icon: "building.2", label: "Publisher", value: pub)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    private var steamStoreLink: some View {
        Button {
            if let url = URL(string: "https://store.steampowered.com/app/\(currentGame.id)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack {
                Label("View on Steam Store", systemImage: "arrow.up.right.square")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .modifier(SettledGlassBackground(cornerRadius: 10, settled: showsAmbient))
    }

    // MARK: - Achievements card

    @ViewBuilder
    private func achievementsCard(radius: CGFloat) -> some View {
        let storeTotal = appDetails?.achievementsSummary?.total ?? 0
        let unlocked   = achievements.filter { $0.achieved }
        let recentUnlocked = Array(
            unlocked.sorted { ($0.unlockDate ?? .distantPast) > ($1.unlockDate ?? .distantPast) }
                .prefix(5)
        )

        VStack(alignment: .leading, spacing: 14) {

            // Header row
            HStack {
                Label("Achievements", systemImage: "trophy.fill")
                    .font(.headline)
                if !achievementsLoading, storeTotal > 0 {
                    Spacer()
                    Text("\(unlocked.count) / \(storeTotal)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if achievementsLoading {
                HStack(spacing: 8) {
                    // The spinner is an NSProgressIndicator; laid out inside the
                    // zoom's scaled page it trips SwiftUI's platform-view length
                    // assertion. Reserve its 32×32 footprint (measured) and
                    // mount it only once the page has landed.
                    Color.clear
                        .frame(width: 32, height: 32)
                        .overlay { if showsAmbient { ProgressView().scaleEffect(0.7) } }
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if achievementsUnavailable || (achievements.isEmpty && storeTotal == 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(achievementsUnavailable ? "Achievements unavailable" : "No achievements")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(achievementsUnavailable
                         ? "Your Steam profile may be set to private, or this game has no stats."
                         : "This game has no achievement system.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {

                // Progress bar (only when we have a known total)
                if storeTotal > 0 {
                    let progress = Double(unlocked.count) / Double(storeTotal)
                    VStack(alignment: .leading, spacing: 4) {
                        // Pure SwiftUI (no NSProgressIndicator), so it can
                        // stay mounted through the zoom and FILL once the
                        // page has landed instead of fading in with the bleeds.
                        AchievementProgressBar(value: progress, armed: achievementBarArmed)
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                        Text(unlocked.count == 0
                             ? "None unlocked yet. Keep playing!"
                             : "\(unlocked.count) of \(storeTotal) unlocked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Recent unlocked list
                if recentUnlocked.isEmpty {
                    Text("None unlocked yet. Keep playing!")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(recentUnlocked.enumerated()), id: \.element.id) { idx, ach in
                            if idx > 0 { Divider().padding(.leading, 54) }
                            Button {
                                selectedAchievement = ach
                            } label: {
                                AchievementRow(achievement: ach)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                }
            }

            // Steam achievements link
            if !achievementsUnavailable {
                Button {
                    if let url = URL(string: "https://steamcommunity.com/stats/\(currentGame.id)/achievements") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label("View all on Steam", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .modifier(SettledGlassBackground(cornerRadius: 10, settled: showsAmbient))
            }
        }
        .padding(GameDetailMetrics.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // MARK: - Achievement loading

    /// Fetches (or, when the page mounted from cache, silently refreshes) the
    /// achievement list. `achievementsLoading` is set at mount, not here, so
    /// a cache-seeded page never flashes its placeholder.
    private func loadAchievements() async {
        defer { achievementsLoading = false }
        let key = steamAuth.apiKey
        let sid = steamAuth.steamID
        guard !key.isEmpty, !sid.isEmpty else { return }
        do {
            let result = try await SteamAPIService.shared.fetchPlayerAchievements(
                steamID: sid,
                apiKey: key,
                appID: game.id
            )
            // Empty result is valid (game has no achievement system); not an error.
            if result != achievements { achievements = result }
            achievementsUnavailable = false
        } catch {
            // Keep whatever the cache gave us; only an empty page reports failure.
            if achievements.isEmpty { achievementsUnavailable = true }
        }
    }

    // MARK: - Steam Cloud status

    /// Keeps the Cloud Saves row current while the page is open: Steam
    /// uploads a game's saves after it exits, for seconds or, with Noita's
    /// world files, minutes. Two small file reads every 2 s, off the main actor.
    private func watchCloudStatus() async {
        let prefix = WinePrefix.defaultPrefix
        let localConfig = prefix.localConfigURL(steamID64: AppSettings.shared.steamCredentialSteamID)
        let cloudLog = prefix.steamInstallDir.appending(path: "logs/cloud_log.txt")
        let appID = game.id
        while !Task.isCancelled {
            let status = await Task.detached(priority: .utility) {
                SteamCloudStatus.read(appID: appID, localConfig: localConfig, cloudLog: cloudLog)
            }.value
            if status != cloudStatus { cloudStatus = status }
            SteamCloudStatus.lastRead[appID] = status
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Tech stack resolution

    /// Resolves the game's tech stack for display in the compatibility popover.
    /// Only runs for installed games (detection needs the files on disk);
    /// PCGamingWiki enrichment is cached, so repeat opens are cheap.
    private func resolveStack() async {
        guard currentGame.isInstalled else { return }
        let prefix = WinePrefix.defaultPrefix
        let installDir = prefix.gameInstallDir(appID: currentGame.id).map {
            prefix.steamInstallDir.appending(path: "steamapps/common/\($0)")
        }
        resolvedStack = await GameStackResolver.shared.resolve(
            appID: currentGame.id,
            name: currentGame.name,
            installDir: installDir
        )
    }

    // MARK: - Per-game gating

    private var isThisGame: Bool {
        launcher.activeAppID == game.id
    }

    private var isThisGameActive: Bool {
        guard isThisGame else { return false }
        return launcher.isBusy
    }

    // MARK: - Play button

    @ViewBuilder
    private var playButton: some View {
        if let activeID = launcher.activeAppID, activeID != game.id {
            idleButton
        } else {
            activePlayButton
        }
    }

    @ViewBuilder
    private var activePlayButton: some View {
        switch launcher.launchState {
        // NOTE: `.failed` must NOT be listed here — it has its own dedicated
        // branch below (Retry/Reset + error caption). Listing it alongside
        // `.idle` made that branch unreachable dead code (pre-existing bug:
        // launch failures silently showed the plain Play button with no
        // error message; the compiler flagged the shadowed case).
        case .idle:
            idleButton

        case .installing:
            HStack(spacing: 8) {
                ProgressButton(launcher.installIsUpdate ? "Updating…" : "Preparing…")
                cancelButton
            }

        case .downloading:
            let isInstalling = (launcher.downloadProgress ?? 0) > 0.88
            HStack(spacing: 8) {
                ProgressButton(launcher.installIsUpdate ? "Updating…" : isInstalling ? "Installing…" : "Downloading…")
                cancelButton
            }

        case .launching:
            // The Play button stays static during a launch (user direction
            // Jul 3 2026: no in-place morphing, no game title in the button).
            // Live status + staged progress render in the StatusCard below,
            // matching the download flow's look.
            HStack(spacing: 8) {
                Button {} label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(
                            minWidth: GameDetailMetrics.launchButtonMinWidth,
                            minHeight: GameDetailMetrics.launchButtonHeight
                        )
                }
                .inactiveAwareProminence(controlActiveState == .inactive)
                .controlSize(.large)
                .disabled(true)

                stopButton
            }

        case .running:
            HStack(spacing: 8) {
                Button {} label: {
                    Label("Running", systemImage: "play.circle.fill")
                        .font(.headline)
                        .frame(
                            minWidth: GameDetailMetrics.launchButtonMinWidth,
                            minHeight: GameDetailMetrics.launchButtonHeight
                        )
                }
                .inactiveAwareProminence(controlActiveState == .inactive)
                .controlSize(.large)
                .disabled(true)

                stopButton
            }

        case .stopping:
            ProgressButton("Stopping…")

        case .uninstalling:
            ProgressButton("Uninstalling…")

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !engine.isReady {
                        Button { showEngineSetup = true } label: {
                            Label("Set Up Engine…", systemImage: "arrow.down.circle")
                                .frame(
                                    minWidth: GameDetailMetrics.launchButtonMinWidth,
                                    minHeight: GameDetailMetrics.launchButtonHeight
                                )
                        }
                        .inactiveAwareProminence(controlActiveState == .inactive)
                        .controlSize(.large)
                    } else {
                        Button { currentGame.installState == .installed ? handlePlayTapped() : handleInstallTapped() } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .frame(
                                    minWidth: GameDetailMetrics.launchButtonMinWidth,
                                    minHeight: GameDetailMetrics.launchButtonHeight
                                )
                        }
                        .inactiveAwareProminence(controlActiveState == .inactive)
                        .controlSize(.large)
                    }

                    Button { showResetConfirm = true } label: {
                        Label("Reset", systemImage: "trash")
                            .frame(minHeight: GameDetailMetrics.launchButtonHeight)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Remove this game's local files and retry the install")
                }

                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var idleButton: some View {
        switch currentGame.installState {
        case .installed:
            let label = launchButtonLabel("Play", systemImage: "play.fill")
            Button { handlePlayTapped() } label: { label }
                .inactiveAwareProminence(controlActiveState == .inactive)
                .controlSize(.large)
                .modifier(settledLaunchButton { label })
                .disabled(!steamAuth.isAuthenticated || isLauncherBusyWithOtherGame)
                .help(isLauncherBusyWithOtherGame ? "Stop the current game before launching another" : "")
        case .updateRequired:
            // Play would only make Steam update first (a launching app's
            // update goes to the front of its queue): say so up front.
            let label = launchButtonLabel("Update", systemImage: "arrow.down.circle.fill")
            Button { handleInstallTapped() } label: { label }
                .inactiveAwareProminence(controlActiveState == .inactive)
                .controlSize(.large)
                .modifier(settledLaunchButton { label })
                .disabled(!steamAuth.isAuthenticated || isLauncherBusyWithOtherGame)
                .help(isLauncherBusyWithOtherGame ? "Another game is currently active" : "A newer version is available")
        case .notInstalled:
            let label = launchButtonLabel("Install", systemImage: "arrow.down.circle.fill")
            Button { handleInstallTapped() } label: { label }
                .inactiveAwareProminence(controlActiveState == .inactive)
                .controlSize(.large)
                .modifier(settledLaunchButton { label })
                .disabled(!steamAuth.isAuthenticated || isLauncherBusyWithOtherGame)
                .help(isLauncherBusyWithOtherGame ? "Another game is currently active" : "")
        }
    }

    private func launchButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(
                minWidth: GameDetailMetrics.launchButtonMinWidth,
                minHeight: GameDetailMetrics.launchButtonHeight
            )
    }

    private func settledLaunchButton<L: View>(@ViewBuilder label: () -> L) -> SettledLaunchButton<L> {
        SettledLaunchButton(settled: showsAmbient, prominent: controlActiveState != .inactive,
                            fade: Self.ambientFade, label: label)
    }

    private var isLauncherBusyWithOtherGame: Bool {
        guard let activeID = launcher.activeAppID, activeID != game.id else { return false }
        return launcher.isBusy
    }

    private var cancelButton: some View {
        Button {
            launcher.cancelLaunch()
        } label: {
            Label("Cancel", systemImage: "xmark")
                .frame(minHeight: GameDetailMetrics.launchButtonHeight)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var stopButton: some View {
        Button {
            launcher.stopGame(engine: engine)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
                Text("Stop")
            }
            .frame(minHeight: GameDetailMetrics.launchButtonHeight)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Helpers

    private var currentGame: Game {
        library.gameWithMergedPlaytime(appID: game.id) ?? library.games.first(where: { $0.id == game.id }) ?? game
    }

    /// The "Installation" row's icon, wording and colour.
    private var installationRow: (icon: String, value: String, color: Color) {
        switch currentGame.installState {
        case .installed:      ("internaldrive", "Installed", .green)
        case .updateRequired: ("arrow.down.circle", "Update Available", .orange)
        case .notInstalled:   ("icloud.and.arrow.down", "Not Installed", .orange)
        }
    }

    private func handleInstallTapped() {
        guard licenseManager.allowsPlay else { requireLicense(for: .install); return }
        guard engine.isReady else { showEngineSetup = true; return }
        launcher.installOnly(
            game: currentGame, engine: engine,
            session: session, steamAuth: steamAuth, library: library
        )
    }

    private func handlePlayTapped() {
        guard licenseManager.allowsPlay else { requireLicense(for: .play); return }
        guard engine.isReady else { showEngineSetup = true; return }
        launcher.launch(
            game: currentGame, engine: engine,
            session: session, steamAuth: steamAuth, library: library
        )
    }

    private func requireLicense(for action: LicenseRequiredSheet.Action) {
        licenseGatedAction = action
        showLicenseRequired = true
    }

    /// Runs once the license sheet has fully closed, so the engine-setup
    /// sheet can follow it when the engine isn't ready.
    private func resumeAfterLicenseSheet() {
        guard resumeGatedAction else { return }
        resumeGatedAction = false
        switch licenseGatedAction {
        case .play: handlePlayTapped()
        case .install: handleInstallTapped()
        }
    }

}

// MARK: - Detail Row helpers

/// `GlassRoundedBackground` for content inside the zoomed page. Glass is a
/// live backdrop sample; under the flight's fractional scale it re-renders
/// every frame and shimmers ("glassEffect() tried to update multiple times
/// per frame"). Mid-flight the row wears the same flat card fill as its
/// neighbours; once the page has landed it takes the real interactive glass.
/// The branch re-identifies the row exactly once, at landing — the rows are
/// stateless link buttons, so nothing is lost.
private struct SettledGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 10
    var settled: Bool

    func body(content: Content) -> some View {
        // Glass fades IN at landing but is cut instantly when a close begins:
        // a fading-out glass would still be sampling under the transform.
        if settled {
            content
                .modifier(GlassRoundedBackground(cornerRadius: cornerRadius))
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        } else {
            content
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 0.5))
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
        }
    }
}

/// The Play / Install button inside the zoomed page. A bordered button is an
/// AppKit control with a glass bezel; under the flight's fractional scale its
/// label jittered against the page around it (user, Oct 12 2026: "usually the
/// play/download text"), the button's version of the glass rows' shimmer
/// above. Mid-flight the real button keeps its place in the layout but isn't
/// shown: a SwiftUI capsule with the same label, in the button's exact frame,
/// stands in. Same timing as the rows: the real button fades in once the page
/// has landed, and is cut at once when a close begins.
///
/// The stand-in stays solid under the real button until its fade is done.
/// Crossfading the two dimmed the button to about 75% halfway (two layers at
/// half opacity don't add up to one) and doubled its slightly offset label:
/// "the install text and arrow fade and then go solid again" (user, Oct 12
/// 2026).
private struct SettledLaunchButton<StandInLabel: View>: ViewModifier {
    var settled: Bool
    /// `.borderedProminent` (accent fill) rather than `.bordered`.
    var prominent: Bool
    var fade: Animation
    @ViewBuilder var label: StandInLabel

    @Environment(\.isEnabled) private var isEnabled
    /// The real button is shown (fading in once the page lands).
    @State private var shown = false
    /// The stand-in under it is gone: only once that fade has finished.
    @State private var standInGone = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .background {
                if !standInGone {
                    label
                        .foregroundStyle(labelStyle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(fillStyle, in: Self.bezel)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                shown = settled
                standInGone = settled
            }
            .onChange(of: settled) { _, settled in
                guard settled else {
                    shown = false
                    standInGone = false
                    return
                }
                withAnimation(fade) {
                    shown = true
                } completion: {
                    // Still settled: a close may have begun mid-fade.
                    if shown { standInGone = true }
                }
            }
    }

    private var labelStyle: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        return prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    private var fillStyle: AnyShapeStyle {
        prominent && isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.quaternary)
    }

    private static var bezel: AnyShape {
        if #available(macOS 26.0, *) {
            return AnyShape(Capsule())
        }
        return AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct DetailRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct DetailDivider: View {
    var body: some View {
        Divider().padding(.leading, 36)
    }
}

// MARK: - Not Installed Badge

private struct NotInstalledBadge: View {
    var body: some View {
        Text("Not Installed")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
    }
}

// MARK: - Progress Button (disabled, spinning)

private struct ProgressButton: View {
    let title: String
    init(_ title: String) { self.title = title }
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button {} label: {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(
                    minWidth: GameDetailMetrics.launchButtonMinWidth,
                    minHeight: GameDetailMetrics.launchButtonHeight
                )
        }
        .inactiveAwareProminence(controlActiveState == .inactive)
        .controlSize(.large)
        .disabled(true)
    }
}

private extension View {
    @ViewBuilder
    func inactiveAwareProminence(_ inactive: Bool) -> some View {
        if inactive {
            self.buttonStyle(.bordered)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Launch mode popover row

// MARK: - Status Card

/// Shared HStack metrics for `BannerCompatBadge` (.card) and `StatusCard` so
/// icons and text share one column grid in the launch section.
private enum CompatCardRowMetrics {
    static let hStackSpacing: CGFloat = 11
    /// Leading symbol column — every row icon is centered here so dynamic
    /// stage glyphs share the verified-badge centerline and text starts flush.
    static let iconColumnWidth: CGFloat = 26
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
}

private struct StatusCard: View {
    let launcher: Launcher
    let openWindow: OpenWindowAction
    @Environment(SteamWindow.self) private var steamWindow

    /// Displayed launch fraction, eased toward the effective target (staged
    /// fraction + gentle creep while a stage is in flight).
    @State private var displayedLaunchFraction: Double = 0
    @State private var stageReachedAt = Date()
    @State private var lastStagedFraction: Double = 0
    @State private var isHovering = false

    /// What the card says: a short headline, a second line only when the
    /// player has something to do or to know, and a symbol. Steam's dozen
    /// boot statuses stay in the launch log; the card names the beat.
    private struct Beat: Equatable {
        let title: String
        var detail: String? = nil
        let symbol: String
    }

    var body: some View {
        let beat = self.beat
        let progress = progressValue
        VStack(alignment: .leading, spacing: 8) {
            // Center-aligned so the text block shares the icon's centerline —
            // matches BannerCompatBadge's card row (default .center HStack).
            HStack(alignment: .center, spacing: CompatCardRowMetrics.hStackSpacing) {
                statusIcon(beat.symbol)

                VStack(alignment: .leading, spacing: 1) {
                    Text(beat.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .id(beat.title)
                        .transition(.blurReplace)

                    if let detail = beat.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .transition(.blurReplace)
                        if let showSteamWindow {
                            // Steam's windows have no Dock icon: one that fell
                            // behind another window is only reachable from here.
                            Button("Show Steam's Window", action: showSteamWindow)
                                .buttonStyle(.link)
                                .font(.caption)
                                .transition(.blurReplace)
                        }
                    } else if let progressText = launcher.downloadProgressText {
                        // Updates in place on every tick: no transition, and
                        // fixed-width digits so the line doesn't jiggle.
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    } else if launcher.isRunning, let since = launcher.runningSince {
                        TimelineView(.everyMinute) { context in
                            Text(Self.playTime(since: since, now: context.date))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                .animation(.smooth(duration: 0.35), value: beat)

                Spacer(minLength: 6)

                if !launcher.isInstalling {
                    logButton
                }
            }

            if let progress {
                CapsuleProgressBar(
                    value: progress,
                    label: launcher.isLaunching ? "Launch progress" : "Download progress"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 8)
                // Align bar start with the text column; fill to the card's trailing inset.
                .padding(.leading, CompatCardRowMetrics.iconColumnWidth + CompatCardRowMetrics.hStackSpacing)
                // Lift the bar off the card's bottom edge so it sits
                // concentric with the rounded corner instead of hugging it.
                .padding(.bottom, 3)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, CompatCardRowMetrics.horizontalPadding)
        .padding(.vertical, CompatCardRowMetrics.verticalPadding)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .animation(.smooth(duration: 0.3), value: progress == nil)
        .onHover { isHovering = $0 }
        .onAppear {
            stageReachedAt = Date()
            lastStagedFraction = launcher.launchStageFraction
            easeLaunchFraction(to: effectiveLaunchTarget(at: Date()))
        }
        .onChange(of: launcher.steamSignIn == nil && launcher.steamWaitingOnPlayer == nil) {
            // Creep restarts after the sign-in or EULA instead of jumping by its length.
            stageReachedAt = Date()
        }
        .onChange(of: launcher.launchStageFraction) { _, newValue in
            if newValue > lastStagedFraction {
                lastStagedFraction = newValue
                stageReachedAt = Date()
            }
            easeLaunchFraction(to: effectiveLaunchTarget(at: Date()))
        }
        .task(id: launcher.isLaunching) {
            guard launcher.isLaunching else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                easeLaunchFraction(to: effectiveLaunchTarget(at: Date()))
            }
        }
    }

    // MARK: Copy

    /// Brings Steam's window back while the launch waits on it: its sign-in,
    /// or a dialog it raised (a EULA, "this game recommends a controller").
    private var showSteamWindow: (() -> Void)? {
        guard launcher.isLaunching else { return nil }
        if launcher.steamWaitingOnPlayer != nil {
            return { steamWindow.bringPromptForward() }
        }
        if launcher.steamSignIn != nil, steamWindow.isSignInWindowShown {
            return { steamWindow.bringSignInForward() }
        }
        return nil
    }

    private var beat: Beat {
        switch launcher.launchState {
        case .launching:
            // Steam's sign-in is the one moment the launch waits on the
            // player. A first-time Steam download inside it keeps its own beat.
            if let signIn = launcher.steamSignIn, launcher.launchPhase != .settingUpSteam {
                return Beat(
                    title: "Sign in to Steam",
                    detail: signIn == .signedOut
                        ? "Steam signed you out. Scan the code in its window with the Steam Mobile App."
                        : "Scan the code in Steam's window with the Steam Mobile App.",
                    symbol: "qrcode.viewfinder"
                )
            }
            // Steam is waiting on the player mid-launch (a game's EULA): its
            // window is on screen, and the card says what it wants.
            if let waiting = launcher.steamWaitingOnPlayer {
                return waiting == "ShowEula"
                    ? Beat(title: "Accept the license agreement",
                           detail: "It's open in Steam's window. Steam only asks the first time.",
                           symbol: "doc.text")
                    : Beat(title: "Steam needs your answer",
                           detail: "It's open in Steam's window.",
                           symbol: "hand.tap")
            }
            return Self.beat(for: launcher.launchPhase, step: launcher.launchStep)
        case .running:
            return Beat(title: "Now playing", symbol: "play.circle.fill")
        case .stopping:
            return Beat(title: "Quitting…", symbol: "stop.circle")
        case .installing, .downloading:
            return Beat(title: launcher.currentActivity ?? "Preparing download…", symbol: "arrow.down.circle")
        default:
            return Beat(title: launcher.currentActivity ?? "Working…", symbol: "arrow.down.circle")
        }
    }

    private static func beat(for phase: Launcher.LaunchPhase, step: String?) -> Beat {
        // One glyph for the usual launch: the play circle breathes while it
        // gets ready, then fills in green when the game is up.
        switch phase {
        case .gettingReady:
            // What Steam is doing on its way up (it can take 20 s from cold).
            return Beat(title: "Getting ready…", detail: step, symbol: "play.circle")
        case .settingUpSteam:
            return Beat(title: "Setting up Steam…", detail: "This only happens once.", symbol: "arrow.down.circle")
        case .updatingSteam:
            return Beat(title: "Updating Steam…", symbol: "arrow.triangle.2.circlepath")
        case .startingGame:
            // A glimpse of what Steam is doing, kept to the happy path.
            return Beat(title: "Starting the game…", detail: step, symbol: "play.circle")
        case .checkingFiles:
            return Beat(title: "Checking game files…", symbol: "doc.text.magnifyingglass")
        }
    }

    /// "Just started", then whole minutes: the card isn't a stopwatch.
    private static func playTime(since start: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        guard minutes >= 1 else { return "Just started" }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    // MARK: Progress

    /// Staged fraction plus a gentle creep while the current stage is in
    /// flight — keeps the bar moving during a 20 s Steam boot even when
    /// connection_log markers arrive in bursts.
    private func effectiveLaunchTarget(at date: Date) -> Double {
        let staged = launcher.launchStageFraction
        // Waiting on the player (Steam's sign-in, a game's EULA): no creep,
        // the bar holds.
        guard launcher.steamSignIn == nil, launcher.steamWaitingOnPlayer == nil else { return staged }
        let stallSeconds = date.timeIntervalSince(stageReachedAt)
        let creep = min(stallSeconds * 0.005, 0.14)
        return min(staged + creep, 0.92)
    }

    private var progressValue: Double? {
        if launcher.isInstalling { return launcher.downloadProgress }
        if launcher.isLaunching { return displayedLaunchFraction }
        return nil
    }

    /// Animates the displayed launch bar toward the target. Monotonic only.
    private func easeLaunchFraction(to target: Double) {
        let clamped = min(max(target, 0), 1)
        guard clamped > displayedLaunchFraction else { return }
        withAnimation(.easeOut(duration: 0.55)) {
            displayedLaunchFraction = clamped
        }
    }

    // MARK: Icon & log

    /// One glyph that morphs between beats. It breathes while the launch
    /// is in flight, its ring turns while the game starts, and it fills in
    /// and bounces green the moment the game is up. The symbol stays in place
    /// under the turning ring so that bounce still plays, and the ring
    /// inherits its font so the two are the same size.
    private func statusIcon(_ symbol: String) -> some View {
        let turning = symbol == "play.circle" && launcher.isLaunching && launcher.launchPhase == .startingGame
        return Image(systemName: symbol)
            .foregroundStyle(iconTint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating.speed(0.35), isActive: launcher.isLaunching && !turning)
            .symbolEffect(.bounce, value: launcher.isRunning)
            .animation(.snappy(duration: 0.35), value: symbol)
            .opacity(turning ? 0 : 1)
            .overlay {
                if turning {
                    TurningPlayGlyph(tint: iconTint)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: turning)
            .font(.title2.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: CompatCardRowMetrics.iconColumnWidth, alignment: .center)
    }

    private var iconTint: Color {
        switch launcher.launchState {
        case .running:  return .green
        case .stopping: return .secondary
        default:        return .accentColor
        }
    }

    /// The launch log stays one hover away: useful when something goes
    /// wrong, noise when it doesn't.
    private var logButton: some View {
        Button {
            openWindow(id: "launch-log")
        } label: {
            Image(systemName: "terminal")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Show Launch Log")
        .accessibilityLabel("Show Launch Log")
        .opacity(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// `play.circle` while the game starts: a stretch of the symbol's own ring
/// turns over the dimmed ring. Built from the symbols themselves in the
/// status icon's font, so it is exactly the still glyph's size. Drawn to
/// the symbol's frame instead, the ring was 17% larger (user, Oct 12 2026).
private struct TurningPlayGlyph: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        Image(systemName: "play.circle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(tint, tint.opacity(0.25))
            .overlay {
                // `circle` draws the same ring as `play.circle`; a wedge
                // from the centre shows 28% of it.
                Image(systemName: "circle")
                    .foregroundStyle(tint)
                    .mask {
                        GeometryReader { proxy in
                            Circle()
                                .trim(from: 0, to: 0.28)
                                .stroke(lineWidth: max(proxy.size.width, proxy.size.height))
                                .rotationEffect(.degrees(turning ? 270 : -90))
                                .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
                                           value: turning)
                        }
                    }
            }
            .onAppear { turning = true }
    }
}

private struct CapsuleProgressBar: View {
    let value: Double
    var label: String = "Download progress"

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.22))

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(proxy.size.width * clamped, proxy.size.height))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }
}

/// Achievement completion. Sits at 0 while the page is in flight, then fills
/// to `value` with a springy ease once `armed` (page landed) — the "counting
/// up" feel of a stats screen rather than a static bar fading in. Later value
/// changes (achievements arriving) animate the same way.
private struct AchievementProgressBar: View {
    let value: Double
    let armed: Bool
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(shown, 0), 1)
            let h: CGFloat = 6
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: clamped > 0 ? max(proxy.size.width * clamped, h) : 0)
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
        }
        .onChange(of: armed, initial: true) { _, on in if on { fill() } }
        .onChange(of: value) { _, _ in if armed { fill() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Achievement progress")
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }

    private func fill() {
        withAnimation(.spring(duration: 0.9, bounce: 0.22)) {
            shown = value
        }
    }
}

// MARK: - Shimmer (loading skeleton animation)

struct ShimmerView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear,            location: 0),
                    .init(color: .white.opacity(0.1), location: 0.4),
                    .init(color: .white.opacity(0.2), location: 0.5),
                    .init(color: .white.opacity(0.1), location: 0.6),
                    .init(color: .clear,            location: 1),
                ],
                startPoint: .init(x: phase - 0.3, y: 0.5),
                endPoint:   .init(x: phase + 0.3, y: 0.5)
            )
            .frame(width: w * 2)
            .offset(x: -w + phase * w * 2)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .clipped()
    }
}

// MARK: - Achievement Row

private struct AchievementRow: View {
    let achievement: GameAchievement

    var body: some View {
        HStack(spacing: 10) {
            AchievementIcon(
                url:     achievement.iconURL,
                grayURL: achievement.iconGrayURL,
                achieved: achievement.achieved
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(achievement.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let date = achievement.unlockDate {
                    TimelineView(.everyMinute) { context in
                        Text(Self.unlockedText(date, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Affordance so the row reads as tappable even on a trackpad
            // without hover; matches the chevron used in the "View all
            // on Steam" row below.
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())  // make the full row hit-test
    }

    /// "Just now", "12 min ago", "2 hr, 5 min ago" within a day, then the
    /// date. Whole minutes: a live `.relative` Text counted the seconds.
    private static func unlockedText(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        guard minutes >= 1 else { return "Just now" }
        guard minutes < 24 * 60 else { return date.formatted(date: .abbreviated, time: .omitted) }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " ago"
    }
}

// MARK: - Achievement Detail Sheet

/// Modal that shows the essentials for a single Steam achievement: glyph,
/// name, unlock status + date, description. Follows Apple HIG — a focused
/// sheet with a clear hierarchy and no developer metadata.
///
/// Hidden-achievement handling mirrors Steam's own behaviour: if the
/// achievement is flagged hidden AND the user hasn't unlocked it, we show
/// a generic "Hidden Achievement" title + locked glyph and no description.
/// Once unlocked, all fields render normally.
private struct AchievementDetailSheet: View {
    let achievement: GameAchievement

    @Environment(\.dismiss) private var dismiss

    private var isLockedHidden: Bool {
        achievement.isHidden && !achievement.achieved
    }

    private var title: String {
        isLockedHidden ? "Hidden Achievement" : achievement.displayName
    }

    private var description: String? {
        guard !isLockedHidden else { return nil }
        let text = achievement.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private var statusText: String {
        if let date = achievement.unlockDate {
            return "Unlocked \(date.formatted(date: .long, time: .shortened))"
        }
        return "Locked"
    }

    var body: some View {
        VStack(spacing: 20) {
            AchievementDetailIcon(
                url: achievement.iconURL,
                grayURL: achievement.iconGrayURL,
                achieved: achievement.achieved
            )

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2).fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Image(systemName: achievement.achieved ? "checkmark.seal.fill" : "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(achievement.achieved ? .green : .secondary)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let desc = description {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 420)
    }
}

/// Larger icon used by `AchievementDetailSheet` — mirrors `AchievementIcon`
/// but at 96 × 96 and without the subtle 45 % fade on locked icons (the
/// Steam-shipped grey asset is already visually distinct).
private struct AchievementDetailIcon: View {
    let url: URL?
    let grayURL: URL?
    let achieved: Bool

    var body: some View {
        CachedAsyncImage(url: achieved ? url : (grayURL ?? url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
                    .opacity(achieved ? 1.0 : 0.6)
            default:
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 96, height: 96)
                    .overlay(
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(achieved ? .yellow.opacity(0.85) : .secondary.opacity(0.5))
                    )
            }
        }
    }
}


private struct AchievementIcon: View {
    let url: URL?
    let grayURL: URL?
    let achieved: Bool

    var body: some View {
        CachedAsyncImage(url: achieved ? url : (grayURL ?? url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(achieved ? 1 : 0.45)
            default:
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.yellow.opacity(achieved ? 0.8 : 0.3))
                    .frame(width: 32, height: 32)
            }
        }
    }
}

// MARK: - Compat Badge (banner overlay)

/// Single-icon compatibility indicator shown in the hero banner.
/// Four visual states using seal icons:
///   - Green checkmark.seal.fill → verified or playable (tested, runs well)
///   - Yellow exclamationmark.seal.fill → launches with known issues
///   - Red xmark.seal.fill → confirmed broken
///   - Gray   checkmark.seal (outline)  → untracked / not yet tested
/// Tapping shows a popover with compatibility status and the rendering pipeline.
private struct BannerCompatBadge: View {
    /// Presentation: a bare seal icon (legacy banner overlay) or the premium
    /// full-width confirmation card shown under the Play button.
    enum Style { case icon, card }

    let status: CompatStatus
    var profile: GameProfile?
    var resolved: ResolvedGameStack? = nil
    var style: Style = .icon
    @Environment(WineEngine.self) private var engine
    @State private var showingPopover = false

    /// D3D9 goes through DXVK and KosmicKrisp only for games that opt in
    /// (`GameProfile.preferDXVK`), as `SteamSession.gameEnvironment` routes it.
    private var d3d9OnMetal: Bool { engine.dxvkPath != nil && profile?.preferDXVK == true }
    /// D3D12 goes through D3DMetal only where the engine carries GPTK;
    /// otherwise Wine's vkd3d (`SteamSession.gameEnvironment`).
    private var d3d12OnD3DMetal: Bool { engine.gptkPath != nil }

    private var icon: String {
        switch status {
        case .verified, .playable: return "checkmark.seal.fill"
        case .launches:            return "exclamationmark.triangle.fill"
        case .broken:              return "xmark.seal.fill"
        case .untested:            return "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .verified, .playable: return .green
        case .launches:            return .yellow
        case .broken:              return .red
        case .untested:            return Color(white: 0.55)
        }
    }

    private var statusTitle: String {
        switch status {
        case .verified: return "Meridian Verified"
        case .playable: return "Works Well"
        case .launches: return "Runs with Issues"
        case .broken:   return "Not Compatible"
        case .untested: return "Not Yet Tested"
        }
    }

    private var statusDetail: String {
        switch status {
        case .verified:
            return "This game is verified with Meridian and optimized for your Mac."
        case .playable:
            return "This game is verified with Meridian, but has some known issues."
        case .launches:
            return "This game runs, but has significant known issues during play."
        case .broken:
            return "This game isn’t compatible with Meridian."
        case .untested:
            return "This game hasn’t been tested with Meridian yet."
        }
    }

    /// Whether to show the "Optimized for Apple Silicon" tagline.
    /// Only shown when the game is known to be working and has a confirmed rendering path.
    private var showAppleSiliconBadge: Bool {
        switch status {
        case .verified, .playable: return pipelineInfo != nil
        default:                   return false
        }
    }

    /// One-line reassurance shown under the status title in the card style.
    private var cardSubtitle: String {
        switch status {
        case .verified:
            return showAppleSiliconBadge ? "Optimized for Apple Silicon" : "Runs well on your Mac"
        case .playable: return "Verified, with a few known issues"
        case .launches: return "Runs, with some known issues"
        case .broken:   return "Not currently compatible"
        case .untested: return "Not yet tested. Give it a try"
        }
    }

    // MARK: Pipeline info (resolved stack preferred, explicit profile fallback)

    private struct PipelineInfo {
        let engine: String
        let api: String
        let translation: String
        let bitness: String?
        /// Provenance of the engine / API facts, shown as a small gray SF
        /// symbol next to each row (verified / PCGamingWiki / detected).
        let engineSource: ResolvedGameStack.Source?
        let apiSource: ResolvedGameStack.Source?
    }

    private var pipelineInfo: PipelineInfo? {
        if let r = resolved {
            return PipelineInfo(
                engine: r.engineName,
                api: r.graphicsAPI.displayName,
                translation: r.graphicsAPI.translationLayer(d3d9OnMetal: d3d9OnMetal, d3d12OnD3DMetal: d3d12OnD3DMetal),
                bitness: r.bitness != nil ? r.bitnessDescription : nil,
                engineSource: r.engineSource,
                apiSource: r.apiSource
            )
        }
        if let p = profile {
            // A hand-written compat profile is, by definition, verified.
            return PipelineInfo(
                engine: p.gameEngine.displayName,
                api: p.graphicsAPI.displayName,
                translation: p.graphicsAPI.translationLayer(d3d9OnMetal: d3d9OnMetal, d3d12OnD3DMetal: d3d12OnD3DMetal),
                bitness: nil,
                engineSource: .explicit,
                apiSource: .explicit
            )
        }
        return nil
    }

    /// SF symbol representing where a tech fact came from. Kept gray (matching
    /// the row text) in the popover.
    private func sourceIcon(_ s: ResolvedGameStack.Source) -> String {
        switch s {
        case .explicit: return "checkmark.seal"
        case .pcgw:     return "globe"
        case .detected: return "magnifyingglass"
        case .unknown:  return "questionmark.circle"
        }
    }

    private func sourceHelp(_ s: ResolvedGameStack.Source) -> String {
        switch s {
        case .explicit: return "Verified by Meridian"
        case .pcgw:     return "From PCGamingWiki"
        case .detected: return "Detected from the game's files"
        case .unknown:  return "Inferred"
        }
    }

    var body: some View {
        switch style {
        case .icon: iconBody
        case .card: cardBody
        }
    }

    private var iconBody: some View {
        Image(systemName: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .onTapGesture { showingPopover.toggle() }
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                pipelinePopover
            }
            .contentShape(Rectangle())
    }

    private var cardBody: some View {
        Button { showingPopover.toggle() } label: {
            HStack(spacing: CompatCardRowMetrics.hStackSpacing) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: CompatCardRowMetrics.iconColumnWidth, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(cardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Image(systemName: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, CompatCardRowMetrics.horizontalPadding)
            .padding(.vertical, CompatCardRowMetrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            pipelinePopover
        }
    }

    @ViewBuilder
    private var pipelinePopover: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Status header ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.headline)
                Text(statusTitle)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            // ── Rendering pipeline card ──────────────────────────────────────
            // Prefer the resolved stack (local detection + PCGamingWiki +
            // explicit profile, merged) so the pipeline shows even for games
            // with no hand-written compat entry. Falls back to the explicit
            // profile when the resolver hasn't run (e.g. not installed yet).
            if let pipeline = pipelineInfo {
                Divider()
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Rendering Pipeline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.4)

                    pipelineRow(label: "Game Engine",   value: pipeline.engine, source: pipeline.engineSource)
                    pipelineRow(label: "Graphics API",  value: pipeline.api,    source: pipeline.apiSource)
                    pipelineRow(label: "Translation",   value: pipeline.translation)
                    if let bitness = pipeline.bitness {
                        pipelineRow(label: "Architecture", value: bitness)
                    }
                    pipelineRow(label: "Output",        value: "Apple Metal")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // ── Apple Silicon optimized tagline ──────────────────────────
                if showAppleSiliconBadge {
                    Divider()
                        .padding(.horizontal, 8)

                    HStack(spacing: 6) {
                        Image(systemName: "apple.logo")
                            .font(.caption.weight(.semibold))
                        Text("Optimized for Apple Silicon")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(width: 280)
    }

    private func pipelineRow(
        label: String,
        value: String,
        source: ResolvedGameStack.Source? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            if let source {
                // Provenance marker — same gray as the row label text.
                Image(systemName: sourceIcon(source))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(sourceHelp(source))
            }
        }
    }
}

// MARK: - Compat Badge (info card row)

private struct CompatBadge: View {
    let status: CompatStatus

    private var label: String {
        switch status {
        case .verified: return "Verified"
        case .playable:  return "Works Well"
        case .launches:  return "Issues"
        case .broken:    return "Not Compatible"
        case .untested:  return "Untested"
        }
    }

    private var color: Color {
        switch status {
        case .verified: return .green
        case .playable:  return Color(hue: 0.25, saturation: 0.70, brightness: 0.65)
        case .launches:  return Color(hue: 0.12, saturation: 0.90, brightness: 0.85)
        case .broken:    return .red
        case .untested:  return Color(white: 0.50)
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Metacritic Badge

private struct MetacriticBadge: View {    let score: Int

    private var color: Color {
        switch score {
        case 75...: return .green
        case 50..<75: return Color(hue: 0.12, saturation: 0.9, brightness: 0.85)
        default: return .red
        }
    }

    var body: some View {
        Text("\(score)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Launch Log Window

struct LaunchLogWindow: View {
    @Environment(Launcher.self) private var launcher

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(minWidth: 500, minHeight: 280)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Launch Log")
                .font(.headline)
            Spacer()
            if !launcher.logs.isEmpty {
                Text("\(launcher.logs.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    let text = launcher.logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            } else {
                Text("No output yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if launcher.logs.isEmpty {
                        Text("Waiting for output…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    } else {
                        ForEach(Array(launcher.logs.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .onChange(of: launcher.logs.count) { _, n in
                guard n > 0 else { return }
                proxy.scrollTo(n - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - HTML entity decoding

private extension String {
    /// Decodes the HTML character entities that Steam's store API sometimes
    /// embeds in short descriptions (e.g. &quot; → ", &amp; → &).
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        // Named entities ordered so &amp; is decoded last to avoid
        // converting &amp;quot; → &quot; → " (double-decode).
        let named: [(String, String)] = [
            ("&quot;",  "\""),
            ("&apos;",  "'"),
            ("&#39;",   "'"),
            ("&#x27;",  "'"),
            ("&lt;",    "<"),
            ("&gt;",    ">"),
            ("&nbsp;",  " "),
            ("&amp;",   "&"),   // last — must not run before the others
        ]
        var result = self
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
