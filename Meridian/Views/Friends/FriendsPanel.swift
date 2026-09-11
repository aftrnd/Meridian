import SwiftUI
import AppKit

/// True while the friends inspector is open. HomeView reads this to freeze
/// its layout at the pre-open width (the panel covers the trailing edge).
extension EnvironmentValues {
    @Entry var friendsPanelOpen: Bool = false
    /// The panel's pinned width while open (0 when closed). HomeView derives
    /// the actually-covered width from live geometry (locked − visible) so
    /// edge-anchored chrome tracks the panel edge 1:1; this value only
    /// reconstructs the full column width when Home mounts under an
    /// already-open panel.
    @Entry var friendsPanelCoverWidth: CGFloat = 0
}

// MARK: - Friends Panel (Discord-style inspector)
//
// Toolbar-toggled trailing panel, standard inspector compression (the window
// frame is never resized — reversal-guarded in FriendsPanelTests).
//
// Layout mirrors the Steam client's friends list: your own profile at the
// top (reinstated Sept 10 2026 — read-only identity, opens the same detail
// popover as a friend), then in-game friends as art-backed cards, then the
// persona-state groups in Liquid Glass islands. Type sizes match the
// sidebar (13 pt rows, 11 pt section headers, sentence case) so the two
// columns read as one system.

struct FriendsPanel: View {
    /// Fixed panel width. ContentView pins the inspector to exactly this and
    /// HomeView uses it to compute the visible row width while the panel is
    /// open — keeping the two in sync is what makes "3 full cards + standard
    /// peek at the panel edge" come out exact.
    static let width: CGFloat = 250

    @Environment(SteamLibraryStore.self) private var library

    /// Collapsed sections by title — session-scoped. Offline starts
    /// collapsed: it's the longest group and the least actionable, and an
    /// open panel should show who's around, not who isn't. A set scales to
    /// all of Steam's persona-state sections without one @State per section.
    @State private var collapsedSections: Set<String> = ["Offline"]

    private var inGame: [PlayerSummary] {
        library.friendSummaries.filter { $0.isInGame }
    }

    /// One list section per Steam persona state, mirroring the Steam
    /// client's own friend grouping (user request July 12 2026): Online,
    /// Busy, Away, Snooze, then Offline. "Looking to Trade/Play" (states
    /// 5/6) fold into Online — the row's status line still shows the
    /// specific text. Sorted alphabetically within a section like Steam;
    /// Offline sorts by most-recently-seen instead so its top stays relevant.
    private var statusSections: [(title: String, friends: [PlayerSummary], dimmed: Bool)] {
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
            ("Online",  byName([1, 5, 6]), false),
            ("Busy",    byName([2]),       false),
            ("Away",    byName([3]),       false),
            ("Snooze",  byName([4]),       false),
            ("Offline", offline,           true),
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
                // Apple-standard large title (Music/TV Home style, user
                // direction Sept 7 2026): lives IN the scroll content,
                // leading-aligned, scrolls away with it. The pinned
                // nav-strip design was retired.
                Text("Friends")
                    .font(.largeTitle.bold())
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                if let me = library.ownSummary {
                    OwnProfileHeader(me: me)
                }

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
                        sectionHeader("In Game", count: inGame.count,
                                      isFirst: firstSection == "In Game" && library.ownSummary == nil,
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
                            sectionHeader(section.title, count: section.friends.count,
                                          isFirst: firstSection == section.title && library.ownSummary == nil,
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
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No friends to show")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Friends appear here once your library loads. Your Steam profile's friend list must be public.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    // MARK: Sections

    /// Collapsible section header styled like a sidebar `Section` header
    /// (11 pt semibold, secondary, sentence case — no shouting caps): the
    /// whole row is a click target that toggles the section, with a
    /// trailing chevron indicating state. No status dot: the rows inside
    /// already carry one each.
    private func sectionHeader(
        _ title: String,
        count: Int,
        isFirst: Bool = false,
        expanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
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

// MARK: - Game-art card chrome

/// Art-backed row surface shared by the in-game friend rows and the own-
/// profile header when the user is playing: crisp header art, a slim scrim
/// under the text only, rounded clip and a hairline that warms on hover.
private struct GameArtCard<Content: View>: View {
    let url: URL?
    let height: CGFloat
    let isHovered: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .leading) {
            SteamImageBackdrop(url: url, height: height, blur: 0)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.62), location: 0),
                    .init(color: .black.opacity(0.30), location: 0.5),
                    .init(color: .clear, location: 0.85),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            content()
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isHovered ? .green.opacity(0.5) : .white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private func gameHeaderURL(for gameID: String?) -> URL? {
    guard let gameID, !gameID.isEmpty else { return nil }
    return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(gameID)/header.jpg")
}

// MARK: - Own profile header

/// The user's own identity under the page title, as in the Steam client's
/// friends window — but set like an Apple identity row (Settings' Apple ID
/// row, Game Center's profile): no bezel, no island. Whitespace and type
/// hierarchy do the work: the avatar is the largest in the panel, the name
/// a step above the friend rows, the status line carries the colour.
/// Read-only — Meridian can't change persona state — but it opens the same
/// detail popover a friend row does.
private struct OwnProfileHeader: View {
    let me: PlayerSummary

    @State private var isHovered = false
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    SteamAvatarView(url: me.avatarFullURL ?? me.avatarMediumURL, size: 48)
                    StatusDot(color: me.statusColor, size: 12)
                        .offset(x: 1, y: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(me.personaName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(statusStyle)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Disclosure affordance only while the pointer is here — the
                // row reads as identity at rest, as a control on approach.
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 0.75 : 1)
        .animation(.smooth(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingDetail, arrowEdge: .leading) {
            FriendDetailPopover(friend: me)
        }
    }

    private var statusText: String {
        if me.isInGame, let game = me.gameExtraInfo, !game.isEmpty { return "Playing \(game)" }
        return me.personaStateText
    }

    private var statusStyle: AnyShapeStyle {
        if me.isInGame { return AnyShapeStyle(.green) }
        return me.isOnline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
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

    var body: some View {
        Button {
            showingDetail.toggle()
        } label: {
            GameArtCard(url: gameHeaderURL(for: friend.gameID), height: 48, isHovered: isHovered) {
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        SteamAvatarView(url: friend.avatarMediumURL, size: 28)
                            .overlay(Circle().strokeBorder(.green.opacity(0.8), lineWidth: 1.5))
                        StatusDot(color: .green, size: 9)
                            .offset(x: 1, y: 1)
                    }

                    Text(friend.personaName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 2)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
            }
        }
        .buttonStyle(.pressable)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.smooth(duration: 0.15), value: isHovered)
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
                    SteamAvatarView(url: friend.avatarMediumURL, size: 32)
                        .opacity(dimmed ? 0.55 : 1)
                    StatusDot(color: friend.statusColor, size: 10)
                        .offset(x: 1.5, y: 1.5)
                }

                VStack(alignment: .leading, spacing: 1) {
                    // Sidebar row type: 13 pt regular; the status line one
                    // step down.
                    Text(friend.personaName)
                        .font(.body)
                        .foregroundStyle(dimmed ? .secondary : .primary)
                        .lineLimit(1)

                    Text(rowStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

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
        if let cached = await ImageCache.shared.imageAsync(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let nsImage = await ImageCache.decode(data) else { return }
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
        if let cached = await ImageCache.shared.imageAsync(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return }
            guard let nsImage = await ImageCache.decode(data) else { return }
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
