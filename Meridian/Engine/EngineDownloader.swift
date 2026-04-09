import Foundation
import Observation

private let log = MeridianLog(category: "EngineDownloader")

/// Downloads and installs a pre-built Wine + DXMT engine from GitHub Releases.
///
/// The engine is a tar.gz archive containing a `wine/` directory with:
///   - `bin/wine64`, `bin/wineserver`
///   - `lib/wine/`, `lib/dxmt/`, `lib/dxvk/` (optional)
///
/// Wine (LGPL), DXMT (open source), DXVK (open source), MoltenVK (Apache 2.0)
/// are all freely redistributable open-source components.
@Observable
@MainActor
final class EngineDownloader {

    enum DownloadState: Equatable {
        case idle
        case fetching
        case downloading(progress: Double)
        case extracting
        case complete
        case failed(String)
    }

    private(set) var state: DownloadState = .idle
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0

    private var downloadTask: Task<Void, Never>?
    private let settings = AppSettings.shared

    var isActive: Bool {
        switch state {
        case .fetching, .downloading, .extracting: return true
        default: return false
        }
    }

    // MARK: - Public API

    /// Downloads the latest engine release and extracts it to the engine directory.
    func download(onComplete: @escaping () -> Void) {
        guard !isActive else {
            log.warning("[download] already in progress")
            return
        }

        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            await self?.executeDownload(onComplete: onComplete)
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
        log.info("[cancel] download cancelled")
    }

    // MARK: - Private

    private func executeDownload(onComplete: @escaping () -> Void) async {
        let repoSlug = settings.engineRepoSlug

        state = .fetching
        log.info("[download] fetching latest release from \(repoSlug)")

        do {
            let asset = try await fetchLatestAsset(repoSlug: repoSlug)
            log.info("[download] found asset: \(asset.name) (\(asset.size) bytes)")
            log.info("[download] url: \(asset.downloadURL)")

            guard !Task.isCancelled else { return }

            let archivePath = try await downloadAsset(asset)

            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: archivePath)
                return
            }

            state = .extracting
            log.info("[download] extracting to \(WineEngine.engineDir.path(percentEncoded: false))")

            try await extractArchive(at: archivePath, to: WineEngine.engineDir)
            try? FileManager.default.removeItem(at: archivePath)

            state = .complete
            log.info("[download] engine installed ✓")
            onComplete()

        } catch is CancellationError {
            log.info("[download] cancelled")
            state = .idle
        } catch {
            let msg = error.localizedDescription
            log.error("[download] failed: \(msg)")
            state = .failed(msg)
        }
    }

    // MARK: - GitHub API

    private struct ReleaseAsset {
        let name: String
        let downloadURL: String
        let size: Int64
    }

    private func fetchLatestAsset(repoSlug: String) async throws -> ReleaseAsset {
        // Use the paginated releases list so we can filter by the -engine tag suffix.
        // /releases/latest returns whatever GitHub marks as "latest" which may be an
        // app release or base image with no engine tarball.
        let urlString = "https://api.github.com/repos/\(repoSlug)/releases?per_page=20"
        guard let url = URL(string: urlString) else {
            throw DownloadError.badURL(urlString)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.networkError("Invalid response")
        }

        log.info("[fetchLatestAsset] HTTP \(http.statusCode) from \(urlString)")

        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.networkError("GitHub API returned HTTP \(http.statusCode)")
        }

        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.parseError("Could not parse releases JSON")
        }

        log.info("[fetchLatestAsset] fetched \(releases.count) release(s)")

        // Walk releases in order (newest first) and find the latest -engine tagged release
        // that has a .tar.gz or .tar.xz asset attached.
        for release in releases {
            let tagName = release["tag_name"] as? String ?? ""
            let isDraft = release["draft"] as? Bool ?? false
            let isPrerelease = release["prerelease"] as? Bool ?? false

            guard tagName.hasSuffix("-engine"), !isDraft, !isPrerelease else { continue }
            guard let assets = release["assets"] as? [[String: Any]] else { continue }

            log.info("[fetchLatestAsset] checking engine release: \(tagName), \(assets.count) asset(s)")

            for asset in assets {
                guard let name = asset["name"] as? String,
                      let downloadURL = asset["browser_download_url"] as? String,
                      let size = asset["size"] as? Int64 else { continue }

                if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.xz") {
                    log.info("[fetchLatestAsset] matched: \(name) from \(tagName)")
                    return ReleaseAsset(name: name, downloadURL: downloadURL, size: size)
                }
            }

            log.warning("[fetchLatestAsset] engine release \(tagName) has no .tar.gz asset — skipping")
        }

        throw DownloadError.noAssetFound("No engine release with a .tar.gz asset found in \(repoSlug)")
    }

    // MARK: - Download

    private func downloadAsset(_ asset: ReleaseAsset) async throws -> URL {
        guard let url = URL(string: asset.downloadURL) else {
            throw DownloadError.badURL(asset.downloadURL)
        }

        totalBytes = asset.size
        downloadedBytes = 0
        state = .downloading(progress: 0)

        let destPath = FileManager.default.temporaryDirectory.appending(path: asset.name)
        try? FileManager.default.removeItem(at: destPath)

        // Use URLSession.downloadTask which downloads natively at full network speed,
        // writing directly to disk via OS-level buffering. The previous approach
        // (URLSession.bytes + for-await-byte loop) iterated one byte at a time through
        // Swift's async runtime, bottlenecking a 300MB file to ~1 MB/s regardless of
        // connection speed.
        let delegate = DownloadTaskDelegate { [weak self] totalWritten, totalExpected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadedBytes = totalWritten
                let total = totalExpected > 0 ? totalExpected : self.totalBytes
                let progress = total > 0 ? Double(totalWritten) / Double(total) : 0
                self.state = .downloading(progress: min(progress, 1.0))
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let tempURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate.continuation = cont
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }

        session.finishTasksAndInvalidate()

        // Move the temp file URLSession created to our chosen destination path.
        do {
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.moveItem(at: tempURL, to: destPath)
        } catch {
            throw DownloadError.networkError("Failed to save download: \(error.localizedDescription)")
        }

        log.info("[downloadAsset] downloaded \(self.downloadedBytes) bytes to \(destPath.path(percentEncoded: false))")
        state = .downloading(progress: 1.0)
        return destPath
    }

    // MARK: - Extraction

    private func extractArchive(at archivePath: URL, to destination: URL) async throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            log.info("[extract] removing existing engine directory")
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let tarPath = archivePath.path(percentEncoded: false)
        let destPath = destination.path(percentEncoded: false)

        log.info("[extract] tar xf \(tarPath) -C \(destPath)")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/tar")
            process.arguments = ["xf", tarPath, "-C", destPath, "--strip-components=0"]

            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    log.info("[extract] tar completed successfully")
                    if !stderr.isEmpty { log.debug("[extract] stderr: \(stderr.prefix(500))") }
                    cont.resume()
                } else {
                    log.error("[extract] tar failed (exit=\(proc.terminationStatus)): \(stderr.prefix(500))")
                    cont.resume(throwing: DownloadError.extractionFailed("tar exit \(proc.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }

        let contents = (try? fm.contentsOfDirectory(atPath: destPath)) ?? []
        log.info("[extract] engine directory contents: \(contents)")
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError {
        case badURL(String)
        case networkError(String)
        case parseError(String)
        case noAssetFound(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let s):            return "Invalid URL: \(s)"
            case .networkError(let s):      return "Network error: \(s)"
            case .parseError(let s):        return "Parse error: \(s)"
            case .noAssetFound(let s):      return s
            case .extractionFailed(let s):  return "Extraction failed: \(s)"
            }
        }
    }
}

// MARK: - Download delegate

/// URLSession delegate that receives native OS download progress callbacks and
/// bridges the final result back into Swift structured concurrency via a continuation.
private final class DownloadTaskDelegate: NSObject, URLSessionDownloadDelegate {

    nonisolated(unsafe) var continuation: CheckedContinuation<URL, Error>?
    // nonisolated(unsafe): closure is set once at init and only called from URLSession
    // delegate queue callbacks — no concurrent mutation.
    nonisolated(unsafe) private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // location is only valid until this method returns, so copy it to a stable temp path.
        let stable = FileManager.default.temporaryDirectory
            .appending(path: "meridian-dl-\(UUID().uuidString).tmp")
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
