import SwiftUI
import AppKit

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth        = SteamAuthService()
    @State private var library          = SteamLibraryStore()
    @State private var engine           = WineEngine()
    @State private var session          = SteamSession()
    @State private var steamWindow      = SteamWindow()
    @State private var launcher         = Launcher()
    @State private var bootstrap        = BootstrapManager()
    @State private var categories       = CategoryStore()
    @State private var updateChecker    = AppUpdateChecker()
    @State private var engineDownloader = EngineDownloader()

    private let settings = AppSettings.shared

    var body: some Scene {
        let _ = {
            // Wire 1:1 relationships between the new objects.
            session.steamWindow     = steamWindow
            launcher.steamWindow    = steamWindow
            bootstrap.steamWindow   = steamWindow
            appDelegate.session     = session
            appDelegate.bootstrap   = bootstrap
        }()

        WindowGroup {
            ContentView()
                .environment(steamAuth)
                .environment(library)
                .environment(engine)
                .environment(session)
                .environment(launcher)
                .environment(bootstrap)
                .environment(categories)
                .environment(steamWindow)
                .environment(updateChecker)
                .environment(engineDownloader)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    steamWindow.refreshPermission()
                }
                .task {
                    updateChecker.installedEngineTag = engine.engineVersion
                    updateChecker.checkIfStale()

                    let current  = AppUpdateChecker.currentVersion
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateChecker.installedEngineTag = engine.engineVersion
                    updateChecker.checkNow()
                    UserDefaults.standard.set("updates", forKey: "meridian.settingsTab")
                    NotificationCenter.default.post(name: .meridianOpenSettings, object: nil)
                }
            }
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
                .environment(SteamSession())
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 320)

        Settings {
            SettingsView()
                .environment(steamAuth)
                .environment(engine)
                .environment(library)
                .environment(steamWindow)
                .environment(updateChecker)
                .environment(engineDownloader)
                .environment(session)
        }
    }
}
