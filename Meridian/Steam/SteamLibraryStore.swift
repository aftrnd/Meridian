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
    /// The signed-in user's own profile summary — drives the "you" header in
    /// the friends panel (avatar + persona status, same data shape as friends).
    private(set) var ownSummary: PlayerSummary?
    /// steamID → date the friendship was created (from GetFriendList's
    /// friend_since). Shown in the friend detail popover.
    private(set) var friendsSince: [String: Date] = [:]
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

    // MARK: - Persistent library-art cache
    //
    // CDN art hashes (capsule/logo/hero) + Steam logo placement resolved on the
    // first launch are cached to disk, so every later launch applies the correct
    // logo + position INSTANTLY instead of re-running the slow anonymous PICS-
    // appinfo pass (which took 1–2 min and left logos at the default position
    // until it finished). The cache also records which apps the appinfo pass has
    // already queried, so resolved games (incl. legacy titles with no new-CDN
    // logo hash) are never re-queried.
    struct ArtCacheEntry: Codable, Equatable {
        var capsuleHash: String? = nil
        var logoHash: String? = nil
        var heroHash: String? = nil
        var logoPinned: String? = nil
        var logoWidthPct: Double? = nil
        var logoHeightPct: Double? = nil
        /// True once the PICS-appinfo pass has queried this app (even when it has
        /// no new-CDN logo, e.g. legacy titles). Prevents re-querying every launch.
        var appinfoResolved: Bool = false
    }

    @ObservationIgnored private var artCache: [Int: ArtCacheEntry] = [:]

    nonisolated static let artCacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/library-art-cache.json")
    }()

    init() {
        artCache = Self.loadArtCache()
    }

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
            // Apply cached art hashes + logo placement immediately so logos
            // render at their correct Steam position on this frame — no waiting
            // for the network passes below.
            applyArtCache()
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

        // Pass 1: batch requests of 50.
        // Recently played games are moved to the front so the visible carousel
        // always resolves in the first batch, regardless of alphabetical position.
        let recentIDSet = Set(recentlyPlayedGames.map(\.id))
        let prioritized = recentlyPlayedGames.map(\.id)
            + appIDs.filter { !recentIDSet.contains($0) }
        for batch in prioritized.chunked(into: 50) {
            let hashes = await SteamAPIService.shared.fetchLibraryCapsuleHashes(
                appIDs: batch, apiKey: apiKey
            )
            applyHashes(hashes)
            try? await Task.sleep(for: .seconds(1))
        }

        let resolvedCount = games.filter { $0.libraryCapsuleHash != nil }.count
        log.info("[prefetchLibraryCapsuleHashes] batch pass resolved \(resolvedCount)/\(appIDs.count) hashes — games without hashes use legacy CDN fallback")

        // Pass 2: Scan Steam's local librarycache for logo hashes.
        //
        // Steam downloads and caches library art from PICSData into
        // appcache/librarycache/{appID}/{hash}/. The hash directory NAME is the
        // asset hash used to construct CDN URLs. Any directory containing
        // logo.png is the logo hash for that game — no API call, no network.
        //
        // This is the authoritative source for logo hashes because:
        // - IStoreBrowseService/GetItems/v1 does not return logo hashes
        // - appdetails only includes screenshot/header hashes, not the logo hash
        // - SteamDB reads the same data from PICSData via CM protocol (not HTTP)
        // Reading from disk is instant and works for every game Steam has cached.
        let libraryCacheBase = WinePrefix.defaultPrefix.steamInstallDir
            .appending(path: "appcache/librarycache")
        let fm = FileManager.default
        var localLogoCount = 0
        for idx in games.indices where games[idx].logoHash == nil {
            let appID = games[idx].id
            let gameDir = libraryCacheBase.appending(path: "\(appID)")
            guard let entries = try? fm.contentsOfDirectory(
                at: gameDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let hash = entry.lastPathComponent
                guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { continue }
                let hasLogo = fm.fileExists(atPath: entry.appending(path: "logo.png").path(percentEncoded: false))
                    || fm.fileExists(atPath: entry.appending(path: "logo_2x.png").path(percentEncoded: false))
                if hasLogo {
                    games[idx].logoHash = hash
                    if let rIdx = recentGames.firstIndex(where: { $0.id == appID }) {
                        recentGames[rIdx].logoHash = hash
                    }
                    localLogoCount += 1
                    log.debug("[prefetchLibraryCapsuleHashes] localCache logo appID=\(appID) hash=\(hash.prefix(8))…")
                    break
                }
            }
        }
        // While we have the librarycache open, also pick up capsule hashes
        // for games the batch API missed. library_capsule.jpg in the same dir
        // gives the capsule hash for free.
        var localCapsuleCount = 0
        for idx in games.indices where games[idx].libraryCapsuleHash == nil {
            let appID = games[idx].id
            let gameDir = libraryCacheBase.appending(path: "\(appID)")
            guard let entries = try? fm.contentsOfDirectory(
                at: gameDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let hash = entry.lastPathComponent
                guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { continue }
                let hasCapsule = fm.fileExists(atPath: entry.appending(path: "library_capsule.jpg").path(percentEncoded: false))
                    || fm.fileExists(atPath: entry.appending(path: "library_600x900.jpg").path(percentEncoded: false))
                if hasCapsule {
                    games[idx].libraryCapsuleHash = hash
                    if let rIdx = recentGames.firstIndex(where: { $0.id == appID }) {
                        recentGames[rIdx].libraryCapsuleHash = hash
                    }
                    localCapsuleCount += 1
                    break
                }
            }
        }
        // Pass 3: PICS appinfo via the DepotDownloader fork (`-appinfo`).
        //
        // This is the AUTHORITATIVE source for the library LOGO hash, which
        // neither GetItems (Pass 1) nor — for never-opened games — the local
        // librarycache (Pass 2) provides. Steam moved library logos to
        // common.library_assets_full.library_logo, reachable only via the CM
        // protocol (SteamKit2). The fork resolves them ANONYMOUSLY (the appinfo
        // `common` section is public) in one batched, no-network-spam call.
        // Replaces the removed appdetails HTTP-probe pass, which never resolved
        // anything. Degrades gracefully: if the fork is absent or a game can't
        // be resolved, that game keeps the legacy CDN fallback.
        // Query appinfo for any game still missing a logo hash OR a logo
        // placement — placement (logo_position) ONLY comes from appinfo, so even
        // games whose logo resolved via Pass 1/2 need this for Steam-accurate
        // positioning on the detail page. Older titles return an empty logo hash
        // (bare legacy filename) but a valid position, which the detail hero
        // applies to their working legacy-CDN logo.
        // Skip games the appinfo pass has already resolved (cached) — including
        // legacy titles that have a placement but no new-CDN logo hash, which
        // would otherwise be re-queried on every launch.
        // Resolve in a recent/visible-first order so the games the user is
        // actually looking at get their logo + position within seconds, while
        // the long tail fills in behind them. Each resolve() call spins up the
        // fork with its own anonymous Steam logon (~5s), so the visible games go
        // in one small first batch, then the rest in large batches.
        func needsAppinfo(_ id: Int) -> Bool {
            if artCache[id]?.appinfoResolved == true { return false }
            guard let g = games.first(where: { $0.id == id }) else { return false }
            return g.logoHash == nil || g.logoPinned == nil
        }
        let recentNeeding = recentlyPlayedGames.map(\.id).filter(needsAppinfo)
        let recentSet = Set(recentNeeding)
        let restNeeding = games.map(\.id).filter { needsAppinfo($0) && !recentSet.contains($0) }
        let appInfoBatches: [[Int]] =
            (recentNeeding.isEmpty ? [] : [recentNeeding]) + restNeeding.chunked(into: 200)

        var appInfoLogoCount = 0
        if !appInfoBatches.isEmpty {
            for batch in appInfoBatches {
                let resolved = await SteamAppInfoResolver.resolve(appIDs: batch)
                guard !resolved.isEmpty else { continue }
                for (appID, hashes) in resolved {
                    // Mark as appinfo-resolved so we never re-query it (even if it
                    // returned no new-CDN logo, like a legacy title).
                    artCache[appID, default: ArtCacheEntry()].appinfoResolved = true
                    if let idx = games.firstIndex(where: { $0.id == appID }) {
                        if let logo = hashes.logo { games[idx].logoHash = logo; appInfoLogoCount += 1 }
                        if games[idx].libraryCapsuleHash == nil, let c = hashes.capsule { games[idx].libraryCapsuleHash = c }
                        if games[idx].heroHash == nil, let h = hashes.hero { games[idx].heroHash = h }
                        if let p = hashes.logoPlacement {
                            games[idx].logoPinned = p.pinned
                            games[idx].logoWidthPct = p.widthPct
                            games[idx].logoHeightPct = p.heightPct
                        }
                    }
                    if let rIdx = recentGames.firstIndex(where: { $0.id == appID }) {
                        if let logo = hashes.logo { recentGames[rIdx].logoHash = logo }
                        if recentGames[rIdx].libraryCapsuleHash == nil, let c = hashes.capsule { recentGames[rIdx].libraryCapsuleHash = c }
                        if recentGames[rIdx].heroHash == nil, let h = hashes.hero { recentGames[rIdx].heroHash = h }
                        if let p = hashes.logoPlacement {
                            recentGames[rIdx].logoPinned = p.pinned
                            recentGames[rIdx].logoWidthPct = p.widthPct
                            recentGames[rIdx].logoHeightPct = p.heightPct
                        }
                    }
                }
                // Persist after each batch so progress survives a crash and the
                // visible games are cached the instant their batch finishes.
                persistArtCache()
            }
        } else {
            // Nothing to appinfo-resolve, but Pass 1/2 may have updated capsule
            // hashes — cache those too.
            persistArtCache()
        }
        log.info("[prefetchLibraryCapsuleHashes] complete — localCache resolved \(localLogoCount) logo + \(localCapsuleCount) capsule; appinfo resolved \(appInfoLogoCount) logo; art cache has \(self.artCache.count) entries")
    }

    // MARK: - Library-art cache (disk persistence)

    private static func loadArtCache() -> [Int: ArtCacheEntry] {
        guard let data = try? Data(contentsOf: artCacheURL),
              let decoded = try? JSONDecoder().decode([String: ArtCacheEntry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    private func saveArtCache() {
        let keyed = Dictionary(uniqueKeysWithValues: artCache.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(keyed) else { return }
        try? FileManager.default.createDirectory(
            at: Self.artCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.artCacheURL, options: .atomic)
    }

    /// Fills art hashes + logo placement on the in-memory games from the on-disk
    /// cache. Only fills fields that are still nil, so a fresh API value always
    /// wins. Applied at the top of every refresh so logos are positioned on the
    /// first frame.
    private func applyArtCache() {
        guard !artCache.isEmpty else { return }
        func fill(_ g: inout Game) {
            guard let e = artCache[g.id] else { return }
            if g.libraryCapsuleHash == nil { g.libraryCapsuleHash = e.capsuleHash }
            if g.logoHash == nil          { g.logoHash = e.logoHash }
            if g.heroHash == nil          { g.heroHash = e.heroHash }
            if g.logoPinned == nil        { g.logoPinned = e.logoPinned }
            if g.logoWidthPct == nil      { g.logoWidthPct = e.logoWidthPct }
            if g.logoHeightPct == nil     { g.logoHeightPct = e.logoHeightPct }
        }
        for idx in games.indices       { fill(&games[idx]) }
        for idx in recentGames.indices { fill(&recentGames[idx]) }
    }

    /// Merges currently-resolved art fields from the in-memory games into the
    /// cache and writes it to disk (preserving the `appinfoResolved` flags).
    private func persistArtCache() {
        func capture(_ g: Game) {
            var e = artCache[g.id] ?? ArtCacheEntry()
            if let h = g.libraryCapsuleHash { e.capsuleHash = h }
            if let h = g.logoHash           { e.logoHash = h }
            if let h = g.heroHash           { e.heroHash = h }
            if let p = g.logoPinned         { e.logoPinned = p }
            if let w = g.logoWidthPct       { e.logoWidthPct = w }
            if let h = g.logoHeightPct      { e.logoHeightPct = h }
            artCache[g.id] = e
        }
        for g in games       { capture(g) }
        for g in recentGames { capture(g) }
        saveArtCache()
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
                // Synchronous: the unstructured Task inherits this class's
                // @MainActor isolation, so no hop (and no await) is needed.
                self?.syncInstallStateFromDisk()
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

    /// Fetches friend list and their profile summaries, plus the user's own
    /// summary (piggybacked into the first batch — no extra request).
    func fetchFriendsActivity(steamID: String, apiKey: String) async {
        do {
            let friends = try await SteamAPIService.shared.fetchFriendList(steamID: steamID, apiKey: apiKey)
            friendsSince = Dictionary(
                uniqueKeysWithValues: friends.compactMap { f in
                    f.friendSinceDate.map { (f.steamID, $0) }
                }
            )
            // Own steamID rides along so the friends panel header shows the
            // user's live persona state without a separate request.
            let ids = [steamID] + friends.map(\.steamID)

            var allSummaries: [PlayerSummary] = []
            for batch in ids.chunked(into: 100) {
                let summaries = try await SteamAPIService.shared.fetchPlayerSummaries(steamIDs: batch, apiKey: apiKey)
                allSummaries.append(contentsOf: summaries)
            }

            ownSummary = allSummaries.first { $0.steamID == steamID }
            friendSummaries = allSummaries
                .filter { $0.steamID != steamID }
                .sorted { $0.activitySortOrder < $1.activitySortOrder }
            log.info("[fetchFriendsActivity] loaded \(self.friendSummaries.count) friend summaries (own profile: \(self.ownSummary != nil))")
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
            heroHash: base.heroHash,
            logoPinned: base.logoPinned,
            logoWidthPct: base.logoWidthPct,
            logoHeightPct: base.logoHeightPct
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
