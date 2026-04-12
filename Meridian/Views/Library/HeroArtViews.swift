import SwiftUI
import AppKit

// MARK: - Steam library hero geometry

/// Pixel dimensions of Steam's `library_hero.jpg` — use to size windows/banners to the art's aspect ratio.
enum SteamLibraryHeroMetrics {
    static let pixelWidth: CGFloat = 1920
    static let pixelHeight: CGFloat = 622
    /// width ÷ height (matches landscape hero art)
    static var aspectRatio: CGFloat { pixelWidth / pixelHeight }

    static func width(forBannerHeight height: CGFloat) -> CGFloat {
        height * aspectRatio
    }
}

// MARK: - Background extension (macOS 26)

private struct BackgroundExtensionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }
}

extension View {
    /// TV-style edge extension on supported macOS versions (matches Home hero).
    func applyBackgroundExtension() -> some View {
        modifier(BackgroundExtensionModifier())
    }
}

// MARK: - Hero Logo (styled title PNG)

/// Loads the game's logo PNG (transparent title lockup) from Steam CDN.
/// Falls back to bold text when no logo exists (same behaviour as Home).
///
/// Non-transparent images (e.g. opaque key art that some games publish as logo.png)
/// are rejected — only images with an alpha channel are accepted as logo overlays.
/// This prevents the banner art from doubling as the "title" overlay.
struct HeroLogoImage: View {
    let urls: [URL]
    let fallbackName: String

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .frame(maxWidth: 420, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
            } else if loadFailed {
                Text(fallbackName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .lineLimit(2)
            } else {
                Color.clear.frame(height: 72)
            }
        }
        .task(id: urls.first) { await loadLogo() }
    }

    private func loadLogo() async {
        loadFailed = false
        loadedImage = nil

        for url in urls {
            // Two-tier cache check (memory + disk).
            if let cached = ImageCache.shared.image(for: url) {
                if hasAlpha(cached) {
                    loadedImage = cached
                    return
                }
                // Cached image has no alpha — it's opaque art, not a logo lockup. Skip it.
                continue
            }

            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.imageSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                // Only accept images with an alpha channel as logo overlays.
                guard hasAlpha(nsImage) else { continue }
                ImageCache.shared.store(nsImage, for: url, rawData: data)
                loadedImage = nsImage
                return
            } catch {
                continue
            }
        }

        loadFailed = true
    }

    /// Returns true when the image has a meaningful alpha channel (i.e. can be transparent).
    private func hasAlpha(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let alpha = cgImage.alphaInfo
        return alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
    }
}

// MARK: - Hero Banner

/// Library hero image with cache + shimmer. Use `.fill` on Home (cropped carousel);
/// use `.fit` on game detail so the full Steam banner is visible.
struct HeroBannerImage: View {
    let urls: [URL]
    var contentMode: ContentMode = .fill
    /// Invoked when dimensions are known so the parent can size the banner to the real aspect ratio.
    var onResolvedImageSize: ((CGSize) -> Void)? = nil

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = loadedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if loadFailed {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 48, weight: .thin))
                                .foregroundStyle(.tertiary)
                        }
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ShimmerView() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: urls.first) { await loadImage() }
    }

    private func emitSize(for image: NSImage) {
        let s = image.size
        guard s.width > 0.5, s.height > 0.5 else { return }
        onResolvedImageSize?(s)
    }

    private func loadImage() async {
        for url in urls {
            // Two-tier cache check (memory + disk).
            if let cached = ImageCache.shared.image(for: url) {
                loadedImage = cached
                emitSize(for: cached)
                return
            }

            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.imageSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                ImageCache.shared.store(nsImage, for: url, rawData: data)
                loadedImage = nsImage
                emitSize(for: nsImage)
                return
            } catch {
                continue
            }
        }

        loadFailed = true
    }
}
