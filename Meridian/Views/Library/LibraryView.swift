import SwiftUI

struct LibraryView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Binding var selectedGame: Game?

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 14)
    ]

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            // Toolbar area
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search games…", text: $library.searchQuery)
                    .textFieldStyle(.plain)

                Spacer()

                Picker("Sort", selection: $library.sortOrder) {
                    ForEach(SteamLibraryStore.SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        // Re-auth objects are in the environment above; trigger refresh via parent
                    }
                } label: {
                    if library.isLoading {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh library")
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
                .foregroundStyle(.yellow)
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
