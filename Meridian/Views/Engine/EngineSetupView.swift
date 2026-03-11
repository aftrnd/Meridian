import SwiftUI

/// Shown when no Wine backend is detected. Offers one-click engine download.
struct EngineSetupView: View {
    @Environment(WineEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var downloader = EngineDownloader()

    var body: some View {
        VStack(spacing: 28) {
            headerSection
            actionSection
            errorSection
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 380)
        .onChange(of: engine.state) { _, newState in
            if newState == .ready { dismiss() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: engine.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(engine.isReady ? .green : Color.accentColor)

            Text(engine.isReady ? "Engine Ready" : "Download Wine Runtime")
                .font(.title2)
                .fontWeight(.semibold)

            if engine.isReady {
                Text("Using \(engine.backendName) backend.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Meridian needs a Wine runtime to run Windows games.\nThis is a one-time download (~200 MB) of open-source components.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        if engine.isReady {
            Label("Engine ready (\(engine.backendName))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
        } else {
            switch downloader.state {
            case .idle, .failed:
                VStack(spacing: 12) {
                    Button {
                        downloader.download { engine.detect() }
                    } label: {
                        Label("Download Engine", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Re-detect Existing") {
                        engine.detect()
                    }
                    .buttonStyle(.bordered)

                    Button("Cancel") { dismiss() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }

            case .fetching:
                progressSection(label: "Finding latest release…", progress: nil)

            case .downloading(let progress):
                progressSection(
                    label: downloadLabel,
                    progress: progress
                )

            case .extracting:
                progressSection(label: "Extracting engine files…", progress: nil)

            case .complete:
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
        }
    }

    private func progressSection(label: String, progress: Double?) -> some View {
        VStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress) {
                    Text(label)
                        .font(.subheadline)
                }
                .frame(maxWidth: 300)
            } else {
                ProgressView {
                    Text(label)
                        .font(.subheadline)
                }
            }

            Button("Cancel") {
                downloader.cancel()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private var downloadLabel: String {
        if downloader.totalBytes > 0 {
            let mb = Double(downloader.downloadedBytes) / 1_000_000
            let totalMb = Double(downloader.totalBytes) / 1_000_000
            return String(format: "Downloading… %.0f / %.0f MB", mb, totalMb)
        }
        return "Downloading…"
    }

    // MARK: - Error

    @ViewBuilder
    private var errorSection: some View {
        if case .failed(let msg) = downloader.state {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }

        if case .error(let msg) = engine.state {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
