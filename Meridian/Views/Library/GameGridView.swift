import SwiftUI
import AppKit
import ImageIO

// MARK: - Detail prefetch

/// Hover is a click candidate: warm the detail page's store data and
/// achievements so they're cached by the time the zoom lands. Debounced so a
/// cursor sweeping a row doesn't fan out a request per card; the Keychain
/// read for the API key happens after the debounce for the same reason.
@MainActor
final class DetailPrefetch {
    private var task: Task<Void, Never>?

    func begin(appID: Int, auth: SteamAuthService) {
        guard task == nil else { return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await SteamAPIService.shared.prefetchDetail(appID: appID, steamID: auth.steamID, apiKey: auth.apiKey)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Capsule art

/// One loader for a game's portrait capsule, shared by the cards and the
/// Library's prefetch: both resolve the same URL, decode once (off the main
/// actor, at card size) and never fetch the same art twice at once.
enum CapsuleArt {
    /// Long side the art is decoded to: 600×900, native for the new-CDN
    /// capsule, sharp for the largest cards (~260 pt at 2×) and for the zoom
    /// ghost while it's visible. The legacy 2× capsule (1200×1800) costs 4×
    /// the memory and decode time for pixels no card draws.
    static let maxPixelSize = 900

    static func urls(for game: Game) -> [URL] {
        game.newCDNCapsuleURLs + [game.verticalCapsuleURL] + game.verticalCapsuleURLFallbacks
    }

    private static func key(for game: Game) -> String { "\(game.id)-\(game.libraryCapsuleHash ?? "")" }

    /// The URL each game's art was found at, so a memory check is one lookup
    /// instead of building and hashing ~15 candidate URLs (cards run it in
    /// `init`, on every parent update).
    @MainActor private static var resolved: [String: URL] = [:]
    @MainActor private static var prefetching: Set<String> = []

    /// Memory-tier hit only: safe in a view's init or body.
    @MainActor static func cached(for game: Game) -> (image: NSImage, url: URL)? {
        if let url = resolved[key(for: game)] {
            return ImageCache.shared.memoryImage(for: url).map { ($0, url) }
        }
        for url in urls(for: game) {
            if let image = ImageCache.shared.memoryImage(for: url) {
                resolved[key(for: game)] = url
                return (image, url)
            }
        }
        return nil
    }

    /// Memory → disk → network, decoded off the main actor. Concurrent calls
    /// for one game share a single load.
    @MainActor static func load(for game: Game) async -> (image: NSImage, url: URL)? {
        if let hit = cached(for: game) { return hit }
        let key = key(for: game)
        guard let loaded = await loads.load(key: key, urls: urls(for: game)) else { return nil }
        resolved[key] = loaded.url
        return (loaded.image, loaded.url)
    }

    /// Decodes art into memory ahead of the cards that will show it (the
    /// Library calls this for the rows below the ones on screen).
    @MainActor static func prefetch(_ games: some Sequence<Game>) {
        for game in games {
            let key = key(for: game)
            guard cached(for: game) == nil, prefetching.insert(key).inserted else { continue }
            Task(priority: .utility) {
                _ = await load(for: game)
                prefetching.remove(key)
            }
        }
    }

    /// Downloads art that isn't on disk yet (bytes only, nothing decoded or
    /// held in memory), so scrolling the Library later is a disk read, never
    /// a network wait. Four at a time, matching the image session.
    static func warmDisk(_ games: [Game]) async {
        let jobs = games.map { (key: key(for: $0), urls: urls(for: $0)) }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for job in jobs {
                guard !Task.isCancelled else { break }
                guard await loads.claimWarm(job.key) else { continue }
                if running == 4 {
                    _ = await group.next()
                    running -= 1
                }
                group.addTask(priority: .utility) {
                    let done = await fetchToDisk(job.urls)
                    await loads.finishWarm(job.key, done: done)
                }
                running += 1
            }
        }
    }

    private static let loads = Loads()

    /// A decoded capsule and where it came from. NSImage isn't Sendable; this
    /// one is only ever read after decoding (same reasoning as
    /// `ImageCache.EdgeColorsBox`).
    private struct Loaded: @unchecked Sendable {
        let image: NSImage
        let url: URL
    }

    private actor Loads {
        private var inFlight: [String: Task<Loaded?, Never>] = [:]
        private var warming: Set<String> = []
        private var warmed: Set<String> = []

        func load(key: String, urls: [URL]) async -> Loaded? {
            if let running = inFlight[key] { return await running.value }
            let task = Task.detached(priority: .userInitiated) { await CapsuleArt.fetch(urls) }
            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil
            return result
        }

        func claimWarm(_ key: String) -> Bool {
            guard !warmed.contains(key) else { return false }
            return warming.insert(key).inserted
        }

        func finishWarm(_ key: String, done: Bool) {
            warming.remove(key)
            if done { warmed.insert(key) }
        }
    }

    /// Same URL order as always: every cached candidate first, then the
    /// network in priority order.
    private static func fetch(_ urls: [URL]) async -> Loaded? {
        for url in urls {
            if let image = await ImageCache.shared.imageAsync(for: url, maxPixelSize: maxPixelSize) {
                return Loaded(image: image, url: url)
            }
        }
        for url in urls {
            guard let (data, response) = try? await URLSession.imageSession.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
            guard let image = await ImageCache.decode(data, maxPixelSize: maxPixelSize) else { continue }
            ImageCache.shared.store(image, for: url, rawData: data)
            return Loaded(image: image, url: url)
        }
        return nil
    }

    /// True once some candidate is on disk (already, or downloaded now).
    private static func fetchToDisk(_ urls: [URL]) async -> Bool {
        if urls.contains(where: { ImageCache.shared.isOnDisk($0) }) { return true }
        for url in urls {
            guard !Task.isCancelled else { return false }
            guard let (data, response) = try? await URLSession.imageSession.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { continue }
            ImageCache.shared.storeOnDisk(data, for: url)
            return true
        }
        return false
    }
}

/// Whether the scroll view holding the cards is moving. Cards don't hover
/// then: content sliding under a still pointer would lift, tilt and re-lay out
/// each card's label in turn, every frame of the scroll. A plain reference,
/// not view state: the phase flips several times per flick, and as `@State`
/// each flip re-ran the whole Library body (filter, sort, grid, scroll view
/// insets) or the Home row, plus every visible card. Cards read it from their
/// hover handlers; the one hovered card leaves a closure to drop its lift.
@MainActor
final class CardHoverGate {
    private(set) var isScrolling = false
    private var dropHover: (() -> Void)?

    func scrollPhaseChanged(to phase: ScrollPhase) {
        let scrolling = phase != .idle
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        if scrolling {
            dropHover?()
            dropHover = nil
        }
    }

    /// The card now under the pointer (replaces the previous one).
    func cardHovered(drop: @escaping () -> Void) {
        dropHover = drop
    }
}

extension EnvironmentValues {
    /// Set by the scroll view holding the cards (Home rows, Library and Search grids).
    @Entry var cardHoverGate: CardHoverGate? = nil
}

// MARK: - Game Card State

enum GameCardState: Equatable {
    case idle
    case notInstalled
    /// Installed, but Steam has a newer build to download first.
    case updateAvailable
    /// Game files are downloading. `progress` is 0…1 or nil while preparing.
    case downloading(progress: Double?)
    case launching
    case running
    case stopping

    /// A game nothing is happening to right now: its install state alone.
    init(resting game: Game) {
        switch game.installState {
        case .installed:      self = .idle
        case .updateRequired: self = .updateAvailable
        case .notInstalled:   self = .notInstalled
        }
    }
}

struct GameGridView: View {
    let game: Game
    let isSelected: Bool
    var isFavorite: Bool = false
    /// When false, the heart badge is hidden (e.g. on the Favorites tab where it's redundant).
    var showFavoriteBadge: Bool = true
    var gameState: GameCardState = .idle

    @State private var isHovered = false
    /// Set when hover resumes after a close landed on this card: the lift
    /// eases back in instead of snapping. Cleared by the next pointer event.
    @State private var hoverEasesIn = false
    @State private var runningPulse = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var cardSize: CGSize = .zero
    /// Art frame in the detail stage's coordinate space — the zoom's card rect.
    /// Held in a plain reference, NOT observed: it changes on every scroll
    /// frame and nothing the card draws depends on it (only the registry and
    /// the flight-source match read it), so writing it must not re-evaluate
    /// the body. As a `@State CGRect` it re-ran every visible card's body per
    /// frame while a row scrolled — the horizontal-scroll lag.
    @State private var art = ArtFrameBox()
    /// Single resolved image shared across the card.
    /// Pre-populated from cache synchronously so the card never renders blank.
    @State private var loadedImage: NSImage?
    @State private var loadFailed = false
    /// Corner colors sampled from the art — drives the ambient glow bleed.
    @State private var glowColors: ImageCache.EdgeColors?
    @State private var prefetch = DetailPrefetch()
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.detailFlightSource) private var flightSource
    @Environment(\.cardHoverGate) private var hoverGate

    init(
        game: Game,
        isSelected: Bool,
        isFavorite: Bool = false,
        showFavoriteBadge: Bool = true,
        gameState: GameCardState = .idle
    ) {
        self.game = game
        self.isSelected = isSelected
        self.isFavorite = isFavorite
        self.showFavoriteBadge = showFavoriteBadge
        self.gameState = gameState
        // A card scrolled into view starts WITH its art when it's in memory
        // (the Library prefetches the rows ahead): loading from `.task` alone
        // drew the placeholder for at least a frame, every time.
        if let hit = CapsuleArt.cached(for: game) {
            _loadedImage = State(initialValue: hit.image)
            _glowColors = State(initialValue: ImageCache.shared.cachedEdgeColors(for: hit.url))
        }
    }

    /// True while the detail zoom is departing from / returning to THIS card
    /// instance (matched by frame, so a duplicate in another row stays
    /// visible). Hover is suppressed for the whole flight, landing included.
    private var isFlightSource: Bool { matches(flightSource) }

    /// The art hides under the ghost until the close has settled; during the
    /// landing crossfade it's shown again beneath the fading ghost.
    private var hidesArt: Bool { isFlightSource && flightSource?.landing == false }

    private func matches(_ s: DetailFlightSource?) -> Bool {
        guard let s, s.gameID == game.id else { return false }
        let artFrame = art.frame
        return abs(s.artFrame.midX - artFrame.midX) < 2 && abs(s.artFrame.midY - artFrame.midY) < 2
    }

    private var hoverSuppressed: Bool { hoverGate?.isScrolling == true }

    private var isRunning: Bool { gameState == .running }
    private var isLaunching: Bool { gameState == .launching || gameState == .stopping }

    private let maxTilt: Double = 6
    private let perspective: CGFloat = 0.4
    /// Matches `DetailZoomParameters.hoverLift` (0.015 per side).
    private static let hoverScale: CGFloat = 1.03

    private var liftScale: CGFloat { isHovered ? Self.hoverScale : 1 }

    /// Where the label sits once the art has lifted: it follows the art's
    /// bottom-left corner, snapped to device pixels so the text lands sharp.
    private var labelLift: CGSize {
        guard isHovered else { return .zero }
        let half = (Self.hoverScale - 1) / 2
        func snap(_ v: CGFloat) -> CGFloat { (v * displayScale).rounded() / displayScale }
        return CGSize(width: snap(-cardSize.width * half), height: snap(cardSize.height * half))
    }

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
            // Transforms stop at the art: text under a scale/tilt is a bitmap
            // being resampled, so the label below grows via real font sizes.
            artSection
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
                .scaleEffect(liftScale)
                .shadow(
                    color: .black.opacity(isHovered ? 0.3 : 0.0),
                    radius: isHovered ? 16 : 0,
                    y: isHovered ? 8 : 0
                )
            if isSelected {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            // The rest-size label holds the layout slot; the visible one rides
            // in an overlay so its growth never re-flows the grid row. Width
            // grows with it so a truncated title keeps its ellipsis in place.
            infoLabel(scale: 1)
                .hidden()
                .overlay(alignment: .topLeading) {
                    infoLabel(scale: liftScale)
                        .frame(width: cardSize.width > 0 ? cardSize.width * liftScale : nil, alignment: .leading)
                        .offset(labelLift)
                }
        }
        // Explicitly bound to the column/frame width so LazyVGrid's first lazy
        // batch doesn't let any card inflate beyond its assigned column.
        .frame(minWidth: 0, maxWidth: .infinity)
        // Critically damped spring: a cursor sweeping across the row reverses
        // the lift mid-flight without the velocity cut an ease would make.
        .animation(.smooth(duration: hoverEasesIn ? 0.4 : 0.15), value: isHovered)
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.7), value: hoverLocation)
        .contentShape(Rectangle())
        .onDisappear {
            isHovered = false
            hoverLocation = .zero
            prefetch.cancel()
            let wasSource = isFlightSource
            // Otherwise a scrolled-away card's stale frame could anchor a zoom
            // to a spot now occupied by a different card.
            DetailTransitionRegistry.shared.forgetCard(id: game.id, artFrame: art.frame)
            if wasSource { DetailTransitionRegistry.shared.flightSourceMoved?() }
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

    /// Loads the card art through `CapsuleArt` (memory → disk → network, URL
    /// priority: new hash-based CDN when `libraryCapsuleHash` is known, then
    /// the legacy CDN). With no hash yet and nothing found, `loadFailed` is
    /// set; the `.task(id:)` re-runs once SteamLibraryStore fills in the hash.
    private func loadCardImage() async {
        loadFailed = false
        guard let loaded = await CapsuleArt.load(for: game) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        if loadedImage == nil { loadedImage = loaded.image }
        await sampleGlow(loaded.image, url: loaded.url)
    }

    /// Cached corner-color lookup (sync hit for previously sampled art),
    /// falling back to an off-main 3×3 downsample.
    private func sampleGlow(_ image: NSImage, url: URL) async {
        if let cached = ImageCache.shared.cachedEdgeColors(for: url) {
            glowColors = cached
        } else {
            glowColors = await ImageCache.shared.edgeColors(for: image, url: url)
        }
    }

    // MARK: - Art (portrait 2:3)

    private var artSection: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if loadFailed {
                artPlaceholder
            } else {
                // A quiet tile, no spinner: art is usually prefetched, and a
                // ProgressView is an AppKit view built per card mid-scroll.
                Color.primary.opacity(0.05)
            }
        }
        // Art that arrives after the card is on screen fades in.
        .animation(.easeOut(duration: 0.2), value: loadedImage != nil)
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
        // The ghost stands in for the art while it lifts off (iOS hides the
        // source cell the same way); no-op at 1 so idle cards pay nothing.
        // Applied BEFORE the glow so the glow stays put under the departing
        // art instead of blinking out on click.
        .opacity(hidesArt ? 0 : 1)
        // Behind the clipped card so the blur bleeds past its edges onto the
        // background (added after clipShape → the glow itself is not clipped).
        .background { ArtGlowBackground(colors: glowColors) }
        // Track hover inside the art area using native SwiftUI APIs.
        // onContinuousHover fires on every mouse-move (not just boundary crossing),
        // provides view-local coordinates with no conversion needed, and fires .ended
        // automatically on disappear / tab-switch — no NSTrackingArea lifecycle to manage.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                // Hit testing is off for the flight's target side only, so
                // moves still arrive mid-close — ignore them until landed.
                guard !isFlightSource, !hoverSuppressed else { return }
                if !isHovered { hoverGate?.cardHovered(drop: dropHover) }
                hoverEasesIn = false
                hoverLocation = point
                isHovered = true
                // Hover = click candidate — make this instance the flight anchor.
                registerCard(hovered: true)
                prefetch.begin(appID: game.id, auth: steamAuth)
            case .ended:
                hoverEasesIn = false
                isHovered = false
                hoverLocation = .zero
                registerCard(hovered: false)
                prefetch.cancel()
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DetailTransitionRegistry.stageSpace)) } action: { frame in
            // frame(in:) includes the card's own hover lift/tilt (verified), so
            // only take layout-scale readings; the registry adds the lift itself.
            guard !isHovered else { return }
            let wasSource = isFlightSource
            // Size only changes on layout, not scroll — skip the no-op write
            // (a same-value @State set still invalidates the view).
            if cardSize != frame.size { cardSize = frame.size }
            art.frame = frame
            registerCard(hovered: false)
            // Scrolled out from under the returning art.
            if wasSource, !isFlightSource { DetailTransitionRegistry.shared.flightSourceMoved?() }
        }
        // The ghost must be exactly what the card draws.
        .onChange(of: loadedImage) { _, _ in registerCard(hovered: isHovered) }
        // The art is lifting off (or landing): drop the hover state now. Hit
        // testing is off for the flight so `.ended` would never arrive, and a
        // stuck hover would re-appear tilted + highlighted when the art returns.
        // Once the landing crossfade ends, a pointer still over the art eases
        // the hover back in (no event fires for a pointer that hasn't moved).
        .onChange(of: flightSource) { old, new in
            let wasSource = matches(old), isSource = matches(new)
            if isSource, !wasSource {
                guard isHovered else { return }
                isHovered = false
                hoverLocation = .zero
                registerCard(hovered: false)
            } else if wasSource, !isSource, old?.landing == true,
                      let p = DetailTransitionRegistry.shared.pointer, art.frame.contains(p) {
                hoverEasesIn = true
                hoverLocation = CGPoint(x: p.x - art.frame.minX, y: p.y - art.frame.minY)
                isHovered = true
                registerCard(hovered: true)
                hoverGate?.cardHovered(drop: dropHover)
            }
        }
    }

    /// A scroll started under the pointer: settle the lift now.
    private func dropHover() {
        guard isHovered else { return }
        isHovered = false
        hoverLocation = .zero
        registerCard(hovered: false)
        prefetch.cancel()
    }

    private func registerCard(hovered: Bool) {
        DetailTransitionRegistry.shared.recordCard(id: game.id, artFrame: art.frame, isHovered: hovered, image: loadedImage)
    }

    /// Non-observable holder for the card's stage-space art frame (see `art`).
    @MainActor
    private final class ArtFrameBox {
        var frame: CGRect = .zero
    }

    // MARK: - Info Label (below art, TV app style)

    private func infoLabel(scale: CGFloat) -> some View {
        CardInfoLabel(game: game, isFavorite: isFavorite, showFavoriteBadge: showFavoriteBadge, scale: scale)
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

        case .downloading(let progress):
            HStack(spacing: 4) {
                BadgeSpinner()
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Downloading")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)

        case .launching, .stopping:
            HStack(spacing: 4) {
                BadgeSpinner()
                Text(gameState == .launching ? "Launching" : "Stopping")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)

        case .updateAvailable:
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                Text("Update")
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

// MARK: - Badge spinner

/// The status badge's busy glyph: SF Symbols' spinner at the badge's text
/// size, white on the dark capsule, like the Update badge's arrow. A
/// `ProgressView` scaled by 0.5 drew AppKit's 32 pt spinner at 16 pt in a
/// 10 pt frame, in light mode's dark gray (user, Oct 22 2026: "a bit big
/// and incorrect color").
private struct BadgeSpinner: View {
    var body: some View {
        Image(systemName: "progress.indicator")
            .font(.caption2)
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
    }
}

// MARK: - Card info label

/// Title + playtime row under the art. `scale` drives real point sizes (the
/// system text-style sizes × scale), so SwiftUI re-lays the glyphs out at each
/// step of the hover lift instead of stretching a bitmap of them.
private struct CardInfoLabel: View, Animatable {
    let game: Game
    let isFavorite: Bool
    let showFavoriteBadge: Bool
    var scale: CGFloat

    nonisolated var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    private static let titleSize  = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
    private static let detailSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    private static let iconSize   = NSFont.preferredFont(forTextStyle: .caption2).pointSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(game.name)
                .font(.system(size: Self.titleSize * scale, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(game.name)

            HStack(spacing: 4) {
                if isFavorite, showFavoriteBadge {
                    Image(systemName: "heart.fill")
                        .font(.system(size: Self.iconSize * scale))
                        .foregroundStyle(.pink)
                }
                if game.playtimeMinutes > 0 {
                    Text(game.playtimeFormatted)
                        .font(.system(size: Self.detailSize * scale))
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
/// The library grid does NOT use `leadingPadding`: it keeps one 20 pt margin
/// all round so its corner cards sit evenly in the window corners (user,
/// Oct 11 2026). It shares only the column count.
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

    /// The content-column width at the app's DEFAULT window size
    /// (AppDelegate.fullFrameSize 1028 − sidebar 215). The column-count
    /// step anchors to this so the default window always shows the canonical
    /// 5-columns + peek layout. The floating sidebar's default (8 + 220)
    /// leaves 800, still 5 columns.
    static let defaultContentWidth: CGFloat = 805

    /// The card size at the default window (5 columns + peek at
    /// `defaultContentWidth`, ≈126.9 pt). This is the ANCHOR for the column
    /// step: a new column is added roughly every time another default-size
    /// card would fit — so the default layout is exactly reproduced and
    /// resizing feels proportional around it.
    static var referenceCardWidth: CGFloat {
        (defaultContentWidth - 6 * spacing) / (5 + 2 * peekFraction)
    }

    /// The library grid's columns: `visibleCount` flexible columns, `spacing`
    /// apart. Shared by the library pages and Search, which keep one
    /// `spacing` margin all round.
    var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: visibleCount)
    }

    /// Derives layout metrics for the given container width.
    ///
    /// STEPPED-PROPORTIONAL model (July 12 2026, settled): cards resize
    /// naturally to fill the width, but the column count steps with the
    /// window — anchored to the default-size card step so the DEFAULT window
    /// yields exactly 5 columns at the reference size. Spacing and the
    /// peek-slice treatment are constant at every size. Home rows clamp to
    /// 3…5 columns; the library grid allows up to 8.
    ///
    /// - Parameters:
    ///   - containerWidth: Available width of the scroll view or grid container.
    ///   - maxCards:       Upper bound on visible column count.
    ///   - minCards:       Lower bound on visible column count.
    static func compute(
        for containerWidth: CGFloat,
        maxCards: Int = 8,
        minCards: Int = 3
    ) -> CardLayoutMetrics {
        let s = spacing
        let p = peekFraction

        guard containerWidth > 0 else {
            let w = referenceCardWidth
            return CardLayoutMetrics(cardWidth: w, visibleCount: 5, leadingPadding: s + p * w)
        }

        // Column count anchored to the default card step: floor(805 / 146.9)
        // = 5 at the default width, stepping down/up as the window shrinks
        // or grows.
        let rawN = Int(floor(containerWidth / (referenceCardWidth + s)))
        let n = min(max(rawN, minCards), maxCards)

        // Proportional fit: n full cards + the peek slice fill the width
        // exactly, with constant spacing.
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
