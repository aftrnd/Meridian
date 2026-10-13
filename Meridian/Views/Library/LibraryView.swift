import SwiftUI

struct LibraryView: View {
    @Environment(SteamLibraryStore.self)  private var library
    @Environment(Launcher.self)           private var launcher
    @Environment(CategoryStore.self)      private var categoryStore
    @Environment(SteamSession.self)        private var session
    @Binding var selectedGame: Game?

    // MARK: - Category mode
    // When set, this view shows a specific category's games instead of the
    // filtered library. Mirrors how Apple Music shows a playlist's tracks.
    var categoryID: UUID? = nil
    var categoryGames: [Game]? = nil
    var categoryTitle: String? = nil

    private var isInCategoryMode: Bool { categoryID != nil }

    /// The games to display — category override or normal filtered library.
    private var displayGames: [Game] {
        categoryGames ?? library.filteredGames
    }

    // MARK: - Layout

    /// Measured at the body (NavigationSplitView detail column) level before
    /// any grid content influences the layout — prevents the feedback loop that
    /// caused fixed columns to push the sidebar off screen.
    @State private var containerWidth: CGFloat = 0
    @State private var hoverGate = CardHoverGate()

    private var metrics: CardLayoutMetrics {
        CardLayoutMetrics.compute(for: containerWidth)
    }

    /// One margin all round: the sides and the gap below the toolbar match
    /// the gutters. Home's peek inset (~45 pt) left the side gap twice the
    /// top one; the old fixed 27 pt was close but uneven.
    private var gridInset: CGFloat { CardLayoutMetrics.spacing }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: CardLayoutMetrics.spacing),
            count: metrics.visibleCount
        )
    }

    // MARK: - Body

    var body: some View {
        @Bindable var library = library
        // Filters + sorts the whole library: once per body pass, shared by
        // the grid, its art prefetch and the disk warm-up.
        let games = displayGames
        Group {
            if library.isLoading && library.games.isEmpty {
                loadingView
            } else if library.games.isEmpty, !isInCategoryMode {
                LibraryEmptyState()
            } else if let error = library.loadError, !isInCategoryMode {
                errorView(error)
            } else if games.isEmpty {
                emptyView
            } else {
                gameGrid(games)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    // MARK: - Game grid

    private func gameGrid(_ games: [Game]) -> some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: CardLayoutMetrics.spacing) {
                ForEach(games) { game in
                    GameGridView(
                        game: game,
                        isSelected: selectedGame?.id == game.id,
                        isFavorite: library.isFavorite(appID: game.id),
                        showFavoriteBadge: library.filter != .favorites && !isInCategoryMode,
                        gameState: gameState(for: game)
                    )
                    .onTapGesture { selectedGame = game }
                    .contextMenu { gameContextMenu(for: game) }
                    .onAppear { prefetchArt(around: game, in: games) }
                    .transition(.blurReplace)
                }
            }
            .padding(.horizontal, gridInset)
            .padding(.vertical, CardLayoutMetrics.spacing)
            // An uninstall or a finished download: the card blurs out of (or
            // into) Installed and the grid closes up, where it used to wait
            // for the page to be left and reopened (user, Oct 12 2026).
            // Filter, sort and search changes don't move this, so they stay
            // instant.
            .animation(.smooth(duration: 0.4), value: games.filter(\.isInstalled).map(\.id))
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .onScrollPhaseChange { _, phase in hoverGate.scrollPhaseChanged(to: phase) }
        .environment(\.cardHoverGate, hoverGate)
        // Every capsule onto disk in the background (bytes only), so no card
        // ever waits on the network. Re-runs as capsule hashes arrive.
        .task(id: artWarmKey(games)) { await CapsuleArt.warmDisk(games) }
    }

    // MARK: - Art prefetch

    /// Rows of art kept decoded ahead of the scroll, and behind it.
    private static let prefetchRowsAhead = 4
    private static let prefetchRowsBehind = 1

    /// A card coming on screen decodes the art for the rows around it, so
    /// cards arrive with their art (`GameGridView.init` reads it from memory).
    private func prefetchArt(around game: Game, in games: [Game]) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let columns = metrics.visibleCount
        let lower = max(0, index - columns * Self.prefetchRowsBehind)
        let upper = min(games.count, index + 1 + columns * Self.prefetchRowsAhead)
        CapsuleArt.prefetch(games[lower..<upper])
    }

    /// Changes when the shown games change or their new-CDN hashes arrive.
    private func artWarmKey(_ games: [Game]) -> String {
        "\(games.count)-\(games.reduce(0) { $0 + ($1.libraryCapsuleHash == nil ? 0 : 1) })"
    }

    // MARK: - Context menu

    @ViewBuilder
    private func gameContextMenu(for game: Game) -> some View {
        // Add to / Remove from Favorites
        Button {
            library.toggleFavorite(appID: game.id)
        } label: {
            Label(
                library.isFavorite(appID: game.id) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: library.isFavorite(appID: game.id) ? "heart.slash" : "heart"
            )
        }

        Divider()

        // Category membership
        if isInCategoryMode, let catID = categoryID {
            // When viewing a category, offer one-tap removal
            Button(role: .destructive) {
                categoryStore.removeGame(appID: game.id, from: catID)
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        } else {
            addToCategoryMenu(for: game)
        }

        Divider()

        Button {
            selectedGame = game
        } label: {
            Label("View Details", systemImage: "info.circle")
        }

        if game.isInstalled {
            Divider()
            Button(role: .destructive) {
                launcher.uninstall(game: game, library: library)
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }

        if !isInCategoryMode {
            Divider()
            Button(role: .destructive) {
                library.hideGame(appID: game.id)
            } label: {
                Label("Hide Game", systemImage: "eye.slash")
            }
        }
    }

    /// Sub-menu listing all existing playlists plus a quick-create option.
    @ViewBuilder
    private func addToCategoryMenu(for game: Game) -> some View {
        let allCategories = categoryStore.categories
        if allCategories.isEmpty {
            // No playlists yet — offer to create the first one
            Button {
                let id = categoryStore.createCategory(name: game.name)
                categoryStore.addGame(appID: game.id, to: id)
            } label: {
                Label("New Playlist from Game", systemImage: "plus.circle")
            }
        } else {
            Menu {
                ForEach(allCategories.sorted { $0.name < $1.name }) { cat in
                    let inCat = categoryStore.containsGame(appID: game.id, in: cat.id)
                    Button {
                        if inCat {
                            categoryStore.removeGame(appID: game.id, from: cat.id)
                        } else {
                            categoryStore.addGame(appID: game.id, to: cat.id)
                        }
                    } label: {
                        Label(cat.name, systemImage: inCat ? "checkmark" : "")
                    }
                }
                Divider()
                Button {
                    let id = categoryStore.createCategory(name: game.name)
                    categoryStore.addGame(appID: game.id, to: id)
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
        }
    }

    // MARK: - Game state

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

    // MARK: - Loading skeleton

    private var loadingView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: CardLayoutMetrics.spacing) {
                ForEach(0..<16, id: \.self) { _ in
                    GameGridPlaceholder()
                }
            }
            .padding(.horizontal, gridInset)
            .padding(.vertical, CardLayoutMetrics.spacing)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Couldn't load library")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: isInCategoryMode ? "folder" : "tray")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(isInCategoryMode ? "No games in this playlist" : "No games found")
                .foregroundStyle(.secondary)
            if isInCategoryMode {
                Text("Right-click any game in your library to add it here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty library

/// Home and Library with no games to show: not signed in, no Web API key, a
/// failed load, or an account without games, each with its way forward.
/// Skipping setup used to leave a blank window (user, Oct 12 2026).
struct LibraryEmptyState: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library

    private enum Reason: Equatable {
        case signedOut, noAPIKey, failed(String), noGames
    }

    /// nil while signed in with a key before the first load has run.
    private var reason: Reason? {
        if !steamAuth.isAuthenticated { return .signedOut }
        if steamAuth.apiKey.isEmpty { return .noAPIKey }
        if let error = library.loadError { return .failed(error) }
        return library.lastRefreshed == nil ? nil : .noGames
    }

    var body: some View {
        Group {
            if let reason {
                VStack(spacing: 12) {
                    Image(systemName: symbol(for: reason))
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text(title(for: reason))
                        .font(.headline)
                    Text(message(for: reason))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    if let action = actionTitle(for: reason) {
                        Button(action) { perform(reason) }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(for reason: Reason) -> String {
        switch reason {
        case .signedOut: "person.crop.circle"
        case .noAPIKey:  "key"
        case .failed:    "exclamationmark.triangle"
        case .noGames:   "tray"
        }
    }

    private func title(for reason: Reason) -> String {
        if case .failed = reason { return "Couldn't load your library" }
        return "Your library is empty"
    }

    private func message(for reason: Reason) -> String {
        switch reason {
        case .signedOut:
            "Sign in with Steam to see your games here."
        case .noAPIKey:
            "Meridian needs a Steam Web API key to load your games. It's free and takes about 30 seconds to get."
        case .failed(let error):
            error
        case .noGames:
            "Games you own on Steam show up here."
        }
    }

    private func actionTitle(for reason: Reason) -> String? {
        switch reason {
        case .signedOut: "Sign In…"
        case .noAPIKey:  "Add API Key…"
        case .failed:    "Try Again"
        case .noGames:   nil
        }
    }

    private func perform(_ reason: Reason) {
        if case .failed = reason {
            Task { await library.refresh(steamID: steamAuth.steamID, apiKey: steamAuth.apiKey) }
        } else {
            NotificationCenter.default.post(name: .meridianShowSetup, object: nil)
        }
    }
}

// MARK: - Sort Menu Button (circular glass)

struct SortMenuButton: View {
    @Binding var sortOrder: SteamLibraryStore.SortOrder
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
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
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SteamLibraryStore.SortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                        showPopover = false
                    } label: {
                        HStack {
                            Text(order.rawValue)
                                .font(.body)
                            Spacer()
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 200)
            .padding(.vertical, 6)
        }
        .help("Sort library")
    }
}

struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Skeleton placeholder card

private struct GameGridPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .aspectRatio(600.0 / 900.0, contentMode: .fit)
                .overlay { ShimmerView() }

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 11)
                    .frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary.opacity(0.6))
                    .frame(height: 9)
                    .frame(maxWidth: 60)
            }
            .padding(.horizontal, 2)
        }
    }
}
