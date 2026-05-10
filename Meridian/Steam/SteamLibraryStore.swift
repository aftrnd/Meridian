import Observation
import Foundation

private let log = MeridianLog(category: "SteamLibrary")

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

    /// Background task that polls ACF files every 5 seconds and flips
    /// `isInstalled` on any game whose state changed on disk. Keeps the
    /// Install/Play button accurate when Steam downloads a game silently
    /// (e.g. via the no-restart IPC path) without Meridian's download loop.
    @ObservationIgnored private var installPollTask: Task<Void, Never>?

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
            startInstallStatePolling()
        } catch {
            loadError = error.localizedDescription
            log.error("[refresh] failed: \(error.localizedDescription)")
        }

        // Friends are fetched separately — failure doesn't block the library
        await fetchFriendsActivity(steamID: steamID, apiKey: apiKey)

        // Fetch library capsule hashes for newer games that use Steam's new CDN.
        // Runs in a child Task so refresh() returns immediately after friends load.
        // @Observable mutations inside the task trigger SwiftUI re-renders that
        // restart the card's .task(id:), which then retries with new-CDN URLs.
        Task { await prefetchLibraryCapsuleHashes(apiKey: apiKey) }
    }

    /// Fetches library capsule content hashes for all owned games and stores them on
    /// game objects. Processed in batches of 50, then individually retries any games
    /// that the batch pass missed, to handle API inconsistencies.
    @MainActor
    private func prefetchLibraryCapsuleHashes(apiKey: String) async {
        let appIDs = games.map(\.id)
        guard !appIDs.isEmpty else { return }
        log.info("[prefetchLibraryCapsuleHashes] starting for \(appIDs.count) games")

        // Pass 1: batch requests of 50 — fast, covers most games.
        for batch in appIDs.chunked(into: 50) {
            let hashes = await SteamAPIService.shared.fetchLibraryCapsuleHashes(
                appIDs: batch, apiKey: apiKey
            )
            applyHashes(hashes)
            try? await Task.sleep(for: .seconds(1))
        }

        let resolvedCount = games.filter { $0.libraryCapsuleHash != nil }.count
        log.info("[prefetchLibraryCapsuleHashes] batch pass resolved \(resolvedCount)/\(appIDs.count) hashes — games without hashes use legacy CDN fallback")

        // Pass 2: for recently-played games that still lack a logo hash, run the
        // targeted appdetails probe. Covers all recently played games so the hero
        // carousel always has logo art regardless of library position.
        let logoMissing = recentlyPlayedGames
            .filter { $0.logoHash == nil }
            .map(\.id)
        if !logoMissing.isEmpty {
            log.info("[prefetchLibraryCapsuleHashes] probing logo hashes for \(logoMissing.count) recently played games")
            for appID in logoMissing {
                if let hash = await SteamAPIService.shared.probeLogoHash(appID: appID) {
                    if let idx = games.firstIndex(where: { $0.id == appID }) {
                        games[idx].logoHash = hash
                    }
                    if let idx = recentGames.firstIndex(where: { $0.id == appID }) {
                        recentGames[idx].logoHash = hash
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        // Pass 3: ALL library games still missing a 600x900 capsule hash after
        // passes 1 & 2. The batch call misses some games (new CDN, API gaps, etc.)
        // that have art only on the hash-based CDN. Probe every missing game so
        // any title in the library grid shows art, not just recently-played ones.
        // probeCapsuleHash hits appdetails and verifies the file exists on CDN,
        // so it safely returns nil for old games with no new-CDN art.
        let capsuleMissing = games
            .filter { $0.libraryCapsuleHash == nil }
            .map(\.id)
        if !capsuleMissing.isEmpty {
            log.info("[prefetchLibraryCapsuleHashes] probing capsule hashes for \(capsuleMissing.count) recently played games")
            for appID in capsuleMissing {
                if let hash = await SteamAPIService.shared.probeCapsuleHash(appID: appID) {
                    if let idx = games.firstIndex(where: { $0.id == appID }) {
                        games[idx].libraryCapsuleHash = hash
                    }
                    if let idx = recentGames.firstIndex(where: { $0.id == appID }) {
                        recentGames[idx].libraryCapsuleHash = hash
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        log.info("[prefetchLibraryCapsuleHashes] complete")
    }

    /// Applies a hash dictionary to both the main games array and recentGames.
    private func applyHashes(_ hashes: [Int: GameCDNHashes]) {
        for (appID, cdnHashes) in hashes {
            if let idx = games.firstIndex(where: { $0.id == appID }) {
                if let h = cdnHashes.capsuleHash { games[idx].libraryCapsuleHash = h }
                if let h = cdnHashes.logoHash    { games[idx].logoHash = h }
                if let h = cdnHashes.heroHash    { games[idx].heroHash = h }
            }
            if let idx = recentGames.firstIndex(where: { $0.id == appID }) {
                if let h = cdnHashes.capsuleHash { recentGames[idx].libraryCapsuleHash = h }
                if let h = cdnHashes.logoHash    { recentGames[idx].logoHash = h }
                if let h = cdnHashes.heroHash    { recentGames[idx].heroHash = h }
            }
        }
    }

    // MARK: - Install state polling

    /// Starts a 5-second background poll that re-reads ACF files and updates
    /// `isInstalled` flags without a full API refresh. Called once after the
    /// library loads; idempotent — cancels any prior task before starting.
    func startInstallStatePolling() {
        installPollTask?.cancel()
        installPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await self?.syncInstallStateFromDisk()
            }
        }
    }

    /// Reads ACF state for every game in the library and updates `isInstalled`
    /// in-memory when it differs from disk. Lightweight: stat() per game, no network.
    @MainActor
    private func syncInstallStateFromDisk() {
        guard !games.isEmpty else { return }
        let prefix = WinePrefix.defaultPrefix
        guard prefix.exists else { return }

        var changedIDs = Set<Int>()
        for idx in games.indices {
            let appID = games[idx].id
            let onDisk = prefix.isGameFullyInstalled(appID: appID)
            guard games[idx].isInstalled != onDisk else { continue }
            games[idx].isInstalled = onDisk
            changedIDs.insert(appID)
            if onDisk {
                log.info("[installPoll] appID=\(appID) '\(games[idx].name)' became installed — updating UI")
                settings.markInstalled(appID: appID)
            } else {
                settings.markNotInstalled(appID: appID)
            }
        }
        guard !changedIDs.isEmpty else { return }
        for idx in recentGames.indices where changedIDs.contains(recentGames[idx].id) {
            recentGames[idx].isInstalled = prefix.isGameFullyInstalled(appID: recentGames[idx].id)
        }
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

    /// Derives install status from ACF manifests on disk (the authoritative source),
    /// then syncs the result back into AppSettings so the UserDefaults cache stays current.
    ///
    /// If the Wine prefix doesn't exist (fresh install or after a prefix wipe) every game
    /// is marked uninstalled and the stale UserDefaults cache is cleared.  When the prefix
    /// does exist, a fast stat() check for each appmanifest_<appID>.acf file is the source
    /// of truth — stale UserDefaults flags are ignored.
    ///
    /// The optimistic "mark installed immediately on launch" write in GameLauncher is still
    /// useful: it flips the card before Steam writes the ACF, and the next refresh confirms.
    private func applyInstallCache(to source: [Game]) -> [Game] {
        let prefix = WinePrefix.defaultPrefix

        guard prefix.exists else {
            if !settings.installedAppIDs.isEmpty {
                log.info("[applyInstallCache] prefix absent — clearing \(self.settings.installedAppIDs.count) stale installed IDs")
                settings.installedAppIDs = []
            }
            return source.map { var g = $0; g.isInstalled = false; return g }
        }

        var reconciledIDs = Set<Int>()
        let result: [Game] = source.map { game in
            var copy = game
            copy.isInstalled = prefix.isGameFullyInstalled(appID: game.id)
            if copy.isInstalled { reconciledIDs.insert(game.id) }
            return copy
        }

        if reconciledIDs != settings.installedAppIDs {
            log.info("[applyInstallCache] reconciled installedAppIDs: \(reconciledIDs.count) installed on disk")
            settings.installedAppIDs = reconciledIDs
        }

        return result
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
            windowsOnly: base.windowsOnly,
            libraryCapsuleHash: base.libraryCapsuleHash,
            logoHash: base.logoHash,
            heroHash: base.heroHash
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
