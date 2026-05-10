import SwiftUI

struct SearchView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Environment(GameLauncher.self)      private var launcher
    @Binding var selectedGame: Game?

    @State private var searchText = ""

    private static let gridSpacing: CGFloat = 16
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 260), spacing: gridSpacing)
    ]

    private var searchResults: [Game] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return library.games.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if searchText.isEmpty {
                promptView
            } else if searchResults.isEmpty {
                noResultsView
            } else {
                resultsGrid
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search all games…")
    }

    private var promptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Search your library")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Find games by name across your entire Steam library.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No results for \"\(searchText)\"")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(searchResults) { game in
                    GameGridView(
                        game: game,
                        isSelected: selectedGame?.id == game.id,
                        isFavorite: library.isFavorite(appID: game.id),
                        gameState: gameState(for: game)
                    )
                    .onTapGesture { selectedGame = game }
                    .contextMenu {
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
                    }
                }
            }
            .padding(Self.gridSpacing)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
    }

    private func gameState(for game: Game) -> GameCardState {
        guard launcher.activeAppID == game.id else {
            return game.isInstalled ? .idle : .notInstalled
        }
        switch launcher.launchState {
        case .awaitingInstallConfirmation:
            return .downloading(progress: launcher.downloadProgress)
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
}
