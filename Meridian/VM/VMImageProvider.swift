import Foundation
import Observation
import Compression

/// Fetches, caches, and assembles the Meridian VM base image from GitHub Releases.
///
/// Asset naming convention (matches actual release layout):
///   meridian-base-v*.img.lzfse.partaa  — first split part  (≤ 2 GiB)
///   meridian-base-v*.img.lzfse.partab  — second split part (≤ 2 GiB)
///   vmlinuz                             — ARM64 Linux kernel (optional)
///   initrd                              — initial RAM disk   (optional)
///
/// Assembly pipeline:
///   1. Download partaa + partab (and vmlinuz/initrd if present)
///   2. Concatenate parts → meridian-base.img.lzfse   (raw LZFSE stream)
///   3. Decompress LZFSE  → meridian-base.img         (raw disk image)
///   4. Delete temporary files
///
/// All heavy I/O runs on a detached background task; only state updates
/// are marshalled back to @MainActor.
@Observable
@MainActor
final class VMImageProvider {

    // MARK: - State

    private(set) var state: ImageProviderState = .idle
    private(set) var cachedTag: String?

    // MARK: - Paths

    nonisolated static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir  = base.appending(path: "com.meridian.app/vm", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var assembledImageURL: URL { Self.supportDir.appending(path: "meridian-base.img") }
    private var tagCacheURL:    URL { Self.supportDir.appending(path: "image.tag") }
    private var compressedURL:  URL { Self.supportDir.appending(path: "meridian-base.img.lzfse") }
    private var partaaURL:      URL { Self.supportDir.appending(path: "meridian-base.img.lzfse.partaa") }
    private var partabURL:      URL { Self.supportDir.appending(path: "meridian-base.img.lzfse.partab") }
    private var kernelURL:      URL { Self.supportDir.appending(path: "vmlinuz") }
    private var initrdURL:      URL { Self.supportDir.appending(path: "initrd") }

    /// True when the decompressed disk image exists.
    /// vmlinuz/initrd are optional — older releases may not include them.
    var isImageReady: Bool {
        FileManager.default.fileExists(atPath: assembledImageURL.path())
    }

    // MARK: - Init

    init() {
        cachedTag = try? String(contentsOf: tagCacheURL, encoding: .utf8)
    }

    // MARK: - Public API

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

    /// Downloads all release assets, then assembles + decompresses the image.
    func downloadLatestImage(onProgress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws {
        let release = try await fetchLatestRelease()

        // Clean up any partial files left from a previous failed attempt
        // so createFile() succeeds and we don't resume a corrupt partial.
        for staleURL in [partaaURL, partabURL, compressedURL] {
            try? FileManager.default.removeItem(at: staleURL)
        }

        // Match split parts by suffix — supports both "partaa/partab" (split -a2)
        // and "part1/part2" naming so the app works with any future release format.
        let parts = release.assets
            .filter { $0.name.contains(".part") }
            .sorted { $0.name < $1.name }   // alphabetical: partaa < partab

        guard parts.count >= 2 else {
            throw ImageError.assetsNotFound(release.tagName)
        }

        let partURLs: [(GitHubAsset, URL)] = [
            (parts[0], partaaURL),
            (parts[1], partabURL),
        ]

        // Optional kernel / initrd
        let kernelAsset = release.assets.first(where: { $0.name == "vmlinuz" })
        let initrdAsset  = release.assets.first(where: { $0.name == "initrd" })

        var downloads: [(asset: GitHubAsset, destination: URL)] = []
        if let k = kernelAsset { downloads.append((k, kernelURL)) }
        if let i = initrdAsset  { downloads.append((i, initrdURL)) }
        downloads.append(contentsOf: partURLs)

        let grandTotal = downloads.reduce(Int64(0)) { $0 + Int64($1.asset.size) }
        var grandReceived: Int64 = 0

        state = .downloading(0)

        for item in downloads {
            let startReceived = grandReceived
            try await downloadAsset(url: item.asset.browserDownloadURL, to: item.destination) { [weak self] received, _ in
                let combined = startReceived + received
                let fraction = Double(combined) / Double(max(grandTotal, 1))
                Task { @MainActor [weak self] in
                    self?.state = .downloading(fraction)
                    onProgress(fraction, combined, grandTotal)
                }
            }
            grandReceived += Int64(item.asset.size)
        }

        // Assembly + decompression happens in VMManager.provision() via assembleImageAsync()
        // Store the tag now so assembleImageAsync() can persist it on success.
        cachedTag = release.tagName
    }

    /// Concatenates downloaded parts, decompresses LZFSE, and cleans up temporaries.
    /// Must be called after downloadLatestImage() completes successfully.
    /// Runs entirely on a background task — never blocks the main actor.
    func assembleImageAsync() async throws {
        let partaa    = partaaURL
        let partab    = partabURL
        let compressed = compressedURL
        let output    = assembledImageURL
        let tag       = cachedTag
        let tagCache  = tagCacheURL

        try await Task.detached(priority: .userInitiated) {
            // Step 1: concatenate parts → compressed file
            if FileManager.default.fileExists(atPath: compressed.path()) {
                try FileManager.default.removeItem(at: compressed)
            }
            guard FileManager.default.createFile(atPath: compressed.path(), contents: nil) else {
                throw ImageError.diskWriteFailed
            }
            let compOut = try FileHandle(forWritingTo: compressed)
            defer { try? compOut.close() }

            for partURL in [partaa, partab] {
                guard FileManager.default.fileExists(atPath: partURL.path()) else {
                    throw ImageError.diskWriteFailed
                }
                let inHandle = try FileHandle(forReadingFrom: partURL)
                defer { try? inHandle.close() }
                while let chunk = try inHandle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    try compOut.write(contentsOf: chunk)
                }
            }
            try compOut.close()

            // Step 2: decompress LZFSE → final disk image
            try Self.decompressLZFSE(from: compressed, to: output)

            // Step 3: persist tag and clean up
            if let tag {
                try tag.write(to: tagCache, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.removeItem(at: partaa)
            try? FileManager.default.removeItem(at: partab)
            try? FileManager.default.removeItem(at: compressed)
        }.value

        state = .idle
    }

    // MARK: - LZFSE streaming decompression

    /// Decompresses an LZFSE-compressed file to `destination` using
    /// Apple's Compression.framework streaming API.
    ///
    /// Streaming (compression_stream) is used instead of the single-shot
    /// compression_decode_buffer because the compressed image is ~2.7 GB;
    /// loading it entirely into memory would require ~8 GB of RAM and crash
    /// on most Macs. The streaming approach keeps the working set to two
    /// fixed-size buffers (4 MB in + 8 MB out) regardless of file size.
    private static nonisolated func decompressLZFSE(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path()) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path(), contents: nil) else {
            throw ImageError.diskWriteFailed
        }

        let inHandle  = try FileHandle(forReadingFrom: source)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? inHandle.close()
            try? outHandle.close()
        }

        let inBufSize  = 4 * 1024 * 1024
        let outBufSize = 8 * 1024 * 1024
        let inBuf  = UnsafeMutablePointer<UInt8>.allocate(capacity: inBufSize)
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outBufSize)
        defer { inBuf.deallocate(); outBuf.deallocate() }

        // compression_stream requires non-nil pointers at init time; we immediately
        // call compression_stream_init which sets up the real state.
        var stream: compression_stream = compression_stream(
            dst_ptr: outBuf, dst_size: 0,
            src_ptr: UnsafePointer(inBuf), src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw ImageError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var hitEOF = false

        while true {
            // Refill input buffer when exhausted
            if stream.src_size == 0 && !hitEOF {
                if let chunk = try inHandle.read(upToCount: inBufSize), !chunk.isEmpty {
                    chunk.copyBytes(to: inBuf, count: chunk.count)
                    stream.src_ptr  = UnsafePointer(inBuf)
                    stream.src_size = chunk.count
                } else {
                    hitEOF = true
                }
            }

            stream.dst_ptr  = outBuf
            stream.dst_size = outBufSize

            let flags: Int32 = hitEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)

            let produced = outBufSize - stream.dst_size
            if produced > 0 {
                try outHandle.write(contentsOf: Data(bytes: outBuf, count: produced))
            }

            switch status {
            case COMPRESSION_STATUS_OK:
                continue
            case COMPRESSION_STATUS_END:
                return  // success
            default:
                throw ImageError.decompressionFailed
            }
        }
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let slug = AppSettings.shared.imageRepoSlug
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest") else {
            throw ImageError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",                  forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageError.githubError }

        switch http.statusCode {
        case 200:  return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 403, 429: throw ImageError.rateLimited
        case 404:  throw ImageError.releaseNotFound(slug)
        default:   throw ImageError.githubError
        }
    }

    // MARK: - Download

    private func downloadAsset(
        url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImageError.downloadFailed(url.lastPathComponent)
        }

        let contentLength = http.expectedContentLength
        var received: Int64 = 0

        // Remove any partial file from a previous attempt before creating fresh.
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path(), contents: nil) else {
            throw ImageError.diskWriteFailed
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let bufferTarget = 512 * 1024
        var buffer = Data(capacity: bufferTarget)

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= bufferTarget {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                onProgress(received, max(contentLength, received))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            onProgress(received, max(contentLength, received))
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
        case rateLimited
        case releaseNotFound(String)
        case assetsNotFound(String)
        case downloadFailed(String)
        case diskWriteFailed
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid GitHub API URL. Check the repo slug in Settings."
            case .githubError:
                return "GitHub API returned an unexpected response."
            case .rateLimited:
                return "GitHub API rate limit reached. Please wait a minute and try again."
            case .releaseNotFound(let slug):
                return "No releases found for \(slug). Check the repo slug in Settings."
            case .assetsNotFound(let tag):
                return "No image assets found in release \(tag). Expected files containing '.part'."
            case .downloadFailed(let file):
                return "Download failed for \(file)."
            case .diskWriteFailed:
                return "Could not write to disk. Check available storage."
            case .decompressionFailed:
                return "Failed to decompress the VM image. The download may be corrupt — try again."
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
