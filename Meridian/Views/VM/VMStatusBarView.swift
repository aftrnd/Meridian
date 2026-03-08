import SwiftUI

/// Compact status bar shown at the bottom of the main window.
struct VMStatusBarView: View {
    @Environment(VMManager.self) private var vmManager

    var onSetUp: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            VMStatusPill(state: vmManager.state)

            if case .downloading(let p, let rx, let total) = vmManager.state {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(formatBytes(rx)) / \(formatBytes(total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if case .notProvisioned = vmManager.state {
                Button("Set Up VM…") { onSetUp?() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else if vmManager.state.isRunning {
                Button("Stop VM") {
                    Task { await vmManager.stop() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// Reusable pill showing VM state with colored dot.
struct VMStatusPill: View {
    let state: VMState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .overlay {
                    if state.isTransitioning {
                        Circle()
                            .stroke(dotColor.opacity(0.4), lineWidth: 3)
                            .scaleEffect(1.8)
                            .opacity(0.6)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: state.isTransitioning)
                    }
                }
            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        switch state.statusColor {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        case .gray:   return .gray
        }
    }
}
