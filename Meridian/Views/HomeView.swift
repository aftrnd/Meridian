import SwiftUI
import AppKit

struct HomeView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(GameLauncher.self) private var launcher
    @Binding var selectedGame: Game?

    @Environment(\.controlActiveState) private var controlActiveState

    @State private var carouselIndex: Int = 0
    @State private var carouselTimer: Timer?
    /// Measured on homeContent so all fixed-position elements share the same
    /// leading inset as the GameScrollRow section titles and cards.
    @State private var contentWidth: CGFloat = 0
    private var leadingInset: CGFloat {
        CardLayoutMetrics.compute(for: contentWidth).leadingPadding
    }

    private static let sectionSpacing: CGFloat = 28
    private static let carouselCount = 3
    private static let carouselInterval: TimeInterval = 20

    private var carouselGames: [Game] {
        Array(library.recentlyPlayedGames.prefix(Self.carouselCount))
    }

    var body: some View {
        Group {
            if library.isLoading && library.games.isEmpty {
                loadingView
            } else {
                homeContent
            }
        }
        .navigationTitle("")
        .onAppear { startCarouselTimer() }
        .onDisappear { carouselTimer?.invalidate() }
        .onChange(of: library.games.count) { _, _ in
            restartCarouselTimer()
        }
    }

    // MARK: - Content

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                if !carouselGames.isEmpty {
                    heroCarousel
                }

                if !library.recentlyPlayedGames.isEmpty {
                    GameScrollRow(
                        title: "Recently Played",
                        games: Array(library.recentlyPlayedGames.prefix(20)),
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

                if !library.favoriteGames.isEmpty {
                    GameScrollRow(
                        title: "Favorites",
                        games: library.favoriteGames,
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
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
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

    // MARK: - Hero Carousel

    private var heroCarousel: some View {
        let games = carouselGames
        let safeIndex = games.isEmpty ? 0 : carouselIndex % games.count
        let game = games.isEmpty ? nil : games[safeIndex]

        return ZStack(alignment: .bottomLeading) {
            if let game {
                HeroBannerImage(urls: [game.heroURL] + game.heroURLFallbacks)
                    .id(game.id)
                    .transition(.opacity)
                    .applyBackgroundExtension()
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .init(x: 0.5, y: 0.3),
                endPoint: .bottom
            )

            // ── Logo ──────────────────────────────────────────────────────────
            // alignment: .leading  =  Alignment(.leading, .center) in SwiftUI —
            // horizontally anchored to leadingInset, vertically centred in the
            // full 302 pt banner height. No VStack+Spacer needed; the frame's
            // alignment does both jobs in one modifier.
            if let game {
                HeroLogoImage(
                    urls: game.newCDNLogoURLs + [game.logoURL] + game.logoURLFallbacks,
                    fallbackName: game.name
                )
                .padding(.leading, leadingInset)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .id(game.id)
                .transition(.opacity)
            }

            // ── Subtitle + button ─────────────────────────────────────────────
            // All values derived from user specifications (÷2 = @2x → pt):
            //
            //   .padding(.bottom, 22.25)
            //     msg1 baseline  62.5 px ÷ 2  = 31.25 pt  button bottom from banner bottom
            //     msg2  −9 px ÷ 2 = −4.5 pt   → 26.75 pt
            //     msg3  −9 px ÷ 2 = −4.5 pt   → 22.25 pt  ← final
            //
            //   Spacer().frame(height: 15.5)
            //     msg1 baseline  36 px ÷ 2  = 18 pt   subtitle bottom to button top
            //     msg2  −5 px ÷ 2 = −2.5 pt  → 15.5 pt  ← final (msg3: "perfect, unchanged")
            if let game {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    Text(heroBannerSubtitle(for: game))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                    Spacer().frame(height: 15.5)
                    Button {
                        selectedGame = game
                    } label: {
                        Label("Continue Playing", systemImage: "play.fill")
                            .font(.headline)
                            .frame(minWidth: 140, minHeight: 24)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(controlActiveState == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, 24)
                .padding(.bottom, 26.75)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .id(game.id)
                .transition(.opacity)
            }

            if games.count > 1 {
                VStack {
                    Spacer()
                    carouselIndicators(count: games.count, current: safeIndex)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .leading) {
            if games.count > 1 {
                ChevronNavButton(direction: .back, isVisible: true) {
                    let count = carouselGames.count
                    guard count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        carouselIndex = (carouselIndex - 1 + count) % count
                    }
                    restartCarouselTimer()
                }
                // Centre the button within the leading-inset strip.
                .padding(.leading, max(0, (leadingInset - 24) / 2))
            }
        }
        .overlay(alignment: .trailing) {
            if games.count > 1 {
                ChevronNavButton(direction: .forward, isVisible: true) {
                    let count = carouselGames.count
                    guard count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        carouselIndex = (carouselIndex + 1) % count
                    }
                    restartCarouselTimer()
                }
                .padding(.trailing, max(0, (leadingInset - 24) / 2))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 302)
    }

    private func carouselIndicators(count: Int, current: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == current ? 1.0 : 0.4))
                    .frame(width: 6, height: 6)
                    .onTapGesture {
                        carouselIndex = i
                        restartCarouselTimer()
                    }
            }
        }
        .padding(.vertical, 4)
    }

    private func startCarouselTimer() {
        guard carouselGames.count > 1 else { return }
        carouselTimer = Timer.scheduledTimer(withTimeInterval: Self.carouselInterval, repeats: true) { _ in
            Task { @MainActor in
                let count = carouselGames.count
                guard count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    carouselIndex = (carouselIndex + 1) % count
                }
            }
        }
    }

    private func restartCarouselTimer() {
        carouselTimer?.invalidate()
        startCarouselTimer()
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

    private func heroBannerSubtitle(for game: Game) -> String {
        let time = game.playtime2WeekFormatted ?? game.playtimeFormatted
        let qualifier = game.playtime2WeekFormatted != nil ? "in the last two weeks" : "recently"
        return "You've played \(game.name) for \(time) \(qualifier)."
    }

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
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching:
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

// MARK: - Tahoe TV App Snap-Scroll Row

private struct GameScrollRow<MenuContent: View>: View {
    let title: String
    let games: [Game]
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
    @State private var containerWidth: CGFloat = 0

    private var metrics: CardLayoutMetrics {
        CardLayoutMetrics.compute(for: containerWidth)
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
                    .padding(.trailing, 10)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
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
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                avatarView
                    .frame(width: 36, height: 36)

                if friend.isOnline || friend.isInGame {
                    Circle()
                        .fill(friend.isInGame ? .green : .green.opacity(0.8))
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
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(
            color: .black.opacity(isHovered ? 0.25 : 0.0),
            radius: isHovered ? 12 : 0,
            y: isHovered ? 6 : 0
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .task { await loadAvatar() }
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
        if friend.isOnline { return "Online" }
        if let date = friend.lastLogoffDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: .now)
        }
        return "Offline"
    }

    private func loadAvatar() async {
        guard let url = friend.avatarMediumURL else { return }

        if let cached = ImageCache.shared.image(for: url) {
            avatarImage = cached
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let nsImage = NSImage(data: data) else { return }
            ImageCache.shared.store(nsImage, for: url)
            avatarImage = nsImage
        } catch {}
    }
}

#Preview {
    HomeView(selectedGame: .constant(nil))
        .environment(SteamAuthService())
        .environment(SteamLibraryStore())
        .environment(GameLauncher())
        .frame(width: 900, height: 800)
}
