import SwiftUI
import AppKit

// MARK: - Sidebar Navigation

enum SidebarDestination: Hashable {
    case home
    case library(SteamLibraryStore.LibraryFilter)
    case search
    case steamProfile
    case steamStore
    case category(UUID)
}

struct ContentView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(WineEngine.self) private var engine
    @Environment(WineSteamManager.self) private var steamManager
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self) private var launcher
    @Environment(BootstrapManager.self) private var bootstrap
    @Environment(CategoryStore.self) private var categoryStore
    @Environment(\.openSettings) private var openSettings
    @State private var selectedGame: Game?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarDestination: SidebarDestination = .home
    @State private var hasAnimatedToFullSize = false
    @State private var splashVisible = true
    /// Starts false so SwiftUI observes the false→true transition that triggers
    /// sheet presentation. Set to true from `.onAppear` on mainContent.
    @State private var showSetupSheet = false
    /// Guards the onAppear setup check so it runs exactly once per app session.
    @State private var hasCheckedSetup = false
    @State private var showingDownloadsPopover = false

    var body: some View {
        Group {
            // Bootstrap always runs first — engine download, prefix creation,
            // Steam installation. No pre-screen for new users; Meridian's splash
            // is the first thing they see.
            if splashVisible {
                SplashView()
            } else {
                mainContent
                    .task {
                        await library.refresh(steamID: steamAuth.steamID, apiKey: steamAuth.apiKey)
                    }
                    .onAppear {
                        guard !hasCheckedSetup else { return }
                        hasCheckedSetup = true
                        if !steamAuth.isAuthenticated || !steamManager.isSteamLoggedIn || steamAuth.needsAPIKey {
                            showSetupSheet = true
                        }
                    }
                    .sheet(isPresented: $showSetupSheet) {
                        SetupSheet()
                            .interactiveDismissDisabled()
                    }
            }
        }
        .onChange(of: bootstrap.isReady) { _, ready in
            if ready && !hasAnimatedToFullSize {
                hasAnimatedToFullSize = true
                NotificationCenter.default.post(name: .meridianBootstrapReady, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    splashVisible = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meridianOpenSettings)) { _ in
            openSettings()
        }
        // Re-show the setup sheet whenever the user signs out — the .onAppear
        // check on mainContent only fires once at bootstrap. Without this,
        // signing out in Settings leaves the app with no way to sign back in
        // until a full restart.
        .onChange(of: steamAuth.isAuthenticated) { _, authenticated in
            if !authenticated {
                showSetupSheet = true
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedDestination: $sidebarDestination)
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: .infinity)
        } detail: {
            NavigationStack {
                detailColumnRoot
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(item: $selectedGame) { game in
                        GameDetailView(game: game) { selectedGame = nil }
                            .id(game.id)
                    }
                    .toolbar {
                        // Flexible space pushes everything after it to the
                        // trailing end — same pattern as GameDetailView.
                        ToolbarItem(placement: .automatic) { Spacer() }
                        ToolbarItem(placement: .automatic) {
                            DownloadsToolbarButton(
                                launcher: launcher,
                                library: library,
                                isPresented: $showingDownloadsPopover,
                                onSelectGame: { selectedGame = $0 }
                            )
                        }
                    }
            }
        }
        .onChange(of: sidebarDestination) { _, newValue in
            if case .library(let filter) = newValue {
                library.filter = filter
            }
            // Dismiss game detail when changing sections — matches standard master–detail behaviour.
            selectedGame = nil
        }
    }

    /// Root of the split-view detail column; game details push on top via `navigationDestination`.
    @ViewBuilder
    private var detailColumnRoot: some View {
        switch sidebarDestination {
        case .home:
            HomeView(selectedGame: $selectedGame)
        case .library:
            LibraryView(selectedGame: $selectedGame)
        case .search:
            SearchView(selectedGame: $selectedGame)
        case .steamProfile:
            if !steamAuth.steamID.isEmpty {
                SteamWebView(url: URL(string: "https://steamcommunity.com/profiles/\(steamAuth.steamID)")!)
            }
        case .steamStore:
            SteamWebView(url: URL(string: "https://store.steampowered.com")!)
        case .category(let id):
            let cat = categoryStore.category(id: id)
            LibraryView(
                selectedGame: $selectedGame,
                categoryID: id,
                categoryGames: categoryStore.games(in: id, from: library.games),
                categoryTitle: cat?.name
            )
            .id(id)
        }
    }
}

extension Notification.Name {
    static let meridianBootstrapReady = Notification.Name("meridianBootstrapReady")
    static let meridianOpenSettings   = Notification.Name("meridianOpenSettings")
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var selectedDestination: SidebarDestination
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(CategoryStore.self) private var categoryStore

    var body: some View {
        List(selection: $selectedDestination) {
            Label("Search", systemImage: "magnifyingglass")
                .tag(SidebarDestination.search)

            Label("Home", systemImage: "house")
                .tag(SidebarDestination.home)

            Section("Library") {
                ForEach(SteamLibraryStore.LibraryFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filterIcon(filter))
                        .tag(SidebarDestination.library(filter))
                }
            }

            // Only show the section when the user has at least one item
            if !categoryStore.categories.isEmpty || !categoryStore.folders.isEmpty {
                CategoriesSidebarSection(selectedDestination: $selectedDestination)
            }

            Section("Steam") {
                Label("Store", systemImage: "cart")
                    .tag(SidebarDestination.steamStore)
                Label("Profile", systemImage: "person.crop.circle")
                    .tag(SidebarDestination.steamProfile)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Meridian")
    }

    private func filterIcon(_ filter: SteamLibraryStore.LibraryFilter) -> String {
        switch filter {
        case .all:       return "square.grid.2x2"
        case .recent:    return "clock"
        case .installed: return "internaldrive"
        case .favorites: return "heart"
        }
    }
}

// MARK: - Categories Section

/// Available icons the user can choose for a playlist. Shown in the
/// right-click "Change Icon" submenu.
private let categoryIconOptions: [(symbol: String, label: String)] = [
    ("folder",         "Folder"),
    ("person.2",       "Multiplayer"),
    ("person",         "Solo"),
    ("gamecontroller", "Controller"),
    ("star",           "Star"),
    ("heart",          "Heart"),
    ("flame",          "Hot"),
    ("trophy",         "Trophy"),
    ("crown",          "Crown"),
    ("bookmark",       "Bookmark"),
    ("bolt",           "Action"),
    ("sparkles",       "Special"),
    ("moon",           "Chill"),
    ("tag",            "Tag"),
    ("map",            "Open World"),
    ("timer",          "Quick Play"),
    ("puzzlepiece",    "Puzzle"),
    ("list.bullet",    "List"),
    ("clock",          "Recent"),
    ("globe",          "Online"),
]

/// The "Categories" section in the sidebar: folders (collapsible) containing
/// playlists plus top-level playlists, inline rename, icon picker, context menus.
private struct CategoriesSidebarSection: View {
    @Binding var selectedDestination: SidebarDestination
    @Environment(CategoryStore.self) private var categoryStore

    /// ID of the item currently in inline-rename mode (folder or category).
    @State private var editingID: UUID?
    @State private var editingName: String = ""

    var body: some View {
        Section("Categories") {
            // Top-level categories (not inside any folder)
            ForEach(categoryStore.topLevelCategories()) { cat in
                categoryRow(cat)
            }

            // Folders with nested categories
            ForEach(categoryStore.sortedFolders) { folder in
                folderRow(folder)
            }
        }
    }

    // MARK: Category row

    @ViewBuilder
    private func categoryRow(_ cat: GameCategory) -> some View {
        Group {
            if editingID == cat.id {
                TextField("", text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit { commitRename(categoryID: cat.id) }
                    .onExitCommand { editingID = nil }
            } else {
                Label(cat.name, systemImage: cat.icon)
            }
        }
        .tag(SidebarDestination.category(cat.id))
        .contextMenu { categoryContextMenu(cat) }
    }

    // MARK: Folder row

    @ViewBuilder
    private func folderRow(_ folder: CategoryFolder) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get:  { folder.isExpanded },
                set:  { _ in categoryStore.toggleFolderExpanded(id: folder.id) }
            )
        ) {
            ForEach(categoryStore.categories(inFolder: folder.id)) { cat in
                categoryRow(cat)
            }
        } label: {
            Group {
                if editingID == folder.id {
                    TextField("", text: $editingName)
                        .textFieldStyle(.plain)
                        .onSubmit { commitFolderRename(folderID: folder.id) }
                        .onExitCommand { editingID = nil }
                } else {
                    Label(folder.name, systemImage: "folder")
                }
            }
            .contextMenu { folderContextMenu(folder) }
        }
    }

    // MARK: Context menus

    @ViewBuilder
    private func categoryContextMenu(_ cat: GameCategory) -> some View {
        Button("Rename") {
            beginRename(id: cat.id, currentName: cat.name)
        }

        // Icon picker — right-click to cycle through SF Symbols
        Menu("Change Icon") {
            ForEach(categoryIconOptions, id: \.symbol) { option in
                Button {
                    categoryStore.changeIcon(id: cat.id, icon: option.symbol)
                } label: {
                    Label(
                        option.label + (cat.icon == option.symbol ? " ✓" : ""),
                        systemImage: option.symbol
                    )
                }
            }
        }

        if !categoryStore.sortedFolders.isEmpty {
            Menu("Move to Folder") {
                Button("No Folder") {
                    categoryStore.moveCategory(id: cat.id, toFolder: nil)
                }
                Divider()
                ForEach(categoryStore.sortedFolders) { folder in
                    Button(folder.name) {
                        categoryStore.moveCategory(id: cat.id, toFolder: folder.id)
                    }
                }
            }
        }

        Divider()

        Button("Delete Playlist", role: .destructive) {
            if case .category(let sel) = selectedDestination, sel == cat.id {
                selectedDestination = .library(.all)
            }
            categoryStore.deleteCategory(id: cat.id)
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: CategoryFolder) -> some View {
        Button("Rename") {
            beginRename(id: folder.id, currentName: folder.name)
        }

        Divider()

        Button("Delete Folder", role: .destructive) {
            // If currently viewing a category inside this folder, navigate away
            if case .category(let sel) = selectedDestination,
               categoryStore.category(id: sel)?.folderID == folder.id {
                selectedDestination = .library(.all)
            }
            categoryStore.deleteFolder(id: folder.id)
        }
    }

    // MARK: Rename helpers

    private func beginRename(id: UUID, currentName: String) {
        editingName = currentName
        editingID   = id
    }

    private func commitRename(categoryID: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            categoryStore.renameCategory(id: categoryID, name: trimmed)
        }
        editingID = nil
    }

    private func commitFolderRename(folderID: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            categoryStore.renameFolder(id: folderID, name: trimmed)
        }
        editingID = nil
    }
}

// MARK: - Engine Status Pill

private struct EngineStatusPill: View {
    @Environment(WineEngine.self) private var engine
    var onSetUp: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !engine.isReady {
                Button("Set Up…") { onSetUp?() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(GlassCapsuleBackground())
    }

    private var dotColor: Color {
        switch engine.state {
        case .ready:          return .green
        case .notInstalled:   return .gray
        case .error:          return .red
        }
    }

    private var statusLabel: String {
        switch engine.state {
        case .ready:          return "Meridian Engine"
        case .notInstalled:   return "Engine Not Found"
        case .error:          return "Engine Error"
        }
    }
}

// MARK: - Glass Effect Backgrounds

struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Update Available Banner

struct UpdateAvailableBanner: View {
    let message: String
    let onDismiss: () -> Void
    let onViewUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .font(.body)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("View Update") {
                onViewUpdate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(GlassRoundedBackground(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

struct GlassRoundedBackground: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

#Preview {
    ContentView()
        .environment(SteamAuthService())
        .environment(SteamLibraryStore())
        .environment(WineEngine())
        .environment(WineSteamManager())
        .environment(SteamSessionBridge())
        .environment(GameLauncher())
        .environment(BootstrapManager())
        .environment(CategoryStore())
        .environment(AppUpdateChecker())
}
