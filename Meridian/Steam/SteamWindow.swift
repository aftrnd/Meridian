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
        engageLayers()
        log.info("[SteamWindow] suppression started")
    }

    /// Register a newly-launched Wine PID immediately.
    /// Called by SteamSession right after starting steam.exe.
    func registerPID(_ pid: pid_t) {
        guard isPermissionGranted, suppressionActive else { return }
        installObserver(for: pid)
        hideWindows(for: pid)
        log.info("[SteamWindow] registered pid=\(pid)")
    }

    /// Pause suppression while the game window is visible.
    func pauseForGame() {
        suppressionActive = false
        isSuppressing = false
        actionableDialogTitle = nil
        log.info("[SteamWindow] paused — game window will appear")
    }

    /// Resume suppression after game exits.
    func resumeAfterGame(steamPID: pid_t) {
        guard isPermissionGranted else { return }
        suppressionActive = true
        isSuppressing = true
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
        actionableDialogTitle = nil
        stopPollingTimer()
        for pid in entries.keys { removeObserver(for: pid) }
        entries.removeAll()
        log.info("[SteamWindow] stopped")
    }

    // MARK: - Private: layers

    private func engageLayers() {
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

        // Remove observers for dead processes.
        for pid in entries.keys {
            if !isProcessAlive(pid) { removeObserver(for: pid) }
        }

        // Discover new Wine PIDs and install observers.
        for pid in currentWinePIDs() {
            if entries[pid] == nil { installObserver(for: pid) }
        }

        // Hide any visible windows.
        hideAllKnownWine()
    }

    private func hideAllKnownWine() {
        guard suppressionActive else { return }
        for pid in Set(entries.keys).union(Set(currentWinePIDs())) {
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
        for notif in [kAXWindowCreatedNotification, kAXApplicationShownNotification] as [CFString] {
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
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        var surfacedTitle: String?
        for window in windows {
            // Read the title so EULA / agreement / purchase dialogs are
            // surfaced (the user MUST act on them) instead of hidden. Anything
            // not on the narrow actionable allowlist is suppressed.
            var titleRef: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String

            if Self.policy(forTitle: title) == .surface {
                // Bring it back on-screen (un-minimize) so the user can act.
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                surfacedTitle = title
                continue
            }

            // Move off-screen immediately (no animation, instant).
            var pos = CGPoint(x: -32000, y: -32000)
            if let posValue = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            }
            // Minimize for belt-and-suspenders.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        }

        // Publish/clear the actionable-dialog banner state. Only updates when
        // it actually changes to avoid churning @Observable subscribers.
        if actionableDialogTitle != surfacedTitle {
            actionableDialogTitle = surfacedTitle
        }
    }

    // MARK: - Private: process detection

    private func currentWinePIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "")
            .filter { $0.executableURL?.path.contains("wineloader") == true
                   || $0.executableURL?.path.contains("wine64") == true
                   || $0.executableURL?.path.contains("/wine/") == true }
            .map { $0.processIdentifier }
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
