import Foundation

/// The full lifecycle state of the Meridian VM.
enum VMState: Equatable, Sendable {
    case notProvisioned
    case checkingForUpdate
    case downloading(progress: Double, bytesReceived: Int64, bytesTotal: Int64)
    case assembling           // joining split image parts
    case stopped
    case starting
    case ready                // running and healthy — Proton calls can be made
    case stopping
    case error(String)

    var isRunning: Bool {
        if case .ready = self { return true }
        return false
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping, .checkingForUpdate, .assembling: return true
        case .downloading: return true
        default: return false
        }
    }

    /// Short status label shown in the status bar.
    var label: String {
        switch self {
        case .notProvisioned:   return "Not Set Up"
        case .checkingForUpdate: return "Checking for Updates…"
        case .downloading(let p, _, _):
            return "Downloading \(Int(p * 100))%"
        case .assembling:       return "Preparing Image…"
        case .stopped:          return "VM Stopped"
        case .starting:         return "Starting VM…"
        case .ready:            return "VM Ready"
        case .stopping:         return "Stopping VM…"
        case .error(let msg):   return "Error: \(msg)"
        }
    }

    var statusColor: VMStatusColor {
        switch self {
        case .ready:            return .green
        case .error:            return .red
        case .notProvisioned:   return .gray
        default:                return .yellow
        }
    }
}

enum VMStatusColor {
    case green, yellow, red, gray
}
