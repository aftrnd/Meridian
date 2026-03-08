import Observation
import Foundation

/// Owns the fetched game list and drives search/filter/sort.
@Observable
@MainActor
final class SteamLibraryStore {
    private(set) var games: [Game] = []
    private(set) var recentGames: [Game] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?
    private(set) var lastRefreshed: Date?

    var searchQuery: String = ""
    var sortOrder: SortOrder = .nameAscending
    var filter: LibraryFilter = .all

    // MARK: - Computed filtered / sorted view

    var filteredGames: [Game] {
        var result = games

        switch filter {
        case .all:      break
        case .recent:   result = recentGames
        case .installed: result = result.filter { $0.isInstalled }
        case .windows:  result = result.filter { $0.requiresProton }
        }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) }
        }

        switch sortOrder {
        case .nameAscending:       result.sort { $0.name < $1.name }
        case .nameDescending:      result.sort { $0.name > $1.name }
        case .playtimeDescending:  result.sort { $0.playtimeMinutes > $1.playtimeMinutes }
        case .recentlyPlayed:      result.sort { ($0.playtime2WeekMinutes ?? 0) > ($1.playtime2WeekMinutes ?? 0) }
        }

        return result
    }

    // MARK: - Fetch

    func refresh(steamID: String, apiKey: String) async {
        guard !isLoading, !steamID.isEmpty else { return }
        guard !apiKey.isEmpty else {
            loadError = "Steam Web API key not configured. Add it in Settings."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            async let owned  = SteamAPIService.shared.fetchOwnedGames(steamID: steamID, apiKey: apiKey)
            async let recent = SteamAPIService.shared.fetchRecentlyPlayed(steamID: steamID, apiKey: apiKey)
            let (ownedGames, recentlyPlayed) = try await (owned, recent)
            games = ownedGames
            recentGames = recentlyPlayed
            lastRefreshed = .now
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Filter / sort types

    enum SortOrder: String, CaseIterable, Identifiable {
        case nameAscending      = "Name (A–Z)"
        case nameDescending     = "Name (Z–A)"
        case playtimeDescending = "Most Played"
        case recentlyPlayed     = "Recently Played"
        var id: String { rawValue }
    }

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all       = "All Games"
        case recent    = "Recent"
        case installed = "Installed"
        case windows   = "Windows Games"
        var id: String { rawValue }
    }
}
