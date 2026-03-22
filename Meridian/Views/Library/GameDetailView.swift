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

    @Environment(SteamLibraryStore.self)  private var library
    @Environment(WineEngine.self)         private var engine
    @Environment(WineSteamManager.self)   private var steamManager
    @Environment(SteamAuthService.self)   private var steamAuth
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self)       private var launcher
    @Environment(\.openWindow)            private var openWindow
    @Environment(\.controlActiveState)    private var controlActiveState

    @State private var showEngineSetup = false
    @State private var showResetConfirm = false
    @State private var showInfoPopover = false
    @State private var appDetails: AppDetails? = nil
    /// Width÷height from the loaded hero `NSImage` (falls back to Steam's typical 1920×622 until decode).
    @State private var heroAspectRatio: CGFloat = SteamLibraryHeroMetrics.aspectRatio
    /// Drives the zoom-in appear animation.
    @State private var appeared = false
    /// Banner image loaded directly — avoids the `GeometryReader` wrapper inside
    /// `HeroBannerImage`, which introduced an internal CALayer boundary that
    /// produced a faint rounded-corner artefact at the clip boundary on macOS 15.
    @State private var bannerImage: NSImage? = nil
    @State private var bannerImageFailed = false

    private func bannerHeight(contentWidth: CGFloat) -> CGFloat {
        contentWidth / heroAspectRatio
    }

    var body: some View {
        GeometryReader { proxy in
            let inset  = GameDetailMetrics.cardInset
            let radius = GameDetailMetrics.cardCornerRadius
            // Cards are inset 16 pt on each side, so their render width is the
            // column width minus two insets.
            let cardWidth = proxy.size.width - inset * 2

            ScrollView {
                VStack(alignment: .leading, spacing: inset) {

                    // ── Banner card ───────────────────────────────────────────
                    // Flat ZStack: Color.black + direct Image from @State (no
                    // GeometryReader inside), gradient, logo, buttons.
                    // ONE clipShape with .continuous corners — nothing else clips
                    // this view tree, so there is exactly one rounded boundary.
                    heroBanner(
                        contentWidth: cardWidth,
                        bannerFrameHeight: bannerHeight(contentWidth: cardWidth)
                    )

                    // ── Info card ─────────────────────────────────────────────
                    // Background: direct Image from @State (no HeroBannerImage /
                    // GeometryReader), blurred + thinMaterial.  No extra clip
                    // inside .background{}; the single outer clipShape below is
                    // the ONLY rounded boundary on this card.
                    VStack(alignment: .leading, spacing: 12) {
                        launchSection
                        statsSection
                    }
                    .padding(GameDetailMetrics.horizontalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // System window colour at full opacity as the base, then
                        // the blurred art at exactly 25 % on top — same ratio in
                        // both light and dark mode, so the card always feels
                        // consistent regardless of colour scheme.
                        Color(nsColor: .windowBackgroundColor)
                        if let img = bannerImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 60)
                                .saturation(1.2)
                                .opacity(0.25)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
                }
                .padding(inset)
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background {
            // Very subtle ambient colour bleed from the game's art — fills the
            // full column including safe areas so the tint shows in the margins
            // and behind the navigation bar, matching the Apple Music album feel.
            if let img = bannerImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .blur(radius: 80)
                    .saturation(1.2)
                    .opacity(0.12)
            }
        }
        .scaleEffect(appeared ? 1 : 0.94, anchor: .center)
        .opacity(appeared ? 1 : 0)
        .blur(radius: appeared ? 0 : 6)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .navigationTitle(currentGame.name)
        .onExitCommand(perform: onDismiss)
        .onChange(of: game.id) { _, _ in
            appeared = false
            heroAspectRatio = SteamLibraryHeroMetrics.aspectRatio
            appDetails = nil
            bannerImage = nil
            bannerImageFailed = false
        }
        .task(id: game.id) {
            appDetails = try? await SteamAPIService.shared.fetchAppDetails(appID: game.id)
        }
        .task(id: game.id) {
            await loadBannerImage()
        }
        .sheet(isPresented: $showEngineSetup) {
            EngineSetupView().environment(engine)
        }
        .alert("Reset Wine Environment?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await launcher.cleanupProcesses(engine: engine, steamManager: steamManager)
                    WinePrefix.defaultPrefix.reset()
                }
            }
        } message: {
            Text("This will delete the Wine prefix, Steam installation, and all downloaded game files. On next launch, everything will be set up fresh.")
        }
    }

    // MARK: - Hero Banner

    private func heroBanner(contentWidth: CGFloat, bannerFrameHeight: CGFloat) -> some View {
        let g = currentGame
        let w = contentWidth
        let h = bannerFrameHeight

        // clipShape lives here, directly on the art — not on a ZStack that also
        // contains gradients, logos, and buttons.  Those elements go into .overlay
        // calls on the already-clipped view so they are never inside the clip
        // computation and cannot produce corner-boundary artefacts.
        return Group {
            if let img = bannerImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if bannerImageFailed {
                Rectangle()
                    .fill(.black)
                    .overlay {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(.tertiary)
                    }
            } else {
                Rectangle()
                    .fill(.black)
                    .overlay { ShimmerView() }
            }
        }
        .id(g.id)
        .frame(width: w, height: h)
        // ── overlays first, then ONE clip for everything ──────────────────
        .overlay {
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .init(x: 0.5, y: 0.3),
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .overlay {
            HeroLogoImage(
                urls: g.newCDNLogoURLs + [g.logoURL] + g.logoURLFallbacks,
                fallbackName: g.name
            )
            .padding(.leading, GameDetailMetrics.horizontalPadding)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .id(g.id)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if g.playtimeMinutes > 0 {
                        Text(g.playtimeFormatted + " played")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        library.toggleFavorite(appID: g.id)
                    } label: {
                        Image(systemName: library.isFavorite(appID: g.id) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(library.isFavorite(appID: g.id) ? .pink : .white.opacity(0.85))
                    }
                    .buttonStyle(.borderless)
                    .help(library.isFavorite(appID: g.id) ? "Remove from Favorites" : "Add to Favorites")

                    Button { showInfoPopover.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.borderless)
                    .help("Game info and logs")
                    .popover(isPresented: $showInfoPopover, arrowEdge: .bottom) {
                        infoPopoverContent
                    }
                }
            }
            .padding(.horizontal, GameDetailMetrics.horizontalPadding)
            .padding(.bottom, 16)
            .frame(width: w)
        }
        .clipShape(RoundedRectangle(cornerRadius: GameDetailMetrics.cardCornerRadius, style: .continuous))
    }

    // MARK: - Banner image loading

    /// Loads the hero banner image via the cache then network, mirroring
    /// `HeroBannerImage.loadImage()` but writing directly to `@State`
    /// so the banner can render as a plain `Image` with no `GeometryReader`.
    private func loadBannerImage() async {
        let urls = [currentGame.heroURL] + currentGame.heroURLFallbacks

        for url in urls {
            if let cached = ImageCache.shared.image(for: url) {
                let r = cached.size.width / cached.size.height
                if r > 0.05, r < 20 { heroAspectRatio = r }
                bannerImage = cached
                return
            }
        }

        for url in urls {
            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let img = NSImage(data: data) else { continue }
                ImageCache.shared.store(img, for: url)
                let r = img.size.width / img.size.height
                if r > 0.05, r < 20 { heroAspectRatio = r }
                bannerImage = img
                return
            } catch { continue }
        }

        bannerImageFailed = true
    }

    // MARK: - Info Popover

    private var infoPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoPopoverRow("App ID", value: String(currentGame.id), monospaced: true)

            if currentGame.windowsOnly {
                Divider().padding(.leading, 12)
                HStack {
                    Text("Compatibility")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                    WindowsBadge()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            Divider().padding(.leading, 12)

            Button {
                showInfoPopover = false
                openWindow(id: "launch-log")
            } label: {
                Label("View Launch Logs", systemImage: "terminal")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().padding(.leading, 12)

            Button {
                showInfoPopover = false
                try? steamManager.showSteamUI(engine: engine, prefix: WinePrefix.defaultPrefix)
            } label: {
                Label("Show Steam", systemImage: "gamecontroller")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if currentGame.isInstalled {
                Divider().padding(.leading, 12)

                Button(role: .destructive) {
                    showInfoPopover = false
                    launcher.uninstall(
                        game: currentGame,
                        engine: engine,
                        steamManager: steamManager,
                        library: library
                    )
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .frame(width: 240)
        .padding(.vertical, 4)
    }

    private func infoPopoverRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Launch section

    @ViewBuilder
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            playButton
            if isThisGameActive {
                StatusCard(game: currentGame, launcher: launcher, openWindow: openWindow)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: isThisGameActive)
            }
        }
    }

    // MARK: - Stats / Info section

    @ViewBuilder
    private var statsSection: some View {
        // Short description from store API
        if let desc = appDetails?.shortDescription, !desc.isEmpty {
            Text(desc)
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
    }

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
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private var gameInfoCard: some View {
        let genres = appDetails?.genres?.compactMap(\.description).filter { !$0.isEmpty } ?? []
        let developer = appDetails?.developers?.first
        let publisher = appDetails?.publishers?.first
        let hasAnyInfo = !genres.isEmpty || developer != nil || publisher != nil || currentGame.windowsOnly

        if hasAnyInfo {
            VStack(spacing: 0) {
                // Install status
                DetailRow(
                    icon: currentGame.isInstalled ? "internaldrive" : "icloud.and.arrow.down",
                    label: "Installation",
                    value: currentGame.isInstalled ? "Installed" : "Not Installed",
                    valueColor: currentGame.isInstalled ? .green : .orange
                )

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
        .modifier(GlassRoundedBackground(cornerRadius: 10))
    }

    // MARK: - Per-game gating

    private var isThisGame: Bool {
        launcher.activeAppID == game.id
    }

    private var isThisGameActive: Bool {
        guard isThisGame else { return false }
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam,
             .installing, .launching, .running, .stopping, .uninstalling:
            return true
        default:
            return false
        }
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
        case .idle, .exited:
            idleButton

        case .preparingEngine, .preparingPrefix:
            HStack(spacing: 8) {
                ProgressButton(launcher.currentActivity ?? "Preparing…")
                cancelButton
            }

        case .bootstrappingSteam:
            HStack(spacing: 8) {
                ProgressButton("Updating Steam…")
                cancelButton
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressButton(launcher.currentActivity ?? "Installing…")
                cancelButton
            }

        case .launching:
            HStack(spacing: 8) {
                ProgressButton("Launching…")
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
            ProgressButton(launcher.currentActivity ?? "Uninstalling…")

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
                        Button { handlePlayTapped() } label: {
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
                    .help("Delete Wine prefix and start fresh")
                }

                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var idleButton: some View {
        Button { handlePlayTapped() } label: {
            Label(
                currentGame.isInstalled ? "Play" : "Install & Play",
                systemImage: currentGame.isInstalled ? "play.fill" : "arrow.down.circle.fill"
            )
            .font(.headline)
            .frame(
                minWidth: GameDetailMetrics.launchButtonMinWidth,
                minHeight: GameDetailMetrics.launchButtonHeight
            )
        }
        .inactiveAwareProminence(controlActiveState == .inactive)
        .controlSize(.large)
        .disabled(!steamAuth.isAuthenticated || isLauncherBusyWithOtherGame)
        .help(isLauncherBusyWithOtherGame ? "Stop the current game before launching another" : "")
    }

    private var isLauncherBusyWithOtherGame: Bool {
        guard let activeID = launcher.activeAppID, activeID != game.id else { return false }
        switch launcher.launchState {
        case .idle, .exited, .failed: return false
        default: return true
        }
    }

    private var cancelButton: some View {
        Button {
            Task { await launcher.cancelLaunch(engine: engine, steamManager: steamManager) }
        } label: {
            Label("Cancel", systemImage: "xmark")
                .frame(minHeight: GameDetailMetrics.launchButtonHeight)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var stopButton: some View {
        Button {
            Task { await launcher.stopGame(engine: engine, steamManager: steamManager) }
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

    private func handlePlayTapped() {
        guard engine.isReady else {
            showEngineSetup = true
            return
        }
        launcher.launch(
            game: currentGame,
            engine: engine,
            steamManager: steamManager,
            sessionBridge: sessionBridge,
            library: library
        )
    }
}

// MARK: - Detail Row helpers

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

// MARK: - Status Card

private struct StatusCard: View {
    let game: Game
    let launcher: GameLauncher
    let openWindow: OpenWindowAction

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    statusIcon

                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusMessage(at: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let elapsed = elapsedText(at: context.date) {
                            Text(elapsed)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }

                    Spacer()

                    Button {
                        openWindow(id: "launch-log")
                    } label: {
                        Label("Logs", systemImage: "terminal")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Open launch log window")
                }
                .padding(12)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch launcher.launchState {
        case .running:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
        case .stopping:
            Image(systemName: "stop.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        default:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 18, height: 18)
        }
    }

    private func statusMessage(at date: Date) -> String {
        switch launcher.launchState {
        case .preparingEngine:
            return launcher.currentActivity ?? "Checking Wine runtime…"
        case .preparingPrefix:
            return launcher.currentActivity ?? "Preparing Wine environment…"
        case .bootstrappingSteam:
            return "Updating Steam — first launch takes a few minutes"
        case .launching:
            if let last = launcher.logs.last, !last.isEmpty {
                return last
            }
            return "Waiting for Steam to start \(game.name)…"
        case .running:
            return "\(game.name) is running"
        case .stopping:
            return "Stopping…"
        default:
            return launcher.currentActivity ?? "Working…"
        }
    }

    private func elapsedText(at date: Date) -> String? {
        let start: Date?
        switch launcher.launchState {
        case .running:
            start = launcher.runningSince ?? launcher.pipelineStartDate
        default:
            start = launcher.pipelineStartDate
        }
        guard let start else { return nil }
        let secs = Int(date.timeIntervalSince(start))
        guard secs >= 3 else { return nil }
        let mins = secs / 60
        let rem  = secs % 60
        return mins > 0 ? "\(mins)m \(rem)s" : "\(rem)s"
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

// MARK: - Launch Log Window

struct LaunchLogWindow: View {
    @Environment(GameLauncher.self) private var launcher

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
