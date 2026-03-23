import SwiftUI
import AppKit

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth         = SteamAuthService()
    @State private var library           = SteamLibraryStore()
    @State private var engine            = WineEngine()
    @State private var steamManager      = WineSteamManager()
    @State private var sessionBridge     = SteamSessionBridge()
    @State private var launcher          = GameLauncher()
    @State private var bootstrap         = BootstrapManager()
    @State private var categories        = CategoryStore()
    @State private var suppressor        = SteamWindowSuppressor()
    @State private var updateChecker     = AppUpdateChecker()
    @State private var engineRefresher   = EngineDownloader()

    private let settings = AppSettings.shared

    var body: some Scene {
        // Wire cross-object dependencies. These assignments are idempotent —
        // they run on every body evaluation but always set the same references.
        let _ = {
            bootstrap.windowSuppressor = suppressor
            launcher.windowSuppressor  = suppressor
            steamManager.windowSuppressor = suppressor
            appDelegate.suppressor     = suppressor
        }()

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
                .environment(suppressor)
                .environment(updateChecker)
                // Refresh permission state when Meridian becomes active (user may
                // have just granted Accessibility access in System Preferences).
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    suppressor.refreshPermission()
                    suppressor.onMeridianDidBecomeActive(
                        resumeForSteamPID: steamManager.persistentProcessIdentifier
                    )
                }
                .task {
                    // Rate-limited background update check (once per 24 hours).
                    updateChecker.checkIfStale()

                    // Silently refresh the Wine engine when the app version changes.
                    // Only runs when the engine is already installed; fresh installs
                    // download the engine automatically via SplashView on first launch.
                    let current = AppUpdateChecker.currentVersion
                    let previous = settings.lastLaunchAppVersion
                    settings.lastLaunchAppVersion = current
                    if !previous.isEmpty && previous != current && engine.isReady {
                        engineRefresher.download { engine.detect() }
                    }
                }
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
                .environment(suppressor)
                .environment(updateChecker)
        }
    }
}
