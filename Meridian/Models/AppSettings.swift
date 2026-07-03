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

    /// Enable msync (Mach-semaphore NT-sync) for all Wine processes.
    ///
    /// CX Wine ships marzent's msync patch. `WINEMSYNC=1` replaces the
    /// eventfd-emulation esync path with native Mach semaphores, cutting CPU
    /// sync overhead substantially on Apple Silicon (marzent's own FFXIV
    /// bench: 219 fps msync+ulock vs 145 fps esync vs 93 fps server-side).
    /// CrossOver applies it bottle-wide; Meridian sets it on BOTH the game
    /// (`environment(for:)`) and admin/steam.exe (`steamCMDEnvironment(for:)`)
    /// paths so every wineserver in the prefix is started with the SAME msync
    /// setting — the msync client aborts (`exit(1)`) if it attaches to a
    /// wineserver started without it. Default ON; master kill-switch if a
    /// broad regression ever appears. Per-game opt-out via
    /// `GameProfile.extraEnv["WINEMSYNC"] = "0"`.
    var msyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "msyncEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "msyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "msyncEnabled") }
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

    // MARK: - Launch Mode (Offline gbe_fork vs Online steam.exe)

    /// How a game is launched:
    /// - `.offline`: gbe_fork Steamworks shim + direct `wine64` exec. No
    ///   `steam.exe`, no auth needed at launch. Cloud saves, in-game
    ///   multiplayer, and real Steam DRM verification are NOT available — the
    ///   game talks to a local emulator, not Valve. Fast, fully seamless.
    ///   This is the default (proven, reliable).
    /// - `.online`: brings the real Steam client online in the background
    ///   (`steam.exe -silent`, authenticated from the QR/OAuth session) and
    ///   launches via `-applaunch`. Enables cloud saves, online multiplayer,
    ///   EULAs, and genuine DRM. Requires a signed-in Steam session.
    enum LaunchMode: String {
        case offline
        case online
    }

    /// App IDs the user has explicitly switched to Online mode. Everything not
    /// in this set defaults to Offline (the reliable gbe_fork path). We store
    /// only the opt-ins so the default stays Offline even as the set of games
    /// grows, and so a cleared/blank set == "all offline".
    private var onlineModeAppIDs: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "onlineModeAppIDs") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "onlineModeAppIDs") }
    }

    /// The effective launch mode for a game. Defaults to `.offline`.
    func launchMode(appID: Int) -> LaunchMode {
        onlineModeAppIDs.contains(appID) ? .online : .offline
    }

    func setLaunchMode(_ mode: LaunchMode, appID: Int) {
        var ids = onlineModeAppIDs
        switch mode {
        case .online:  ids.insert(appID)
        case .offline: ids.remove(appID)
        }
        onlineModeAppIDs = ids
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

    /// Tracks the 32-bit (WoW64) COM class registration applied to the current
    /// prefix. Wine's prefix template ships with the 64-bit `HKLM\Software\
    /// Classes\CLSID` hive fully populated (1935 classes) but the 32-bit
    /// `Software\Classes\Wow6432Node\CLSID` view EMPTY — the release-engine
    /// `wineboot --init` was killed before its 32-bit wine.inf registration
    /// pass ran (Pattern 7). 32-bit games (Half-Life 2, any Source/DX9 title)
    /// then get `REGDB_E_CLASSNOTREG` from `CoCreateInstance` — most visibly
    /// for `MMDeviceEnumerator` (no audio device → NO SOUND), plus
    /// `DirectInput8` and the WBEM locator. Increment
    /// `WinePrefix.wow64ComRegistrationVersion` to force a re-write.
    var wow64ComRegistrationAppliedVersion: Int {
        get { UserDefaults.standard.integer(forKey: "wow64ComRegistrationAppliedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "wow64ComRegistrationAppliedVersion") }
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
    }

    // MARK: - Steam Credential Cache
    //
    // After a successful Meridian-side OAuth (SteamCredentialAuth via Valve's
    // IAuthenticationService REST API), the resulting refresh_token is persisted
    // here so it can be re-injected into the prefix's local.vdf on every cold
    // start. The DPAPI ciphertext that lands in local.vdf is keyed to
    // deterministic Wine inputs (user name "crossover" + accountName entropy +
    // compile-time Wine secret + embedded salt) so the same refresh_token
    // re-encrypts to a valid blob each launch.

    var steamCredentialSteamID: String {
        get { UserDefaults.standard.string(forKey: "steamCredentialSteamID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "steamCredentialSteamID") }
    }

    var steamCredentialAccountName: String {
        get { UserDefaults.standard.string(forKey: "steamCredentialAccountName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "steamCredentialAccountName") }
    }

    /// JWT refresh_token returned by Valve's IAuthenticationService after a
    /// successful Meridian-side OAuth. Long-lived (months); only invalidated by
    /// the user signing out of Steam Mobile or rotating account password.
    var steamCredentialRefreshToken: String {
        get { UserDefaults.standard.string(forKey: "steamCredentialRefreshToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "steamCredentialRefreshToken") }
    }

    /// True when all three credential pieces are present so bootstrap can
    /// inject a fresh local.vdf and steam.exe -silent auto-logs in.
    var hasSteamCredentials: Bool {
        !steamCredentialSteamID.isEmpty
            && !steamCredentialAccountName.isEmpty
            && !steamCredentialRefreshToken.isEmpty
    }


    private init() {}
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
