import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "EngineDownloader")

/// Downloads and installs a pre-built Wine + DXMT engine from GitHub Releases.
///
/// The engine is a tar.gz archive containing a `wine/` directory with:
///   - `bin/wine64`, `bin/wineserver`
///   - `lib/wine/`, `lib/dxmt/`, `lib/dxvk/` (optional)
///
/// Wine (LGPL), DXMT (MIT), DXVK (Zlib), MoltenVK (Apache 2.0)
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

    // MARK: - Pipeline

    private func executeDownload(onComplete: @escaping () -> Void) async {
        let repoSlug = settings.engineRepoSlug

        state = .fetching
        log.info("[download] fetching latest engine release from \(repoSlug)")

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
        // Use the releases list (not /releases/latest) so we can filter specifically
        // for engine-tagged releases. GitHub's "latest" endpoint resolves to the
        // most-recently-published release regardless of tag, which may be an app
        // DMG release with no tarball asset when an app release follows an engine release.
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

        log.info("[fetchLatestAsset] received \(releases.count) release(s)")

        // Iterate newest-first (GitHub default). Pick the first release whose tag
        // contains "-engine" — these are engine snapshots, not app releases.
        for release in releases {
            guard
                let tagName = release["tag_name"] as? String,
                tagName.contains("-engine"),
                let assets = release["assets"] as? [[String: Any]]
            else { continue }

            if let isDraft = release["draft"] as? Bool, isDraft { continue }

            log.info("[fetchLatestAsset] engine release: \(tagName), \(assets.count) asset(s)")

            for asset in assets {
                guard
                    let name = asset["name"] as? String,
                    let downloadURL = asset["browser_download_url"] as? String,
                    let size = asset["size"] as? Int64
                else { continue }

                if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.xz") {
                    log.info("[fetchLatestAsset] matched: \(name) (\(size) bytes)")
                    return ReleaseAsset(name: name, downloadURL: downloadURL, size: size)
                }
            }

            log.warning("[fetchLatestAsset] engine release \(tagName) has no .tar.gz/.tar.xz asset")
        }

        throw DownloadError.noAssetFound("No engine release with a .tar.gz asset found in \(repoSlug)")
    }

    // MARK: - Download
    //
    // Uses URLSessionDownloadTask + delegate so the OS networking stack handles
    // the transfer at full speed. The old URLSession.bytes(from:) approach iterated
    // one byte at a time through an async loop (133M suspensions for a 127 MB file),
    // which throttled real-world throughput to ~200 KB/s regardless of bandwidth.

    private func downloadAsset(_ asset: ReleaseAsset) async throws -> URL {
        guard let url = URL(string: asset.downloadURL) else {
            throw DownloadError.badURL(asset.downloadURL)
        }

        totalBytes = asset.size
        downloadedBytes = 0
        state = .downloading(progress: 0)

        let destPath = FileManager.default.temporaryDirectory.appending(path: asset.name)
        try? FileManager.default.removeItem(at: destPath)

        log.info("[downloadAsset] starting URLSessionDownloadTask → \(destPath.lastPathComponent)")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate(
                expectedBytes: asset.size,
                destination: destPath,
                onProgress: { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.downloadedBytes = received
                        self.totalBytes = max(total, self.totalBytes)
                        let progress = total > 0 ? Double(received) / Double(total) : 0
                        self.state = .downloading(progress: min(progress, 1.0))
                    }
                },
                continuation: continuation
            )

            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil   // URLSession manages its own background queue
            )
            let task = session.downloadTask(with: url)
            delegate.sessionRef = session  // Keep session alive until delegate fires
            task.resume()
            log.info("[downloadAsset] task resumed")
        }
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

// MARK: - Download progress delegate

/// Bridges URLSessionDownloadTask callbacks into a Swift checked continuation.
/// All delegate methods are called on URLSession's internal serial queue, so
/// the `resumed` guard is sufficient to prevent double-continuation-resume.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let expectedBytes: Int64
    private let destination: URL
    private let onProgress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumed = false

    /// Held strongly so the session (and delegate) survive until the transfer completes.
    var sessionRef: URLSession?

    init(
        expectedBytes: Int64,
        destination: URL,
        onProgress: @escaping (Int64, Int64) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    // Progress updates — called frequently on the session queue.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        onProgress(totalBytesWritten, total)
    }

    // Download complete — move temp file then resume the continuation.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // location is only valid inside this callback; move it immediately.
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            resume(with: .success(destination))
        } catch {
            resume(with: .failure(error))
        }
    }

    // Called after didFinishDownloadingTo (error == nil) or on failure (error != nil).
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(with: .failure(error))
        }
        sessionRef?.finishTasksAndInvalidate()
        sessionRef = nil
    }

    private func resume(with result: Result<URL, Error>) {
        guard !resumed else { return }
        resumed = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
