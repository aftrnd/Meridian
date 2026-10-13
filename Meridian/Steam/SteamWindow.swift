import AppKit
import ApplicationServices
import Observation

private let log = MeridianLog(category: "SteamWindow")

// MARK: - AX callback bridge

private let axCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<_AXBox>.fromOpaque(refcon).takeUnretainedValue().fire()
}

private final class _AXBox: @unchecked Sendable {
    let fn: @Sendable () -> Void
    init(_ fn: @escaping @Sendable () -> Void) { self.fn = fn }
    func fire() { fn() }
}

// MARK: - SteamWindow

/// Suppresses all Wine/Steam windows using AXObserver + a single polling timer.
///
/// Design compared to the deleted SteamWindowSuppressor:
///   • One polling interval (250 ms). No burst timers, no layered suppression.
///   • No multi-layer "suppressNow" reasons. Just suppress or don't.
///   • Pauses while a game window is visible, resumes when the game exits.
///   • Directly registered PIDs get an AXObserver installed immediately
///     (no delay waiting for auto-discovery).
///
/// Bound 1:1 to SteamSession — starts when session starts, stops when it stops.
@Observable
@MainActor
final class SteamWindow {

    private(set) var isPermissionGranted: Bool
    private(set) var isSuppressing: Bool = false

    /// The title of a user-actionable Steam dialog currently being surfaced
    /// (EULA acceptance, subscriber agreement, purchase/family-sharing
    /// confirmation). nil when no such dialog is on screen. Observed by the UI
    /// to show a "Steam needs your confirmation" banner while the real dialog
    /// is brought on-screen (rather than hidden). Reset when the window closes.
    private(set) var actionableDialogTitle: String?

    // MARK: - Window classification (A2 allowlist)

    /// How a Steam-rendered window should be handled.
    enum WindowPolicy: Equatable {
        /// Hide it (off-screen + minimize) — Meridian owns this UX.
        case suppress
        /// Surface it — the user MUST interact (EULA / agreement / purchase /
        /// family-sharing confirmation). These are rare, legitimate, and can't
        /// be actioned any other way without showing Steam's own dialog.
        case surface
    }

    /// Titles that indicate a dialog the user must act on. Matched
    /// case-insensitively as substrings. Ordered before the blanket suppress
    /// so e.g. "Steam Subscriber Agreement" surfaces even though it contains
    /// "steam". Kept deliberately narrow — anything not on this list is hidden.
    ///
    /// MIRROR CONTRACT: mirrored in WindowClassificationTests.actionableTitlePatterns.
    static let actionableTitlePatterns: [String] = [
        "end user license", "eula",
        "subscriber agreement", "license agreement", "agreement",
        "terms of service",
        "purchase", "checkout", "confirm your purchase",
        "family sharing", "family view", "parental",
        "enter your", "authorize",
    ]

    /// Classifies a window title into a handling policy. Actionable dialogs
    /// (EULA / agreement / purchase / family) are surfaced; everything else —
    /// Steam chrome, install/download/notification windows, unknown titles — is
    /// suppressed. A nil/empty title is always suppressed (Steam's transient
    /// chrome windows often have no title before they paint).
    ///
    /// MIRROR CONTRACT: mirrored in WindowClassificationTests.classifyPolicy.
    static func policy(forTitle title: String?) -> WindowPolicy {
        guard let title, !title.isEmpty else { return .suppress }
        let lower = title.lowercased()
        for pattern in actionableTitlePatterns where lower.contains(pattern) {
            return .surface
        }
        return .suppress
    }

    private struct Entry {
        let observer: AXObserver
        let source: CFRunLoopSource
        let box: UnsafeMutableRawPointer
    }

    private var entries: [pid_t: Entry] = [:]
    private var pollingTimer: Timer?
    private var suppressionActive = false

    /// Game-mode suppression (Online launches): suppression stays ACTIVE but
    /// only windows belonging to Steam-owned Wine processes (steam.exe,
    /// steamwebhelper) are hidden — the game's own Wine process is left alone
    /// so its window appears naturally. This replaces the old blanket
    /// `pauseForGame()` during `-applaunch`, which disabled ALL suppression
    /// and let Steam's full post-login UI stay on screen (Bug A,
    /// HANDOFF-2026-07-02-v4).
    private var gameMode = false
    private var steamOwnedPIDs: Set<pid_t> = []
    private var pollTick = 0

    /// Wine processes that can own windows, kept from KVO on
    /// `NSWorkspace.runningApplications` instead of walking the running apps
    /// per tick. Every per-app read is LaunchServices XPC: `bundleIdentifier`
    /// / `executableURL` aren't cached for apps without a bundle (every Wine
    /// process), and even `processIdentifier` is re-fetched after each main
    /// run loop turn (NSRunningApplication.h). Walking ~150 apps per 250 ms
    /// tick was 85% of Meridian's main thread, then still ~12 ms/s with a
    /// per-PID cache, and dropped frames while scrolling and zooming
    /// (Instruments Animation Hitches + Time Profiler, Oct 11 2026).
    private var winePIDs: Set<pid_t> = []
    /// Every listed app, classified once: its pid if it is Wine, nil if not.
    /// Holding the app keeps its identity from being reused while listed.
    private var classifiedApps: [ObjectIdentifier: (app: NSRunningApplication, winePID: pid_t?)] = [:]
    /// Just-launched apps LaunchServices can't name yet; retried each tick
    /// (never classified "not Wine", or their windows would never be hidden).
    private var unclassifiedApps: [NSRunningApplication] = []
    private var runningAppsObservation: NSKeyValueObservation?

    /// Interactive Steam sign-in (`beginSignIn()`): Steam's sign-in window is
    /// the one window shown — centred over Meridian and brought forward once.
    /// Everything else Steam opens (updater, helper windows) stays hidden.
    private var signInMode = false {
        didSet { if !signInMode { isSignInWindowShown = false } }
    }
    private var presentedSignInWindows: Set<CFHashCode> = []

    /// Steam is waiting on the player mid-launch (a game's EULA, a choice of
    /// launch option): every titled Steam window is shown, centred over
    /// Meridian once, until `endSteamPrompt()`. Steam titles its EULA dialog
    /// just "Steam", so the title allowlist hid it and the launch waited for
    /// an answer nobody could give (Super Battle Golf, Oct 12 2026).
    private var promptMode = false
    private var presentedPromptWindows: Set<CFHashCode> = []

    /// True once Steam's sign-in window has been presented in sign-in mode
    /// (onboarding switches from "Starting Steam" to "scan the code").
    private(set) var isSignInWindowShown = false

    /// Command-line substrings identifying Steam-owned Wine processes. These
    /// survive Wine's argv[0] rewrite (the Windows path still contains the
    /// process name — engine-research-findings.mdc Pattern 2).
    /// MIRROR CONTRACT: mirrored in OnlineFlowTests.steamProcessPatterns.
    static let steamProcessPatterns = ["steam.exe", "steamwebhelper"]

    init() {
        isPermissionGranted = AXIsProcessTrusted()
    }

    // MARK: - Permission

    func refreshPermission() {
        let before = isPermissionGranted
        isPermissionGranted = AXIsProcessTrusted()
        if !before && isPermissionGranted && suppressionActive {
            engageLayers()
        }
    }

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    /// Start suppressing all Wine windows. Call when SteamSession starts.
    func startSuppressing() {
        guard isPermissionGranted else {
            log.warning("[SteamWindow] no AX permission — suppression inactive")
            return
        }
        suppressionActive = true
        isSuppressing = true
        gameMode = false
        signInMode = false
        engageLayers()
        log.info("[SteamWindow] suppression started")
    }

    /// Present Steam's own sign-in for the one-time interactive sign-in: keep
    /// every other Steam window hidden, centre the sign-in window over
    /// Meridian's window and bring it forward. Ends when any other mode
    /// starts (`startSuppressing()` after logon). Without Accessibility
    /// permission Steam's window simply appears where Steam places it.
    func beginSignIn() {
        guard isPermissionGranted else {
            log.warning("[SteamWindow] no AX permission — sign-in window shown unmanaged")
            return
        }
        suppressionActive = true
        isSuppressing = true
        gameMode = false
        signInMode = true
        presentedSignInWindows = []
        isSignInWindowShown = false
        engageLayers()
        log.info("[SteamWindow] sign-in mode — presenting Steam's sign-in window")
    }

    /// Re-centre Steam's sign-in window over Meridian and bring it forward
    /// (it can fall behind Meridian when the user clicks back into the app).
    func bringSignInForward() {
        guard signInMode else { return }
        presentedSignInWindows = []
        hideAllKnownWine()
    }

    /// Enter game-mode suppression for an Online (`-applaunch`) launch:
    /// Steam-owned windows (steam.exe, steamwebhelper) keep getting hidden —
    /// including Steam's main window left over from an interactive sign-in —
    /// while every other Wine process (the game Steam is about to spawn) is
    /// exempt so its window appears naturally. Actionable dialogs (EULA /
    /// purchase) still surface via the `policy(forTitle:)` allowlist.
    func enterGameMode() {
        guard isPermissionGranted else {
            log.warning("[SteamWindow] no AX permission — game mode inactive")
            return
        }
        suppressionActive = true
        isSuppressing = true
        gameMode = true
        signInMode = false
        promptMode = false
        refreshSteamOwnedPIDs()
        engageLayers()
        log.info("[SteamWindow] game mode — suppressing Steam windows only")
    }

    /// Show Steam's windows while it waits on the player during a launch
    /// (`Launcher` reads that from Steam's console log). Game mode only.
    func presentSteamPrompt() {
        guard gameMode, !promptMode else { return }
        promptMode = true
        presentedPromptWindows = []
        refreshSteamOwnedPIDs()
        hideAllKnownWine()
        log.info("[SteamWindow] Steam is waiting on the player — showing its window")
    }

    /// Re-centre the windows Steam is waiting on and bring them forward, its
    /// dialog on top. Steam's windows have no Dock icon, so one that fell
    /// behind (a click on the library window behind Steam's controller
    /// dialog, user Oct 12 2026) could not be reached any other way.
    func bringPromptForward() {
        guard promptMode else { return }
        presentedPromptWindows = []
        hideAllKnownWine()
    }

    /// Steam has its answer: hide its windows again.
    func endSteamPrompt() {
        guard promptMode else { return }
        promptMode = false
        hideAllKnownWine()
        log.info("[SteamWindow] Steam's prompt answered — hiding its windows again")
    }

    /// Register a newly-launched Wine PID immediately.
    /// Called by SteamSession right after starting steam.exe (and for the
    /// short-lived `-applaunch` IPC forwarders). All call sites are Steam-side
    /// processes, so the PID also joins the game-mode Steam-owned set without
    /// waiting for the next refresh.
    func registerPID(_ pid: pid_t) {
        guard isPermissionGranted, suppressionActive else { return }
        steamOwnedPIDs.insert(pid)
        installObserver(for: pid)
        hideWindows(for: pid)
        log.info("[SteamWindow] registered pid=\(pid)")
    }

    /// Pause suppression while the game window is visible. Only appropriate
    /// when Steam has NO windows that could surface (e.g. the interactive
    /// sign-in window, which must render and take input). Online game
    /// launches use `enterGameMode()` instead so Steam chrome stays hidden.
    func pauseForGame() {
        suppressionActive = false
        isSuppressing = false
        gameMode = false
        signInMode = false
        actionableDialogTitle = nil
        log.info("[SteamWindow] paused — game window will appear")
    }

    /// Resume suppression after game exits.
    func resumeAfterGame(steamPID: pid_t) {
        guard isPermissionGranted else { return }
        suppressionActive = true
        isSuppressing = true
        gameMode = false
        signInMode = false
        promptMode = false
        if steamPID > 0 {
            if entries[steamPID] == nil { installObserver(for: steamPID) }
            hideWindows(for: steamPID)
        }
        hideAllKnownWine()
        log.info("[SteamWindow] resumed after game exit")
    }

    /// Stop all suppression. Call when SteamSession shuts down.
    func stopSuppressing() {
        suppressionActive = false
        isSuppressing = false
        gameMode = false
        signInMode = false
        actionableDialogTitle = nil
        stopPollingTimer()
        for pid in entries.keys { removeObserver(for: pid) }
        entries.removeAll()
        runningAppsObservation = nil
        classifiedApps.removeAll()
        unclassifiedApps.removeAll()
        winePIDs.removeAll()
        log.info("[SteamWindow] stopped")
    }

    // MARK: - Private: layers

    private func engageLayers() {
        watchRunningApps()
        hideAllKnownWine()
        startPollingTimer()
    }

    private func startPollingTimer() {
        stopPollingTimer()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollingTick() }
        }
    }

    private func stopPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollingTick() {
        guard suppressionActive else { return }
        pollTick &+= 1

        // Remove observers for dead processes.
        for pid in entries.keys {
            if !isProcessAlive(pid) { removeObserver(for: pid) }
        }

        // Discover new Wine PIDs and install observers.
        if !unclassifiedApps.isEmpty { classifyPendingApps() }
        for pid in winePIDs {
            if entries[pid] == nil { installObserver(for: pid) }
        }

        // In game mode, refresh the Steam-owned PID set about once per second
        // (steam.exe/steamwebhelper PIDs are long-lived — including after a
        // code=42 self-update re-exec, which the refresh picks up even
        // though the new PID was never registered by SteamSession).
        if gameMode, pollTick % 4 == 0 {
            refreshSteamOwnedPIDs()
        }

        // Hide any visible windows.
        hideAllKnownWine()
    }

    private func hideAllKnownWine() {
        guard suppressionActive else { return }
        for pid in winePIDs.union(entries.keys) {
            hideWindows(for: pid)
        }
    }

    // MARK: - Private: AXObserver

    private func installObserver(for pid: pid_t) {
        guard entries[pid] == nil else { return }

        let box = _AXBox { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.suppressionActive else { return }
                self.hideWindows(for: pid)
            }
        }
        let boxPtr = Unmanaged.passRetained(box).toOpaque()

        var axObserver: AXObserver?
        guard AXObserverCreate(pid, axCallback, &axObserver) == .success,
              let observer = axObserver else {
            Unmanaged<_AXBox>.fromOpaque(boxPtr).release()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        // Moved: Steam reuses some windows (its toasts) and moves them back on
        // screen to show them; hiding on the move beats the next poll.
        for notif in [kAXWindowCreatedNotification, kAXWindowMovedNotification,
                      kAXApplicationShownNotification] as [CFString] {
            AXObserverAddNotification(observer, appElement, notif, boxPtr)
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        entries[pid] = Entry(observer: observer, source: source, box: boxPtr)
        log.debug("[SteamWindow] observer installed pid=\(pid)")
    }

    private func removeObserver(for pid: pid_t) {
        guard let entry = entries.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), entry.source, .defaultMode)
        Unmanaged<_AXBox>.fromOpaque(entry.box).release()
        log.debug("[SteamWindow] observer removed pid=\(pid)")
    }

    // MARK: - Private: window hiding

    private func hideWindows(for pid: pid_t) {
        guard suppressionActive else { return }
        // Game mode: only Steam-owned processes get their windows hidden; the
        // game's own Wine process is exempt so its window appears naturally.
        if gameMode, !steamOwnedPIDs.contains(pid) { return }
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        let isWebhelper = signInMode
            && Self.commandLine(of: pid)?.lowercased().contains("steamwebhelper") == true

        var surfacedTitle: String?
        var prompts: [(window: AXUIElement, size: CGSize)] = []
        for window in windows {
            // Read the title so EULA / agreement / purchase dialogs are
            // surfaced (the user MUST act on them) instead of hidden. Anything
            // not on the narrow actionable allowlist is suppressed.
            var titleRef: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String
            let size = Self.size(of: window)

            if isWebhelper, Self.isSignInWindow(title: title, size: size) {
                presentSignInWindow(window, pid: pid)
                continue
            }

            // Steam waiting on the player, or a dialog the allowlist names:
            // bring it back from off-screen so the user can act.
            if (promptMode && gameMode && Self.isPromptWindow(title: title, size: size))
                || Self.policy(forTitle: title) == .surface {
                prompts.append((window, size))
                surfacedTitle = title
                continue
            }

            // Move off-screen (no animation, instant). Not minimized: every
            // minimized window gets a Dock thumbnail, even from an accessory
            // process, and clicking it restored a blank "Steam" window at
            // -32000 during onboarding (user, Oct 12 2026).
            let origin = Self.position(of: window)
            guard Self.isOnScreen(origin: origin, size: size) else { continue }
            log.info("[SteamWindow] hid pid=\(pid) '\(title ?? "")' \(Int(size.width))×\(Int(size.height)) from \(Int(origin.x)),\(Int(origin.y))")
            var pos = Self.offScreen
            if let posValue = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            }
        }

        // Largest first, so a dialog lands on top of the library window Steam
        // opens behind it.
        for (window, _) in prompts.sorted(by: { $0.size.width * $0.size.height > $1.size.width * $1.size.height }) {
            present(window, pid: pid, once: &presentedPromptWindows)
        }

        // Publish/clear the actionable-dialog banner state. Only updates when
        // it actually changes to avoid churning @Observable subscribers.
        if actionableDialogTitle != surfacedTitle {
            actionableDialogTitle = surfacedTitle
        }
    }

    // MARK: - Private: sign-in presentation

    /// Steam's sign-in window during `beginSignIn()`: a titled steamwebhelper
    /// window of dialog size. Matched by size, not title (the title is
    /// localized). Steam's helper windows ("ANGLE Mock Window", 0×0 browser
    /// hosts) are tiny or untitled, and its library window, which opens the
    /// moment sign-in succeeds, is far larger than 900×700, so it stays hidden.
    ///
    /// MIRROR CONTRACT: mirrored in WindowClassificationTests.
    static func isSignInWindow(title: String?, size: CGSize) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return (300...900).contains(size.width) && (200...700).contains(size.height)
    }

    /// A Steam window worth showing while Steam waits on the player: titled
    /// and dialog-sized (its EULA window was "Steam", 1010×600). Its helper
    /// windows are untitled or tiny.
    ///
    /// MIRROR CONTRACT: mirrored in WindowClassificationTests.
    static func isPromptWindow(title: String?, size: CGSize) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return size.width >= 300 && size.height >= 200
    }

    private static func size(of window: AXUIElement) -> CGSize {
        var sizeRef: AnyObject?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let value = sizeRef, CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return size
    }

    /// Where hidden windows go. macOS clamps it: they read back at -8000,-8000
    /// (meridian.log, Oct 12 2026), so "hidden" is tested against the
    /// displays (`isOnScreen`), not this point.
    private static let offScreen = CGPoint(x: -32000, y: -32000)

    /// Whether any part of a window is on a display. AX frames are top-left
    /// based on the primary display, y down; NSScreen frames are y up.
    private static func isOnScreen(origin: CGPoint, size: CGSize) -> Bool {
        guard let primary = NSScreen.screens.first else { return true }
        let window = CGRect(origin: origin, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
        return NSScreen.screens.contains { screen in
            let f = screen.frame
            return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
                .intersects(window)
        }
    }

    private static func position(of window: AXUIElement) -> CGPoint {
        var positionRef: AnyObject?
        var position = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
           let value = positionRef, CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        return position
    }

    private func presentSignInWindow(_ window: AXUIElement, pid: pid_t) {
        guard present(window, pid: pid, once: &presentedSignInWindows) else { return }
        isSignInWindowShown = true
        log.info("[SteamWindow] presented sign-in window pid=\(pid)")
    }

    /// Un-minimizes `window` and, the first time it is seen, centres it over
    /// Meridian's window and brings it forward. Later polls leave its
    /// position alone so the user can move it. Returns true that first time.
    @discardableResult
    private func present(_ window: AXUIElement, pid: pid_t, once presented: inout Set<CFHashCode>) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        guard presented.insert(CFHash(window)).inserted else { return false }

        if let anchor = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
           let primary = NSScreen.screens.first {
            // AX positions are top-left based on the primary display.
            let size = Self.size(of: window)
            var origin = CGPoint(x: anchor.frame.midX - size.width / 2,
                                 y: primary.frame.maxY - anchor.frame.midY - size.height / 2)
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return true
    }

    // MARK: - Private: process detection

    /// Refreshes the set of Steam-owned Wine PIDs from each process's
    /// command line. A sysctl per process, no subprocess, so it is cheap on
    /// the main actor.
    private func refreshSteamOwnedPIDs() {
        steamOwnedPIDs = Set(winePIDs.filter { pid in
            guard let commandLine = Self.commandLine(of: pid) else { return false }
            return Self.steamProcessPatterns.contains { commandLine.contains($0) }
        })
    }

    /// Starts following `NSWorkspace.runningApplications`, which changes on
    /// the main run loop as apps launch and quit.
    private func watchRunningApps() {
        guard runningAppsObservation == nil else { return }
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { @Sendable [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.syncRunningApps() }
        }
        syncRunningApps()
    }

    /// Wine processes with an app connection (the ones that can own windows).
    /// winemac names each one after its Windows program: no bundle
    /// identifier, `localizedName` "steamwebhelper.exe", executable a link in
    /// a `winetemp-…` folder (probed Oct 7 2026 with notepad.exe). Looking
    /// them up by an empty bundle identifier or by engine paths
    /// matched none of them, so suppression never saw steamwebhelper, which
    /// draws both Steam's sign-in and its library window.
    ///
    /// Only apps not seen before are classified; the rest are matched by
    /// identity, without reading any of their properties.
    private func syncRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
        let listed = Set(apps.map(ObjectIdentifier.init))
        classifiedApps = classifiedApps.filter { listed.contains($0.key) }
        unclassifiedApps = apps.filter { classifiedApps[ObjectIdentifier($0)] == nil }
        classifyPendingApps()
    }

    private func classifyPendingApps() {
        var unknown: [NSRunningApplication] = []
        for app in unclassifiedApps {
            guard let isWine = Self.wineClassification(of: app) else {
                unknown.append(app)
                continue
            }
            classifiedApps[ObjectIdentifier(app)] = (app, isWine ? app.processIdentifier : nil)
        }
        unclassifiedApps = unknown
        winePIDs = Set(classifiedApps.values.compactMap(\.winePID))
    }

    /// Whether an app is a Wine process, or nil while LaunchServices doesn't
    /// know its executable yet (a just-launched process; never cache "no"
    /// for it, or its windows would never be hidden).
    private static func wineClassification(of app: NSRunningApplication) -> Bool? {
        if app.bundleIdentifier != nil { return false }
        guard let path = app.executableURL?.path else { return nil }
        return path.contains("/winetemp-") || path.contains("/wine/") || path.contains("wine64")
    }

    /// A process's arguments joined by spaces (what `pgrep -f` matches), read
    /// with `KERN_PROCARGS2`. Wine rewrites argv to the Windows command line,
    /// so this names the Windows program (steam.exe, steamwebhelper.exe);
    /// the executable and `localizedName` are only "wine" (Pattern 2).
    nonisolated static func commandLine(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc (Int32), the executable path,
    /// NUL padding, then argc NUL-terminated arguments.
    /// MIRROR CONTRACT: mirrored in WindowClassificationTests.
    nonisolated static func parseProcArgs(_ buffer: [UInt8]) -> String? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return nil }
        let argc = buffer.prefix(header).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = header
        while index < buffer.count, buffer[index] != 0 { index += 1 }  // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }  // padding
        var args: [String] = []
        while index < buffer.count, args.count < argc {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
