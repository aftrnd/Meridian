import Foundation
import Observation
import CryptoKit

/// Fetches, caches, and assembles the Meridian VM base image from GitHub Releases.
///
/// Design:
/// - Uses the GitHub REST API  `GET /repos/{owner}/{repo}/releases/latest`
///   to discover the current image tag and download URLs dynamically.
/// - The repo slug (`owner/repo`) is configurable in Settings so users can
///   self-host or use a fork without recompiling.
/// - A release is expected to contain assets named `meridian-base.img.part1`
///   and `meridian-base.img.part2` (split due to GitHub's 2 GiB asset limit).
///   The assembled image is stored in Application Support.
/// - On launch the app checks the latest release tag; if it differs from the
///   cached tag, it offers/performs an update.
@Observable
@MainActor
final class VMImageProvider {

    // MARK: - State

    private(set) var state: ImageProviderState = .idle
    private(set) var cachedTag: String? = nil

    // MARK: - Paths

    nonisolated static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir  = base.appending(path: "com.meridian.app/vm", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var assembledImageURL: URL { Self.supportDir.appending(path: "meridian-base.img") }
    private var tagCacheURL:  URL { Self.supportDir.appending(path: "image.tag") }
    private var part1URL:     URL { Self.supportDir.appending(path: "meridian-base.img.part1") }
    private var part2URL:     URL { Self.supportDir.appending(path: "meridian-base.img.part2") }

    var isImageReady: Bool {
        FileManager.default.fileExists(atPath: assembledImageURL.path())
    }

    // MARK: - Init

    init() {
        cachedTag = try? String(contentsOf: tagCacheURL, encoding: .utf8)
    }

    // MARK: - Public API

    /// Checks GitHub for a newer release. Returns true if an update is available.
    @discardableResult
    func checkForUpdate() async -> Bool {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            state = .idle
            return release.tagName != cachedTag || !isImageReady
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    /// Downloads and assembles the latest base image, calling `progress` on the main actor.
    func downloadLatestImage(onProgress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws {
        let release = try await fetchLatestRelease()

        guard let part1Asset = release.assets.first(where: { $0.name.hasSuffix(".part1") }),
              let part2Asset = release.assets.first(where: { $0.name.hasSuffix(".part2") })
        else {
            throw ImageError.assetsNotFound(release.tagName)
        }

        // Download both parts with combined progress
        state = .downloading(0)
        try await downloadPart(url: part1Asset.browserDownloadURL, to: part1URL, partIndex: 0, totalParts: 2, onProgress: onProgress)
        try await downloadPart(url: part2Asset.browserDownloadURL, to: part2URL, partIndex: 1, totalParts: 2, onProgress: onProgress)

        // Assemble
        state = .assembling
        try assembleImage()

        // Persist new tag
        cachedTag = release.tagName
        try release.tagName.write(to: tagCacheURL, atomically: true, encoding: .utf8)

        // Clean up parts
        try? FileManager.default.removeItem(at: part1URL)
        try? FileManager.default.removeItem(at: part2URL)

        state = .idle
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let slug = AppSettings.shared.imageRepoSlug
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest") else {
            throw ImageError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImageError.githubError
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Download with progress

    private func downloadPart(
        url: URL,
        to destination: URL,
        partIndex: Int,
        totalParts: Int,
        onProgress: @escaping @MainActor (Double, Int64, Int64) -> Void
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImageError.downloadFailed(url.lastPathComponent)
        }

        let total = http.expectedContentLength
        var received: Int64 = 0

        guard FileManager.default.createFile(atPath: destination.path(), contents: nil) else {
            throw ImageError.diskWriteFailed
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1024 * 1024)

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 512 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                let partProgress = Double(received) / Double(max(total, 1))
                let overallProgress = (Double(partIndex) + partProgress) / Double(totalParts)
                onProgress(overallProgress, received * Int64(partIndex + 1), total * Int64(totalParts))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
    }

    // MARK: - Assembly

    private func assembleImage() throws {
        if FileManager.default.fileExists(atPath: assembledImageURL.path()) {
            try FileManager.default.removeItem(at: assembledImageURL)
        }
        guard FileManager.default.createFile(atPath: assembledImageURL.path(), contents: nil) else {
            throw ImageError.diskWriteFailed
        }
        let output = try FileHandle(forWritingTo: assembledImageURL)
        defer { try? output.close() }

        for partURL in [part1URL, part2URL] {
            let input = try FileHandle(forReadingFrom: partURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
    }

    // MARK: - State / errors

    enum ImageProviderState: Equatable {
        case idle
        case checking
        case downloading(Double)
        case assembling
        case error(String)
    }

    enum ImageError: LocalizedError {
        case badURL
        case githubError
        case assetsNotFound(String)
        case downloadFailed(String)
        case diskWriteFailed

        var errorDescription: String? {
            switch self {
            case .badURL:              return "Invalid GitHub API URL. Check the repo slug in Settings."
            case .githubError:         return "GitHub API returned an unexpected response."
            case .assetsNotFound(let t): return "No split image assets found in release \(t)."
            case .downloadFailed(let f): return "Download failed for \(f)."
            case .diskWriteFailed:     return "Could not write to disk. Check available storage."
            }
        }
    }
}

// MARK: - GitHub API models

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
