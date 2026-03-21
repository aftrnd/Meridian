import AppKit
import ApplicationServices
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "SteamWindowSuppressor")

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
/// `localizedName`. CrossOver's wineloader runs steam.exe and the process registers
/// with macOS as "Steam" — the name-based filter matches zero processes. The path
/// always contains "wineloader", "wine64", "/wine/", or "crossover" regardless of
/// display name.
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
    func stopSuppressingNewWindows() {
        suppressionActive = false
        isSuppressing = false
        log.info("[suppressor] suppression paused — game window will appear")
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
                self?.hideAllObservedWindows()
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
        }

        // 3. If suppression is active, hide all visible windows.
        if suppressionActive {
            hideAllObservedWindows()
        }

        // Periodic diagnostic: log process counts every 10 ticks (~5s).
        if pollingTickCount % 10 == 0 {
            let allApps = NSWorkspace.shared.runningApplications
            let matched = allApps.filter { isWineProcess($0) }
            log.info("[suppressor] poll#\(self.pollingTickCount) — observed=\(self.observerEntries.count) Wine matches=\(matched.count)/\(allApps.count) active=\(self.suppressionActive)")
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

            // Check using the same path-based filter as pollingTick.
            let lowerPath = exePath.lowercased()
            let isWine = lowerPath.contains("wineloader") || lowerPath.contains("wine64")
                      || lowerPath.contains("/wine/") || lowerPath.contains("crossover")
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

    /// Identifies a Wine process by its executable path rather than display name.
    ///
    /// CrossOver's wineloader hosts Windows processes (Steam, games) which register
    /// with macOS using the Windows app's name ("Steam", game titles, etc.), not
    /// "wine" or "wineloader". Checking the executable path is the only reliable
    /// way to identify Wine processes regardless of backend (CrossOver or bundled).
    private func isWineProcess(_ app: NSRunningApplication) -> Bool {
        guard let path = app.executableURL?.path.lowercased() else { return false }
        return path.contains("wineloader")
            || path.contains("wine64")
            || path.contains("/wine/")
            || path.contains("crossover")
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    private func hideAllObservedWindows() {
        for pid in observerEntries.keys { hideWindows(for: pid) }
    }

    /// Public surface so call sites in GameLauncher can trigger an immediate
    /// suppress sweep without needing a specific PID (e.g. at uninstall start).
    func suppressNow() {
        guard isPermissionGranted, suppressionActive else { return }
        hideAllObservedWindows()
    }

    /// Two-step hide: move off-screen first (instant, no animation), then minimize.
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
        for window in windows {
            // Step 1: Move off-screen instantly — no animation, user never sees it.
            if let pos = posValue {
                let posResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
                if posResult != .success {
                    log.debug("[suppressor] kAXPositionAttribute set failed pid=\(pid) code=\(posResult.rawValue)")
                }
            }
            // Step 2: Minimize — keeps it hidden if Steam repositions it.
            let minResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            if minResult != .success {
                log.debug("[suppressor] kAXMinimizedAttribute set failed pid=\(pid) code=\(minResult.rawValue)")
            }
            hiddenCount += 1
        }
        if hiddenCount > 0 {
            log.info("[suppressor] hid \(hiddenCount) window(s) for pid=\(pid)")
        }
    }
}
