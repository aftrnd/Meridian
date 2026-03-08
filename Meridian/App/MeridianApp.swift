import SwiftUI

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth = SteamAuthService()
    @State private var library = SteamLibraryStore()
    @State private var vmManager = VMManager()
    @State private var sessionBridge = SteamSessionBridge()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(steamAuth)
                .environment(library)
                .environment(vmManager)
                .environment(sessionBridge)
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

        Settings {
            SettingsView()
                .environment(steamAuth)
                .environment(vmManager)
        }
    }
}
