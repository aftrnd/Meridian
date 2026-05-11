import SwiftUI

struct LibraryView: View {
    @Environment(SteamLibraryStore.self)  private var library
    @Environment(Launcher.self)           private var launcher
    @Environment(CategoryStore.self)      private var categoryStore
    @Environment(WineEngine.self)         private var engine
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

    private var metrics: CardLayoutMetrics {
        CardLayoutMetrics.compute(for: containerWidth)
    }

    /// Horizontal inset for the library grid — 27 pt = 54 px at 2× Retina.
    private static let gridInset: CGFloat = 27

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: CardLayoutMetrics.spacing),
            count: metrics.visibleCount
        )
    }

    // MARK: - Body

    var body: some View {
        @Bindable var library = library
        Group {
            if library.isLoading && library.games.isEmpty {
                loadingView
            } else if let error = library.loadError, !isInCategoryMode {
                errorView(error)
            } else if displayGames.isEmpty {
                emptyView
            } else {
                gameGrid
            }
        }
        .navigationTitle(categoryTitle ?? "")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    // MARK: - Game grid

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: CardLayoutMetrics.spacing) {
                ForEach(displayGames) { game in
                    GameGridView(
                        game: game,
                        isSelected: selectedGame?.id == game.id,
                        isFavorite: library.isFavorite(appID: game.id),
                        showFavoriteBadge: library.filter != .favorites && !isInCategoryMode,
                        gameState: gameState(for: game)
                    )
                    .onTapGesture { selectedGame = game }
                    .contextMenu { gameContextMenu(for: game) }
                }
            }
            .padding(.horizontal, Self.gridInset)
            .padding(.vertical, CardLayoutMetrics.spacing)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
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
                launcher.uninstall(game: game, engine: engine)
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
            .padding(.horizontal, Self.gridInset)
            .padding(.vertical, CardLayoutMetrics.spacing)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
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
