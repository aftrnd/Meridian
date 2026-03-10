import SwiftUI
import AppKit

/// Shown when the Meridian base image hasn't been downloaded yet,
/// or when an update is available.
struct VMProvisionView: View {
    @Environment(VMManager.self) private var vmManager
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
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
                Text("Meridian needs a lightweight Ubuntu VM image with Proton GE pre-installed. Download it automatically, or point to a local copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            // Progress / action
            if isWorking {
                workingProgress
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
    private var workingProgress: some View {
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
                ProgressView("Decompressing image…")
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
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

            Button("Use Local File…") {
                pickLocalFile()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func startProvision() {
        isWorking = true
        errorMessage = nil
        Task {
            await vmManager.provision()
            if case .error(let msg) = vmManager.state {
                errorMessage = msg
                isWorking = false
            } else {
                dismiss()
            }
        }
    }

    private func pickLocalFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Meridian Base Image"
        panel.message = "Choose a meridian-base-*.img.lzfse file"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Start accessing the security-scoped resource so the sandbox
        // allows reads from outside the container for the full duration.
        let accessing = url.startAccessingSecurityScopedResource()

        isWorking = true
        errorMessage = nil
        Task {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            await vmManager.provisionLocal(from: url)
            if case .error(let msg) = vmManager.state {
                errorMessage = msg
                isWorking = false
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
