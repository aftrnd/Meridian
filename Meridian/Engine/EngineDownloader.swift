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
        let urlString = "https://api.github.com/repos/\(repoSlug)/releases/latest"
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw DownloadError.parseError("Could not parse release JSON")
        }

        let tagName = json["tag_name"] as? String ?? "unknown"
        log.info("[fetchLatestAsset] release tag: \(tagName), \(assets.count) asset(s)")

        let archSuffix = ProcessInfo.processInfo.machineArchitecture
        log.info("[fetchLatestAsset] looking for architecture: \(archSuffix)")

        for asset in assets {
            guard let name = asset["name"] as? String,
                  let downloadURL = asset["browser_download_url"] as? String,
                  let size = asset["size"] as? Int64 else { continue }

            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.xz") {
                log.info("[fetchLatestAsset] matched: \(name)")
                return ReleaseAsset(name: name, downloadURL: downloadURL, size: size)
            }
        }

        throw DownloadError.noAssetFound("No .tar.gz or .tar.xz asset found in release \(tagName)")
    }

    // MARK: - Download

    private func downloadAsset(_ asset: ReleaseAsset) async throws -> URL {
        guard let url = URL(string: asset.downloadURL) else {
            throw DownloadError.badURL(asset.downloadURL)
        }

        totalBytes = asset.size
        downloadedBytes = 0
        state = .downloading(progress: 0)

        let tempDir = FileManager.default.temporaryDirectory
        let destPath = tempDir.appending(path: asset.name)
        try? FileManager.default.removeItem(at: destPath)

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse {
            log.info("[downloadAsset] HTTP \(http.statusCode) | content-length=\(http.expectedContentLength)")
            if http.expectedContentLength > 0 {
                totalBytes = http.expectedContentLength
            }
        }

        let handle = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: destPath.path(percentEncoded: false), contents: nil)
            return destPath
        }())

        var written: Int64 = 0
        let chunkSize = 65536
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                handle.write(buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                downloadedBytes = written
                let progress = totalBytes > 0 ? Double(written) / Double(totalBytes) : 0
                state = .downloading(progress: min(progress, 1.0))
            }
        }

        if !buffer.isEmpty {
            handle.write(buffer)
            written += Int64(buffer.count)
        }
        handle.closeFile()

        downloadedBytes = written
        state = .downloading(progress: 1.0)
        log.info("[downloadAsset] downloaded \(written) bytes to \(destPath.path(percentEncoded: false))")

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

// MARK: - Architecture helper

private extension ProcessInfo {
    var machineArchitecture: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
