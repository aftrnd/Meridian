import SwiftUI
import AppKit

// MARK: - Game Card State

enum GameCardState: Equatable {
    case idle
    case notInstalled
    case launching
    case running
    case stopping
}

struct GameGridView: View {
    let game: Game
    let isSelected: Bool
    var isFavorite: Bool = false
    /// When false, the heart badge is hidden (e.g. on the Favorites tab where it's redundant).
    var showFavoriteBadge: Bool = true
    var gameState: GameCardState = .idle

    @State private var isHovered = false
    @State private var runningPulse = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var cardSize: CGSize = .zero
    /// Single resolved image shared across the card.
    /// Pre-populated from cache synchronously so the card never renders blank.
    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    private var isRunning: Bool { gameState == .running }
    private var isLaunching: Bool { gameState == .launching || gameState == .stopping }

    private let maxTilt: Double = 6
    private let perspective: CGFloat = 0.4

    private var tiltX: Double {
        guard isHovered, cardSize.height > 0 else { return 0 }
        let normalized = (hoverLocation.y / cardSize.height) - 0.5
        return -normalized * maxTilt
    }

    private var tiltY: Double {
        guard isHovered, cardSize.width > 0 else { return 0 }
        let normalized = (hoverLocation.x / cardSize.width) - 0.5
        return normalized * maxTilt
    }

    private var highlightOffset: UnitPoint {
        guard isHovered, cardSize.width > 0, cardSize.height > 0 else {
            return .center
        }
        return UnitPoint(
            x: hoverLocation.x / cardSize.width,
            y: hoverLocation.y / cardSize.height
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artSection
            if isSelected {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            infoLabel
        }
        // Explicitly bound to the column/frame width so LazyVGrid's first lazy
        // batch doesn't let any card inflate beyond its assigned column.
        .frame(minWidth: 0, maxWidth: .infinity)
        .rotation3DEffect(
            .degrees(tiltX),
            axis: (x: 1, y: 0, z: 0),
            perspective: perspective
        )
        .rotation3DEffect(
            .degrees(tiltY),
            axis: (x: 0, y: 1, z: 0),
            perspective: perspective
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(
            color: .black.opacity(isHovered ? 0.3 : 0.0),
            radius: isHovered ? 16 : 0,
            y: isHovered ? 8 : 0
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.7), value: hoverLocation)
        .contentShape(Rectangle())
        .onDisappear {
            isHovered = false
            hoverLocation = .zero
        }
        .onAppear { updatePulse() }
        .onChange(of: gameState) { _, _ in updatePulse() }
        // Re-run whenever the game's hash arrives (nil → hash string triggers a reload
        // so new-CDN games display their art as soon as the background fetch resolves).
        .task(id: "\(game.id)-\(game.libraryCapsuleHash ?? "")") { await loadCardImage() }
    }

    private func updatePulse() {
        if isRunning {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                runningPulse = true
            }
        } else {
            runningPulse = false
        }
    }

    /// Loads the card image from cache (synchronous) or network (async).
    ///
    /// URL priority:
    ///  1. New hash-based CDN (shared.*.steamstatic.com/store_item_assets/…) — required
    ///     for games published after ~2024. Only tried when libraryCapsuleHash is set.
    ///  2. Legacy CDN (cdn.akamai.steamstatic.com/steam/apps/…) — covers older titles.
    ///
    /// When Phase 1 fails and libraryCapsuleHash is not yet available, loadFailed is set.
    /// The .task(id:) will re-run once SteamLibraryStore populates the hash, automatically
    /// retrying with the new-CDN URLs.
    private func loadCardImage() async {
        loadFailed = false

        // New-CDN URLs are prepended when a hash is available; otherwise only legacy URLs.
        let urlsToTry = game.newCDNCapsuleURLs
            + [game.verticalCapsuleURL]
            + game.verticalCapsuleURLFallbacks

        // Synchronous cache check — avoids a blank flash for previously loaded images.
        for url in urlsToTry {
            if let cached = ImageCache.shared.image(for: url) {
                if loadedImage == nil { loadedImage = cached }
                return
            }
        }

        // Network fetch — try each URL in priority order.
        for url in urlsToTry {
            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
                guard let nsImage = NSImage(data: data) else { continue }
                ImageCache.shared.store(nsImage, for: url)
                loadedImage = nsImage
                return
            } catch {
                continue
            }
        }

        loadFailed = true
    }

    // MARK: - Art (portrait 2:3)

    private var artSection: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if loadFailed {
                artPlaceholder
            } else {
                Color.primary.opacity(0.05)
                    .overlay { ProgressView().scaleEffect(0.6) }
            }
        }
        .aspectRatio(600.0 / 900.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        // Radial highlight lives here so it's clipped to art bounds and
        // highlightOffset / tiltX are computed against art dimensions only
        // (not the full card including the text label below).
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.12), .clear],
                        center: highlightOffset,
                        startRadius: 0,
                        endRadius: max(cardSize.width, cardSize.height) * 0.8
                    )
                )
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { statusBadge }
        .overlay(alignment: .topTrailing) { trailingBadges }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Track hover inside the art area using native SwiftUI APIs.
        // onContinuousHover fires on every mouse-move (not just boundary crossing),
        // provides view-local coordinates with no conversion needed, and fires .ended
        // automatically on disappear / tab-switch — no NSTrackingArea lifecycle to manage.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverLocation = point
                isHovered = true
            case .ended:
                isHovered = false
                hoverLocation = .zero
            }
        }
        // Recovery for the post-scroll "stuck at false" case: when proxy.scrollTo
        // animates the scroll row, a card translates under the cursor. onContinuousHover
        // only fires on pointer movement so a stationary cursor never triggers .active
        // for the newly arrived card. onHover (NSTrackingArea) re-evaluates whenever
        // the view's frame settles, catching this case.
        // Only recover to true — false is handled exclusively by onContinuousHover
        // .ended to avoid spurious clears from scroll view re-renders.
        .onHover { hovered in
            guard hovered, !isHovered else { return }
            // Position to card center as a neutral default; onContinuousHover
            // .active will correct it to the actual cursor location on first move.
            hoverLocation = CGPoint(x: cardSize.width / 2, y: cardSize.height / 2)
            isHovered = true
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
    }

    // MARK: - Info Label (below art, TV app style)

    private var infoLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(game.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(game.name)

            HStack(spacing: 4) {
                if isFavorite, showFavoriteBadge {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                }
                if game.playtimeMinutes > 0 {
                    Text(game.playtimeFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if game.windowsOnly {
                    WindowsBadge()
                }
            }
        }
        // minWidth: 0 is critical — it lets the label compress to any width,
        // so long game titles don't inflate the card or the grid column.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // MARK: - State Badge

    @ViewBuilder
    private var statusBadge: some View {
        switch gameState {
        case .running:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .scaleEffect(runningPulse ? 1.3 : 0.8)
                Text("Now Playing")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)

        case .launching, .stopping:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text(gameState == .launching ? "Launching" : "Stopping")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)

        case .notInstalled, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingBadges: some View {
        EmptyView()
    }

    private var artPlaceholder: some View {
        Color.primary.opacity(0.05)
            .overlay {
                Image(systemName: "gamecontroller")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Border helpers

    private var cardBorderColor: Color {
        if isRunning { return .green.opacity(runningPulse ? 0.9 : 0.5) }
        if isSelected { return .accentColor }
        if isHovered { return .primary.opacity(0.15) }
        return .clear
    }

    private var cardBorderWidth: CGFloat {
        (isRunning || isSelected) ? 1.5 : 1
    }
}

// MARK: - Windows badge

struct WindowsBadge: View {
    var body: some View {
        Label("Windows", systemImage: "desktopcomputer")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.indigo, in: Capsule())
    }
}


// MARK: - Adaptive Card Layout Metrics

/// Shared engine that computes card width, visible column count, and leading
/// inset for both the horizontal scroll rows (HomeView) and the library grid
/// (LibraryView) so both surfaces always display identically-sized cards.
///
/// **Formula derivation (symmetric peek):**
/// We want `peekFraction` of the adjacent card to show on *both* the leading
/// edge (when scrolled forward) and the trailing edge (always).
///
///   leadingPadding = spacing + peekFraction × cardWidth
///   containerWidth = leadingPadding + N×cardWidth + N×spacing + peekFraction×cardWidth
///                  = (N+1)×spacing + (N + 2×peekFraction)×cardWidth
///   → cardWidth    = (containerWidth − (N+1)×spacing) / (N + 2×peekFraction)
///
/// Using `leadingPadding` as both leading and trailing padding in the library
/// grid produces exactly `containerWidth` total — no leftover space.
struct CardLayoutMetrics {
    let cardWidth: CGFloat
    let visibleCount: Int
    /// Content inset for the leading edge. Produces a symmetric peek:
    /// `peekFraction × cardWidth` shows on each side when scrolling.
    let leadingPadding: CGFloat

    /// Gap between cards (columns) and between grid rows.
    /// 20 pt = 40 px at 2× Retina, matching the TV app's inter-card spacing.
    static let spacing: CGFloat = 20
    /// Fraction of the adjacent card that "peeks" at each scroll edge.
    static let peekFraction: CGFloat = 0.2

    /// Derives layout metrics for the given container width.
    ///
    /// - Parameters:
    ///   - containerWidth: Available width of the scroll view or grid container.
    ///   - maxCards:       Upper bound on visible column count (default 8,
    ///                     matching the TV app's full-screen maximum).
    ///   - minCards:       Lower bound on visible column count (default 5).
    ///                     The window simply shows smaller cards rather than
    ///                     dropping below 5 columns.
    static func compute(
        for containerWidth: CGFloat,
        maxCards: Int = 8,
        minCards: Int = 5
    ) -> CardLayoutMetrics {
        let s = spacing
        let p = peekFraction

        guard containerWidth > 0 else {
            let w: CGFloat = 155
            return CardLayoutMetrics(cardWidth: w, visibleCount: minCards, leadingPadding: s + p * w)
        }

        // Pick N by anchoring to a target card width so the column count steps
        // predictably with window size (rather than always maximising columns).
        let targetWidth: CGFloat = 155
        let rawN = Int(floor(containerWidth / (targetWidth + s)))
        let n = min(max(rawN, minCards), maxCards)

        // No minimum card width clamp — cards shrink evenly when the window
        // is narrow rather than reducing the column count below minCards.
        let w = (containerWidth - CGFloat(n + 1) * s) / (CGFloat(n) + 2 * p)
        let lp = s + p * w
        return CardLayoutMetrics(cardWidth: w, visibleCount: n, leadingPadding: lp)
    }
}

#Preview {
    HStack(alignment: .top, spacing: 16) {
        GameGridView(game: Game.previews[0], isSelected: false, isFavorite: true, gameState: .running)
        GameGridView(game: Game.previews[2], isSelected: true, isFavorite: false, gameState: .notInstalled)
        GameGridView(game: Game.previews[4], isSelected: false, isFavorite: false, gameState: .launching)
    }
    .padding()
    .frame(width: 560)
}
