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

    @State private var isExiting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo — template rendering in the asset catalog fills it with
            // .primary automatically: black in light mode, white in dark mode.
            Image("MeridianLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260)
                .foregroundStyle(.primary)

            Spacer().frame(height: 40)

            if isFailed {
                failedContent
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
                sessionBridge: sessionBridge
            )
        }
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
                    sessionBridge: sessionBridge
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
        .frame(width: 480, height: 300)
}
