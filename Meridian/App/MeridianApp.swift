import SwiftUI
import AppKit

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth     = SteamAuthService()
    @State private var library       = SteamLibraryStore()
    @State private var engine        = WineEngine()
    @State private var steamManager  = WineSteamManager()
    @State private var sessionBridge = SteamSessionBridge()
    @State private var launcher      = GameLauncher()
    @State private var bootstrap     = BootstrapManager()
    @State private var categories    = CategoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(steamAuth)
                .environment(library)
                .environment(engine)
                .environment(steamManager)
                .environment(sessionBridge)
                .environment(launcher)
                .environment(bootstrap)
                .environment(categories)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 300)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Meridian") {
                Button("Sign Out of Steam") {
                    steamAuth.signOut()
                }
                .disabled(!steamAuth.isAuthenticated)
            }
        }

        WindowGroup("Launch Log", id: "launch-log") {
            LaunchLogWindow()
                .environment(launcher)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 320)

        Settings {
            SettingsView()
                .environment(steamAuth)
                .environment(engine)
                .environment(library)
        }
    }
}
