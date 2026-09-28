import SwiftUI
import AppKit

/// Shown at app launch while the bootstrap pipeline runs.
///
/// Displays a spinner and live status while Wine/Steam initialize.
/// Transitions to the main app once `BootstrapManager.phase == .ready`.
/// Shows an error state with a retry button if anything fails.
struct SplashView: View {
    @Environment(BootstrapManager.self) private var bootstrap
    @Environment(WineEngine.self) private var engine
    @Environment(SteamSession.self) private var session
    @Environment(SteamWindow.self) private var steamWindow
    @Environment(EngineDownloader.self) private var engineDownloader

    @State private var isExiting = false

    var body: some View {
        VStack(spacing: 0) {
            if case .awaitingPermission = bootstrap.phase {
                // Replaces the logo: logo + gate don't fit in the 300pt splash.
                permissionGate
                    .frame(maxHeight: .infinity)
            } else {
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
                } else if case .downloadingEngine = bootstrap.phase {
                    engineDownloadContent
                } else {
                    statusContent
                }

                Spacer()
            }

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
            // Re-center the window AFTER SwiftUI layout settles.
            // AppDelegate's `enforceMainWindowLaunchFrame` runs synchronously
            // in `applicationDidFinishLaunching`, but window restoration can
            // race with it. Re-applying the same Dock-aware math here is
            // belt-and-suspenders.
            //
            // CRITICAL: do NOT use `NSWindow.center()` — that uses Apple's
            // "cascade" convention which places the window in the upper third
            // (Dock-unaware). Use visibleFrame.midX/midY for true centering
            // that accounts for the menu bar AND the Dock.
            if let window = NSApp.mainWindow,
               let screen = window.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                window.setFrameOrigin(CGPoint(
                    x: vf.midX - window.frame.width  / 2,
                    y: vf.midY - window.frame.height / 2
                ))
            }
            bootstrap.start(
                engine: engine,
                session: session,
                engineDownloader: engineDownloader
            )
        }
    }

    // MARK: - Permission Gate

    /// Full-screen gate that blocks the bootstrap pipeline until the user grants
    /// Accessibility permission or explicitly chooses to continue without it.
    private var permissionGate: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "accessibility")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.blue, in: Circle())
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
                .accessibilityHidden(true)

            Text("Allow Accessibility Access")
                .font(.title3.weight(.semibold))
                .padding(.top, 14)

            Text("Meridian uses Accessibility to keep Steam’s windows hidden while your games install and launch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 6)

            HStack(spacing: 12) {
                Button("Continue Without Access") {
                    bootstrap.skipPermissionRequirement()
                }

                Button("Open System Settings") {
                    steamWindow.requestPermission()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 20)

            Text("Turn on Meridian in Privacy & Security → Accessibility.\nSetup continues automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(.horizontal, 32)
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
                    session: session,
                    engineDownloader: engineDownloader
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
        .environment(SteamSession())
        .environment(SteamWindow())
        .environment(EngineDownloader())
        .frame(width: 480, height: 300)
}
