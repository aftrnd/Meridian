import Foundation

/// Bridges the macOS Steam client's session data into the Meridian VM.
///
/// Strategy (in priority order):
///
/// 1. **virtio-fs session share** — if Steam for Mac is installed, its
///    `loginusers.vdf` and `config/` directory are copied into a staging directory
///    that VMConfiguration mounts into the VM at `/mnt/steam-session`. A small
///    guest init script then copies these files into the in-VM Steam data directory
///    before Steam starts, achieving auto-login with no credentials entered.
///    This is the same approach used by Whisky and CrossOver.
///
/// 2. **Credential injection fallback** — if no macOS Steam install is found,
///    `vmUsername` and `vmPassword` stored in Keychain are written to a transient
///    credentials file in the same staging directory. The guest init script then
///    launches Steam with `+login <user> <pass>` on first run. After that, Steam's
///    own remember-me tokens take over so this only happens once.
///
/// The staging directory lives in the Meridian app support folder and is
/// mounted read-only into the VM so the guest cannot tamper with host Steam data.
@Observable
@MainActor
final class SteamSessionBridge {

    // MARK: - State

    /// Whether a macOS Steam install with usable session files was found.
    private(set) var hasMacSteamSession: Bool = false

    /// Path to the staging directory that VMConfiguration mounts as a virtio-fs share.
    nonisolated static let stagingDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "com.meridian.app/steam-session", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Public API

    /// Prepares the staging directory before VM launch.
    ///
    /// - Parameter auth: The authenticated SteamAuthService instance, used to
    ///   read vmUsername/vmPassword for the credential fallback.
    /// - Returns: The staging strategy that was applied.
    @discardableResult
    func prepare(auth: SteamAuthService) async -> SessionStrategy {
        let staging = Self.stagingDir
        clearStaging(at: staging)

        if let steamDataDir = macSteamDataDirectory(), copySessionFiles(from: steamDataDir, to: staging) {
            hasMacSteamSession = true
            return .sessionFileCopy
        }

        // Fallback: write a transient credentials file for guest-side `steam +login`.
        let username = auth.vmUsername
        let password = auth.vmPassword
        if !username.isEmpty, !password.isEmpty {
            writeCredentials(username: username, password: password, to: staging)
            return .credentialInjection
        }

        return .none
    }

    // MARK: - Session strategy

    enum SessionStrategy {
        /// macOS Steam session files were copied into the staging directory.
        case sessionFileCopy
        /// A transient credentials file was written for guest-side `steam +login`.
        case credentialInjection
        /// No session data is available; the user will need to sign into Steam manually inside the VM.
        case none
    }

    // MARK: - Private helpers

    /// Returns the macOS Steam data directory if Steam is installed and a logged-in session exists.
    private func macSteamDataDirectory() -> URL? {
        let candidates: [URL] = [
            // Standard Steam for Mac install location
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Steam"),
        ]

        for dir in candidates {
            let loginUsers = dir.appending(path: "config/loginusers.vdf")
            if FileManager.default.fileExists(atPath: loginUsers.path) {
                return dir
            }
        }
        return nil
    }

    /// Copies the minimum session files needed for auto-login.
    ///
    /// Files copied:
    /// - `config/loginusers.vdf`   — tells Steam who is logged in
    /// - `config/config.vdf`       — stores auth tokens / remember-me state
    /// - `registry.vdf`            — Windows registry equivalent for Steam settings
    @discardableResult
    private func copySessionFiles(from steamDir: URL, to staging: URL) -> Bool {
        let fm = FileManager.default
        let files: [(String, String)] = [
            ("config/loginusers.vdf", "config/loginusers.vdf"),
            ("config/config.vdf",     "config/config.vdf"),
            ("registry.vdf",          "registry.vdf"),
        ]

        var copiedAny = false
        for (src, dst) in files {
            let source = steamDir.appending(path: src)
            guard fm.fileExists(atPath: source.path) else { continue }

            let destination = staging.appending(path: dst)
            let destDir = destination.deletingLastPathComponent()
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: destination)
            copiedAny = true
        }
        return copiedAny
    }

    /// Writes a transient `credentials.env` file for the guest init script.
    ///
    /// The guest reads this file, runs `steam +login $STEAM_USER $STEAM_PASS`,
    /// then deletes the file so credentials do not persist inside the VM.
    private func writeCredentials(username: String, password: String, to staging: URL) {
        let content = "STEAM_USER=\(username)\nSTEAM_PASS=\(password)\n"
        let dest = staging.appending(path: "credentials.env")
        try? content.write(to: dest, atomically: true, encoding: .utf8)
        // Mark the file as owner-read-only so only the Meridian process can read it
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path())
    }

    /// Removes all files from the staging directory.
    private func clearStaging(at dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in contents {
            try? fm.removeItem(at: item)
        }
    }
}
