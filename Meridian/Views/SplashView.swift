import SwiftUI

/// Shown at app launch while the bootstrap pipeline runs.
///
/// Displays a spinner and live status while Wine/Steam initialize.
/// Transitions to the main app once `BootstrapManager.phase == .ready`.
/// Shows an error state with a retry button if anything fails.
struct SplashView: View {
    @Environment(BootstrapManager.self) private var bootstrap
    @Environment(WineEngine.self) private var engine
    @Environment(WineSteamManager.self) private var steamManager
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(SteamWindowSuppressor.self) private var suppressor
    @Environment(EngineDownloader.self) private var engineDownloader
    @Environment(SteamCMDService.self) private var steamCMDService

    @State private var isExiting = false

    var body: some View {
        VStack(spacing: 0) {
            // minLength ensures the logo never sits flush against the window
            // edge when a tall phase (e.g. permissionGate) is active.
            Spacer(minLength: 24)

            // Fixed width — the logo never changes size regardless of which
            // bootstrap phase renders below it.
            Image("MeridianLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 220)
                .foregroundStyle(.primary)

            Spacer().frame(height: 32)

            if isFailed {
                failedContent
            } else if case .awaitingPermission = bootstrap.phase {
                permissionGate
            } else if case .downloadingEngine = bootstrap.phase {
                engineDownloadContent
            } else {
                statusContent
            }

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
        .task {
            // Center the window here — .task fires after SwiftUI layout is fully
            // settled, making it more reliable than AppDelegate's async dispatch.
            NSApp.mainWindow?.center()
            bootstrap.start(
                engine: engine,
                steamManager: steamManager,
                sessionBridge: sessionBridge,
                engineDownloader: engineDownloader,
                steamCMDService: steamCMDService
            )
        }
    }

    // MARK: - Permission Gate

    /// Full-screen gate that blocks the bootstrap pipeline until the user grants
    /// Accessibility permission or explicitly chooses to continue without it.
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

    // MARK: - Engine Download

    @ViewBuilder
    private var engineDownloadContent: some View {
        VStack(spacing: 12) {
            switch bootstrap.engineDownloadState {
            case .fetching:
                ProgressView()
                    .scaleEffect(0.8)
                Text("Finding latest Wine engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 280)
                    Text(engineDownloadLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .extracting:
                ProgressView()
                    .scaleEffect(0.8)
                Text("Installing Wine engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            default:
                ProgressView()
                    .scaleEffect(0.8)
                Text("Downloading Wine engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var engineDownloadLabel: String {
        let downloaded = engineDownloader.downloadedBytes
        let total      = engineDownloader.totalBytes
        if total > 0 {
            let mb      = Double(downloaded) / 1_000_000
            let totalMb = Double(total) / 1_000_000
            return String(format: "Downloading… %.0f / %.0f MB", mb, totalMb)
        }
        return "Downloading Wine engine…"
    }

    // MARK: - Status

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

    // MARK: - Failed

    private var isFailed: Bool {
        if case .failed = bootstrap.phase { return true }
        return false
    }

    private var failureMessage: String {
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

            Button("Retry") {
                bootstrap.retry(
                    engine: engine,
                    steamManager: steamManager,
                    sessionBridge: sessionBridge,
                    engineDownloader: engineDownloader,
                    steamCMDService: steamCMDService
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
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
        .environment(EngineDownloader())
        .frame(width: 480, height: 300)
}
