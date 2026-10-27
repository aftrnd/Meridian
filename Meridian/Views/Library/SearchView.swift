import SwiftUI
import AppKit

struct SearchView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Environment(Launcher.self)      private var launcher
    @Binding var selectedGame: Game?
    /// The search field sits in the toolbar row; drop it (and its keyboard
    /// focus) while a game detail is presented over this page.
    @Environment(\.detailPresented) private var detailPresented

    @State private var searchText = ""
    /// The genre row's selection (a Steam store tag ID); nil = every game.
    @State private var selectedTag: Int?
    @State private var hoverGate = CardHoverGate()
    /// Measured at the body, as on the library pages, so results use their
    /// grid: same columns, card size and margins.
    @State private var containerWidth: CGFloat = 0
    /// The toolbar's height (the page's top safe area): the search field is
    /// centred in it.
    @State private var toolbarHeight: CGFloat = 0

    /// Genres in the row, at most: the library's most common store tags.
    private static let genreLimit = 24
    /// Results reflow and cross-fade as the query or the genre changes.
    private static let reflow = Animation.smooth(duration: 0.35)
    /// Above and below the genre chips, inside the row.
    private static let genreRowPadding: CGFloat = 8

    private var metrics: CardLayoutMetrics {
        CardLayoutMetrics.compute(for: containerWidth)
    }

    private struct Genre: Identifiable {
        let id: Int
        let name: String
        let look: GenreLook
        let gameCount: Int
    }

    /// The genres (`GenreLook.byTag`) among the games' top store tags
    /// (`SteamLibraryStore.storeTags`), carried by at least two games, most
    /// common first.
    private var genres: [Genre] {
        var counts: [Int: Int] = [:]
        for game in library.games {
            for tag in library.storeTags[game.id] ?? [] { counts[tag, default: 0] += 1 }
        }
        let tagged = counts.compactMap { id, count -> Genre? in
            guard count >= 2, let look = GenreLook.byTag[id], let name = library.storeTagNames[id] else { return nil }
            return Genre(id: id, name: name, look: look, gameCount: count)
        }
        return Array(
            tagged
                .sorted { $0.gameCount != $1.gameCount ? $0.gameCount > $1.gameCount : $0.name < $1.name }
                .prefix(Self.genreLimit)
        )
    }

    /// Games matching the query within the selected genre, best match first
    /// (`matchRank`), then A to Z. No query lists the genre (or, under All
    /// Games, the library) A to Z. Hidden games show only when Library shows them.
    private var searchResults: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var pool = library.games.filter { library.showHiddenGames || !library.isHidden(appID: $0.id) }
        if let tag = selectedTag {
            pool = pool.filter { library.storeTags[$0.id]?.contains(tag) == true }
        }
        let ranked: [(game: Game, rank: Int)] = pool.compactMap { game in
            guard let rank = Self.matchRank(game.name, query) else { return nil }
            return (game, rank)
        }
        return ranked
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                return a.game.name.localizedStandardCompare(b.game.name) == .orderedAscending
            }
            .map(\.game)
    }

    /// 0: the name starts with the query; 1: a word in it does; 2: the query
    /// is inside a word; nil: no match. Ignores case and accents. An empty
    /// query matches everything.
    private static func matchRank(_ name: String, _ query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        var best: Int?
        var searchRange = name.startIndex..<name.endIndex
        while let found = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let rank: Int
            if found.lowerBound == name.startIndex {
                rank = 0
            } else {
                let before = name[name.index(before: found.lowerBound)]
                rank = before.isLetter || before.isNumber ? 2 : 1
            }
            best = min(best ?? rank, rank)
            if rank == 0 { break }
            searchRange = name.index(after: found.lowerBound)..<name.endIndex
        }
        return best
    }

    var body: some View {
        let results = searchResults
        Group {
            if library.isLoading && library.games.isEmpty {
                ProgressView()
            } else if library.games.isEmpty {
                LibraryEmptyState()
            } else if results.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                resultsGrid(results)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(TopBar { genreRow })
        // In the page, not the toolbar: a toolbar item can only centre on
        // the whole window, and this centres on the content area, beside
        // the floating panel (user, Oct 14 2026). The toolbar row passes
        // clicks through to it (probe, Oct 14 2026).
        .overlay(alignment: .top) {
            if !detailPresented {
                SearchField(text: $searchText)
                    .frame(height: toolbarHeight)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarHeight = $0 }
    }

    // MARK: - Genre row

    /// All Games, then the library's genres, scrolling sideways (Apple Games'
    /// category row). A genre lists its games; All Games, or the genre again,
    /// clears it. Always there, genres or not: a bar inserted once the store
    /// tags arrive (~10 s after launch) wasn't drawn until the page scrolled
    /// (meridian.log, Oct 13 2026); the genres fill in beside All Games instead.
    private var genreRow: some View {
        let genres = self.genres
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                GenreChip(title: "All Games", look: .allGames, isSelected: selectedTag == nil) {
                    withAnimation(Self.reflow) { selectedTag = nil }
                }
                ForEach(genres) { genre in
                    GenreChip(title: genre.name, look: genre.look, isSelected: selectedTag == genre.id) {
                        withAnimation(Self.reflow) {
                            selectedTag = selectedTag == genre.id ? nil : genre.id
                        }
                    }
                }
            }
            // Room for the glass's shadow inside the scroll clip.
            .padding(.vertical, Self.genreRowPadding)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, CardLayoutMetrics.spacing, for: .scrollContent)
        // Up under the toolbar to the window's top, and under the floating
        // panel, so the fade has no edge anywhere. It fades across the chips
        // and ends one padding below the row, where the first row of cards
        // rests: nothing is under it until the page scrolls.
        .background {
            TopFade(blurClearance: Self.genreRowPadding * 2)
                .padding(.bottom, -Self.genreRowPadding)
                .ignoresSafeArea(edges: [.top, .leading])
        }
    }

    // MARK: - Results

    private func resultsGrid(_ results: [Game]) -> some View {
        ScrollView {
            LazyVGrid(columns: metrics.gridColumns, spacing: CardLayoutMetrics.spacing) {
                ForEach(results) { game in
                    GameGridView(
                        game: game,
                        isSelected: selectedGame?.id == game.id,
                        isFavorite: library.isFavorite(appID: game.id),
                        gameState: gameState(for: game)
                    )
                    .onTapGesture { selectedGame = game }
                    .contextMenu {
                        Button {
                            library.toggleFavorite(appID: game.id)
                        } label: {
                            Label(
                                library.isFavorite(appID: game.id) ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: library.isFavorite(appID: game.id) ? "heart.slash" : "heart"
                            )
                        }
                        Divider()
                        Button {
                            selectedGame = game
                        } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                    }
                    .transition(.blurReplace)
                }
            }
            .padding(.horizontal, CardLayoutMetrics.spacing)
            // 16 pt from the genre row to the cards, as from the search field
            // to the row (the toolbar leaves 8 pt under the field, the row's
            // padding 8 more): the row's 8 plus these 8.
            .padding(.top, Self.genreRowPadding)
            .padding(.bottom, CardLayoutMetrics.spacing)
            // Typing rearranges the cards in place: kept ones glide to their
            // new spots, dropped ones blur out, new ones blur in.
            .animation(Self.reflow, value: results.map(\.id))
            // Inside the scroll view, so it can find it.
            .background { NoTopScrollEdgeEffect().frame(width: 0, height: 0) }
        }
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in hoverGate.scrollPhaseChanged(to: phase) }
        .environment(\.cardHoverGate, hoverGate)
    }

    private func gameState(for game: Game) -> GameCardState {
        guard launcher.activeAppID == game.id else {
            return GameCardState(resting: game)
        }
        switch launcher.launchState {
        case .downloading, .installing:
            return .downloading(progress: launcher.downloadProgress)
        case .launching:
            return .launching
        case .running:
            return .running
        case .stopping:
            return .stopping
        default:
            return GameCardState(resting: game)
        }
    }
}

// MARK: - Search field

/// The page's search field, centred in the toolbar row: the size of the
/// system toolbar search field it replaces (325 × 36 pt, measured Oct 14
/// 2026), on the same glass. Esc clears it, as it did in the toolbar.
private struct SearchField: View {
    static let width: CGFloat = 325
    static let height: CGFloat = 36
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search all games…", text: $text)
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: Self.width)
        .frame(height: Self.height)
        .background { SearchFieldBackground() }
    }
}

/// The toolbar's glass, drawn behind the field rather than around it: as
/// glass content the text would get its vibrancy (see GenreChipBackground).
private struct SearchFieldBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

// MARK: - Genre row chrome

/// The genre row under the toolbar, in macOS 26's safe-area bar; earlier
/// systems get a plain inset.
private struct TopBar<Bar: View>: ViewModifier {
    @ViewBuilder var bar: Bar

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.safeAreaBar(edge: .top) { bar }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { bar }
        }
    }
}

// MARK: - Scroll edge effect

/// Turns off the enclosing scroll view's top scroll edge effect: the blur
/// macOS 26+ draws under the toolbar and the genre row, with a hard line at
/// its foot (user: no blur, Oct 14 2026). SwiftUI's
/// `scrollEdgeEffectHidden(true)` never reaches it on 27.0.1. Probes without
/// the blur only lacked it because their scroll view was there from the
/// window's first frame, which leaves the effect stuck off; Search always
/// mounts later (probe, Oct 14 2026). NSScrollView's private
/// `allowedPocketEdges` (top = 1) is the switch. Only used while it exists;
/// without it the page keeps the system blur.
private struct NoTopScrollEdgeEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollViewHook { ScrollViewHook() }
    func updateNSView(_ view: ScrollViewHook, context: Context) {}

    final class ScrollViewHook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let scrollView = enclosingScrollView,
                  scrollView.responds(to: NSSelectorFromString("setAllowedPocketEdges:")),
                  let edges = scrollView.value(forKey: "allowedPocketEdges") as? Int else { return }
            scrollView.setValue(edges & ~1, forKey: "allowedPocketEdges")
        }
    }
}

/// In place of that blur (user, Oct 14 2026): the results fade into the
/// window colour towards the top, `peak` at the window's top edge and clear
/// one padding below the genre row, along (1 − t)²: strong only near the
/// top, a long gentle tail through the chips, no edge at either end. (Dark
/// down to the chips, then a fade across them, read as a wall in light
/// mode, user.) Under it, a variable blur `blurRadius` from the window's top
/// edge eases to none at the chips' foot (`blurClearance` up from the
/// bottom), along smootherstep so it never visibly starts or stops (user:
/// "from there to there, smooth, eased"): a touch of detail, the darkening
/// carries it (16 and 4 read as too much, user), and the search field's and
/// the chips' own glass do the rest. The page's own
/// colour, so it's invisible over the bare page at rest (probe: at most
/// 3/255 under the glass) and only shows once cards scroll under: darker in
/// dark mode, lighter in light.
private struct TopFade: View {
    static let peak = 0.95
    static let blurRadius: CGFloat = 2
    /// The blur holds full until this far down its band, then eases out
    /// (user: more blur until near the end; an even taper read as linear).
    static let blurHold = 0.3
    /// The bottom of the view the blur stays out of: below the chips.
    let blurClearance: CGFloat

    var body: some View {
        let base = Color(nsColor: .windowBackgroundColor)
        let steps = 16
        let stops = (0...steps).map { i -> Gradient.Stop in
            let t = Double(i) / Double(steps)
            return Gradient.Stop(color: base.opacity(Self.peak * (1 - t) * (1 - t)), location: t)
        }
        ZStack {
            VStack(spacing: 0) {
                VariableBlur(radius: Self.blurRadius, hold: Self.blurHold)
                Color.clear.frame(height: blurClearance)
            }
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// A blur `radius` strong from one edge (the top for Search, either side for
/// the achievements Cover Flow) to `hold` (a fraction of the way across),
/// easing (smootherstep) to none at the far side, over whatever is
/// behind it: Core Animation's `variableBlur`
/// filter on a backdrop layer, as macOS's own soft scroll edge draws it
/// (probe, 27.0.1). Private (CABackdropLayer, CAFilter), so it's only drawn
/// while both exist; without them, no blur.
struct VariableBlur: NSViewRepresentable {
    enum Edge { case top, leading, trailing }

    let radius: CGFloat
    let hold: Double
    var edge: Edge = .top

    func makeNSView(context: Context) -> BlurView { BlurView(radius: radius, hold: hold, edge: edge) }
    func updateNSView(_ view: BlurView, context: Context) {}

    final class BlurView: NSView {
        private let backdrop: CALayer?

        init(radius: CGFloat, hold: Double, edge: Edge) {
            backdrop = Self.makeBackdrop(radius: radius, hold: hold, edge: edge)
            super.init(frame: .zero)
            wantsLayer = true
            if let backdrop { layer?.addSublayer(backdrop) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // An AppKit view sits above SwiftUI's drawing in hit-testing; never take events.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // Follows resizes without the implicit frame animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop?.frame = bounds
            CATransaction.commit()
        }

        private static func makeBackdrop(radius: CGFloat, hold: Double, edge: Edge) -> CALayer? {
            let factory = NSSelectorFromString("filterWithType:")
            guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
                  let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
                  filterType.responds(to: factory),
                  let filter = filterType.perform(factory, with: "variableBlur")?.takeUnretainedValue() as? NSObject,
                  let mask = maskImage(hold: hold, edge: edge) else { return nil }
            filter.setValue(radius, forKey: "inputRadius")
            filter.setValue(true, forKey: "inputNormalizeEdges")
            filter.setValue(mask, forKey: "inputMaskImage")
            let backdrop = layerType.init()
            backdrop.filters = [filter]
            return backdrop
        }

        /// The filter's radius map: opaque (full radius) from the strong edge
        /// to `hold`, then smootherstep (flat at both ends) to clear along
        /// the far side. A 1 px strip along the blur's axis.
        private static func maskImage(hold: Double, edge: Edge) -> CGImage? {
            let length = 64
            let vertical = edge == .top
            guard let context = CGContext(data: nil, width: vertical ? 1 : length, height: vertical ? length : 1,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            for step in 0..<length {
                // 0 at the strong edge. CG rows count up from the bottom, so
                // for the top edge that's the last row.
                let fraction = Double(step) / Double(length - 1)
                let t = edge == .leading ? fraction : 1 - fraction
                let u = max(0, t - hold) / (1 - hold)
                let eased = u * u * u * (u * (u * 6 - 15) + 10)
                context.setFillColor(gray: 0, alpha: 1 - eased)
                context.fill(vertical ? CGRect(x: 0, y: step, width: 1, height: 1)
                                      : CGRect(x: step, y: 0, width: 1, height: 1))
            }
            return context.makeImage()
        }
    }
}

/// A genre's icon and colour in the row, keyed by Steam store tag ID (IDs,
/// not names, which are localised). Genres only: descriptive tags such as
/// Singleplayer, First-Person or Pixel Graphics have no entry and never show.
private struct GenreLook {
    let symbol: String
    let color: Color

    static let allGames = GenreLook(symbol: "square.grid.2x2.fill", color: .red)

    static let byTag: [Int: GenreLook] = [
        19:    GenreLook(symbol: "flame.fill", color: .orange),                     // Action
        21:    GenreLook(symbol: "map.fill", color: .green),                        // Adventure
        1667:  GenreLook(symbol: "moon.haze.fill", color: .purple),                 // Horror
        1721:  GenreLook(symbol: "brain.head.profile.fill", color: .pink),          // Psychological Horror
        1664:  GenreLook(symbol: "puzzlepiece.fill", color: .blue),                 // Puzzle
        599:   GenreLook(symbol: "shippingbox.fill", color: .brown),                // Simulation
        597:   GenreLook(symbol: "party.popper.fill", color: .yellow),              // Casual
        1774:  GenreLook(symbol: "scope", color: .red),                             // Shooter
        1663:  GenreLook(symbol: "scope", color: .orange),                          // FPS
        9:     GenreLook(symbol: "flag.2.crossed.fill", color: .red),               // Strategy
        122:   GenreLook(symbol: "shield.lefthalf.filled", color: .indigo),         // RPG
        1662:  GenreLook(symbol: "tent.fill", color: .green),                       // Survival
        3810:  GenreLook(symbol: "square.stack.3d.up.fill", color: .orange),        // Sandbox
        1695:  GenreLook(symbol: "globe.americas.fill", color: .teal),              // Open World
        3834:  GenreLook(symbol: "safari.fill", color: .cyan),                      // Exploration
        1625:  GenreLook(symbol: "figure.run", color: .orange),                     // Platformer
        1716:  GenreLook(symbol: "dice.fill", color: .purple),                      // Roguelike
        699:   GenreLook(symbol: "flag.checkered", color: .mint),                   // Racing
        701:   GenreLook(symbol: "sportscourt.fill", color: .green),                // Sports
        1685:  GenreLook(symbol: "person.2.fill", color: .blue),                    // Co-op
        3859:  GenreLook(symbol: "person.3.fill", color: .blue),                    // Multiplayer
        1742:  GenreLook(symbol: "book.fill", color: .brown),                       // Story Rich
        1698:  GenreLook(symbol: "cursorarrow.click.2", color: .gray),              // Point & Click
        1719:  GenreLook(symbol: "theatermasks.fill", color: .yellow),              // Comedy
        5900:  GenreLook(symbol: "figure.walk", color: .green),                     // Walking Simulator
        3942:  GenreLook(symbol: "atom", color: .cyan),                             // Sci-fi
        492:   GenreLook(symbol: "sparkles", color: .pink),                         // Indie
        1743:  GenreLook(symbol: "figure.boxing", color: .red),                     // Fighting
        1752:  GenreLook(symbol: "music.note", color: .pink),                       // Rhythm
        1666:  GenreLook(symbol: "suit.spade.fill", color: .indigo),                // Card Game
        3799:  GenreLook(symbol: "text.book.closed.fill", color: .orange),          // Visual Novel
        1687:  GenreLook(symbol: "eye.slash.fill", color: .gray),                   // Stealth
        1643:  GenreLook(symbol: "hammer.fill", color: .orange),                    // Building
        12472: GenreLook(symbol: "chart.bar.fill", color: .blue),                   // Management
        7178:  GenreLook(symbol: "balloon.2.fill", color: .pink),                   // Party Game
        1645:  GenreLook(symbol: "shield.checkered", color: .blue),                 // Tower Defense
        1628:  GenreLook(symbol: "map", color: .purple),                            // Metroidvania
        1646:  GenreLook(symbol: "figure.fencing", color: .red),                    // Hack and Slash
        5350:  GenreLook(symbol: "figure.and.child.holdinghands", color: .blue),    // Family Friendly
    ]
}

/// One button in the genre row, as in Apple Games: a coloured icon and the
/// name on Liquid Glass in a continuous-corner (squircle) rounded rectangle,
/// accent-tinted when selected.
private struct GenreChip: View {
    let title: String
    let look: GenreLook
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: look.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(look.color))
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .frame(height: GenreChipBackground.height)
            .contentShape(.rect(cornerRadius: GenreChipBackground.cornerRadius))
            .background { GenreChipBackground(isSelected: isSelected) }
        }
        .buttonStyle(.plain)
    }
}

/// Apple Games' chip: 38 pt tall, 12 pt continuous corners. `.glass` button
/// styles ignore `buttonBorderShape` here (they draw ~7 pt circular corners),
/// so the glass is drawn in the shape itself, behind the label: as glass
/// content the label would get its vibrancy (jagged text in light mode).
private struct GenreChipBackground: View {
    static let height: CGFloat = 38
    static let cornerRadius: CGFloat = 12
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: shape)
        } else {
            shape.fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
        }
    }
}
