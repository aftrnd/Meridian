import Observation
import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "SteamLibrary")

/// Owns the fetched game list and drives search/filter/sort.
@Observable
@MainActor
final class SteamLibraryStore {
    private(set) var games: [Game] = []
    private(set) var recentGames: [Game] = []
    private(set) var friendSummaries: [PlayerSummary] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?
    private(set) var lastRefreshed: Date?

    var searchQuery: String = ""
    var sortOrder: SortOrder = .nameAscending
    var filter: LibraryFilter = .all
    private let settings = AppSettings.shared

    // Stored so @Observable can track changes and re-evaluate filteredGames immediately.
    // AppSettings persists to UserDefaults; this mirrors it for reactive updates.
    private(set) var hiddenAppIDs: Set<Int> = AppSettings.shared.hiddenAppIDs
    var showHiddenGames: Bool = AppSettings.shared.showHiddenGames {
        didSet { settings.showHiddenGames = showHiddenGames }
    }

    // MARK: - Computed filtered / sorted view

    var filteredGames: [Game] {
        var result = games

        if !showHiddenGames {
            result = result.filter { !hiddenAppIDs.contains($0.id) }
        }

        switch filter {
        case .all:       break
        case .recent:    result = recentGames.filter { showHiddenGames || !hiddenAppIDs.contains($0.id) }
        case .installed: result = result.filter { $0.isInstalled }
        case .favorites: result = result.filter { settings.isFavorite(appID: $0.id) }
        }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) }
        }

        switch sortOrder {
        case .nameAscending:       result.sort { $0.name < $1.name }
        case .nameDescending:      result.sort { $0.name > $1.name }
        case .playtimeDescending:  result.sort { $0.playtimeMinutes > $1.playtimeMinutes }
        case .recentlyPlayed:      result.sort { effectiveLastPlayed($0) > effectiveLastPlayed($1) }
        }

        return result
    }

    // MARK: - Fetch

    func refresh(steamID: String, apiKey: String) async {
        guard !isLoading, !steamID.isEmpty else {
            log.debug("[refresh] skipped: isLoading=\(self.isLoading) steamID.isEmpty=\(steamID.isEmpty)")
            return
        }
        guard !apiKey.isEmpty else {
            log.warning("[refresh] no API key configured")
            loadError = "Steam Web API key not configured. Add it in Settings."
            return
        }
        log.info("[refresh] starting for steamID=\(steamID)")
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            async let owned  = SteamAPIService.shared.fetchOwnedGames(steamID: steamID, apiKey: apiKey)
            async let recent = SteamAPIService.shared.fetchRecentlyPlayed(steamID: steamID, apiKey: apiKey)
            let (ownedGames, recentlyPlayed) = try await (owned, recent)
            games = applyInstallCache(to: ownedGames)
            recentGames = applyInstallCache(to: recentlyPlayed)
            lastRefreshed = .now
            log.info("[refresh] complete: \(ownedGames.count) owned, \(recentlyPlayed.count) recent")
        } catch {
            loadError = error.localizedDescription
            log.error("[refresh] failed: \(error.localizedDescription)")
        }

        // Friends are fetched separately — failure doesn't block the library
        await fetchFriendsActivity(steamID: steamID, apiKey: apiKey)
    }

    func setInstalled(_ installed: Bool, for appID: Int) {
        log.info("[setInstalled] appID=\(appID) installed=\(installed)")
        if installed {
            settings.markInstalled(appID: appID)
        } else {
            settings.markNotInstalled(appID: appID)
        }
        updateInstalledFlag(for: appID, installed: installed)
    }

    // MARK: - Private helpers

    private func applyInstallCache(to source: [Game]) -> [Game] {
        source.map { game in
            var copy = game
            copy.isInstalled = settings.isInstalled(appID: game.id)
            return copy
        }
    }

    private func updateInstalledFlag(for appID: Int, installed: Bool) {
        if let idx = games.firstIndex(where: { $0.id == appID }) {
            games[idx].isInstalled = installed
        }
        if let idx = recentGames.firstIndex(where: { $0.id == appID }) {
            recentGames[idx].isInstalled = installed
        }
    }

    // MARK: - Home tab helpers

    /// Effective last-played date considering both Steam API and local launch tracking.
    func effectiveLastPlayed(_ game: Game) -> Date {
        let steam = game.lastPlayedDate ?? .distantPast
        let local = settings.lastLaunchDate(appID: game.id) ?? .distantPast
        return max(steam, local)
    }

    /// All games that have been played, sorted by most recently launched first.
    var recentlyPlayedGames: [Game] {
        games
            .filter { effectiveLastPlayed($0) > .distantPast }
            .sorted { effectiveLastPlayed($0) > effectiveLastPlayed($1) }
    }

    /// The single most recently played game (for the hero banner).
    var mostRecentGame: Game? { recentlyPlayedGames.first }

    /// Favorite games for the home quick-access row.
    var favoriteGames: [Game] {
        games.filter { settings.isFavorite(appID: $0.id) }
    }

    /// Fetches friend list and their profile summaries.
    func fetchFriendsActivity(steamID: String, apiKey: String) async {
        do {
            let friends = try await SteamAPIService.shared.fetchFriendList(steamID: steamID, apiKey: apiKey)
            let ids = friends.map(\.steamID)

            var allSummaries: [PlayerSummary] = []
            for batch in ids.chunked(into: 100) {
                let summaries = try await SteamAPIService.shared.fetchPlayerSummaries(steamIDs: batch, apiKey: apiKey)
                allSummaries.append(contentsOf: summaries)
            }

            friendSummaries = allSummaries.sorted { $0.activitySortOrder < $1.activitySortOrder }
            log.info("[fetchFriendsActivity] loaded \(allSummaries.count) friend summaries")
        } catch {
            log.error("[fetchFriendsActivity] failed: \(error.localizedDescription)")
        }
    }

    /// Returns a game with playtime2WeekMinutes merged from recentGames when available.
    /// GetOwnedGames often returns 0 for playtime_2weeks; GetRecentlyPlayedGames has the real data.
    func gameWithMergedPlaytime(appID: Int) -> Game? {
        guard let base = games.first(where: { $0.id == appID }) else { return nil }
        guard let recent = recentGames.first(where: { $0.id == appID }),
              let twoWeek = recent.playtime2WeekMinutes, twoWeek > 0
        else { return base }
        return Game(
            id: base.id,
            name: base.name,
            playtimeMinutes: base.playtimeMinutes,
            playtime2WeekMinutes: twoWeek,
            lastPlayedDate: base.lastPlayedDate,
            iconHash: base.iconHash,
            isInstalled: base.isInstalled,
            windowsOnly: base.windowsOnly
        )
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
        case favorites = "Favorites"
        var id: String { rawValue }
    }

    func isFavorite(appID: Int) -> Bool {
        settings.isFavorite(appID: appID)
    }

    func toggleFavorite(appID: Int) {
        log.info("[toggleFavorite] appID=\(appID)")
        settings.toggleFavorite(appID: appID)
    }

    func isHidden(appID: Int) -> Bool {
        hiddenAppIDs.contains(appID)
    }

    func hideGame(appID: Int) {
        log.info("[hideGame] appID=\(appID)")
        settings.hideGame(appID: appID)
        hiddenAppIDs = settings.hiddenAppIDs
    }

    func unhideGame(appID: Int) {
        log.info("[unhideGame] appID=\(appID)")
        settings.unhideGame(appID: appID)
        hiddenAppIDs = settings.hiddenAppIDs
    }
}

// MARK: - Array chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
