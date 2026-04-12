import Foundation
import Observation
import AppKit

private let log = MeridianLog(category: "AppUpdateChecker")

/// Checks GitHub Releases for new Meridian app AND engine versions.
///
/// A single "Check for Updates" action covers both:
/// - **App updates**: releases tagged exactly `vX.Y.Z` (no suffix). Releases with
///   suffixes like `-engine`, `-base`, `-beta`, `-rc` are deliberately excluded
///   to prevent pre-release or maintenance releases from being offered as app updates.
/// - **Engine updates**: releases tagged `vX.Y.Z-engine`. Compared against the
///   installed engine tag stored in `wine/meridian-engine-version.txt`.
///
/// Both checks share the same 24-hour rate limit. Bypass via `checkNow()`.
@Observable
@MainActor
final class AppUpdateChecker {

    // MARK: - State

    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed(String)
    }

    enum AppUpdateState: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case failed(String)
        case readyToRelaunch
    }

    private(set) var state: CheckState = .idle

    /// Tracks the in-app download + install process for app updates.
    private(set) var appUpdateState: AppUpdateState = .idle

    /// The tag of the available app release, e.g. `v1.2.0`. Nil when current.
    private(set) var availableVersion: String?

    /// The release body / changelog text for the available app release.
    private(set) var releaseNotes: String?

    /// The GitHub releases page URL for the available app release.
    private(set) var releasePageURL: URL?

    /// The direct download URL for the .dmg asset of the available app release.
    private(set) var dmgDownloadURL: URL?

    /// The latest engine release tag found on GitHub, e.g. `v1.0.3-engine`.
    /// Non-nil when the installed engine is older than what GitHub has.
    private(set) var availableEngineTag: String?

    var hasUpdate: Bool {
        if case .updateAvailable = state { return true }
        return false
    }

    var hasEngineUpdate: Bool { availableEngineTag != nil }

    /// Set this before calling `checkNow()` or `checkIfStale()` so the checker
    /// knows what engine version is currently installed. Typically set by MeridianApp
    /// at launch from `WineEngine.engineVersion`.
    var installedEngineTag: String?

    /// Call after a successful engine download+extract to sync the installed tag
    /// and dismiss the "update available" UI immediately.
    func clearEngineUpdate(newTag: String?) {
        installedEngineTag = newTag
        availableEngineTag = nil
        log.info("[check] engine update cleared — installed tag now \(newTag ?? "nil")")
    }

    private let settings = AppSettings.shared

    // MARK: - Current app version

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Public API

    /// Checks for both app and engine updates immediately, bypassing the 24-hour rate limit.
    func checkNow() {
        Task { await performCheck() }
    }

    /// Checks for updates only if the last successful check was more than 24 hours ago.
    func checkIfStale() {
        if let last = settings.lastUpdateCheck,
           Date().timeIntervalSince(last) < 86_400 { return }
        checkNow()
    }

    /// Opens the GitHub release page in the default browser.
    func openReleasePage() {
        let fallback = URL(string: "https://github.com/\(settings.engineRepoSlug)/releases/latest")!
        NSWorkspace.shared.open(releasePageURL ?? fallback)
    }

    private var updateTask: Task<Void, Never>?

    /// Downloads the .dmg, mounts it, replaces the running app, and relaunches.
    /// Falls back to opening the release page if no DMG asset is available.
    func downloadAndInstallUpdate() {
        guard let url = dmgDownloadURL else {
            log.info("[update] no DMG URL available — falling back to browser")
            openReleasePage()
            return
        }
        guard case .idle = appUpdateState else {
            log.warning("[update] already in progress")
            return
        }

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            await self?.executeAppUpdate(dmgURL: url)
        }
    }

    func cancelAppUpdate() {
        updateTask?.cancel()
        updateTask = nil
        appUpdateState = .idle
    }

    private func executeAppUpdate(dmgURL: URL) async {
        appUpdateState = .downloading(progress: 0)
        log.info("[update] downloading DMG from \(dmgURL)")

        let destPath = FileManager.default.temporaryDirectory.appending(path: "Meridian-update.dmg")
        try? FileManager.default.removeItem(at: destPath)

        do {
            let delegate = AppUpdateDownloadDelegate { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.appUpdateState = .downloading(progress: progress)
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            let tempURL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    delegate.continuation = cont
                    session.downloadTask(with: dmgURL).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
            session.finishTasksAndInvalidate()

            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: tempURL, to: destPath)
            log.info("[update] DMG downloaded to \(destPath.path(percentEncoded: false))")

            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: destPath)
                appUpdateState = .idle
                return
            }

            appUpdateState = .installing
            try await installFromDMG(at: destPath)

        } catch is CancellationError {
            log.info("[update] cancelled")
            try? FileManager.default.removeItem(at: destPath)
            appUpdateState = .idle
        } catch {
            log.error("[update] failed: \(error.localizedDescription)")
            appUpdateState = .failed(error.localizedDescription)
        }
    }

    private func installFromDMG(at dmgPath: URL) async throws {
        let dmgFile = dmgPath.path(percentEncoded: false)

        // Mount the DMG
        let mountPoint = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/hdiutil")
            process.arguments = ["attach", dmgFile, "-nobrowse", "-readonly", "-plist"]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { proc in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    cont.resume(throwing: UpdateError.networkError("hdiutil attach failed (exit \(proc.terminationStatus))"))
                    return
                }
                // Parse plist to find mount point
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let entities = plist["system-entities"] as? [[String: Any]] {
                    for entity in entities {
                        if let mp = entity["mount-point"] as? String {
                            cont.resume(returning: mp)
                            return
                        }
                    }
                }
                cont.resume(throwing: UpdateError.parseError)
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }

        log.info("[update] DMG mounted at \(mountPoint)")

        defer {
            // Detach in the background
            let detach = Process()
            detach.executableURL = URL(filePath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet"]
            detach.standardOutput = FileHandle.nullDevice
            detach.standardError = FileHandle.nullDevice
            try? detach.run()
        }

        // Find the .app inside the mounted volume
        let fm = FileManager.default
        let mountContents = (try? fm.contentsOfDirectory(atPath: mountPoint)) ?? []
        guard let appName = mountContents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.parseError
        }
        let sourceApp = URL(filePath: mountPoint).appending(path: appName)
        let currentAppURL = Bundle.main.bundleURL
        let backupURL = currentAppURL.deletingLastPathComponent().appending(path: "\(currentAppURL.lastPathComponent).bak")

        log.info("[update] replacing \(currentAppURL.path) with \(sourceApp.path)")

        // Backup current app, then replace
        try? fm.removeItem(at: backupURL)
        try fm.moveItem(at: currentAppURL, to: backupURL)

        do {
            try fm.copyItem(at: sourceApp, to: currentAppURL)
        } catch {
            // Restore backup on failure
            try? fm.removeItem(at: currentAppURL)
            try? fm.moveItem(at: backupURL, to: currentAppURL)
            throw error
        }

        // Clean up backup
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: dmgPath)
        log.info("[update] app replaced successfully — relaunching")

        appUpdateState = .readyToRelaunch

        // Relaunch: use open(1) which waits for the current process to exit
        let relaunchProcess = Process()
        relaunchProcess.executableURL = URL(filePath: "/usr/bin/open")
        relaunchProcess.arguments = ["-n", "-a", currentAppURL.path(percentEncoded: false)]
        try? relaunchProcess.run()

        // Give the new process a moment to start, then quit
        try? await Task.sleep(for: .milliseconds(500))
        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Private

    private func performCheck() async {
        guard state != .checking else { return }
        state = .checking
        log.info("[check] checking for updates (current app: \(Self.currentVersion), engine: \(self.installedEngineTag ?? "unknown"))")

        // Run app and engine checks concurrently; failures in either are independent.
        async let appResult = checkAppUpdate()
        async let engineResult = checkEngineUpdate()

        let (appUpdate, engineUpdate) = await (appResult, engineResult)
        settings.lastUpdateCheck = Date()

        // Apply engine result
        if let latestEngine = engineUpdate,
           let installed = installedEngineTag,
           isNewerEngine(latestEngine, than: installed) {
            availableEngineTag = latestEngine
            log.info("[check] engine update available: \(latestEngine) (installed: \(installed))")
        } else {
            availableEngineTag = nil
            log.info("[check] engine up to date (installed: \(self.installedEngineTag ?? "none"), latest: \(engineUpdate ?? "none"))")
        }

        // Apply app result
        switch appUpdate {
        case .success(let release):
            if let release, isNewer(release.tagName, than: Self.currentVersion) {
                availableVersion = release.tagName
                releaseNotes = release.body
                releasePageURL = release.pageURL
                dmgDownloadURL = release.dmgURL
                state = .updateAvailable(version: release.tagName)
                log.info("[check] app update available: \(release.tagName) dmg=\(release.dmgURL?.absoluteString ?? "none")")
            } else {
                availableVersion = nil
                releaseNotes = nil
                releasePageURL = nil
                dmgDownloadURL = nil
                state = .upToDate
                log.info("[check] app up to date")
            }
        case .failure(let error):
            availableVersion = nil
            releaseNotes = nil
            releasePageURL = nil
            dmgDownloadURL = nil
            state = .failed(error.localizedDescription)
            log.error("[check] app check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - App update check

    private struct AppRelease {
        let tagName: String
        let body: String
        let pageURL: URL
        let dmgURL: URL?
    }

    private func checkAppUpdate() async -> Result<AppRelease?, Error> {
        do {
            let release = try await fetchLatestAppRelease()
            return .success(release)
        } catch UpdateError.noRelease {
            log.info("[check] no canonical app releases found — app up to date")
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    private func fetchLatestAppRelease() async throws -> AppRelease {
        let releases = try await fetchReleases()

        for release in releases {
            guard
                let tagName = release["tag_name"] as? String,
                let pageURLString = release["html_url"] as? String,
                let pageURL = URL(string: pageURLString)
            else { continue }

            guard isCanonicalAppTag(tagName) else {
                log.debug("[check] skipping non-app release: \(tagName)")
                continue
            }

            if let isDraft = release["draft"] as? Bool, isDraft { continue }

            // Look for a .dmg asset for in-app update
            var dmgURL: URL?
            if let assets = release["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let urlStr = asset["browser_download_url"] as? String,
                       let url = URL(string: urlStr) {
                        dmgURL = url
                        log.info("[check] found DMG asset: \(name)")
                        break
                    }
                }
            }

            let body = release["body"] as? String ?? ""
            log.info("[check] latest app release: \(tagName)")
            return AppRelease(tagName: tagName, body: body, pageURL: pageURL, dmgURL: dmgURL)
        }

        throw UpdateError.noRelease
    }

    // MARK: - Engine update check

    private func checkEngineUpdate() async -> String? {
        do {
            return try await fetchLatestEngineTag()
        } catch {
            log.warning("[check] engine check failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchLatestEngineTag() async throws -> String {
        let releases = try await fetchReleases()

        for release in releases {
            guard let tagName = release["tag_name"] as? String else { continue }
            guard tagName.hasSuffix("-engine") else { continue }
            if let isDraft = release["draft"] as? Bool, isDraft { continue }
            if let isPre = release["prerelease"] as? Bool, isPre { continue }
            log.info("[check] latest engine release: \(tagName)")
            return tagName
        }

        throw UpdateError.noRelease
    }

    // MARK: - Shared GitHub API fetch

    private func fetchReleases() async throws -> [[String: Any]] {
        let repoSlug = settings.engineRepoSlug
        let urlString = "https://api.github.com/repos/\(repoSlug)/releases?per_page=20"
        guard let url = URL(string: urlString) else { throw UpdateError.badURL }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateError.networkError("GitHub API returned an unexpected response")
        }
        log.info("[check] GitHub API HTTP \(http.statusCode)")

        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateError.parseError
        }
        return releases
    }

    // MARK: - Tag classification

    /// Returns true only for canonical app release tags: `v<major>.<minor>.<patch>`
    /// with NO additional suffixes. Any tag like `v1.0.2-base`, `v1.1.0-beta`,
    /// `v2.0.0-rc1`, or `v1.0.3-engine` is rejected.
    private func isCanonicalAppTag(_ tag: String) -> Bool {
        let stripped = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { Int($0) != nil }
    }

    // MARK: - Version comparison

    /// Returns `true` if `candidate` is strictly newer than `current`.
    /// Strips any leading `v` and ignores suffixes before comparing major.minor.patch.
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = semverComponents(candidate)
        let b = semverComponents(current)
        let length = max(a.count, b.count)
        for i in 0..<length {
            let ac = i < a.count ? a[i] : 0
            let bc = i < b.count ? b[i] : 0
            if ac > bc { return true }
            if ac < bc { return false }
        }
        return false
    }

    /// Compares two engine tags (e.g. `v1.0.3-engine` vs `v1.0.2-engine`).
    private func isNewerEngine(_ candidate: String, than current: String) -> Bool {
        let clean = { (s: String) -> String in
            s.replacingOccurrences(of: "-engine", with: "")
        }
        return isNewer(clean(candidate), than: clean(current))
    }

    private func semverComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case badURL
        case networkError(String)
        case parseError
        case noRelease

        var errorDescription: String? {
            switch self {
            case .badURL:               return "Invalid URL"
            case .networkError(let s):  return "Network error: \(s)"
            case .parseError:           return "Could not parse release data"
            case .noRelease:            return "No releases found in this repository"
            }
        }
    }
}

// MARK: - App Update Download Delegate

private final class AppUpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    nonisolated(unsafe) var continuation: CheckedContinuation<URL, Error>?
    nonisolated(unsafe) private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(progress, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let stable = FileManager.default.temporaryDirectory
            .appending(path: "meridian-app-dl-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
