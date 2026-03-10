import SwiftUI
import AppKit

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth     = SteamAuthService()
    @State private var library       = SteamLibraryStore()
    @State private var vmManager     = VMManager()
    @State private var sessionBridge = SteamSessionBridge()
    @State private var launcher      = GameLauncher()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(steamAuth)
                .environment(library)
                .environment(vmManager)
                .environment(sessionBridge)
                .environment(launcher)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Meridian") {
                Button("Check for VM Image Update") {
                    Task { await vmManager.imageProvider.checkForUpdate() }
                }
                .keyboardShortcut("U", modifiers: [.command, .shift])

                Divider()

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

        // Full-screen game window opened when a game launches.
        // Independent of the main Meridian window — the player interacts
        // directly with the VM display here.
        WindowGroup("Game", id: "game-window") {
            VMGameWindow(vmManager: vmManager, launcher: launcher)
                .environment(vmManager)
                .environment(launcher)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(steamAuth)
                .environment(vmManager)
        }
    }
}
