import AppKit
import UserNotifications

private let log = MeridianLog(category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private static let splashSize     = NSSize(width: 480, height: 300)
    private static let fullFrameSize  = NSSize(width: 1030, height: 625)

    private var readyObserver: NSObjectProtocol?

    /// Set by MeridianApp so suppression observers are torn down at termination.
    var suppressor: SteamWindowSuppressor?

    /// Set by MeridianApp for process cleanup on termination.
    var steamManager: WineSteamManager?

    /// Set by MeridianApp so the bootstrap pipeline is cancelled before Wine cleanup.
    var bootstrap: BootstrapManager?

    /// Prevents `killAllWineProcesses` from running concurrently or twice.
    private var cleanupDone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Become the notification delegate so banners display even when Meridian is
        // in the foreground (without this delegate method macOS suppresses them).
        UNUserNotificationCenter.current().delegate = self
        MeridianNotifications.requestAuthorization()

        NSApp.setActivationPolicy(.regular)

        if let w = mainWindow {
            setTrafficLights(hidden: true, in: w)
        }

        // Call synchronously — no async hop. The window exists by the time
        // applicationDidFinishLaunching fires. An async dispatch gives macOS
        // window restoration one runloop cycle to restore the previous full-size
        // frame (1030×625) before we can override it, causing the wrong size to
        // flash on screen. Synchronous call wins the race.
        enforceMainWindowLaunchFrame()

        readyObserver = NotificationCenter.default.addObserver(
            forName: .meridianBootstrapReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Observer is delivered on .main — safe to assume main actor isolation
            MainActor.assumeIsolated { self?.animateToFullSize() }
        }
    }

    private func enforceMainWindowLaunchFrame() {
        guard let window = mainWindow else {
            log.warning("enforceMainWindowLaunchFrame: no eligible window found")
            return
        }

        // Prevent macOS window restoration from applying the previous session's
        // frame (full-size 1030×625). Must be set before setContentSize so the
        // restore system never overrides what we're about to write.
        window.isRestorable = false
        window.setFrameAutosaveName("")

        // Lock to splash size first, then center. Centering must come after
        // setContentSize so NSWindow.center() uses the correct geometry when
        // computing the Dock-aware centered position.
        window.contentMinSize = Self.splashSize
        window.contentMaxSize = Self.splashSize
        window.setContentSize(Self.splashSize)
        setTrafficLights(hidden: true, in: window)

        // NSWindow.center() uses the same algorithm as Cmd+Ctrl+C:
        // horizontally centered on the main display, vertically centered in the
        // usable area (screen minus menu bar and Dock).
        window.center()

        log.debug("Main window locked to splash size \(Self.splashSize.width)x\(Self.splashSize.height) and centered")
    }

    private func animateToFullSize() {
        guard let window = mainWindow else {
            log.warning("animateToFullSize: no eligible window found")
            return
        }

        // Unlock sizing before animating — min/max restored in completion handler.
        window.contentMinSize = NSSize(width: 1, height: 1)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)

        setTrafficLights(hidden: false, in: window)

        // Expand from the splash's current center so the final window lands
        // at the same center point that window.center() chose for the splash.
        let currentFrame = window.frame
        let newFrame = NSRect(
            x: currentFrame.midX - Self.fullFrameSize.width / 2,
            y: currentFrame.midY - Self.fullFrameSize.height / 2,
            width: Self.fullFrameSize.width,
            height: Self.fullFrameSize.height
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            // Completion handler is always called on the main thread by AppKit
            MainActor.assumeIsolated {
                guard let window = self?.mainWindow else { return }
                window.setFrame(newFrame, display: true)
                window.contentMinSize = window.contentRect(forFrameRect: window.frame).size
            }
        })

        log.debug("Animating window to full frame \(Self.fullFrameSize.width)x\(Self.fullFrameSize.height)")
    }

    private func setTrafficLights(hidden: Bool, in window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !$0.isSheet && $0.styleMask.contains(.titled) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        suppressor?.stopSuppressing()
        // Final safety-net cleanup — `applicationShouldTerminate` is the primary
        // path and normally runs first with background cleanup; this handles the
        // edge case of a force-quit that skips ShouldTerminate (e.g. SIGTERM).
        if !cleanupDone {
            cleanupDone = true
            TerminationCleanup.killAllWineProcesses()
        }
        if let observer = readyObserver {
            NotificationCenter.default.removeObserver(observer)
            readyObserver = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info("[AppDelegate] termination requested — running Wine/Steam cleanup on background thread")

        // Cancel the bootstrap pipeline so it stops launching Wine processes
        // before the cleanup kills them — prevents race conditions with partial state.
        bootstrap?.cancelForTermination()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            log.warning("[AppDelegate] cleanup timed out — forcing quit")
            sender.reply(toApplicationShouldTerminate: true)
        }

        // Flip the flag on the main actor before dispatching — `cleanupDone` is
        // a @MainActor-isolated property and the actual cleanup work runs off
        // the main actor. If cleanup is already in progress, skip redispatch.
        guard !cleanupDone else {
            log.info("[AppDelegate] cleanup already ran — skipping")
            return .terminateNow
        }
        cleanupDone = true

        DispatchQueue.global(qos: .userInitiated).async {
            TerminationCleanup.killAllWineProcesses()
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Allows notification banners to appear while Meridian is the active foreground app.
    /// Without this, macOS silently drops notifications when the app is focused.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // .banner  → slide-in popup (requires alert style ≠ "None" in System Settings)
        // .list    → always record in Notification Centre regardless of alert style
        // .sound   → play the notification sound
        completionHandler([.banner, .list, .sound])
    }
}
