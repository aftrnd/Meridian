@preconcurrency import Virtualization
import Observation
import Foundation

/// Manages the full Meridian VM lifecycle using Apple's Virtualization.framework.
///
/// Threading model:
///   - @Observable @MainActor: published state updates happen on main thread
///   - VZVirtualMachine must be created and called on the same serial queue
///   - We use a dedicated `vmQueue` for all VZ calls and marshal state back to MainActor
@Observable
@MainActor
final class VMManager: NSObject {

    // MARK: - Published state

    private(set) var state: VMState = .notProvisioned
    let imageProvider = VMImageProvider()

    // MARK: - Private

    private var virtualMachine: VZVirtualMachine?
    private let vmQueue = DispatchQueue(label: "com.meridian.vm", qos: .userInteractive)
    private var startContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Init

    override init() {
        super.init()
        updateProvisionedState()
    }

    // MARK: - Public API

    /// Provisions the VM by downloading + assembling the Meridian base image.
    func provision() async {
        state = .checkingForUpdate
        do {
            try await imageProvider.downloadLatestImage { [weak self] progress, received, total in
                self?.state = .downloading(progress: progress, bytesReceived: received, bytesTotal: total)
            }
            state = .stopped
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Starts the VM. No-op if already running.
    func start() async throws {
        guard case .stopped = state else { return }
        state = .starting

        do {
            let vm = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VZVirtualMachine, Error>) in
                vmQueue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: VMError.managerDeallocated)
                        return
                    }
                    do {
                        let config = try VMConfiguration.build(settings: AppSettings.shared)
                        let machine = VZVirtualMachine(configuration: config, queue: self.vmQueue)
                        machine.delegate = self
                        cont.resume(returning: machine)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            virtualMachine = vm
            let sendableVM = SendableVM(raw: vm)

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                startContinuation = cont
                vmQueue.async {
                    sendableVM.raw.start { result in
                        Task { @MainActor [weak self] in
                            switch result {
                            case .success:
                                self?.startContinuation?.resume()
                            case .failure(let error):
                                self?.startContinuation?.resume(throwing: error)
                            }
                            self?.startContinuation = nil
                        }
                    }
                }
            }

            state = .ready
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stops the VM gracefully (requests guest shutdown, then forces after timeout).
    func stop() async {
        guard case .ready = state else { return }
        state = .stopping
        let vmToStop = virtualMachine.map { SendableVM(raw: $0) }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vmQueue.async {
                    guard let vmToStop else {
                        cont.resume(throwing: VMError.notRunning)
                        return
                    }
                    do {
                        try vmToStop.raw.requestStop()
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch {
            // Guest stop failed; force-stop
            await forceStop()
            return
        }

        // Give the guest up to 10 seconds to shut down cleanly
        let deadline = ContinuousClock.now + .seconds(10)
        while case .stopping = state {
            if ContinuousClock.now > deadline {
                await forceStop()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    var vmView: VZVirtualMachineView {
        let view = VZVirtualMachineView()
        if let vm = virtualMachine {
            view.virtualMachine = vm
        }
        view.capturesSystemKeys = true
        return view
    }

    // MARK: - Private helpers

    private func forceStop() async {
        let vmToStop = virtualMachine.map { SendableVM(raw: $0) }
        vmQueue.async {
            vmToStop?.raw.stop(completionHandler: { _ in })
        }
        virtualMachine = nil
        state = .stopped
    }

    private func updateProvisionedState() {
        state = imageProvider.isImageReady ? .stopped : .notProvisioned
    }

    enum VMError: LocalizedError {
        case managerDeallocated
        case notRunning

        var errorDescription: String? {
            switch self {
            case .managerDeallocated:
                return "VM manager was deallocated."
            case .notRunning:
                return "VM is not running."
            }
        }
    }

    private struct SendableVM: @unchecked Sendable {
        let raw: VZVirtualMachine
    }
}

// MARK: - VZVirtualMachineDelegate

extension VMManager: VZVirtualMachineDelegate {
    nonisolated func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.virtualMachine = nil
            self?.state = .error(error.localizedDescription)
        }
    }

    nonisolated func guestDidStop(_ vm: VZVirtualMachine) {
        Task { @MainActor [weak self] in
            self?.virtualMachine = nil
            self?.state = .stopped
        }
    }
}
