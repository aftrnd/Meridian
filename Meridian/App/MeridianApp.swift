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
    @State private var licenseManager   = LicenseManager()
    @Environment(\.openWindow) private var openWindow
    /// Debug builds get the Developer menu out of the box; release builds
    /// switch it on in Settings › Developer.
    @AppStorage(AppSettings.developerMenuKey) private var developerMenuEnabled = AppSettings.isDebugBuild

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
                .environment(licenseManager)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    steamWindow.refreshPermission()
                    licenseManager.refresh()
                }
                .task {
                    // Begin MetricKit frame-rate/GPU telemetry (B4). App-level
                    // aggregate; logged for overall-performance diagnostics.
                    GamePerformanceMonitor.shared.start()

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
            // Sign-out lives in Settings › Steam, as on macOS generally; the
            // old second "Meridian" menu next to the app menu is gone.
            if developerMenuEnabled {
                DeveloperCommands()
            }
        }

        Window("Zoom Tuning", id: "zoom-tuning") {
            DetailZoomTuningWindow()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 720)

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
                .environment(licenseManager)
                .environment(session)
        }
    }
}

// MARK: - Developer menu

/// Menu-bar "Developer" menu (Safari's Develop menu pattern): tuning windows,
/// diagnostics, and feature flags. Only installed when
/// `AppSettings.developerMenuKey` is on — default for debug builds.
private struct DeveloperCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Developer") {
            Button("Zoom Tuning…") {
                openWindow(id: "zoom-tuning")
            }
            .keyboardShortcut("z", modifiers: [.command, .option])

            Button("Launch Log") {
                openWindow(id: "launch-log")
            }

            Divider()

            Button("Reveal Logs in Finder") {
                NSWorkspace.shared.open(LogFileWriter.logsDir)
            }
            Button("Reveal Application Support in Finder") {
                NSWorkspace.shared.open(LogFileWriter.logsDir.deletingLastPathComponent())
            }

            Divider()

            Menu("Feature Flags") {
                ForEach(FeatureFlag.allCases) { flag in
                    FeatureFlagToggle(flag: flag)
                }
            }

            Divider()

            Text("\(AppSettings.isDebugBuild ? "Debug" : "Release") build \(AppUpdateChecker.currentVersion)")
        }
    }
}

/// One checkmark menu item / settings toggle per flag. Its own view so each
/// flag gets its own `@AppStorage` (keys are dynamic).
struct FeatureFlagToggle: View {
    let flag: FeatureFlag
    @AppStorage private var isOn: Bool

    init(flag: FeatureFlag) {
        self.flag = flag
        _isOn = AppStorage(wrappedValue: false, flag.defaultsKey)
    }

    var body: some View {
        Toggle(flag.title, isOn: $isOn)
    }
}
