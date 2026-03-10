@preconcurrency import Virtualization
import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "GameLauncher")

/// Orchestrates the full game launch pipeline:
///   1. Stage Steam session files into the virtio-fs share
///   2. Start the VM if it is not running
///   3. Retry connecting ProtonBridge via vsock until the guest daemon is up
///   4. Register log/exit/progress handlers
///   5. Send the launch command
///   6. Monitor game process exit and clean up
///
/// bridgeConnected lifecycle:
///   Set to true when vsock connect succeeds; cleared when:
///     - the guest exit event fires (game exited)
///     - the VM stops unexpectedly (guestDidStop / didStopWithError via vmStatusTask)
///   This ensures the next launch always reconnects after any VM restart.
@Observable
@MainActor
final class GameLauncher {

    // MARK: - State

    enum LaunchState: Equatable {
        case idle
        case preparingVM
        case connectingBridge
        case launching
        case running(appID: Int)
        case installing(appID: Int, progress: Double)
        case exited(appID: Int, code: Int)
        case failed(String)
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var logs: [String] = []

    /// Human-readable summary of the current in-progress phase, derived from
    /// agent log events. Shown inline in the game detail panel during long
    /// operations (e.g. Steam bootstrap, IPC wait, install handoff).
    private(set) var currentActivity: String?

    /// When the install phase started, used to show elapsed time in the UI.
    private(set) var installStartedAt: Date?

    // MARK: - Private

    private let bridge = ProtonBridge()
    private var bridgeConnected = false

    /// Observes VMManager state so bridgeConnected is cleared whenever the VM stops.
    private var vmObserverTask: Task<Void, Never>?

    // MARK: - Public API

    func launch(
        game: Game,
        vmManager: VMManager,
        steamAuth: SteamAuthService,
        sessionBridge: SteamSessionBridge,
        library: SteamLibraryStore? = nil
    ) async {
        switch launchState {
        case .preparingVM, .connectingBridge, .launching, .running, .installing:
            return  // already in flight
        case .idle, .exited, .failed:
            break
        }

        logs.removeAll()
        currentActivity = nil
        installStartedAt = nil
        launchState = .preparingVM
        log.info("launch started: appID=\(game.id) '\(game.name)' vmState=\(String(describing: vmManager.state))")

        // 1. Stage Steam session files in the virtio-fs share before VM boots.
        log.debug("[1] staging Steam session files")
        await sessionBridge.prepare(auth: steamAuth)

        // 2. Start the VM if it is not already running.
        log.debug("[2] vmState=\(String(describing: vmManager.state)) isRunning=\(vmManager.state.isRunning)")
        if !vmManager.state.isRunning {
            if case .notProvisioned = vmManager.state {
                log.error("[2] VM image not provisioned")
                let missing = vmManager.imageProvider.missingBootArtifacts.joined(separator: ", ")
                launchState = .failed(
                    "VM is not fully provisioned. Missing: \(missing). " +
                    "Run VM setup to download base image + kernel + initrd."
                )
                return
            }
            log.info("[2] starting VM…")
            do {
                try await vmManager.start()
                log.info("[2] VM start() succeeded → state=\(String(describing: vmManager.state))")
            } catch {
                log.error("[2] VM start() failed: \(error.localizedDescription) | \(String(describing: error))")
                launchState = .failed("Failed to start VM: \(error.localizedDescription)")
                return
            }
        } else {
            log.info("[2] VM already running, skipping start")
        }

        // Start observing VM state so we can clear bridgeConnected on any stop.
        startVMObserver(vmManager: vmManager)

        // 3. Connect ProtonBridge (guest daemon takes time to start — retry for 60 s).
        //    Each attempt takes up to 1.3 s (300 ms phantom-connect guard + 1 s delay),
        //    so 60 retries gives a ~78 s window — enough for the vsock driver probe to
        //    complete and the agent to start accepting.
        log.debug("[3] bridgeConnected=\(self.bridgeConnected)")
        if !bridgeConnected {
            launchState = .connectingBridge
            guard let socketDevice = vmManager.socketDevice else {
                log.error("[3] socketDevice is nil — vsock device not in VM config?")
                launchState = .failed("VM vsock device is unavailable.")
                return
            }
            log.info("[3] connecting to vsock:1234 (up to 60 attempts)…")
            let connected = await retryConnect(to: socketDevice, on: vmManager.vmQueue, retries: 60, delay: .seconds(1))
            if connected {
                log.info("[3] vsock connected ✓")
            } else {
                log.error("[3] vsock connect failed after 60 attempts")
                launchState = .failed(
                    "Could not connect to Proton bridge after 60 s. " +
                    "Check that meridian-bridge is installed in the base image."
                )
                return
            }
        } else {
            log.info("[3] reusing existing bridge connection")
        }

        // 4. Register event handlers (overwrite previous handlers on each launch).
        await bridge.onLog { [weak self] line in
            Task { @MainActor [weak self] in
                self?.logs.append(line)
                self?.parseActivity(from: line)
                log.info("guest: \(line)")
            }
        }
        await bridge.onExit { [weak self] code in
            Task { @MainActor [weak self] in
                guard let self else { return }
                log.info("game exited code=\(code)")
                self.currentActivity = nil
                if code != 0 {
                    self.launchState = .failed("Guest launch failed (exit code \(code)). Check Steam preflight logs.")
                } else {
                    self.launchState = .exited(appID: game.id, code: code)
                }
                self.bridgeConnected = false  // force reconnect on next launch
            }
        }
        await bridge.onProgress { [weak self] appID, pct in
            Task { @MainActor [weak self] in
                if pct > 0 { self?.currentActivity = "Downloading..." }
                self?.launchState = .installing(appID: appID, progress: pct)
            }
        }
        await bridge.onInstalled { appID, installed in
            log.info("install status appID=\(appID) installed=\(installed)")
        }

        // 5. Ensure game is installed before launching.
        do {
            var isInstalled = game.isInstalled
            do {
                isInstalled = try await bridge.isGameInstalled(appID: game.id)
            } catch let err as ProtonBridge.BridgeError {
                if case .unsupportedCommand = err {
                    // Older guest agent: no is_installed support; fall back to cached state.
                    log.warning("[5] guest agent lacks is_installed support, using cached install state=\(game.isInstalled)")
                    isInstalled = game.isInstalled
                } else {
                    throw err
                }
            }

            if !isInstalled {
                log.info("[5] game not installed appID=\(game.id) → starting install")
                installStartedAt = Date()
                currentActivity = "Checking Steam status..."
                launchState = .installing(appID: game.id, progress: 0)
                let installOK = try await bridge.installGameAndWait(appID: game.id, timeout: .seconds(3600))
                if installOK {
                    library?.setInstalled(true, for: game.id)
                    log.info("[5] install complete appID=\(game.id)")
                } else {
                    log.error("[5] install returned installed=false appID=\(game.id)")
                    library?.setInstalled(false, for: game.id)
                    launchState = .failed(
                        "Steam did not confirm install completion for \(game.name). " +
                        "Check guest launch logs for Steam bootstrap errors."
                    )
                    return
                }
            } else {
                library?.setInstalled(true, for: game.id)
            }
        } catch {
            log.error("[5] install status check failed: \(error.localizedDescription)")
            launchState = .failed("Could not verify install status: \(error.localizedDescription)")
            return
        }

        // 6. Send launch command.
        launchState = .launching
        log.info("[6] sending launch command appID=\(game.id)")
        do {
            try await bridge.launchGame(appID: game.id, steamID: steamAuth.steamID)
            log.info("[6] launch command sent OK → running")
            launchState = .running(appID: game.id)
        } catch {
            log.error("[6] launch command failed: \(error.localizedDescription) | errno=\((error as? POSIXError)?.code.rawValue ?? -1)")
            launchState = .failed("Launch command failed: \(error.localizedDescription)")
        }
    }

    /// Sends an install command for a game that hasn't been downloaded yet.
    func install(game: Game, vmManager: VMManager) async {
        guard vmManager.state.isRunning, bridgeConnected else {
            launchState = .failed("VM must be running to install games.")
            return
        }
        do {
            try await bridge.installGame(appID: game.id)
            launchState = .installing(appID: game.id, progress: 0)
        } catch {
            launchState = .failed("Install failed: \(error.localizedDescription)")
        }
    }

    /// Sends a stop command to the running game (graceful in-guest process kill).
    func stopGame() async {
        guard case .running = launchState else { return }
        try? await bridge.stopGame()
    }

    // MARK: - Private helpers

    private func retryConnect(
        to device: VZVirtioSocketDevice,
        on queue: DispatchQueue,
        retries: Int,
        delay: Duration
    ) async -> Bool {
        // Copy into local `let` so Swift 6 treats it as a non-isolated sending parameter
        // when we cross into the ProtonBridge actor via bridge.connect(to:on:).
        nonisolated(unsafe) let socketDevice = device
        let vmQueue = queue
        for attempt in 1...retries {
            do {
                try await bridge.connect(to: socketDevice, on: vmQueue)
                bridgeConnected = true
                return true
            } catch {
                // Log every 5 attempts to avoid spamming the console
                if attempt % 5 == 0 {
                    logs.append("[bridge] connect attempt \(attempt)/\(retries) failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: delay)
            }
        }
        return false
    }

    /// Maps raw agent log lines to terse human-readable status messages shown
    /// inline in the game detail panel. Only meaningful phase transitions update
    /// currentActivity — noisy or diagnostic lines (steam-log:, snapshots) are
    /// intentionally skipped so the message stays useful.
    private func parseActivity(from line: String) {
        // Skip raw Steam console log dumps and process snapshots — too noisy
        guard !line.hasPrefix("steam-log:"),
              !line.hasPrefix("steam console log"),
              !line.hasPrefix("steam process snapshot") else { return }

        let l = line.lowercased()

        if l.contains("steam process not running") {
            currentActivity = "Launching Steam..."
        } else if l.contains("steam is bootstrapping") || l.contains("bootstrap started") {
            currentActivity = "Steam is loading — first start can take several minutes"
        } else if l.contains("steam binary running") && l.contains("waiting for steam.pipe") {
            currentActivity = "Steam is initializing..."
        } else if l.contains("steam ipc ready") {
            currentActivity = "Steam ready, sending install request..."
        } else if l.contains("handoff client succeeded") {
            currentActivity = "Install request sent to Steam"
        } else if l.contains("install waiting for appmanifest") {
            currentActivity = "Waiting for Steam to begin download..."
        } else if l.contains("install handoff reassert") {
            currentActivity = "Retrying install request..."
        } else if l.contains("steam client already running") {
            currentActivity = "Connecting to Steam..."
        } else if l.contains("install complete") {
            currentActivity = "Download complete, preparing to launch..."
        }
    }

    /// Starts a lightweight observation task that clears `bridgeConnected` when
    /// the VM transitions out of `.ready` so the next launch always reconnects.
    private func startVMObserver(vmManager: VMManager) {
        vmObserverTask?.cancel()
        vmObserverTask = Task { [weak self, weak vmManager] in
            guard let vmManager else { return }
            var last = vmManager.state
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let current = vmManager.state
                if current != last {
                    // VM stopped or errored — reset bridge connection state
                    if case .stopped = current { self?.bridgeConnected = false }
                    if case .error   = current { self?.bridgeConnected = false }
                    if case .notProvisioned = current { self?.bridgeConnected = false }
                    last = current
                }
            }
        }
    }
}
