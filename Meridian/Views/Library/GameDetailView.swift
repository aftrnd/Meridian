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
    @Environment(GameLauncher.self)       private var launcher
    @Environment(BootstrapManager.self)   private var bootstrap
    @Environment(EngineDownloader.self)   private var engineDownloader
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(\.openWindow)            private var openWindow
    @Environment(\.controlActiveState)    private var controlActiveState

    @State private var showEngineSetup = false
    @State private var showResetConfirm = false
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
    @State private var achievements: [GameAchievement] = []
    @State private var achievementsLoading = false
    @State private var achievementsUnavailable = false
    /// When non-nil, the achievement-detail sheet is presented for this row.
    /// Using `sheet(item:)` so each selection replaces the previous without
    /// a dismiss bounce.
    @State private var selectedAchievement: GameAchievement? = nil

    private func bannerHeight(contentWidth: CGFloat) -> CGFloat {
        contentWidth / heroAspectRatio
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

                        // Right: achievements — natural 1/4 width, minimum 425 pt.
                        // At large windows the 1/4 rule applies; at small windows the
                        // 425 pt floor holds and the left card shrinks to whatever remains.
                        achievementsCard(radius: radius)
                            .frame(width: max(250, (cardWidth - inset) / 4))
                    }
                }
                .padding(.horizontal, inset)
                .padding(.bottom, inset)
            }
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
        .toolbar {
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
                        Task {
                            await steamManager.showSteamUI(engine: engine, prefix: WinePrefix.defaultPrefix)
                        }
                    } label: {
                        Label("Show Steam", systemImage: "gamecontroller")
                    }

                    if currentGame.isInstalled {
                        Divider()
                        Button(role: .destructive) {
                            launcher.uninstall(
                                game: currentGame,
                                engine: engine,
                                steamManager: steamManager,
                                library: library
                            )
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
        .onExitCommand(perform: onDismiss)
        .onChange(of: game.id) { _, _ in
            appeared = false
            heroAspectRatio = SteamLibraryHeroMetrics.aspectRatio
            appDetails = nil
            bannerImage = nil
            bannerImageFailed = false
            achievements = []
            achievementsLoading = false
            achievementsUnavailable = false
        }
        .task(id: game.id) {
            appDetails = try? await SteamAPIService.shared.fetchAppDetails(appID: game.id)
        }
        .task(id: game.id) {
            await loadBannerImage()
        }
        .task(id: game.id) {
            await loadAchievements()
        }
        .sheet(isPresented: $showEngineSetup) {
            EngineSetupView().environment(engine)
        }
        .sheet(item: $selectedAchievement) { ach in
            AchievementDetailSheet(achievement: ach, gameName: currentGame.name)
        }
        .alert("Reset Wine Environment?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await launcher.cleanupProcesses(engine: engine, steamManager: steamManager)
                    WinePrefix.defaultPrefix.reset()
                    // Re-run the full bootstrap pipeline so the app recovers immediately
                    // without requiring a restart. ContentView watches bootstrap.isReady
                    // and shows SplashView while the pipeline runs.
                    bootstrap.retry(
                        engine: engine,
                        steamManager: steamManager,
                        sessionBridge: sessionBridge,
                        engineDownloader: engineDownloader
                    )
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

        // Color.black establishes the frame as a concrete view (not a Group),
        // which prevents the SwiftUI layout engine from implicitly clipping the
        // image to the frame's straight edges before clipShape rounds the corners.
        // The image lives entirely in .overlay so it overflows the layout frame
        // freely — the one and only clip boundary is the final clipShape below.
        return Color.black
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
            .overlay(alignment: .bottomLeading) {
                let compatProfile = GameCompatibilityDB.shared.profile(for: g.id)
                HStack(alignment: .bottom, spacing: 6) {
                    BannerCompatBadge(status: compatProfile?.status ?? .untested,
                                      profile: compatProfile)
                    if g.playtimeMinutes > 0 {
                        Text(g.playtimeFormatted + " played")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, GameDetailMetrics.horizontalPadding)
                .padding(.bottom, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: GameDetailMetrics.cardCornerRadius, style: .continuous))
    }

    // MARK: - Banner image loading

    /// Loads the hero banner image via the cache then network, mirroring
    /// `HeroBannerImage.loadImage()` but writing directly to `@State`
    /// so the banner can render as a plain `Image` with no `GeometryReader`.
    private func loadBannerImage() async {
        let urls = currentGame.newCDNHeroURLs + [currentGame.heroURL] + currentGame.heroURLFallbacks

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
                let (data, response) = try await URLSession.imageSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let img = NSImage(data: data) else { continue }
                ImageCache.shared.store(img, for: url, rawData: data)
                let r = img.size.width / img.size.height
                if r > 0.05, r < 20 { heroAspectRatio = r }
                bannerImage = img
                return
            } catch { continue }
        }

        bannerImageFailed = true
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
        let genres     = appDetails?.genres?.compactMap(\.description).filter { !$0.isEmpty } ?? []
        let developer  = appDetails?.developers?.first
        let publisher  = appDetails?.publishers?.first
        let metacritic = appDetails?.metacritic?.score
        let releaseStr = appDetails?.releaseDate?.date.flatMap { $0.isEmpty ? nil : $0 }
        let hasAnyInfo = !genres.isEmpty || developer != nil || publisher != nil
            || currentGame.windowsOnly || metacritic != nil || releaseStr != nil

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
        .modifier(GlassRoundedBackground(cornerRadius: 10))
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
                    ProgressView().scaleEffect(0.7)
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
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                        Text(unlocked.count == 0
                             ? "None unlocked yet — keep playing!"
                             : "\(unlocked.count) of \(storeTotal) unlocked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Recent unlocked list
                if recentUnlocked.isEmpty {
                    Text("None unlocked yet — keep playing!")
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
                .modifier(GlassRoundedBackground(cornerRadius: 10))
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

    private func loadAchievements() async {
        let key = steamAuth.apiKey
        let sid = steamAuth.steamID
        guard !key.isEmpty, !sid.isEmpty else { return }
        achievementsLoading = true
        achievementsUnavailable = false
        defer { achievementsLoading = false }
        do {
            let result = try await SteamAPIService.shared.fetchPlayerAchievements(
                steamID: sid,
                apiKey: key,
                appID: game.id
            )
            achievements = result
            // Empty result is valid (game has no achievement system); not an error.
        } catch {
            achievements = []
            achievementsUnavailable = true
        }
    }

    // MARK: - Per-game gating

    private var isThisGame: Bool {
        launcher.activeAppID == game.id
    }

    private var isThisGameActive: Bool {
        guard isThisGame else { return false }
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam,
             .awaitingInstallConfirmation, .launching, .running, .stopping, .uninstalling:
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

        case .awaitingInstallConfirmation:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressButton("Downloading…")
                    cancelButton
                }
                if let progress = launcher.downloadProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                        if let activity = launcher.currentActivity {
                            Text(activity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
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
                        Button { currentGame.isInstalled ? handlePlayTapped() : handleInstallTapped() } label: {
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

    @ViewBuilder
    private var idleButton: some View {
        if currentGame.isInstalled {
            Button { handlePlayTapped() } label: {
                Label("Play", systemImage: "play.fill")
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
        } else {
            Button { handleInstallTapped() } label: {
                Label("Install", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(
                        minWidth: GameDetailMetrics.launchButtonMinWidth,
                        minHeight: GameDetailMetrics.launchButtonHeight
                    )
            }
            .inactiveAwareProminence(controlActiveState == .inactive)
            .controlSize(.large)
            .disabled(!steamAuth.isAuthenticated || isLauncherBusyWithOtherGame)
            .help(isLauncherBusyWithOtherGame ? "Another game is currently active" : "")
        }
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

    private func handleInstallTapped() {
        guard engine.isReady else {
            showEngineSetup = true
            return
        }
        launcher.installOnly(
            game: currentGame,
            engine: engine,
            steamManager: steamManager,
            steamAuth: steamAuth,
            library: library
        )
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
            steamAuth: steamAuth,
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
        case .awaitingInstallConfirmation:
            return "Downloading…"
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
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
}

// MARK: - Achievement Detail Sheet

/// Modal that shows the full details for a single Steam achievement. Reuses
/// the same fixed-width / padded-card shape as `SetupSheet` (sign-in) so the
/// app's modal vocabulary stays consistent.
private struct AchievementDetailSheet: View {
    let achievement: GameAchievement
    let gameName: String

    @Environment(\.dismiss) private var dismiss

    private var isLockedHidden: Bool {
        achievement.isHidden && !achievement.achieved
    }

    private var headlineTitle: String {
        isLockedHidden ? "Hidden Achievement" : achievement.displayName
    }

    private var descriptionText: String? {
        if isLockedHidden {
            // Steam explicitly hides the description until unlocked — mirror
            // that behaviour rather than showing the Steam-schema hint.
            return "This achievement's description is hidden until you unlock it."
        }
        let text = achievement.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private var unlockDateFormatted: String? {
        guard let date = achievement.unlockDate else { return nil }
        return date.formatted(date: .long, time: .shortened)
    }

    var body: some View {
        VStack(spacing: 24) {
            // Close button aligned top-trailing, same row as a grabber for
            // consistency with macOS sheet conventions.
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            // Hero icon
            AchievementDetailIcon(
                url: achievement.iconURL,
                grayURL: achievement.iconGrayURL,
                achieved: achievement.achieved
            )

            // Title + status badge
            VStack(spacing: 8) {
                Text(headlineTitle)
                    .font(.title2).fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                StatusBadge(achieved: achievement.achieved)

                Text(gameName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Description (full, wrap-friendly)
            if let desc = descriptionText {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            // Facts table — only non-empty rows rendered
            VStack(spacing: 0) {
                if let when = unlockDateFormatted {
                    detailRow(label: "Unlocked", value: when)
                }
                if achievement.isHidden {
                    detailRow(label: "Hidden", value: "Steam hides this until unlocked")
                }
                detailRow(label: "API name", value: achievement.apiName, monospaced: true)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .frame(width: 460)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)  // API name is useful to copy for debugging
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 90)
        }
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

/// Pill-style achievement-status badge (Unlocked / Locked) shown under the
/// achievement title in the detail sheet. Deliberately subtler than a
/// bordered label so the heading stays the focal point.
private struct StatusBadge: View {
    let achieved: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: achieved ? "checkmark.seal.fill" : "lock.fill")
                .font(.caption2)
            Text(achieved ? "Unlocked" : "Locked")
                .font(.caption).fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(achieved ? .green : .secondary)
        .background(
            Capsule()
                .fill((achieved ? Color.green : Color.secondary).opacity(0.12))
        )
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
    let status: CompatStatus
    var profile: GameProfile?
    @State private var showingPopover = false

    private var icon: String {
        switch status {
        case .verified, .playable: return "checkmark.seal.fill"
        case .launches:            return "seal.fill"
        case .broken:              return "xmark.seal.fill"
        case .untested:            return "xmark.seal.fill"
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
        case .playable:  return "Playable"
        case .launches:  return "Launches with Issues"
        case .broken:    return "Not Compatible"
        case .untested:  return "Not Yet Tested"
        }
    }

    private var statusDetail: String {
        switch status {
        case .verified:
            return "This game has been tested and runs well on your Mac with Meridian."
        case .playable:
            return "This game runs with minor issues. Expect a generally good experience."
        case .launches:
            return "This game starts but may have significant issues during play."
        case .broken:
            return "This game currently does not work with Meridian."
        case .untested:
            return "This game has not yet been tested with Meridian. It may or may not work."
        }
    }

    /// Whether to show the "Optimized for Apple Silicon" tagline.
    /// Only shown when the game is known to be working and has a confirmed rendering path.
    private var showAppleSiliconBadge: Bool {
        switch status {
        case .verified, .playable: return profile != nil
        default:                   return false
        }
    }

    var body: some View {
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

            // ── Rendering pipeline card (shown when profile exists) ──────────
            if let p = profile {
                Divider()
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Rendering Pipeline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.4)

                    pipelineRow(label: "Game Engine",   value: p.gameEngineDisplayName)
                    pipelineRow(label: "Graphics API",  value: p.graphicsAPIDisplayName)
                    pipelineRow(label: "Translation",   value: p.translationLayerDescription)
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
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(width: 280)
    }

    private func pipelineRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Compat Badge (info card row)

private struct CompatBadge: View {
    let status: CompatStatus

    private var label: String {
        switch status {
        case .verified: return "Verified"
        case .playable:  return "Playable"
        case .launches:  return "Launches"
        case .broken:    return "Broken"
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
