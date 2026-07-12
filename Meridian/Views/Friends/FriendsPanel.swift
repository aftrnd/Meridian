import SwiftUI
import AppKit

/// True while the friends inspector is open. HomeView reads this to freeze
/// its layout at the pre-open width (the panel covers the trailing edge).
extension EnvironmentValues {
    @Entry var friendsPanelOpen: Bool = false
    /// How much of the content column's trailing edge the friends panel
    /// covers (0 when closed). Lets edge-anchored chrome — the rows' forward
    /// chevrons — shift inward to stay visible at the panel edge. Set once
    /// per toggle inside the animation transaction, so it animates with the
    /// slide instead of chasing per-frame geometry.
    @Entry var friendsPanelCoverWidth: CGFloat = 0
}

// MARK: - Friends Panel (Discord-style inspector)
//
// Toolbar-toggled trailing panel, standard inspector compression (the window
// frame is never resized — reversal-guarded in FriendsPanelTests).
//
// No own-profile card: Meridian can't change the user's persona state, so a
// "you" header was dead UI (user direction July 12 2026). The panel is just
// the friends: in-game friends float as art-backed cards, online/offline
// live in Liquid Glass islands.

struct FriendsPanel: View {
    /// Fixed panel width. ContentView pins the inspector to exactly this and
    /// HomeView uses it to compute the visible row width while the panel is
    /// open — keeping the two in sync is what makes "3 full cards + standard
    /// peek at the panel edge" come out exact.
    static let width: CGFloat = 250

    @Environment(SteamLibraryStore.self) private var library

    /// Collapsed sections by title — session-scoped, everything expanded by
    /// default. A set scales to all of Steam's persona-state sections
    /// without one @State per section.
    @State private var collapsedSections: Set<String> = []

    private var inGame: [PlayerSummary] {
        library.friendSummaries.filter { $0.isInGame }
    }

    /// One list section per Steam persona state, mirroring the Steam
    /// client's own friend grouping (user request July 12 2026): Online,
    /// Busy, Away, Snooze, then Offline. "Looking to Trade/Play" (states
    /// 5/6) fold into Online — the row's status line still shows the
    /// specific text. Sorted alphabetically within a section like Steam;
    /// Offline sorts by most-recently-seen instead so its top stays relevant.
    private var statusSections: [(title: String, tint: Color, friends: [PlayerSummary], dimmed: Bool)] {
        let notInGame = library.friendSummaries.filter { !$0.isInGame }
        func byName(_ states: Set<Int>) -> [PlayerSummary] {
            notInGame
                .filter { states.contains($0.personaState) }
                .sorted { $0.personaName.lowercased() < $1.personaName.lowercased() }
        }
        let offline = notInGame
            .filter { !$0.isOnline }
            .sorted { ($0.lastLogoffDate ?? .distantPast) > ($1.lastLogoffDate ?? .distantPast) }

        return [
            ("Online", .green,             byName([1, 5, 6]), false),
            ("Busy",   .red,               byName([2]),       false),
            ("Away",   .yellow,            byName([3]),       false),
            ("Snooze", .orange,            byName([4]),       false),
            ("Offline", Color(white: 0.45), offline,          true),
        ]
    }

    private func isExpanded(_ title: String) -> Bool {
        !collapsedSections.contains(title)
    }

    private func expansionBinding(_ title: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(title) },
            set: { expanded in
                if expanded { collapsedSections.remove(title) }
                else { collapsedSections.insert(title) }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if library.friendSummaries.isEmpty {
                    emptyState
                } else {
                    // The first visible section hugs the title (2 pt) — the
                    // full 16 pt section gap only applies BETWEEN sections.
                    let firstSection = !inGame.isEmpty
                        ? "In Game"
                        : (statusSections.first { !$0.friends.isEmpty }?.title ?? "")

                    // In-game friends float as individual art-backed cards —
                    // the showpiece tier.
                    if !inGame.isEmpty {
                        sectionHeader("In Game", tint: .green, count: inGame.count,
                                      isFirst: firstSection == "In Game",
                                      expanded: expansionBinding("In Game"))
                        if isExpanded("In Game") {
                            VStack(spacing: 6) {
                                ForEach(inGame) { friend in
                                    InGameFriendRow(friend: friend)
                                }
                            }
                            .padding(.horizontal, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    // Persona-state sections in Liquid Glass islands
                    // (glassEffect on macOS 26, material fallback earlier).
                    ForEach(statusSections, id: \.title) { section in
                        if !section.friends.isEmpty {
                            sectionHeader(section.title, tint: section.tint, count: section.friends.count,
                                          isFirst: firstSection == section.title,
                                          expanded: expansionBinding(section.title))
                            if isExpanded(section.title) {
                                glassGroup {
                                    ForEach(section.friends) { friend in
                                        FriendPanelRow(friend: friend, dimmed: section.dimmed)
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }

                Spacer(minLength: 16)
            }
        }
        .scrollIndicators(.hidden)
        // Title pinned INTO the title-bar strip (nav area), mathematically
        // centered on the toolbar's centerline: the strip is the standard
        // macOS unified-toolbar height (52 pt), and the row is exactly that
        // tall with the text vertically centered — so the title's midline
        // lands on the circular button's center (26 pt), not an eyeballed
        // padding. Settled after two reversals (July 12 2026); final: the
        // title lives in the nav area.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Friends")
                    .font(.largeTitle.bold())
                Spacer()
            }
            .padding(.leading, 16)
            .frame(height: Self.toolbarStripHeight)
        }
        .ignoresSafeArea(edges: .top)
        // NOTE: do NOT clipShape this view to round the panel's top-leading
        // corner (tried July 12 2026 — broke the safe-area title hoist), and
        // do NOT put the title in a ToolbarItem (macOS merges it with the
        // circular friends button into a pill).
    }

    /// Standard macOS unified title-bar + toolbar strip height. The pinned
    /// title row matches it exactly so the text centers on the toolbar line.
    private static let toolbarStripHeight: CGFloat = 52

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No friends to show")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Friends appear here once your library loads. Your Steam profile's friend list must be public.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    // MARK: Sections

    /// Collapsible section header: the whole row is a click target that
    /// toggles the section, with a trailing chevron indicating state.
    private func sectionHeader(
        _ title: String,
        tint: Color,
        count: Int,
        isFirst: Bool = false,
        expanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // First section hugs the pinned title; 16 pt is the BETWEEN-sections
        // rhythm only (magenta-gap cleanup, July 12 2026).
        .padding(.top, isFirst ? 2 : 16)
        .padding(.bottom, 6)
    }

    /// Floating Liquid Glass island containing a stack of friend rows.
    /// glassEffect on macOS 26+, material + hairline fallback earlier — same
    /// dual-path pattern as GlassRoundedBackground app-wide.
    private func glassGroup<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 1) {
            rows()
        }
        .padding(5)
        .modifier(GlassRoundedBackground(cornerRadius: 12))
        .padding(.horizontal, 12)
    }
}

// MARK: - In-game friend row (game art backdrop)

/// The showpiece rows: friends currently playing get their game's header art
/// as the row backdrop, kept CRISP — no game-title text (the art IS the
/// title; the detail popover has the name). Just avatar + persona name over
/// a slim scrim behind the text.
private struct InGameFriendRow: View {
    let friend: PlayerSummary

    @State private var isHovered = false
    @State private var showingDetail = false

    private var gameHeaderURL: URL? {
        guard let gameID = friend.gameID, !gameID.isEmpty else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(gameID)/header.jpg")
    }

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            ZStack(alignment: .leading) {
                SteamImageBackdrop(url: gameHeaderURL, height: 48, blur: 0)

                // Slim scrim only where the text sits — the art stays crisp.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.62), location: 0),
                        .init(color: .black.opacity(0.30), location: 0.5),
                        .init(color: .clear, location: 0.85),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        SteamAvatarView(url: friend.avatarMediumURL, size: 28)
                            .overlay(Circle().strokeBorder(.green.opacity(0.8), lineWidth: 1.5))
                        StatusDot(color: .green, size: 9)
                            .offset(x: 1, y: 1)
                    }

                    Text(friend.personaName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 2)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
            }
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovered ? .green.opacity(0.5) : .white.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.snappy(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingDetail, arrowEdge: .leading) {
            FriendDetailPopover(friend: friend)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Standard friend row (online / offline)

private struct FriendPanelRow: View {
    let friend: PlayerSummary
    var dimmed: Bool = false

    @State private var isHovered = false
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    SteamAvatarView(url: friend.avatarMediumURL, size: 30)
                        .opacity(dimmed ? 0.55 : 1)
                    StatusDot(color: friend.statusColor, size: 10)
                        .offset(x: 1.5, y: 1.5)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(friend.personaName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(dimmed ? .secondary : .primary)
                        .lineLimit(1)

                    Text(rowStatusText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(
            isHovered ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingDetail, arrowEdge: .leading) {
            FriendDetailPopover(friend: friend)
        }
    }

    private var rowStatusText: String {
        if friend.isOnline { return friend.personaStateText }
        if let date = friend.lastLogoffDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last seen \(formatter.localizedString(for: date, relativeTo: .now))"
        }
        return "Offline"
    }
}

// MARK: - Friend Detail Popover

/// Rich friend profile: everything GetPlayerSummaries returns plus two lazy
/// per-friend fetches (Steam level, recent playtime — both public-profile
/// dependent; rows simply hide when Valve returns nothing).
struct FriendDetailPopover: View {
    let friend: PlayerSummary

    @Environment(SteamLibraryStore.self) private var library
    @Environment(SteamAuthService.self) private var steamAuth

    @State private var steamLevel: Int?
    @State private var recentGames: [Game] = []
    @State private var detailsLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Identity header ─────────────────────────────────────────
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    SteamAvatarView(url: friend.avatarFullURL ?? friend.avatarMediumURL, size: 56)
                    StatusDot(color: friend.statusColor, size: 14)
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.personaName)
                        .font(.headline)
                        .lineLimit(1)

                    if let real = friend.realName, !real.isEmpty {
                        Text(real + (countryFlag.map { "  \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let flag = countryFlag {
                        Text(flag)
                            .font(.caption)
                    }

                    Text(friend.personaStateText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(friend.isInGame ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 16)

            // ── Facts ───────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 7) {
                if let level = steamLevel {
                    factRow(icon: "star.circle", label: "Steam Level", value: "\(level)")
                }
                if let created = friend.accountCreatedDate {
                    factRow(icon: "calendar", label: "Member Since", value: created.formatted(.dateTime.month(.abbreviated).year()))
                }
                if let since = library.friendsSince[friend.steamID] {
                    factRow(icon: "person.2", label: "Friends Since", value: since.formatted(.dateTime.month(.abbreviated).year()))
                }
                if !friend.isOnline, let seen = friend.lastLogoffDate {
                    let formatter = RelativeDateTimeFormatter()
                    factRow(icon: "clock", label: "Last Seen", value: formatter.localizedString(for: seen, relativeTo: .now))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // ── Recent games (public profiles only) ─────────────────────
            if !recentGames.isEmpty {
                Divider().padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recently Played")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(recentGames.prefix(3)) { game in
                        HStack(spacing: 8) {
                            Image(systemName: "gamecontroller")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Text(game.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let time = game.playtime2WeekFormatted {
                                Text(time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 16)

            // ── Actions ─────────────────────────────────────────────────
            Button {
                if let url = URL(string: friend.profileURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("View Steam Profile", systemImage: "arrow.up.forward.app")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 280)
        .task { await loadDetails() }
    }

    private func factRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
        }
    }

    /// Regional-indicator flag for an ISO 3166-1 alpha-2 country code.
    private var countryFlag: String? {
        guard let code = friend.countryCode, code.count == 2 else { return nil }
        let flag = code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value).map(Character.init)
        }
        guard flag.count == 2 else { return nil }
        return String(flag)
    }

    /// Lazy per-friend fetches. Both endpoints respect the friend's privacy
    /// settings — a private profile returns empty and the rows stay hidden.
    private func loadDetails() async {
        guard !detailsLoaded else { return }
        detailsLoaded = true
        let apiKey = steamAuth.apiKey
        guard !apiKey.isEmpty else { return }

        async let level = try? SteamAPIService.shared.fetchSteamLevel(steamID: friend.steamID, apiKey: apiKey)
        async let recent = try? SteamAPIService.shared.fetchRecentlyPlayed(steamID: friend.steamID, apiKey: apiKey, count: 3)
        steamLevel = await level ?? nil
        recentGames = await recent ?? []
    }
}

// MARK: - Shared image helpers

/// Circular Steam avatar backed by the shared ImageCache (memory + disk).
struct SteamAvatarView: View {
    let url: URL?
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let nsImage = NSImage(data: data) else { return }
            ImageCache.shared.store(nsImage, for: url, rawData: data)
            image = nsImage
        } catch {}
    }
}

/// Full-bleed image backdrop (game header art, blurred avatars) backed by the
/// shared ImageCache. Falls back to a quiet gradient while loading.
struct SteamImageBackdrop: View {
    let url: URL?
    let height: CGFloat
    var blur: CGFloat = 0

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: height)
                        .blur(radius: blur)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .frame(height: height)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let nsImage = NSImage(data: data) else { return }
            ImageCache.shared.store(nsImage, for: url, rawData: data)
            image = nsImage
        } catch {}
    }
}

/// Status dot with a punch-out ring so it reads cleanly over any avatar.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1.5))
    }
}
