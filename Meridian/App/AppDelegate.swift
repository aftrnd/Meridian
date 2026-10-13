import AppKit
import UserNotifications

private let log = MeridianLog(category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private static let splashSize     = NSSize(width: 480, height: 300)
    // 1040×625, whole points throughout. Width: the sidebar is 215
    // (ContentView) and the content column 825
    // (`CardLayoutMetrics.defaultContentWidth`). Height: Home's first row sits
    // centred under the hero, 63.6 pt from the hero to the card art and 63.6
    // from the art to the window bottom (hero 302 + 63.6 + art 195.8 + 63.6).
    // Floating sidebar: 1038×625, the glass's 8 pt inset + 215 pt glass +
    // 815 pt content (user, Oct 13 2026); still 5 columns + peek.
    private static var fullFrameSize: NSSize {
        let floating = FloatingSidebar.isAvailable && FeatureFlag.floatingSidebar.isEnabled
        return NSSize(width: floating ? 1038 : 1040, height: 625)
    }
    /// Splash → full-size resize. ContentView swaps the splash for the main
    /// content only after this has elapsed (`ContentView.splashHandoffDelay`),
    /// so the app's heaviest layout never lands mid-resize.
    static let launchResizeDuration: TimeInterval = 0.5

    private var readyObserver: NSObjectProtocol?

    /// Set by MeridianApp for process cleanup on termination.
    var session: SteamSession?

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
        // frame (1040×625) before we can override it, causing the wrong size to
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
        // frame (full-size 1040×625). Must be set before setContentSize so the
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

        // Center the window in the screen's visible frame — the area that excludes
        // both the menu bar (top) and the Dock (bottom/side). This matches the
        // geometric result of Window → Center (Ctrl+Fn+C), which positions the
        // window at the true midpoint of the available display area.
        //
        // NSWindow.center() uses a different formula (Apple's "cascade" convention
        // that places windows at roughly the upper third), which is why calling it
        // produces a window that sits too high. Using visibleFrame.mid directly
        // gives the exact centre the user expects.
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            window.setFrameOrigin(CGPoint(
                x: vf.midX - window.frame.width  / 2,
                y: vf.midY - window.frame.height / 2
            ))
        }

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

        // Traffic lights fade in with the resize instead of popping at t=0.
        setTrafficLights(hidden: false, in: window)
        setTrafficLights(alpha: 0, in: window)

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
            ctx.duration = Self.launchResizeDuration
            // Ease-out heavy: leaves the splash quickly, settles gently.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            window.animator().setFrame(newFrame, display: true)
            self.setTrafficLights(alpha: 1, in: window, animated: true)
        }, completionHandler: { [weak self] in
            // Completion handler is always called on the main thread by AppKit
            MainActor.assumeIsolated {
                guard let window = self?.mainWindow else { return }
                window.setFrame(newFrame, display: true)
                window.contentMinSize = window.contentRect(forFrameRect: window.frame).size
                self?.setTrafficLights(alpha: 1, in: window)
            }
        })

        log.debug("Animating window to full frame \(Self.fullFrameSize.width)x\(Self.fullFrameSize.height)")
    }

    private func setTrafficLights(hidden: Bool, in window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func setTrafficLights(alpha: CGFloat, in window: NSWindow, animated: Bool = false) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            if animated { button.animator().alphaValue = alpha } else { button.alphaValue = alpha }
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !$0.isSheet && $0.styleMask.contains(.titled) }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        if Self.relaunchesOnTerminate { Self.openNewInstance() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info("[AppDelegate] termination requested — running Wine/Steam cleanup on background thread")

        // Cancel the bootstrap pipeline so it stops launching Wine processes
        // before the cleanup kills them — prevents race conditions with partial state.
        bootstrap?.cancelForTermination()

        // The reply and its timeout go through the main RUN LOOP, not the main
        // dispatch queue: while AppKit waits for the reply it doesn't drain the
        // main queue if `terminate(_:)` was itself called from it (a @MainActor
        // Task, `DispatchQueue.main.async`). Sign Out's relaunch waited forever
        // (sample, Oct 12 2026: main thread in `-[NSApplication _shouldTerminate]`,
        // cleanup "done" 20:44:34, no reply, no timeout).
        let timeout = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated {
                log.warning("[AppDelegate] cleanup timed out — forcing quit")
                // Its kill sweeps may still be running: a new instance now
                // could lose its Wine processes to them.
                AppDelegate.relaunchesOnTerminate = false
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timeout, forMode: .common)

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
            Self.onMainRunLoop {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    /// Runs `body` on the main run loop in its common modes, which include the
    /// one AppKit spins while a `.terminateLater` reply is pending.
    nonisolated private static func onMainRunLoop(_ body: @escaping @Sendable @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: - Relaunch

    /// Set by `relaunch()`: a new Meridian opens as this one exits.
    private static var relaunchesOnTerminate = false

    /// Quits and opens Meridian again, for a sign-out or reset that should
    /// leave nothing of the old account on screen (user, Oct 12 2026: the
    /// library stayed behind setup until a restart). Meridian hides at once;
    /// the new instance opens from `applicationWillTerminate`, after the quit
    /// cleanup (`TerminationCleanup.killAllWineProcesses`) has finished, so
    /// that cleanup can't kill the new instance's Wine processes.
    static func relaunch() {
        log.info("[relaunch] quitting; a new Meridian opens once the quit cleanup is done")
        relaunchesOnTerminate = true
        NSApp.hide(nil)
        NSApp.terminate(nil)
    }

    /// `open -n`: a new instance while this one is still exiting. A separate
    /// process, so the launch doesn't depend on this one living on.
    private static func openNewInstance() {
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundleURL.path(percentEncoded: false)]
        do {
            try open.run()
            log.info("[relaunch] opening a new Meridian")
        } catch {
            log.error("[relaunch] couldn't open a new Meridian: \(error.localizedDescription)")
        }
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
