import SwiftUI
import AppKit

/// An AsyncImage replacement that caches images in memory via NSCache.
/// Prevents images from re-fetching when SwiftUI rebuilds views
/// (e.g., switching tabs, scrolling offscreen).
/// Supports fallback URLs when the primary CDN fails.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    var fallbacks: [URL] = []
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase

    /// Initializes with a synchronous cache pre-check so `LazyVGrid` cells
    /// that scroll back into view never flash blank -- they start fully rendered.
    init(url: URL?, fallbacks: [URL] = [], @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.fallbacks = fallbacks
        self.content = content
        let urlsToCheck = [url].compactMap { $0 } + fallbacks
        if let hit = urlsToCheck.first(where: { ImageCache.shared.image(for: $0) != nil }),
           let cached = ImageCache.shared.image(for: hit) {
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
            if let cached = ImageCache.shared.image(for: tryURL) {
                phase = .success(Image(nsImage: cached))
                return
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: tryURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                ImageCache.shared.store(nsImage, for: tryURL)
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

/// Thread-safe in-memory image cache backed by NSCache.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
