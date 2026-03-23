import SwiftUI

/// Shown at app launch while the engine and bootstrap pipeline run.
///
/// First-launch flow (fully automatic — no user interaction required):
///   1. Engine not installed → auto-download begins immediately with inline progress
///   2. Download completes  → engine.detect() → engine.isReady
///   3. Bootstrap starts    → Wine prefix / Steam setup
///   4. Ready               → fade out to main UI
///
/// Subsequent launches skip step 1 and go straight to bootstrap.
struct SplashView: View {
    @Environment(BootstrapManager.self) private var bootstrap
    @Environment(WineEngine.self) private var engine
    @Environment(WineSteamManager.self) private var steamManager
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(SteamWindowSuppressor.self) private var suppressor

    @State private var isExiting = false
    @State private var engineDownloader = EngineDownloader()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("MeridianLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260)
                .foregroundStyle(.primary)

            Spacer().frame(height: 40)

            Group {
                if isDownloadFailed || isBootstrapFailed {
                    failedContent
                } else if case .awaitingPermission = bootstrap.phase {
                    permissionGate
                } else if engineDownloader.isActive || needsEngineDownload {
                    engineDownloadContent
                } else {
                    statusContent
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.25)))

            Spacer()

            finePrint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isExiting ? 0 : 1)
        .blur(radius: isExiting ? 14 : 0)
        .animation(.easeIn(duration: 0.3), value: isExiting)
        .onChange(of: bootstrap.isReady) { _, ready in
            if ready { isExiting = true }
        }
        .onChange(of: engine.isReady) { _, ready in
            // Engine just became ready (download finished) — start bootstrap automatically.
            if ready && bootstrap.phase == .idle {
                bootstrap.start(
                    engine: engine,
                    steamManager: steamManager,
                    sessionBridge: sessionBridge
                )
            }
        }
        .task {
            NSApp.mainWindow?.center()

            if engine.isReady {
                // Engine already installed — go straight to bootstrap.
                bootstrap.start(
                    engine: engine,
                    steamManager: steamManager,
                    sessionBridge: sessionBridge
                )
            } else {
                // No engine — download it first. Bootstrap will start automatically
                // once engine.isReady via the .onChange observer above.
                startEngineDownload()
            }
        }
    }

    // MARK: - Engine Download

    /// True during the initial engine-install window before download has been triggered.
    private var needsEngineDownload: Bool {
        engine.state == .notInstalled && bootstrap.phase == .idle
    }

    private func startEngineDownload() {
        engineDownloader.download { engine.detect() }
    }

    @ViewBuilder
    private var engineDownloadContent: some View {
        VStack(spacing: 10) {
            switch engineDownloader.state {
            case .idle:
                ProgressView().scaleEffect(0.8)
                Text("Preparing…")
                    .font(.callout).foregroundStyle(.secondary)

            case .fetching:
                ProgressView().scaleEffect(0.8)
                Text("Finding latest engine…")
                    .font(.callout).foregroundStyle(.secondary)

            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                    .animation(.linear(duration: 0.2), value: progress)
                Text(downloadProgressLabel)
                    .font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()

            case .extracting:
                ProgressView().scaleEffect(0.8)
                Text("Installing Wine engine…")
                    .font(.callout).foregroundStyle(.secondary)

            case .complete:
                ProgressView().scaleEffect(0.8)
                Text("Starting up…")
                    .font(.callout).foregroundStyle(.secondary)

            case .failed:
                EmptyView() // handled by failedContent
            }
        }
    }

    private var downloadProgressLabel: String {
        let dl = engineDownloader.downloadedBytes
        let total = engineDownloader.totalBytes
        guard total > 0 else { return "Downloading Wine engine…" }
        return "Downloading Wine engine — \(formatMB(dl)) / \(formatMB(total)) MB"
    }

    private func formatMB(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000)
    }

    // MARK: - Status (bootstrap in progress)

    @ViewBuilder
    private var statusContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
            Text(bootstrap.statusMessage.isEmpty ? "Starting up…" : bootstrap.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.2), value: bootstrap.statusMessage)
        }
    }

    // MARK: - Permission Gate

    private var permissionGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("Permission Required")
                    .font(.headline)
                Text("Meridian needs Accessibility access to keep Steam running silently in the background. Without it, Steam windows will appear during game installs and launches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            Button {
                suppressor.requestPermission()
            } label: {
                Label("Open System Settings", systemImage: "gear")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("After enabling Meridian in Privacy & Security → Accessibility,\nreturn here and setup will continue automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Continue Without Permission") {
                bootstrap.skipPermissionRequirement()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: - Failed

    private var isDownloadFailed: Bool {
        if case .failed = engineDownloader.state { return true }
        return false
    }

    private var isBootstrapFailed: Bool {
        if case .failed = bootstrap.phase { return true }
        return false
    }

    private var failureMessage: String {
        if case .failed(let msg) = engineDownloader.state { return msg }
        if case .failed(let msg) = bootstrap.phase { return msg }
        return "Something went wrong."
    }

    @ViewBuilder
    private var failedContent: some View {
        VStack(spacing: 14) {
            Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if isDownloadFailed {
                Button {
                    startEngineDownload()
                } label: {
                    Label("Retry Download", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button("Retry") {
                    bootstrap.retry(
                        engine: engine,
                        steamManager: steamManager,
                        sessionBridge: sessionBridge
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Fine Print

    private var finePrint: some View {
        VStack(spacing: 3) {
            Text("Not affiliated with or endorsed by Valve Corporation or Apple Inc.")
            Text("Wine is free software distributed under the GNU LGPL · © 2026 Meridian · All rights reserved.")
        }
        .font(.system(size: 9, weight: .regular))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .lineSpacing(1)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }
}

#Preview {
    SplashView()
        .environment(BootstrapManager())
        .environment(WineEngine())
        .environment(WineSteamManager())
        .environment(SteamSessionBridge())
        .environment(SteamWindowSuppressor())
        .frame(width: 480, height: 300)
}
