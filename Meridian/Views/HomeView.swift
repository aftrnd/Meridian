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

    private static let gridSpacing: CGFloat = 16
    private static let sectionSpacing: CGFloat = 28
    private static let cardWidth: CGFloat = 200
    private static let carouselCount = 3
    private static let carouselInterval: TimeInterval = 6

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
                    recentlyPlayedSection
                }

                if !library.friendSummaries.isEmpty {
                    friendActivitySection
                }

                if !library.favoriteGames.isEmpty {
                    favoritesSection
                }

                Spacer(minLength: Self.gridSpacing)
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
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
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .init(x: 0.5, y: 0.3),
                endPoint: .bottom
            )

            if let game {
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                        .id("title-\(game.id)")
                        .transition(.opacity)

                    Text("You recently played \(game.name). Pick up where you left off…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)

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
                .padding(.horizontal, Self.gridSpacing + 4)
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
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipped()
        .applyBackgroundExtension()
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

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recently Played")
                .padding(.horizontal, Self.gridSpacing)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.gridSpacing) {
                    ForEach(Array(library.recentlyPlayedGames.prefix(20))) { game in
                        GameGridView(
                            game: game,
                            isSelected: selectedGame?.id == game.id,
                            isFavorite: library.isFavorite(appID: game.id),
                            showFavoriteBadge: true,
                            gameState: gameState(for: game)
                        )
                        .frame(width: Self.cardWidth)
                        .onTapGesture { selectedGame = game }
                        .contextMenu { gameContextMenu(for: game) }
                    }
                }
                .padding(.horizontal, Self.gridSpacing)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Friend Activity

    private var friendActivitySection: some View {
        let topFriends = Array(library.friendSummaries.prefix(15))
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Friends")
                .padding(.horizontal, Self.gridSpacing)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(topFriends) { friend in
                        FriendCard(friend: friend)
                    }
                }
                .padding(.horizontal, Self.gridSpacing)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Favorites")
                .padding(.horizontal, Self.gridSpacing)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.gridSpacing) {
                    ForEach(library.favoriteGames) { game in
                        GameGridView(
                            game: game,
                            isSelected: selectedGame?.id == game.id,
                            isFavorite: true,
                            showFavoriteBadge: false,
                            gameState: gameState(for: game)
                        )
                        .frame(width: Self.cardWidth)
                        .onTapGesture { selectedGame = game }
                        .contextMenu { gameContextMenu(for: game) }
                    }
                }
                .padding(.horizontal, Self.gridSpacing)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
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
        .frame(width: 800, height: 700)
}
