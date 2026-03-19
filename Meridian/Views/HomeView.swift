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

            if let game {
                VStack(alignment: .leading, spacing: 2) {
                    // Logo image with transparent background — falls back to bold text
                    // if the game doesn't have a logo asset on Steam.
                    HeroLogoImage(
                        urls: game.newCDNLogoURLs + [game.logoURL] + game.logoURLFallbacks,
                        fallbackName: game.name
                    )
                    .id("logo-\(game.id)")
                    .transition(.opacity)

                    Text(heroBannerSubtitle(for: game))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .padding(.top, 4)

                    Button {
                        selectedGame = game
                    } label: {
                        Label("Continue Playing", systemImage: "play.fill")
                            .font(.headline)
                            .frame(minWidth: 140, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controlActiveState == .inactive ? nil : .white)
                    .foregroundStyle(controlActiveState == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.black))
                    .controlSize(.large)
                    .padding(.top, 10)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, 24)
                .padding(.bottom, 20)
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
            // Left chevron — sits horizontally centred within the leadingInset strip,
            // vertically centred in the banner. No background; plain arrow only.
            if games.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        carouselIndex = (safeIndex - 1 + games.count) % games.count
                    }
                    restartCarouselTimer()
                } label: {
                    Image(systemName: "chevron.compact.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(width: leadingInset)
            }
        }
        .overlay(alignment: .trailing) {
            // Right chevron — mirrored positioning.
            if games.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        carouselIndex = (safeIndex + 1) % games.count
                    }
                    restartCarouselTimer()
                } label: {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(width: leadingInset)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 302)
        .contentShape(Rectangle())
        .onTapGesture {
            if let game { selectedGame = game }
        }
        .animation(.easeInOut(duration: 0.5), value: carouselIndex)
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
                carouselIndex += 1
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
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    /// Measured by onGeometryChange; drives all adaptive sizing.
    @State private var containerWidth: CGFloat = 0

    /// Recomputed whenever containerWidth changes.
    private var metrics: CardLayoutMetrics {
        CardLayoutMetrics.compute(for: containerWidth)
    }

    /// Number of cards to advance per arrow press, equals the visible count
    /// so one press shows the next "page" of cards.
    private var pageSize: Int { metrics.visibleCount }

    private var visibleStartIndex: Int {
        guard let id = scrollPosition.viewID(type: Int.self),
              let idx = games.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    private var canScrollBack: Bool { visibleStartIndex > 0 }
    private var canScrollForward: Bool { visibleStartIndex < games.count - pageSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section title aligns with the leading edge of the first card.
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.leading, metrics.leadingPadding)
                .padding(.bottom, 14)

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
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .scrollPosition($scrollPosition)
                .overlay(alignment: .leading) {
                    scrollArrow(direction: .back, proxy: proxy)
                }
                .overlay(alignment: .trailing) {
                    scrollArrow(direction: .forward, proxy: proxy)
                }
            }
        }
        .onHover { isRowHovered = $0 }
        // Measure the row's container width to drive adaptive sizing.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    @ViewBuilder
    private func scrollArrow(direction: ArrowDirection, proxy: ScrollViewProxy) -> some View {
        let show = isRowHovered && (direction == .back ? canScrollBack : canScrollForward)
        Button {
            let currentIndex = visibleStartIndex
            let targetIndex: Int
            if direction == .back {
                targetIndex = max(0, currentIndex - pageSize)
            } else {
                targetIndex = min(games.count - 1, currentIndex + pageSize)
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                proxy.scrollTo(games[targetIndex].id, anchor: .leading)
            }
        } label: {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background {
            if #available(macOS 26.0, *) {
                Circle().glassEffect(.regular.interactive())
            } else {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 10)
        // Offset upward so the arrow is centred on the card art rather than
        // the full card height (art + text label + bottom padding).
        // Shift = (VStack spacing 6 + label ~31 + bottom padding 8) / 2 ≈ 22 pt.
        .offset(y: -22)
        .opacity(show ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: show)
        .allowsHitTesting(show)
    }

    private enum ArrowDirection { case back, forward }
}

// MARK: - Background Extension Effect (macOS 26)

private struct BackgroundExtensionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }
}

extension View {
    func applyBackgroundExtension() -> some View {
        modifier(BackgroundExtensionModifier())
    }
}

// MARK: - Hero Logo Image

/// Loads the game's logo PNG (transparent, styled title lockup) from Steam CDN.
/// Falls back to bold text matching the original title style when no logo exists.
private struct HeroLogoImage: View {
    let urls: [URL]
    let fallbackName: String

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .frame(maxWidth: 420, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
            } else if loadFailed {
                // Fallback: plain bold text matching the previous carousel style
                Text(fallbackName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .lineLimit(2)
            } else {
                // Loading: show invisible placeholder of similar height so
                // layout doesn't jump when the logo arrives.
                Color.clear.frame(height: 72)
            }
        }
        .task(id: urls.first) { await loadLogo() }
    }

    private func loadLogo() async {
        loadFailed = false

        for url in urls {
            if let cached = ImageCache.shared.image(for: url) {
                loadedImage = cached
                return
            }
        }

        for url in urls {
            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                ImageCache.shared.store(nsImage, for: url)
                loadedImage = nsImage
                return
            } catch {
                continue
            }
        }

        loadFailed = true
    }
}

// MARK: - Hero Banner Image

private struct HeroBannerImage: View {
    let urls: [URL]
    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = loadedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if loadFailed {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 48, weight: .thin))
                                .foregroundStyle(.tertiary)
                        }
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ShimmerView() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: urls.first) { await loadImage() }
    }

    private func loadImage() async {
        for url in urls {
            if let cached = ImageCache.shared.image(for: url) {
                loadedImage = cached
                return
            }

            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                ImageCache.shared.store(nsImage, for: url)
                loadedImage = nsImage
                return
            } catch {
                continue
            }
        }

        loadFailed = true
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
