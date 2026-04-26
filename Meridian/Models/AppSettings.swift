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

    /// Modification time (Unix timestamp) of the engine's `meridian-engine-version.txt`
    /// when the prefix was last reset/updated. Used as a content fingerprint alongside
    /// `lastPrefixEngineTag` so that re-publishing the same tag with different content
    /// (e.g. re-running `release-engine.sh` without bumping the version) still triggers
    /// a prefix reset. The mtime changes on every `gh release upload` even if the tag
    /// string is unchanged.
    var lastPrefixEngineModTime: Double {
        get { UserDefaults.standard.double(forKey: "lastPrefixEngineModTime") }
        set { UserDefaults.standard.set(newValue, forKey: "lastPrefixEngineModTime") }
    }

    /// Tracks which WinRT registration batch has been applied to the current prefix.
    ///
    /// Increment `WinePrefix.winRTRegistrationVersion` whenever new WinRT entries are
    /// added to `registerWinRTClasses()`. Bootstrap compares this stored value against
    /// the current version and only re-runs registration when behind. This avoids
    /// spawning a Wine process on every launch for an already-configured prefix.
    var winRTRegistrationAppliedVersion: Int {
        get { UserDefaults.standard.integer(forKey: "winRTRegistrationAppliedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "winRTRegistrationAppliedVersion") }
    }

    /// Tracks whether VKD3D-proton DLLs have been installed into the prefix system32.
    ///
    /// Increment `WinePrefix.vkd3dProtonInstalledVersion` whenever the set of DLLs
    /// to install changes. Bootstrap compares this stored value against the current
    /// version and only re-runs the install when behind.
    var vkd3dProtonInstalledVersion: Int {
        get { UserDefaults.standard.integer(forKey: "vkd3dProtonInstalledVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "vkd3dProtonInstalledVersion") }
    }

    /// Tracks whether the Steam HKLM install-path registry keys have been written.
    ///
    /// steam.exe writes HKLM\SOFTWARE\Valve\Steam\InstallPath on first run.
    /// When using the native bootstrap (steam.exe never runs its own updater),
    /// these keys are absent and 32-bit steamcmd.exe crashes immediately on startup.
    /// Increment `WinePrefix.steamInstallPathRegistrationVersion` to force a re-write.
    var steamInstallPathRegistrationVersion: Int {
        get { UserDefaults.standard.integer(forKey: "steamInstallPathRegistrationVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "steamInstallPathRegistrationVersion") }
    }

    /// Tracks whether the prefix's reported Windows version has been set to `win10`.
    ///
    /// Valve deprecated Windows 7/8 support for the Steam client in late 2024 — any
    /// prefix reporting pre-Windows-10 triggers "Steam is no longer supported on
    /// your operating system" at startup. Increment
    /// `WinePrefix.windowsVersionRegistrationVersion` to force a re-write.
    var windowsVersionAppliedVersion: Int {
        get { UserDefaults.standard.integer(forKey: "windowsVersionAppliedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "windowsVersionAppliedVersion") }
    }

    /// Tracks whether quarantine attributes have been stripped from the engine directory.
    ///
    /// macOS sets `com.apple.quarantine` on files downloaded via URLSession. On macOS 26,
    /// quarantined Wine executables have restricted network access — secur32.so's GnuTLS
    /// cannot complete TLS handshakes, causing SteamCMD to hang indefinitely at
    /// "Loading Steam API...". EngineDownloader strips quarantine after every fresh
    /// extraction, but users with engines downloaded before this fix need a one-time
    /// cleanup pass at bootstrap startup.
    ///
    /// Version history:
    ///   1 — initial pass: strip com.apple.quarantine from entire engine directory
    var quarantineCleanedVersion: Int {
        get { UserDefaults.standard.integer(forKey: "quarantineCleanedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "quarantineCleanedVersion") }
    }

    /// One-time cleanup pass for stale `Steam Client Service` Windows service
    /// registration. Old Meridian versions (running the Jan 29 steam.exe stub)
    /// left behind a `HKLM\System\CurrentControlSet\Services\Steam Client Service`
    /// entry pointing to `C:\Program Files (x86)\Common Files\Steam\steamservice.exe`.
    /// The Mar 12 Steam install has its service binary at
    /// `C:\Program Files\Steam\bin\SteamService.exe`, so Steam's `StartService`
    /// call fails (`GLE 126 = ERROR_MOD_NOT_FOUND`). Not directly the cause of
    /// 0x3008 but a documented broken-state that logs noise and should never
    /// have been written. Compare to `WinePrefix.staleSteamServiceCleanupVersion`.
    ///
    /// Version history:
    ///   1 — delete HKLM\System\CurrentControlSet\Services\Steam Client Service once
    var staleSteamServiceCleanupVersion: Int {
        get { UserDefaults.standard.integer(forKey: "staleSteamServiceCleanupVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "staleSteamServiceCleanupVersion") }
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
        UserDefaults.standard.removeObject(forKey: "isSteamLoggedIn")
        steamCredentialSteamID = ""
        steamCredentialAccountName = ""
        steamCredentialRefreshToken = ""
        steamSelfManagedSession = false
    }

    // MARK: - Steam Credential Cache
    //
    // The JWT refresh token received from Meridian's IAuthenticationService sign-in
    // is persisted here so `SteamSessionBridge` can write a fresh ConnectCache into
    // the Wine prefix before each `steam.exe` startup. Steam's own auto-login reads
    // ConnectCache and logs the user in silently — no password, no Steam Guard push,
    // no UI. Persisting the token across launches means sign-in happens exactly once
    // and subsequent app starts are fully passwordless.
    //
    // The token is already stored in plaintext in the Wine prefix's config.vdf on
    // disk. Storing it in UserDefaults adds convenient re-write on every launch
    // without reducing security below that baseline.

    var steamCredentialSteamID: String {
        get { UserDefaults.standard.string(forKey: "steamCredentialSteamID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "steamCredentialSteamID") }
    }

    var steamCredentialAccountName: String {
        get { UserDefaults.standard.string(forKey: "steamCredentialAccountName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "steamCredentialAccountName") }
    }

    var steamCredentialRefreshToken: String {
        get { UserDefaults.standard.string(forKey: "steamCredentialRefreshToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "steamCredentialRefreshToken") }
    }

    var hasSteamCredentials: Bool {
        !steamCredentialRefreshToken.isEmpty && !steamCredentialSteamID.isEmpty
    }

    /// Set to true once `SteamExeSignIn` (April 25 2026+) drives a successful
    /// `steam.exe -login` round-trip. From that point on, Meridian must NEVER
    /// rewrite `local.vdf` — Steam owns the file and our DPAPI-encrypted
    /// JWT lacks the `machine_id` HMAC binding Valve's CM requires (Pattern 7
    /// rejection cascade).
    ///
    /// Cleared on sign-out so the next sign-in starts clean. Persisted to
    /// UserDefaults so Steam keeps owning its session across launches.
    var steamSelfManagedSession: Bool {
        get { UserDefaults.standard.bool(forKey: "steamSelfManagedSession") }
        set { UserDefaults.standard.set(newValue, forKey: "steamSelfManagedSession") }
    }

    private init() {}
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
