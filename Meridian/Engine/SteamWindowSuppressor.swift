import AppKit
import ApplicationServices
import Observation

private let log = MeridianLog(category: "SteamWindowSuppressor")

// C-compatible AXObserver callback — bridges to the Swift handler stored in the box.
// Must be file-scope; Swift requires @convention(c) callables to be global.
private let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<_AXCallbackBox>.fromOpaque(refcon).takeUnretainedValue().fire()
}

/// Heap-allocated bridge from the C AXObserver callback to a Swift closure.
/// Lifetime is explicit: `passRetained` at install, `release()` at removal.
private final class _AXCallbackBox: @unchecked Sendable {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    func fire() { handler() }
}

/// Suppresses all windows from Wine/Steam processes using three independent layers:
///
/// **Layer 1 — AXObserver per Wine PID** (instant, event-driven)
/// Receives `kAXWindowCreatedNotification` / `kAXApplicationShownNotification` the
/// moment Steam creates or reveals a window and hides it before it paints.
///
/// **Layer 2 — 0.5-second polling timer** (catch-all)
/// Scans `NSWorkspace.shared.runningApplications` every 0.5 s, discovers new Wine
/// PIDs, installs observers, and hides any window that slipped through.
///
/// **Layer 3 — NSWorkspace app-launch observer** (instant for new processes)
/// Reacts to `NSWorkspace.didLaunchApplicationNotification` so a fresh Wine process
/// (e.g. spawned by a Steam IPC command) is caught immediately.
///
/// ## Process Detection
/// Uses `NSRunningApplication.executableURL` (the actual binary path) rather than
/// `localizedName`. Wine's wineloader runs steam.exe and the process registers
/// with macOS as "Steam" — the name-based filter matches zero processes. The path
/// always contains "wineloader", "wine64", or "/wine/" regardless of display name.
///
/// ## Permission
/// Requires a one-time Accessibility grant (System Settings → Privacy & Security →
/// Accessibility). `refreshPermission()` detects a `false → true` transition and
/// automatically engages all three layers without any manual call.
///
/// ## Hiding strategy
/// 1. Move window to (-32000, -32000) — instant, no animation, invisible immediately
/// 2. Minimize — keeps it hidden if it tries to reposition itself
///
/// ## Dock icon
/// Wine's Mac Driver sets `NSApplicationActivationPolicyRegular` on every hosted
/// Windows process, which causes a Dock icon. There is no macOS API to change
/// another process's activation policy — the Dock icon is unavoidable. The windows
/// themselves are suppressed.
@Observable
@MainActor
final class SteamWindowSuppressor {

    // MARK: - Observable state

    /// Whether the system has granted Accessibility permission to this app.
    private(set) var isPermissionGranted: Bool

    /// Whether window suppression is currently active.
    private(set) var isSuppressing: Bool = false

    // MARK: - Private

    private struct ObserverEntry {
        let observer: AXObserver
        let source: CFRunLoopSource
        /// Retained _AXCallbackBox pointer; released in removeObserver(for:).
        let boxPtr: UnsafeMutableRawPointer
    }

    private var observerEntries: [pid_t: ObserverEntry] = [:]

    /// Set to false while a game is confirmed running so its window can appear.
    private var suppressionActive: Bool = false

    private var pollingTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var pollingTickCount: Int = 0
    private var lastLoggedObservedCount: Int = -1
    private var lastLoggedMatchCount: Int = -1

    /// Coalesces AX-driven hide sweeps so we don't hammer Steam every few ms — that
    /// fight causes Steam to restore windows repeatedly ("reopens and reopens").
    private var lastGlobalHideAt: Date = .distantPast

    /// Set by `allowSteamUITemporarily()`; when true, returning to Meridian re-engages suppression.
    private var reengageSuppressionWhenMeridianActivates: Bool = false

    // MARK: - Init

    init() {
        isPermissionGranted = AXIsProcessTrusted()
    }

    // MARK: - Permission

    /// Re-check Accessibility permission. Automatically engages all suppression layers
    /// if permission just transitioned from denied to granted.
    func refreshPermission() {
        let wasGranted = isPermissionGranted
        isPermissionGranted = AXIsProcessTrusted()
        if !wasGranted && isPermissionGranted {
            log.info("[suppressor] permission granted — auto-engaging all layers")
            engageAllLayers()
        }
    }

    /// Show the macOS Accessibility permission prompt in System Settings.
    ///
    /// The grant is asynchronous — the system dialog opens but returns immediately.
    /// `refreshPermission()` (called via `didBecomeActiveNotification`) picks up the
    /// grant when the user returns to Meridian.
    func requestPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Do NOT update isPermissionGranted here — it's still false until user grants.
    }

    // MARK: - Session control

    /// Start all three suppression layers. Call once after permission is confirmed,
    /// before Steam is launched. The polling timer will find Steam within 0.5 s.
    func beginSession() {
        log.info("[suppressor] beginSession — permission=\(self.isPermissionGranted) suppressionActive=\(self.suppressionActive) observedPIDs=\(self.observerEntries.count)")
        guard isPermissionGranted else {
            log.warning("[suppressor] beginSession without permission — suppression inactive; grant access in System Settings → Privacy & Security → Accessibility")
            return
        }
        engageAllLayers()
    }

    /// Directly register a known Wine/Steam PID for immediate suppression.
    ///
    /// Called by `WineSteamManager` for every Wine process it launches so the
    /// suppressor doesn't rely solely on auto-discovery (which depends on
    /// `NSWorkspace.runningApplications` being updated before the first window appears).
    func registerPID(_ pid: pid_t) {
        guard isPermissionGranted, suppressionActive else {
            log.info("[suppressor] registerPID(\(pid)) deferred — permission=\(self.isPermissionGranted) active=\(self.suppressionActive)")
            return
        }
        log.info("[suppressor] registerPID(\(pid)) — installing observer and hiding immediately")
        installObserver(for: pid)
        hideWindows(for: pid)
    }

    /// Resume suppression after `stopSuppressingNewWindows()` (game exited or stopped).
    ///
    /// `pid` is used as an immediate-focus hint — that process's windows are hidden
    /// right away. The polling timer handles any other Wine processes.
    func resumeSuppressing(pid: pid_t) {
        guard isPermissionGranted else { return }
        reengageSuppressionWhenMeridianActivates = false
        suppressionActive = true
        isSuppressing = true
        if pid > 0 {
            if observerEntries[pid] == nil { installObserver(for: pid) }
            hideWindows(for: pid)
        }
        hideAllObservedWindows()
        log.info("[suppressor] resumed suppression pid=\(pid)")
    }

    /// Pause new-window minimization so the game's own window can appear on screen.
    /// The polling timer and observers remain active; call `resumeSuppressing` to re-enable.
    ///
    /// This intentionally does NOT call `restoreAllObservedWindows()`. Game windows start
    /// fresh and have never been moved by us — calling restore would reposition them from
    /// their native full-screen layout to a fixed centered point, causing the window to
    /// jump off-screen. Only `allowSteamUITemporarily()` needs the restore step, to
    /// un-hide Steam windows that we moved to (-32000, -32000) during suppression.
    func stopSuppressingNewWindows() {
        reengageSuppressionWhenMeridianActivates = false
        suppressionActive = false
        isSuppressing = false
        log.info("[suppressor] suppression paused — game window will appear")
    }

    /// Call before `steam.exe -activate` so the window can appear. Suppression turns
    /// back on when Meridian becomes the active app again (user finished with Steam).
    ///
    /// This does two things: it pauses future suppression AND it un-hides any Steam
    /// windows that are currently minimized / positioned off-screen at (-32000,-32000).
    /// Without the restore step, Steam windows remain invisible even after suppression
    /// pauses, and `-activate` cannot surface them from that state.
    func allowSteamUITemporarily() {
        reengageSuppressionWhenMeridianActivates = true
        suppressionActive = false
        isSuppressing = false
        log.info("[suppressor] paused for explicit Show Steam — restoring windows and will resume when Meridian activates")
        restoreAllObservedWindows()
    }

    /// Reverse the hide operation for all Wine/Steam PIDs.
    ///
    /// Scans ALL currently-running Wine processes, not only the ones that have
    /// active AXObserver entries. The process that owns the Steam UI window
    /// (typically a `wine64-preloader` that was never independently registered)
    /// may not appear in `observerEntries`, so limiting the restore to observer
    /// keys would leave the window invisible even after suppression pauses.
    func restoreAllObservedWindows() {
        // Union of observer-tracked PIDs and live Wine PIDs discovered right now.
        let observedPIDs = Set(observerEntries.keys)
        let livePIDs = Set(currentWinePIDs())
        let allPIDs = Array(observedPIDs.union(livePIDs))
        log.info("[suppressor] restoreAllObservedWindows — restoring \(allPIDs.count) PID(s) (observed=\(observedPIDs.count) live=\(livePIDs.count))")
        for pid in allPIDs { restoreWindows(for: pid) }
    }

    /// Un-minimize and reposition all windows for `pid` so they are visible on screen.
    private func restoreWindows(for pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var val: CFTypeRef?
        let fetchResult = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val)
        guard fetchResult == .success,
              let windows = val as? [AXUIElement], !windows.isEmpty else {
            log.debug("[suppressor] restoreWindows pid=\(pid) — no windows (fetchResult=\(fetchResult.rawValue))")
            return
        }

        // Place windows near the center of the main display.
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let targetX = screenFrame.midX - 480   // 960px wide window centered
        let targetY = screenFrame.midY - 300   // 600px tall window centered
        var onScreen = CGPoint(
            x: max(screenFrame.minX + 20, targetX),
            y: max(screenFrame.minY + 20, targetY)
        )
        let posValue = AXValueCreate(.cgPoint, &onScreen)

        var restoredCount = 0
        for window in windows {
            // Step 1: Un-minimize first so the window is a real on-screen window again.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            // Step 2: Move to a visible position.
            if let pos = posValue {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
            }
            // Step 3: Raise to the front.
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            restoredCount += 1
        }

        if restoredCount > 0 {
            log.info("[suppressor] restored \(restoredCount) window(s) for pid=\(pid)")
        }
    }

    /// Invoke from `NSApplication.didBecomeActiveNotification` for Meridian.
    func onMeridianDidBecomeActive(resumeForSteamPID pid: pid_t?) {
        guard reengageSuppressionWhenMeridianActivates else { return }
        guard let pid, pid > 0 else { return }
        reengageSuppressionWhenMeridianActivates = false
        resumeSuppressing(pid: pid)
        log.info("[suppressor] Meridian active again — resumed suppression pid=\(pid)")
    }

    /// Tear down all layers. Call at app termination.
    func stopSuppressing() {
        suppressionActive = false
        isSuppressing = false

        pollingTimer?.invalidate()
        pollingTimer = nil

        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }

        for (pid, entry) in observerEntries {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), entry.source, .defaultMode)
            Unmanaged<_AXCallbackBox>.fromOpaque(entry.boxPtr).release()
            log.info("[suppressor] released observer pid=\(pid)")
        }
        observerEntries.removeAll()
        log.info("[suppressor] all layers stopped")
    }

    // MARK: - Private: engage

    private func engageAllLayers() {
        suppressionActive = true
        isSuppressing = true

        // Log every running application so we can diagnose detection failures.
        let allApps = NSWorkspace.shared.runningApplications
        let wineApps = allApps.filter { isWineProcess($0) }
        log.info("[suppressor] engageAllLayers — total running apps=\(allApps.count) Wine matches=\(wineApps.count)")
        for app in wineApps {
            log.info("[suppressor]   matched Wine app: name='\(app.localizedName ?? "?")' pid=\(app.processIdentifier) exe=\(app.executableURL?.path ?? "?")")
        }
        if wineApps.isEmpty {
            log.info("[suppressor]   (no Wine processes running yet — timer will discover them)")
        }

        startPollingTimer()         // Layer 2
        installWorkspaceObserver()  // Layer 3
        scanAndInstallObservers()   // Layer 1 — existing Wine PIDs
        hideAllObservedWindows()    // Immediately hide anything visible

        log.info("[suppressor] all 3 layers active — observed=\(self.observerEntries.count) initial Wine PID(s)")
    }

    // MARK: - Layer 1: AXObserver per PID

    private func installObserver(for pid: pid_t) {
        guard pid > 0, observerEntries[pid] == nil else { return }

        let box = _AXCallbackBox { [weak self] in
            // AXObserver callbacks fire on the main thread (we added the source to
            // CFRunLoopGetMain). assumeIsolated gives us direct @MainActor access.
            MainActor.assumeIsolated {
                guard self?.suppressionActive == true else { return }
                self?.throttledHideAllObservedWindows()
            }
        }
        let boxPtr = Unmanaged.passRetained(box).toOpaque()

        var axObserver: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &axObserver) == .success,
              let axObserver else {
            log.warning("[suppressor] AXObserverCreate failed pid=\(pid)")
            Unmanaged<_AXCallbackBox>.fromOpaque(boxPtr).release()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        for notif in [kAXWindowCreatedNotification as CFString,
                      kAXApplicationShownNotification as CFString,
                      kAXMainWindowChangedNotification as CFString,
                      // Fired when an app becomes frontmost — catches Steam restoring its
                      // already-existing main window from the Dock, which kAXWindowCreated
                      // does not fire for.
                      kAXApplicationActivatedNotification as CFString,
                      // Fired when keyboard focus moves to a new window — catches Steam
                      // dialogs (e.g. cloud sync errors) that appear without creating
                      // a brand-new window object.
                      kAXFocusedWindowChangedNotification as CFString] {
            AXObserverAddNotification(axObserver, appElement, notif, boxPtr)
        }

        let source = AXObserverGetRunLoopSource(axObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        observerEntries[pid] = ObserverEntry(observer: axObserver, source: source, boxPtr: boxPtr)
        log.info("[suppressor] AXObserver installed pid=\(pid)")
    }

    private func removeObserver(for pid: pid_t) {
        guard let entry = observerEntries.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), entry.source, .defaultMode)
        Unmanaged<_AXCallbackBox>.fromOpaque(entry.boxPtr).release()
        log.debug("[suppressor] removed dead observer pid=\(pid)")
    }

    // MARK: - Layer 2: 0.5s polling timer

    private func startPollingTimer() {
        pollingTimer?.invalidate()
        pollingTickCount = 0
        // Use .common mode so the timer fires during window tracking and event loops.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollingTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
        log.info("[suppressor] polling timer started")
    }

    private func pollingTick() {
        pollingTickCount += 1

        // 1. Clean up observers for processes that have exited.
        for pid in observerEntries.keys where !isProcessAlive(pid) {
            removeObserver(for: pid)
        }

        // 2. Discover new Wine processes and install observers.
        let winePIDs = currentWinePIDs()
        for pid in winePIDs where observerEntries[pid] == nil {
            log.info("[suppressor] pollingTick discovered new Wine PID=\(pid)")
            installObserver(for: pid)
            if suppressionActive {
                hideWindows(for: pid)
            }
        }

        // 3. Periodic safety sweep only — hiding every 0.5 s fights Steam, which keeps
        //    restoring its client and feels like an infinite reopen loop.
        if suppressionActive, pollingTickCount % 10 == 0 {
            throttledHideAllObservedWindows()
        }

        // Diagnostic: log process counts only when something changed or every 120 ticks (~60s).
        // This avoids flooding the log file with no-change polls during idle sessions.
        let allApps = NSWorkspace.shared.runningApplications
        let matched = allApps.filter { isWineProcess($0) }
        let observedCount = observerEntries.count
        let matchCount    = matched.count
        let countChanged  = observedCount != lastLoggedObservedCount || matchCount != lastLoggedMatchCount
        let periodicDump  = pollingTickCount % 120 == 0

        if countChanged || periodicDump {
            lastLoggedObservedCount = observedCount
            lastLoggedMatchCount    = matchCount
            log.info("[suppressor] poll#\(self.pollingTickCount) — observed=\(observedCount) Wine matches=\(matchCount)/\(allApps.count) active=\(self.suppressionActive)")
            for app in matched {
                log.info("[suppressor]   pid=\(app.processIdentifier) name='\(app.localizedName ?? "?")' exe='\(app.executableURL?.lastPathComponent ?? "?")'")
            }
        }
    }

    // MARK: - Layer 3: NSWorkspace launch observer

    private func installWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract values from notification before crossing actor boundary
            // to avoid Swift concurrency sendability violations.
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                      as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let name = app.localizedName ?? "?"
            let exePath = app.executableURL?.path ?? ""

            let lowerPath = exePath.lowercased()
            let isWine = lowerPath.contains("wineloader") || lowerPath.contains("wine64")
                      || lowerPath.contains("/wine/")
            guard isWine else { return }

            MainActor.assumeIsolated {
                guard let self else { return }
                log.info("[suppressor] workspace observer: new Wine app launched pid=\(pid) name='\(name)' exe='\(exePath)'")
                self.installObserver(for: pid)
                if self.suppressionActive { self.hideWindows(for: pid) }
            }
        }
        log.info("[suppressor] workspace observer installed")
    }

    // MARK: - Helpers

    private func scanAndInstallObservers() {
        for pid in currentWinePIDs() { installObserver(for: pid) }
    }

    private func currentWinePIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { isWineProcess($0) }
            .map(\.processIdentifier)
    }

    /// Identifies a Wine process by its executable path.
    private func isWineProcess(_ app: NSRunningApplication) -> Bool {
        guard let path = app.executableURL?.path.lowercased() else { return false }
        return path.contains("wineloader")
            || path.contains("wine64")
            || path.contains("/wine/")
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    private func hideAllObservedWindows() {
        for pid in observerEntries.keys { hideWindows(for: pid) }
    }

    /// AX notifications can fire in bursts; spacing global sweeps avoids a hide/restore tug-of-war with Steam.
    private func throttledHideAllObservedWindows() {
        let now = Date()
        guard now.timeIntervalSince(lastGlobalHideAt) >= 0.45 else { return }
        lastGlobalHideAt = now
        hideAllObservedWindows()
    }

    /// Public surface so call sites in GameLauncher can trigger an immediate
    /// suppress sweep without needing a specific PID (e.g. at uninstall start).
    func suppressNow() {
        guard isPermissionGranted, suppressionActive else { return }
        hideAllObservedWindows()
    }

    // MARK: - Window Classification

    enum WindowClassification {
        case essential   // Must be shown: install dialogs, EULAs, updates, Steam Guard
        case suppressible // Main Steam UI: store, library, friends, community
        case unknown     // No title or unrecognized — suppress by default
    }

    private static let essentialTitlePatterns: [String] = [
        "install", "uninstall", "update", "updating",
        "eula", "license", "agreement",
        "steam guard", "verification", "confirm", "warning", "error",
        "sign in", "log in", "login", "activate", "redeem",
        "extracting", "validating", "downloading", "preparing", "completing",
        "first-time setup", "setup", "requires restart",
    ]

    private static let suppressibleTitlePatterns: [String] = [
        "friends", "community", "store", "news", "screenshot",
        "chat", "voice", "broadcast", "music player",
    ]

    private func classifyWindow(_ window: AXUIElement) -> WindowClassification {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard let title = titleRef as? String, !title.isEmpty else {
            return .unknown
        }

        let lower = title.lowercased()

        for pattern in Self.essentialTitlePatterns {
            if lower.contains(pattern) { return .essential }
        }

        for pattern in Self.suppressibleTitlePatterns {
            if lower.contains(pattern) { return .suppressible }
        }

        // "Steam" alone is the main client window — suppress it.
        // But "Steam - Installing..." or similar should be essential.
        if lower == "steam" || lower == "steam client" {
            return .suppressible
        }

        return .unknown
    }

    /// Two-step hide: move off-screen first (instant, no animation), then minimize.
    /// Essential windows (install dialogs, EULAs, Steam Guard, etc.) are allowed through.
    private func hideWindows(for pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var val: CFTypeRef?
        let fetchResult = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val)
        guard fetchResult == .success,
              let windows = val as? [AXUIElement], !windows.isEmpty else {
            if fetchResult != .success {
                log.debug("[suppressor] hideWindows pid=\(pid) — AXWindowsAttribute fetch failed code=\(fetchResult.rawValue)")
            }
            return
        }

        var offScreen = CGPoint(x: -32000, y: -32000)
        let posValue = AXValueCreate(.cgPoint, &offScreen)

        var hiddenCount = 0
        var allowedCount = 0
        for window in windows {
            let classification = classifyWindow(window)
            if classification == .essential {
                allowedCount += 1
                continue
            }

            if let pos = posValue {
                let posResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
                if posResult != .success {
                    log.debug("[suppressor] kAXPositionAttribute set failed pid=\(pid) code=\(posResult.rawValue)")
                }
            }
            let minResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            if minResult != .success {
                log.debug("[suppressor] kAXMinimizedAttribute set failed pid=\(pid) code=\(minResult.rawValue)")
            }
            hiddenCount += 1
        }
        if hiddenCount > 0 || allowedCount > 0 {
            log.info("[suppressor] pid=\(pid): hid \(hiddenCount), allowed \(allowedCount) essential window(s)")
        }
    }
}
