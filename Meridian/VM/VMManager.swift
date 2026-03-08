@preconcurrency import Virtualization
import Observation
import Foundation

/// Manages the full Meridian VM lifecycle using Apple's Virtualization.framework.
///
/// Threading model:
///   - @Observable @MainActor: published state updates happen on main thread.
///   - VZVirtualMachine must be created and called on the same serial queue.
///   - We use a dedicated `vmQueue` for all VZ calls and marshal state back to MainActor.
///
/// vmView ownership:
///   The VZVirtualMachineView is created once and cached. On VM restart we
///   re-assign its `virtualMachine` property rather than recreating the view;
///   recreating it causes a black-frame flash and loses SwiftUI layout state.
@Observable
@MainActor
final class VMManager: NSObject {

    // MARK: - Published state

    private(set) var state: VMState = .notProvisioned
    let imageProvider = VMImageProvider()

    // MARK: - Private

    /// The running VZVirtualMachine. Nil when stopped.
    private(set) var virtualMachine: VZVirtualMachine?

    /// Cached VZVirtualMachineView — created once, `virtualMachine` updated on restart.
    private var _vmView: VZVirtualMachineView?

    let vmQueue = DispatchQueue(label: "com.meridian.vm", qos: .userInteractive)
    private var startContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Init

    override init() {
        super.init()
        updateProvisionedState()
    }

    // MARK: - Public API

    /// The virtio-vsock device for ProtonBridge. Only non-nil when VM is running.
    var socketDevice: VZVirtioSocketDevice? {
        virtualMachine?.socketDevices.first as? VZVirtioSocketDevice
    }

    /// Returns the shared VZVirtualMachineView, creating it on first access.
    /// Updating virtualMachine is handled internally — callers just hold the reference.
    var vmView: VZVirtualMachineView {
        if let existing = _vmView { return existing }
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        _vmView = view
        return view
    }

    /// Provisions the VM: downloads + assembles the Meridian base image (kernel + rootfs).
    func provision() async {
        state = .checkingForUpdate
        do {
            try await imageProvider.downloadLatestImage { [weak self] progress, received, total in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: progress, bytesReceived: received, bytesTotal: total)
                }
            }
            state = .assembling
            try await imageProvider.assembleImageAsync()
            state = .stopped
            updateProvisionedState()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Provisions the VM from a local LZFSE-compressed image file on disk.
    func provisionLocal(from url: URL) async {
        state = .assembling
        do {
            try await imageProvider.installFromLocalFile(url)
            updateProvisionedState()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Starts the VM. Throws if not in a startable state.
    func start() async throws {
        // Recover from a previous error — treat it as stopped and retry.
        if case .error = state { state = .stopped }
        guard case .stopped = state else {
            if state.isRunning { return }  // already running — no-op
            throw VMError.notStopped
        }
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
            // Keep the cached view pointing to the new VM instance
            _vmView?.virtualMachine = vm

            let sendableVM = SendableVM(raw: vm)

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Store continuation before dispatching so the completion handler
                // can always find it — avoids a narrow race if start() returns
                // synchronously on some future hardware.
                Task { @MainActor [weak self] in self?.startContinuation = cont }
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

    /// Requests a clean guest shutdown, falling back to force-stop after 10 s.
    func stop() async {
        guard state.isRunning else { return }
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
            await forceStop()
            return
        }

        let deadline = ContinuousClock.now + .seconds(10)
        while case .stopping = state {
            if ContinuousClock.now > deadline { await forceStop(); return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Private helpers

    private func forceStop() async {
        let vmToStop = virtualMachine.map { SendableVM(raw: $0) }
        vmQueue.async { vmToStop?.raw.stop(completionHandler: { _ in }) }
        didStop()
    }

    /// Centralised teardown so both forceStop and guestDidStop use the same path.
    private func didStop() {
        virtualMachine = nil
        _vmView?.virtualMachine = nil
        state = .stopped
    }

    private func updateProvisionedState() {
        state = imageProvider.isImageReady ? .stopped : .notProvisioned
    }

    // MARK: - Errors

    enum VMError: LocalizedError {
        case managerDeallocated
        case notRunning
        case notStopped

        var errorDescription: String? {
            switch self {
            case .managerDeallocated: return "VM manager was deallocated."
            case .notRunning:         return "VM is not running."
            case .notStopped:         return "VM cannot start from its current state."
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
            self?._vmView?.virtualMachine = nil
            self?.state = .error(error.localizedDescription)
        }
    }

    nonisolated func guestDidStop(_ vm: VZVirtualMachine) {
        Task { @MainActor [weak self] in
            self?.didStop()
        }
    }
}
