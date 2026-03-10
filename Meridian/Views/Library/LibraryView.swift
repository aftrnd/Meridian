import SwiftUI

struct LibraryView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Binding var selectedGame: Game?

    @State private var isSearching = false

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 14)
    ]

    var body: some View {
        @Bindable var library = library
        Group {
            if library.isLoading && library.games.isEmpty {
                loadingView
            } else if let error = library.loadError {
                errorView(error)
            } else if library.filteredGames.isEmpty {
                emptyView
            } else {
                gameGrid
            }
        }
        .navigationTitle(library.filter.rawValue)
        .navigationSubtitle("\(library.filteredGames.count) games")
        // isPresented binds to our toggle button so the field is hidden until needed.
        // Dismissing with Escape sets isSearching = false; we clear the query then too.
        .searchable(
            text: $library.searchQuery,
            isPresented: $isSearching,
            placement: .toolbar,
            prompt: "Search games…"
        )
        .onChange(of: isSearching) { _, active in
            if !active { library.searchQuery = "" }
        }
        .toolbar {
            // Sort — menu of options, active item shown with a checkmark
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $library.sortOrder) {
                        ForEach(SteamLibraryStore.SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort library")
            }

            // Search — circular icon button; tap to expand the search field
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isSearching.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search library")
            }
        }
    }

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(library.filteredGames) { game in
                    GameGridView(game: game, isSelected: selectedGame?.id == game.id)
                        .onTapGesture { selectedGame = game }
                }
            }
            .padding(16)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading your library…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No games found")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
