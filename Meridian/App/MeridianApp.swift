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
    @State private var engineDownloader  = EngineDownloader()
    @State private var steamCMDService   = SteamCMDService()

    private let settings = AppSettings.shared

    var body: some Scene {
        // Wire cross-object dependencies. These assignments are idempotent —
        // they run on every body evaluation but always set the same references.
        let _ = {
            bootstrap.windowSuppressor    = suppressor
            launcher.windowSuppressor     = suppressor
            launcher.steamCMDService      = steamCMDService
            steamManager.windowSuppressor = suppressor
            appDelegate.suppressor        = suppressor
            appDelegate.steamManager      = steamManager
            appDelegate.bootstrap         = bootstrap
            appDelegate.steamCMDService   = steamCMDService
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
                .environment(engineDownloader)
                .environment(steamCMDService)
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
                    // Tell the update checker which engine is installed so it can
                    // compare against the latest engine release on GitHub.
                    updateChecker.installedEngineTag = engine.engineVersion

                    // Rate-limited background update check (once per 24 hours).
                    updateChecker.checkIfStale()

                    // Silently refresh the Wine engine when the app version changes.
                    // Only runs when the engine is already installed, so it never
                    // interferes with a fresh bootstrap.
                    let current = AppUpdateChecker.currentVersion
                    let previous = settings.lastLaunchAppVersion
                    settings.lastLaunchAppVersion = current
                    if !previous.isEmpty && previous != current && engine.isReady {
                        engineDownloader.download {
                            engine.detect()
                            updateChecker.clearEngineUpdate(newTag: engine.engineVersion)
                        }
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
                .environment(engineDownloader)
                .environment(steamManager)
        }
    }
}
