import Foundation
import Observation
import os.log
import AppKit

private let log = Logger(subsystem: "com.meridian.app", category: "AppUpdateChecker")

/// Checks GitHub Releases for new Meridian app versions.
///
/// Filters out engine-only releases (those tagged with `-engine`) so the
/// update check reflects only full app releases. Version comparison is
/// semantic (major.minor.patch), with an optional leading `v` stripped.
///
/// Rate-limited to one network check per 24 hours when called via
/// `checkIfStale()`. Bypass the limit at any time via `checkNow()`.
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

    private(set) var state: CheckState = .idle

    /// The tag name of the available release, e.g. `v1.2.0`. Nil when up to date.
    private(set) var availableVersion: String?

    /// The release body / changelog text for the available release.
    private(set) var releaseNotes: String?

    /// The GitHub releases page URL for the available release.
    private(set) var releasePageURL: URL?

    var hasUpdate: Bool {
        if case .updateAvailable = state { return true }
        return false
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

    /// Checks for updates immediately, bypassing the 24-hour rate limit.
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

    // MARK: - Private

    private func performCheck() async {
        guard state != .checking else { return }
        state = .checking
        log.info("[check] checking for updates (current: \(Self.currentVersion))")

        do {
            let release = try await fetchLatestAppRelease()
            settings.lastUpdateCheck = Date()

            let current = Self.currentVersion
            if isNewer(release.tagName, than: current) {
                availableVersion = release.tagName
                releaseNotes = release.body
                releasePageURL = release.pageURL
                state = .updateAvailable(version: release.tagName)
                log.info("[check] update available: \(release.tagName)")
            } else {
                availableVersion = nil
                releaseNotes = nil
                releasePageURL = nil
                state = .upToDate
                log.info("[check] up to date")
            }
        } catch UpdateError.noRelease {
            // No app release published yet (pre-release / development build).
            // Silently treat as up to date rather than surfacing an error to the user.
            settings.lastUpdateCheck = Date()
            state = .upToDate
            log.info("[check] no app release found — treating as up to date")
        } catch {
            state = .failed(error.localizedDescription)
            log.error("[check] failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub API

    private struct AppRelease {
        let tagName: String
        let body: String
        let pageURL: URL
    }

    private func fetchLatestAppRelease() async throws -> AppRelease {
        let repoSlug = settings.engineRepoSlug
        let urlString = "https://api.github.com/repos/\(repoSlug)/releases?per_page=20"
        guard let url = URL(string: urlString) else {
            throw UpdateError.badURL
        }

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

        for release in releases {
            guard
                let tagName = release["tag_name"] as? String,
                let pageURLString = release["html_url"] as? String,
                let pageURL = URL(string: pageURLString)
            else { continue }

            // Only accept clean vX.Y.Z tags as app releases. Any tag with a hyphen
            // suffix (-engine, -base, -beta, -rc, etc.) is not a full app release.
            let versionPart = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            guard !versionPart.contains("-") else { continue }

            // Must look like a version number (contains at least one dot).
            guard versionPart.contains(".") else { continue }

            // Skip drafts.
            if let isDraft = release["draft"] as? Bool, isDraft { continue }

            let body = release["body"] as? String ?? ""
            log.info("[check] latest app release: \(tagName)")
            return AppRelease(tagName: tagName, body: body, pageURL: pageURL)
        }

        throw UpdateError.noRelease
    }

    // MARK: - Version comparison

    /// Returns `true` if `candidate` is strictly newer than `current`.
    ///
    /// Strips any leading `v` before comparing major.minor.patch components.
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
            case .noRelease:            return "No app releases found in this repository"
            }
        }
    }
}
