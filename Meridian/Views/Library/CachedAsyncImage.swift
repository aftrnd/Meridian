import SwiftUI
import AppKit
import CryptoKit
import ImageIO

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
            // Two-tier cache: memory then disk (disk read + decode off-main).
            if let cached = await ImageCache.shared.imageAsync(for: tryURL) {
                phase = .success(Image(nsImage: cached))
                return
            }

            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.imageSession.data(from: tryURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = await ImageCache.decode(data) else { continue }
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

// MARK: - Ambient art glow

/// Shared ambient-bleed layer: a 3×3 mesh of the art's sampled colors,
/// blurred outward behind a card. Static GPU layer — no per-frame work.
/// Light mode gets extra opacity + saturation to survive the white backdrop.
struct ArtGlowBackground: View {
    let colors: ImageCache.EdgeColors?
    var cornerRadius: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let c = colors, c.mesh.count == 9 {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.5, 0.5], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ],
                    colors: c.mesh
                ))
                // Glow plate extends 8 pt past the card, then a wide 32 pt
                // blur — radiates well beyond the edges instead of hugging them.
                .padding(-8)
                .blur(radius: 32)
                .saturation(colorScheme == .dark ? 1.0 : 1.3)
                // 20% under the original 0.47 / 0.6 (user, Oct 11 2026).
                .opacity(colorScheme == .dark ? 0.376 : 0.48)
                .allowsHitTesting(false)
        }
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

    /// Decoded bytes the memory tier may hold. Every entry is a fully
    /// decoded bitmap (see `decodeNow`), so cost = width × height × 4.
    private static let memoryCostLimit = 384 * 1024 * 1024

    private init() {
        memory.countLimit = 500
        memory.totalCostLimit = Self.memoryCostLimit
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

    /// Full two-tier lookup: memory first, then disk. Synchronous — the disk
    /// read blocks the calling thread, so prefer `imageAsync(for:)` from
    /// @MainActor (view) code.
    func image(for url: URL) -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        return readFromDisk(url: url)
    }

    /// Two-tier lookup whose disk read + decode run off the caller's actor
    /// (nonisolated async), keeping the main thread free of file I/O.
    /// `maxPixelSize` downsamples a disk hit (see `decodeNow`).
    func imageAsync(for url: URL, maxPixelSize: Int? = nil) async -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        return readFromDisk(url: url, maxPixelSize: maxPixelSize)
    }

    /// Decodes raw image bytes off the caller's actor (nonisolated async).
    /// Use instead of `NSImage(data:)` in @MainActor code.
    static func decode(_ data: Data, maxPixelSize: Int? = nil) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decodeNow(source, maxPixelSize: maxPixelSize)
    }

    /// Decodes on the calling thread, now. ImageIO is lazy: `NSImage(data:)`
    /// and `NSImage(contentsOf:)` keep the JPEG compressed until its first
    /// draw, which happens in Core Animation's commit on the MAIN thread,
    /// mid-scroll or mid-zoom (`cgImage(forProposedRect:)` doesn't change
    /// that). `kCGImageSourceShouldCacheImmediately` decodes here instead.
    /// `maxPixelSize` caps the long side: card art is drawn ~250-500 px wide
    /// while the 2x capsule is 1200×1800. Point size = pixel size, as
    /// `NSImage(data:)` gave for Steam's 72 dpi art.
    static func decodeNow(_ source: CGImageSource, maxPixelSize: Int?) -> NSImage? {
        let image: CGImage?
        if let maxPixelSize {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Memory-tier cost of a decoded image (`decodeNow` sizes in pixels).
    private static func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    /// True when `url`'s bytes are already in the disk tier (no read, no decode).
    func isOnDisk(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: diskFileURL(for: url).path(percentEncoded: false))
    }

    /// Writes downloaded bytes to the disk tier only: for warming art that
    /// isn't on screen yet, without holding a decoded bitmap for it.
    func storeOnDisk(_ data: Data, for url: URL) {
        let fileURL = diskFileURL(for: url)
        ioQueue.async {
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Edge color sampling (ambient art glow)

    /// 3×3 grid of colors sampled from an artwork (row-major, top-left →
    /// bottom-right): corners, edge midpoints, and center. Drives the ambient
    /// glow behind cards; sampled once and cached by URL.
    struct EdgeColors: Sendable {
        /// Exactly 9 colors, row-major from the top-left.
        let mesh: [Color]
    }

    private let edgeColorCache = NSCache<NSURL, EdgeColorsBox>()
    final class EdgeColorsBox: @unchecked Sendable {
        let colors: EdgeColors
        init(_ colors: EdgeColors) { self.colors = colors }
    }

    /// Synchronous cache-only lookup so cards can render the glow immediately
    /// for previously sampled art.
    func cachedEdgeColors(for url: URL) -> EdgeColors? {
        edgeColorCache.object(forKey: url as NSURL)?.colors
    }

    /// Samples a 3×3 color grid off the caller's actor (nonisolated async) by
    /// drawing the art into a 3×3 bitmap — microseconds per image, cached by
    /// URL so it runs once per artwork. Saturation is boosted so the blurred
    /// glow keeps the art's character instead of washing toward gray.
    func edgeColors(for image: NSImage, url: URL) async -> EdgeColors? {
        if let cached = edgeColorCache.object(forKey: url as NSURL) { return cached.colors }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let side = 3
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        func color(_ x: Int, _ y: Int) -> Color {
            let i = (y * side + x) * 4
            let ns = NSColor(srgbRed: CGFloat(pixels[i]) / 255,
                             green: CGFloat(pixels[i + 1]) / 255,
                             blue: CGFloat(pixels[i + 2]) / 255,
                             alpha: 1)
            // Boost saturation ~35% so the glow reflects the art's hues.
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(NSColor(hue: h, saturation: min(1, s * 1.35), brightness: b, alpha: 1))
        }
        // CGContext origin is bottom-left → flip rows so mesh is top-first.
        var mesh: [Color] = []
        for y in stride(from: side - 1, through: 0, by: -1) {
            for x in 0..<side { mesh.append(color(x, y)) }
        }
        let colors = EdgeColors(mesh: mesh)
        edgeColorCache.setObject(EdgeColorsBox(colors), forKey: url as NSURL)
        return colors
    }

    /// Stores the image in memory immediately and schedules an async disk write.
    ///
    /// - Parameters:
    ///   - image:   Decoded NSImage to cache.
    ///   - url:     Source URL, used as the cache key.
    ///   - rawData: Raw HTTP response bytes. When provided these are written
    ///              directly (no re-encoding). Pass `nil` to re-encode from NSImage.
    func store(_ image: NSImage, for url: URL, rawData: Data? = nil) {
        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
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

    private func readFromDisk(url: URL, maxPixelSize: Int? = nil) -> NSImage? {
        let fileURL = diskFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = Self.decodeNow(source, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
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
        // Use contentAccessDate (last read time) for true LRU eviction —
        // keeps recently viewed art and discards long-unviewed images first.
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? fm.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else { return }

        var entries: [(url: URL, size: Int, accessDate: Date)] = []
        var totalBytes = 0
        for file in files {
            guard let res = try? file.resourceValues(forKeys: keys),
                  let size = res.fileSize,
                  let date = res.contentAccessDate else { continue }
            entries.append((file, size, date))
            totalBytes += size
        }

        guard totalBytes > Self.maxDiskBytes else { return }

        // Evict least-recently-accessed files until under target size.
        entries.sort { $0.accessDate < $1.accessDate }
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
