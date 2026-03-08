import SwiftUI

/// Shown when the Meridian base image hasn't been downloaded yet,
/// or when an update is available.
struct VMProvisionView: View {
    @Environment(VMManager.self) private var vmManager
    @Environment(\.dismiss) private var dismiss

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.tint)
                Text("Set Up Meridian VM")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Meridian needs to download a lightweight Ubuntu VM image with Proton GE pre-installed. This is a one-time download (~2 GB).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            // Progress / action
            if isDownloading {
                downloadProgress
            } else {
                actionButtons
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 340)
    }

    @ViewBuilder
    private var downloadProgress: some View {
        VStack(spacing: 16) {
            if case .downloading(let p, let rx, let total) = vmManager.state {
                VStack(spacing: 8) {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(width: 340)
                    HStack {
                        Text(formatBytes(rx))
                        Spacer()
                        Text("\(Int(p * 100))%")
                        Spacer()
                        Text(formatBytes(total))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 340)
                }
            } else if case .assembling = vmManager.state {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing VM image…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Checking for image…")
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 14) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

            Button("Download & Install") {
                startProvision()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
    }

    private func startProvision() {
        isDownloading = true
        errorMessage = nil
        Task {
            await vmManager.provision()
            if case .error(let msg) = vmManager.state {
                errorMessage = msg
                isDownloading = false
            } else {
                dismiss()
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}
