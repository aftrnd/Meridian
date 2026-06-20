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

// MARK: - Shared logo loading

/// Shared loader for the transparent title-logo PNG. Used by both the Home
/// carousel (`HeroLogoImage`) and the game-detail positioned logo
/// (`HeroLogoPositioned`) so the alpha-rejection rule stays identical.
enum HeroLogoLoader {
    /// Returns the first URL whose image has a real alpha channel (a genuine
    /// transparent logo lockup), checking the two-tier cache then network.
    /// Opaque images (key art mistakenly published as logo.png) are rejected.
    static func load(urls: [URL]) async -> NSImage? {
        for url in urls {
            if let cached = ImageCache.shared.image(for: url) {
                if hasAlpha(cached) { return cached }
                continue
            }
            guard !Task.isCancelled else { return nil }
            do {
                let (data, response) = try await URLSession.imageSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data), hasAlpha(nsImage) else { continue }
                ImageCache.shared.store(nsImage, for: url, rawData: data)
                return nsImage
            } catch { continue }
        }
        return nil
    }

    static func hasAlpha(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let alpha = cgImage.alphaInfo
        return alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
    }

    /// Maps Steam's `pinned_position` string to a SwiftUI alignment.
    /// Steam's default (and most common) is bottom-left.
    static func alignment(for pinned: String) -> Alignment {
        switch pinned {
        case "BottomLeft":    return .bottomLeading
        case "BottomCenter":  return .bottom
        case "BottomRight":   return .bottomTrailing
        case "CenterLeft":    return .leading
        case "CenterCenter":  return .center
        case "CenterRight":   return .trailing
        case "UpperLeft", "TopLeft":     return .topLeading
        case "UpperCenter", "TopCenter": return .top
        case "UpperRight", "TopRight":   return .topTrailing
        default:              return .bottomLeading
        }
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
                    .interpolation(.high)
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
        if let image = await HeroLogoLoader.load(urls: urls) {
            loadedImage = image
        } else {
            loadFailed = true
        }
    }
}

// MARK: - Positioned Hero Logo (game detail — Steam-accurate placement)

/// Renders the title logo using Steam's own `logo_position` data — the pinned
/// corner and width/height-percent box from PICS appinfo. This reproduces the
/// exact placement Steam uses in its library detail view (e.g. a small
/// bottom-left lockup, or a large centred wordmark). Used ONLY on the game
/// detail hero; the Home carousel keeps its fixed leading layout via
/// `HeroLogoImage`.
///
/// Falls back to positioned bold text (anchored at the same corner) when no
/// transparent logo is available.
struct HeroLogoPositioned: View {
    let urls: [URL]
    let fallbackName: String
    let placement: LogoPlacement
    /// The hero banner's rendered size, so the percent box can be resolved.
    let containerSize: CGSize
    /// Inset from the hero edges so the logo never sits flush against the
    /// rounded corners. Matches the detail hero's content padding feel.
    var inset: CGFloat = 24

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    private var alignment: Alignment { HeroLogoLoader.alignment(for: placement.pinned) }

    var body: some View {
        // Steam's box is a fraction of the FULL hero; clamp to the inset area.
        let boxW = max(40, containerSize.width  * placement.widthPct  / 100.0)
        let boxH = max(24, containerSize.height * placement.heightPct / 100.0)

        return Color.clear
            .overlay(alignment: alignment) {
                Group {
                    if let image = loadedImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: boxW, maxHeight: boxH, alignment: alignment)
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
                    } else if loadFailed {
                        Text(fallbackName)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            .lineLimit(2)
                            .multilineTextAlignment(textAlignment)
                            .frame(maxWidth: boxW, alignment: alignment)
                    }
                }
            }
            .padding(inset)
            .task(id: urls.first) {
                loadFailed = false
                loadedImage = nil
                if let image = await HeroLogoLoader.load(urls: urls) {
                    loadedImage = image
                } else {
                    loadFailed = true
                }
            }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .center, .top, .bottom: return .center
        case .trailing, .topTrailing, .bottomTrailing: return .trailing
        default: return .leading
        }
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
