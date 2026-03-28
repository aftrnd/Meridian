import Foundation
import Observation

/// Persisted user preferences, stored in UserDefaults.
@Observable
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    // MARK: - Engine

    /// GitHub repo slug used to fetch Wine+GPTK engine releases.
    var engineRepoSlug: String {
        get { UserDefaults.standard.string(forKey: "engineRepoSlug") ?? "aftrnd/meridian" }
        set { UserDefaults.standard.set(newValue, forKey: "engineRepoSlug") }
    }

    /// Show the Metal performance HUD overlay during gameplay.
    var metalHUD: Bool {
        get { UserDefaults.standard.bool(forKey: "metalHUD") }
        set { UserDefaults.standard.set(newValue, forKey: "metalHUD") }
    }

    /// Force Wine virtual desktop at a fixed resolution instead of windowed mode.
    var useVirtualDesktop: Bool {
        get { UserDefaults.standard.bool(forKey: "useVirtualDesktop") }
        set { UserDefaults.standard.set(newValue, forKey: "useVirtualDesktop") }
    }

    /// Virtual desktop width in pixels (used when useVirtualDesktop is enabled).
    var virtualDesktopWidth: Int {
        get { UserDefaults.standard.integer(forKey: "virtualDesktopWidth").nonZero ?? 1920 }
        set { UserDefaults.standard.set(newValue, forKey: "virtualDesktopWidth") }
    }

    /// Virtual desktop height in pixels (used when useVirtualDesktop is enabled).
    var virtualDesktopHeight: Int {
        get { UserDefaults.standard.integer(forKey: "virtualDesktopHeight").nonZero ?? 1080 }
        set { UserDefaults.standard.set(newValue, forKey: "virtualDesktopHeight") }
    }

    // MARK: - Library

    /// Locally cached set of Steam app IDs that are known to be installed.
    var installedAppIDs: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "installedAppIDs") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "installedAppIDs") }
    }

    func isInstalled(appID: Int) -> Bool {
        installedAppIDs.contains(appID)
    }

    func markInstalled(appID: Int) {
        var ids = installedAppIDs
        ids.insert(appID)
        installedAppIDs = ids
    }

    func markNotInstalled(appID: Int) {
        var ids = installedAppIDs
        ids.remove(appID)
        installedAppIDs = ids
    }

    // MARK: - Hidden Games

    var hiddenAppIDs: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "hiddenAppIDs") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenAppIDs") }
    }

    var showHiddenGames: Bool {
        get { UserDefaults.standard.bool(forKey: "showHiddenGames") }
        set { UserDefaults.standard.set(newValue, forKey: "showHiddenGames") }
    }

    func isHidden(appID: Int) -> Bool {
        hiddenAppIDs.contains(appID)
    }

    func hideGame(appID: Int) {
        var ids = hiddenAppIDs
        ids.insert(appID)
        hiddenAppIDs = ids
    }

    func unhideGame(appID: Int) {
        var ids = hiddenAppIDs
        ids.remove(appID)
        hiddenAppIDs = ids
    }

    // MARK: - Launch History

    private var launchTimestamps: [Int: TimeInterval] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: "launchTimestamps") as? [String: Double] ?? [:]
            return raw.reduce(into: [Int: TimeInterval]()) { result, pair in
                if let key = Int(pair.key) { result[key] = pair.value }
            }
        }
        set {
            let stringKeyed = newValue.reduce(into: [String: Double]()) { $0[String($1.key)] = $1.value }
            UserDefaults.standard.set(stringKeyed, forKey: "launchTimestamps")
        }
    }

    func recordLaunch(appID: Int) {
        var timestamps = launchTimestamps
        timestamps[appID] = Date().timeIntervalSince1970
        launchTimestamps = timestamps
    }

    func lastLaunchDate(appID: Int) -> Date? {
        guard let ts = launchTimestamps[appID], ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    // MARK: - Updates

    /// Timestamp of the last update check. Used to rate-limit background checks to once per day.
    var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// The app version string from the previous launch. Used to detect upgrades and
    /// trigger an automatic engine refresh when the app version changes.
    var lastLaunchAppVersion: String {
        get { UserDefaults.standard.string(forKey: "lastLaunchAppVersion") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastLaunchAppVersion") }
    }

    /// The engine release tag (e.g. `v1.0.3-engine`) that was active when the Wine
    /// prefix was last initialized via `wineboot`. Used by `BootstrapManager` to
    /// detect engine upgrades that require `wineboot --update` to refresh system DLL
    /// symlinks in the prefix. Without this, updating the engine produces missing-DLL
    /// errors (e.g. `coml2.dll not found`) because the prefix's system32 still has
    /// symlinks pointing into the old engine's DLL directory.
    var lastPrefixEngineTag: String {
        get { UserDefaults.standard.string(forKey: "lastPrefixEngineTag") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastPrefixEngineTag") }
    }

    // MARK: - Favorites

    var favoriteAppIDs: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "favoriteAppIDs") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "favoriteAppIDs") }
    }

    func isFavorite(appID: Int) -> Bool {
        favoriteAppIDs.contains(appID)
    }

    func toggleFavorite(appID: Int) {
        var ids = favoriteAppIDs
        if ids.contains(appID) {
            ids.remove(appID)
        } else {
            ids.insert(appID)
        }
        favoriteAppIDs = ids
    }

    /// Removes all account-scoped data from UserDefaults.
    /// Called on sign-out so a subsequent sign-in (or a different account) starts clean.
    func clearAccountData() {
        installedAppIDs = []
        hiddenAppIDs    = []
        favoriteAppIDs  = []
        UserDefaults.standard.removeObject(forKey: "launchTimestamps")
    }

    private init() {}
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
