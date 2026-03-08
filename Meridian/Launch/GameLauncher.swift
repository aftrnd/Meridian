import Foundation
import Observation

/// Orchestrates the full game launch pipeline:
///   1. Ensure VM is running (start if stopped)
///   2. Connect ProtonBridge
///   3. Send launch command with Steam credentials
///   4. Monitor game process exit
@Observable
@MainActor
final class GameLauncher {

    enum LaunchState: Equatable {
        case idle
        case preparingVM
        case launching
        case running(appID: Int)
        case exited(appID: Int, code: Int)
        case failed(String)
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var logs: [String] = []

    private let bridge = ProtonBridge()
    private var bridgeConnected = false

    // MARK: - Public

    func launch(game: Game, vmManager: VMManager, steamAuth: SteamAuthService, sessionBridge: SteamSessionBridge) async {
        // Prevent double-launch while an existing launch/run is active.
        switch launchState {
        case .preparingVM, .launching, .running:
            return
        case .idle, .exited, .failed:
            break
        }

        logs.removeAll()
        launchState = .preparingVM

        // 1. Prepare Steam session files in the virtio-fs staging directory.
        //    This must happen before the VM starts so the mount is current at boot.
        await sessionBridge.prepare(auth: steamAuth)

        // 3. Start VM if needed
        if !vmManager.state.isRunning {
            do {
                try await vmManager.start()
            } catch {
                launchState = .failed("Failed to start VM: \(error.localizedDescription)")
                return
            }
        }

        // 4. Connect bridge (with retry — socket may not exist the instant the VM boots)
        if !bridgeConnected {
            let connected = await retryConnect(retries: 10, delay: .seconds(1))
            if !connected {
                launchState = .failed("Could not connect to Proton bridge. Is the VM fully booted?")
                return
            }
        }

        // 5. Register handlers
        await bridge.onLog { [weak self] line in
            Task { @MainActor [weak self] in self?.logs.append(line) }
        }
        await bridge.onExit { [weak self] code in
            Task { @MainActor [weak self] in
                self?.launchState = .exited(appID: game.id, code: code)
                self?.bridgeConnected = false
            }
        }

        // 6. Send launch command
        launchState = .launching
        do {
            try await bridge.launchGame(
                appID: game.id,
                steamID: steamAuth.steamID
            )
            launchState = .running(appID: game.id)
        } catch {
            launchState = .failed("Launch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func retryConnect(retries: Int, delay: Duration) async -> Bool {
        for _ in 0..<retries {
            do {
                try await bridge.connect()
                bridgeConnected = true
                return true
            } catch {
                try? await Task.sleep(for: delay)
            }
        }
        return false
    }
}
