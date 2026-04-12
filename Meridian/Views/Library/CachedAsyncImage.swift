import SwiftUI
import AppKit
import CryptoKit

// MARK: - CachedAsyncImage

/// An AsyncImage replacement that caches images in a two-tier store:
/// memory (NSCache, fast) and disk (~/Library/Caches/com.meridian.app/images/,
/// persistent across launches). Prevents re-fetching on tab switches, scrolling,
/// or app restarts.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    var fallbacks: [URL] = []
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase

    /// Initializes with a synchronous memory-cache pre-check so `LazyVGrid` cells
    /// that scroll back into view never flash blank -- they start fully rendered.
    /// Disk reads are deferred to the async `.task` to avoid main-thread I/O.
    init(url: URL?, fallbacks: [URL] = [], @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.fallbacks = fallbacks
        self.content = content
        let urlsToCheck = [url].compactMap { $0 } + fallbacks
        if let hit = urlsToCheck.first(where: { ImageCache.shared.memoryImage(for: $0) != nil }),
           let cached = ImageCache.shared.memoryImage(for: hit) {
            _phase = State(initialValue: .success(Image(nsImage: cached)))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    private func loadImage() async {
        let urlsToTry = [url].compactMap { $0 } + fallbacks
        guard !urlsToTry.isEmpty else {
            phase = .empty
            return
        }

        for tryURL in urlsToTry {
            // Two-tier cache: memory then disk.
            if let cached = ImageCache.shared.image(for: tryURL) {
                phase = .success(Image(nsImage: cached))
                return
            }

            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.imageSession.data(from: tryURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                ImageCache.shared.store(nsImage, for: tryURL, rawData: data)
                phase = .success(Image(nsImage: nsImage))
                return
            } catch {
                continue
            }
        }
        phase = .failure(ImageError.allURLsFailed)
    }

    private enum ImageError: Error {
        case invalidData
        case allURLsFailed
    }
}

// MARK: - ImageCache

/// Thread-safe two-tier image cache: in-memory (NSCache) and persistent disk.
///
/// Memory tier uses NSCache (up to 500 items) — fast, automatically evicted
/// under memory pressure.
///
/// Disk tier stores raw image bytes in ~/Library/Caches/com.meridian.app/images/
/// using SHA-256 of the source URL as the filename. Survives app launches.
/// Capped at 500 MB; when exceeded, the oldest-written files are removed first
/// until the total drops to 400 MB.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, NSImage>()
    private let ioQueue = DispatchQueue(label: "com.meridian.imagecache.io", qos: .utility)

    /// Root of the on-disk image cache directory.
    let diskCacheDirectory: URL

    private static let maxDiskBytes    = 500 * 1024 * 1024  // 500 MB
    private static let targetDiskBytes = 400 * 1024 * 1024  // 400 MB post-eviction target

    private init() {
        memory.countLimit = 500
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheDirectory = caches.appendingPathComponent("com.meridian.app/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDirectory,
                                                  withIntermediateDirectories: true)
        ioQueue.async { [weak self] in self?.evictIfNeeded() }
    }

    // MARK: - Public API

    /// Memory-only lookup. Safe to call on the main thread from view inits.
    func memoryImage(for url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Full two-tier lookup: memory first, then disk. Safe from any thread/actor.
    func image(for url: URL) -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        return readFromDisk(url: url)
    }

    /// Stores the image in memory immediately and schedules an async disk write.
    ///
    /// - Parameters:
    ///   - image:   Decoded NSImage to cache.
    ///   - url:     Source URL, used as the cache key.
    ///   - rawData: Raw HTTP response bytes. When provided these are written
    ///              directly (no re-encoding). Pass `nil` to re-encode from NSImage.
    func store(_ image: NSImage, for url: URL, rawData: Data? = nil) {
        memory.setObject(image, forKey: url as NSURL)
        let fileURL = diskFileURL(for: url)
        let sourceURL = url
        ioQueue.async { [weak self] in
            self?.writeToDisk(rawData: rawData, image: image, fileURL: fileURL, sourceURL: sourceURL)
        }
    }

    // MARK: - Disk internals

    func diskFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        return diskCacheDirectory.appendingPathComponent("\(hex).\(ext)")
    }

    private func readFromDisk(url: URL) -> NSImage? {
        let fileURL = diskFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    private func writeToDisk(rawData: Data?, image: NSImage, fileURL: URL, sourceURL: URL) {
        // Skip if a prior write already landed (e.g. duplicate concurrent fetches).
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        if let rawData {
            try? rawData.write(to: fileURL, options: .atomic)
        } else {
            // Re-encode: PNG for images with potential alpha (logos), JPEG for photos.
            let ext = sourceURL.pathExtension.lowercased()
            let usePNG = ext == "png"
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let data: Data?
            if usePNG {
                data = rep.representation(using: .png, properties: [:])
            } else {
                data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            guard let data else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var entries: [(url: URL, size: Int, creationDate: Date)] = []
        var totalBytes = 0
        for file in files {
            guard let res = try? file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
                  let size = res.fileSize,
                  let date = res.creationDate else { continue }
            entries.append((file, size, date))
            totalBytes += size
        }

        guard totalBytes > Self.maxDiskBytes else { return }

        // Remove oldest-created files first until total drops to the target size.
        entries.sort { $0.creationDate < $1.creationDate }
        for entry in entries {
            guard totalBytes > Self.targetDiskBytes else { break }
            try? fm.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }
}

// MARK: - Dedicated image URLSession

extension URLSession {
    /// Shared session for all Steam art image downloads.
    /// Limits concurrent connections per CDN host to reduce contention during
    /// fast library scrolling, with conservative timeouts for network images.
    static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
}
