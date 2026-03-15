import SwiftUI
import AppKit

// MARK: - Sidebar Navigation

enum SidebarDestination: Hashable {
    case home
    case library(SteamLibraryStore.LibraryFilter)
    case search
    case steamProfile
    case steamStore
}

struct ContentView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(WineEngine.self) private var engine
    @Environment(WineSteamManager.self) private var steamManager
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self) private var launcher
    @Environment(BootstrapManager.self) private var bootstrap

    @State private var selectedGame: Game?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarDestination: SidebarDestination = .home
    @State private var hasAnimatedToFullSize = false
    @State private var splashVisible = true

    var body: some View {
        Group {
            if splashVisible {
                SplashView()
            } else if !steamAuth.isAuthenticated {
                AuthView()
            } else {
                mainContent
                    .task {
                        await library.refresh(steamID: steamAuth.steamID, apiKey: steamAuth.apiKey)
                    }
                    .sheet(isPresented: Binding(
                        get: { steamAuth.needsAPIKey },
                        set: { _ in }
                    )) {
                        APIKeySetupSheet()
                    }
                    .sheet(item: $selectedGame) { game in
                        GameDetailView(game: game) {
                            selectedGame = nil
                        }
                        .presentationSizing(.fitted)
                    }
            }
        }
        .onChange(of: bootstrap.isReady) { _, ready in
            if ready && !hasAnimatedToFullSize {
                hasAnimatedToFullSize = true
                // Post immediately so the window animation starts in sync with the
                // SplashView blur/fade (both triggered by bootstrap.isReady).
                NotificationCenter.default.post(name: .meridianBootstrapReady, object: nil)
                // Delay the view switch until the 0.3s fade animation finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    splashVisible = false
                }
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedDestination: $sidebarDestination)
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: .infinity)
        } detail: {
            detailContent
        }
        .onChange(of: sidebarDestination) { _, newValue in
            if case .library(let filter) = newValue {
                library.filter = filter
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
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
        }
    }
}

extension Notification.Name {
    static let meridianBootstrapReady = Notification.Name("meridianBootstrapReady")
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var selectedDestination: SidebarDestination
    @Environment(SteamAuthService.self) private var steamAuth

    var body: some View {
        List(selection: $selectedDestination) {
            Label("Home", systemImage: "house")
                .tag(SidebarDestination.home)

            Label("Search", systemImage: "magnifyingglass")
                .tag(SidebarDestination.search)

            Section("Library") {
                ForEach(SteamLibraryStore.LibraryFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filterIcon(filter))
                        .tag(SidebarDestination.library(filter))
                }
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
        case .favorites: return "heart.fill"
        }
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
        case .ready:          return "Engine: \(engine.backendName)"
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
}
