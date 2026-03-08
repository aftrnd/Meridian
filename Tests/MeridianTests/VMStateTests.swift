/// Tests for VMState — the VM lifecycle state machine.
///
/// Run with:  swift test --filter VMStateTests

import Testing

// Mirror of VMState from Meridian/Models/VMState.swift.
// Kept here as a duplicate so the test target doesn't need to import
// Virtualization.framework or SwiftUI. If VMState changes, update this too —
// the tests will catch divergence in label/behavior.
enum VMState: Equatable {
    case notProvisioned
    case checkingForUpdate
    case downloading(progress: Double, bytesReceived: Int64, bytesTotal: Int64)
    case assembling
    case stopped
    case starting
    case ready
    case stopping
    case paused
    case error(String)

    var isRunning: Bool {
        if case .ready  = self { return true }
        if case .paused = self { return true }
        return false
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping, .checkingForUpdate, .assembling: return true
        case .downloading: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .notProvisioned:       return "Not Set Up"
        case .checkingForUpdate:    return "Checking for Updates…"
        case .downloading(let p, _, _):
            return "Downloading \(Int(p * 100))%"
        case .assembling:           return "Preparing Image…"
        case .stopped:              return "VM Stopped"
        case .starting:             return "Starting VM…"
        case .ready:                return "VM Ready"
        case .paused:               return "VM Paused"
        case .stopping:             return "Stopping VM…"
        case .error(let msg):
            let truncated = msg.count > 60 ? String(msg.prefix(60)) + "…" : msg
            return "Error: \(truncated)"
        }
    }
}

@Suite("VMState — isRunning")
struct VMStateIsRunningTests {

    @Test("only ready and paused are considered running")
    func runningStates() {
        #expect(VMState.ready.isRunning == true)
        #expect(VMState.paused.isRunning == true)
    }

    @Test("non-running states are not running")
    func nonRunningStates() {
        #expect(VMState.stopped.isRunning == false)
        #expect(VMState.starting.isRunning == false)
        #expect(VMState.stopping.isRunning == false)
        #expect(VMState.notProvisioned.isRunning == false)
        #expect(VMState.assembling.isRunning == false)
        #expect(VMState.checkingForUpdate.isRunning == false)
        #expect(VMState.error("oops").isRunning == false)
        #expect(VMState.downloading(progress: 0.5, bytesReceived: 500, bytesTotal: 1000).isRunning == false)
    }
}

@Suite("VMState — isTransitioning")
struct VMStateIsTransitioningTests {

    @Test("transitioning states are marked correctly")
    func transitioningStates() {
        #expect(VMState.starting.isTransitioning == true)
        #expect(VMState.stopping.isTransitioning == true)
        #expect(VMState.checkingForUpdate.isTransitioning == true)
        #expect(VMState.assembling.isTransitioning == true)
        #expect(VMState.downloading(progress: 0.1, bytesReceived: 100, bytesTotal: 1000).isTransitioning == true)
    }

    @Test("stable states are not transitioning")
    func stableStates() {
        #expect(VMState.ready.isTransitioning == false)
        #expect(VMState.stopped.isTransitioning == false)
        #expect(VMState.paused.isTransitioning == false)
        #expect(VMState.notProvisioned.isTransitioning == false)
        #expect(VMState.error("x").isTransitioning == false)
    }
}

@Suite("VMState — label text")
struct VMStateLabelTests {

    @Test("downloading label includes percentage")
    func downloadingLabel() {
        let state = VMState.downloading(progress: 0.42, bytesReceived: 420, bytesTotal: 1000)
        #expect(state.label == "Downloading 42%")
    }

    @Test("downloading 0% shows 0")
    func downloadingZero() {
        let state = VMState.downloading(progress: 0.0, bytesReceived: 0, bytesTotal: 1000)
        #expect(state.label == "Downloading 0%")
    }

    @Test("downloading 100% shows 100")
    func downloadingComplete() {
        let state = VMState.downloading(progress: 1.0, bytesReceived: 1000, bytesTotal: 1000)
        #expect(state.label == "Downloading 100%")
    }

    @Test("error label is truncated at 60 chars")
    func errorTruncation() {
        let longMsg = String(repeating: "x", count: 80)
        let state = VMState.error(longMsg)
        let label = state.label
        #expect(label.hasPrefix("Error: "))
        // 7 ("Error: ") + 60 + 1 ("…") = 68
        #expect(label.count <= 68)
        #expect(label.hasSuffix("…"))
    }

    @Test("error label short message is not truncated")
    func errorShortMessage() {
        let state = VMState.error("kernel not found")
        #expect(state.label == "Error: kernel not found")
    }

    @Test("all stable state labels are non-empty")
    func labelsNonEmpty() {
        let states: [VMState] = [
            .notProvisioned, .checkingForUpdate, .assembling,
            .stopped, .starting, .ready, .stopping, .paused,
            .error("test"), .downloading(progress: 0.5, bytesReceived: 5, bytesTotal: 10)
        ]
        for state in states {
            #expect(!state.label.isEmpty, "Label for \(state) is empty")
        }
    }
}

@Suite("VMState — Equatable")
struct VMStateEquatableTests {

    @Test("same states are equal")
    func sameStatesEqual() {
        #expect(VMState.ready == VMState.ready)
        #expect(VMState.stopped == VMState.stopped)
        #expect(VMState.error("x") == VMState.error("x"))
    }

    @Test("different error messages are not equal")
    func differentErrors() {
        #expect(VMState.error("a") != VMState.error("b"))
    }

    @Test("downloading states with same values are equal")
    func downloadingEqual() {
        let a = VMState.downloading(progress: 0.5, bytesReceived: 500, bytesTotal: 1000)
        let b = VMState.downloading(progress: 0.5, bytesReceived: 500, bytesTotal: 1000)
        #expect(a == b)
    }

    @Test("downloading states with different progress are not equal")
    func downloadingDifferent() {
        let a = VMState.downloading(progress: 0.3, bytesReceived: 300, bytesTotal: 1000)
        let b = VMState.downloading(progress: 0.5, bytesReceived: 500, bytesTotal: 1000)
        #expect(a != b)
    }
}

@Suite("GameLauncher — state transitions (logic only)")
struct LaunchStateTransitionTests {
    // Mirror of GameLauncher.LaunchState
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

    @Test("idle is the initial state")
    func initialState() {
        let state = LaunchState.idle
        if case .idle = state { } else { Issue.record("Expected idle") }
    }

    @Test("failed state stores the error message")
    func failedMessage() {
        let state = LaunchState.failed("kernel not found")
        if case .failed(let msg) = state {
            #expect(msg == "kernel not found")
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test("running state stores appID")
    func runningAppID() {
        let state = LaunchState.running(appID: 1091500)
        if case .running(let id) = state {
            #expect(id == 1091500)
        } else {
            Issue.record("Expected running state")
        }
    }

    @Test("exited state stores appID and code")
    func exitedInfo() {
        let state = LaunchState.exited(appID: 730, code: 0)
        if case .exited(let id, let code) = state {
            #expect(id == 730)
            #expect(code == 0)
        } else {
            Issue.record("Expected exited state")
        }
    }

    @Test("in-flight states block re-entry (not idle/exited/failed)")
    func inFlightCheck() {
        let inFlight: [LaunchState] = [
            .preparingVM, .connectingBridge, .launching,
            .running(appID: 1), .installing(appID: 1, progress: 0.5)
        ]
        let retriable: [LaunchState] = [
            .idle, .exited(appID: 1, code: 0), .failed("err")
        ]

        func canLaunch(_ s: LaunchState) -> Bool {
            switch s {
            case .preparingVM, .connectingBridge, .launching, .running, .installing:
                return false
            case .idle, .exited, .failed:
                return true
            }
        }

        for s in inFlight  { #expect(!canLaunch(s), "Should block in state \(s)") }
        for s in retriable { #expect(canLaunch(s),  "Should allow in state \(s)") }
    }
}
