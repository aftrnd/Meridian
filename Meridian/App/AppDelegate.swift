import AppKit
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let splashSize     = NSSize(width: 480, height: 300)
    private static let fullFrameSize  = NSSize(width: 1030, height: 625)

    private var readyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async { [weak self] in
            self?.enforceMainWindowLaunchFrame()
        }

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

        // Prevent macOS from restoring a saved window position/size
        window.isRestorable = false
        window.setFrameAutosaveName("")

        window.contentMinSize = Self.splashSize
        window.contentMaxSize = Self.splashSize
        window.setContentSize(Self.splashSize)
        setTrafficLights(hidden: true, in: window)

        // SplashView centers the window via its .task body (after SwiftUI layout settles).
        // Calling center() here as well gives an early best-effort position.
        window.center()

        log.debug("Main window locked to splash size \(Self.splashSize.width, privacy: .public)x\(Self.splashSize.height, privacy: .public)")
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

        log.debug("Animating window to full frame \(Self.fullFrameSize.width, privacy: .public)x\(Self.fullFrameSize.height, privacy: .public)")
    }

    private func setTrafficLights(hidden: Bool, in window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !$0.isSheet && $0.styleMask.contains(.titled) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info("Termination requested — killing Wine/Steam on background thread")

        // Safety valve: always terminate within 3s even if cleanup hangs
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            log.warning("Termination cleanup timed out — forcing quit")
            sender.reply(toApplicationShouldTerminate: true)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            TerminationCleanup.killAllWineProcesses()
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        // Return .terminateLater so the main thread stays unblocked while
        // cleanup runs. The app exits when reply(toApplicationShouldTerminate:)
        // is called above (or the 3s timeout fires).
        return .terminateLater
    }
}
