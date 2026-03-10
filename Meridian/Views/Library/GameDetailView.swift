import SwiftUI
import Virtualization
import AppKit

struct GameDetailView: View {
    let game: Game
    let onDismiss: () -> Void

    @Environment(SteamLibraryStore.self)  private var library
    @Environment(VMManager.self)          private var vmManager
    @Environment(SteamAuthService.self)   private var steamAuth
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self)       private var launcher
    @Environment(\.openWindow)            private var openWindow

    @State private var showProvisionSheet = false
    @State private var showPasswordPrompt = false
    @State private var passwordInput      = ""

    var body: some View {
        VStack(spacing: 0) {
            heroSection

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    launchSection
                    infoSection
                }
                .padding(20)
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 520, minHeight: 480)
        .sheet(isPresented: $showProvisionSheet) {
            VMProvisionView().environment(vmManager)
        }
        .sheet(isPresented: $showPasswordPrompt) {
            SteamPasswordSheet(
                accountName: sessionBridge.detectedAccountName ?? steamAuth.vmUsername,
                password: $passwordInput
            ) {
                steamAuth.vmPassword = passwordInput
                if let detected = sessionBridge.detectedAccountName, steamAuth.vmUsername.isEmpty {
                    steamAuth.vmUsername = detected
                }
                showPasswordPrompt = false
                startLaunch()
            } onCancel: {
                showPasswordPrompt = false
            }
        }
    }

    // MARK: - Hero (banner + title/playtime overlaid at bottom)

    private var heroSection: some View {
        heroImage
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .clipped()
            // Localised readability gradient — only covers the bottom 110pt
            // where the text sits, not the whole image.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
                .allowsHitTesting(false)
            }
            // Title + metadata float over the bottom of the art
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentGame.name)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

                    HStack(spacing: 8) {
                        if currentGame.playtimeMinutes > 0 {
                            Text(currentGame.playtimeFormatted + " played")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        if currentGame.requiresProton {
                            ProtonBadge()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
    }

    @ViewBuilder
    private var heroImage: some View {
        AsyncImage(url: game.heroURL) { heroPhase in
            switch heroPhase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                AsyncImage(url: game.capsuleURL) { capsulePhase in
                    switch capsulePhase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.primary.opacity(0.05)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Launch

    @ViewBuilder
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                playButton
                vmStatusPill
                Spacer()
            }
            // Activity card appears during any active phase so the user always
            // knows what is happening instead of staring at a frozen 0% bar.
            if isActivePhase {
                InstallActivityCard(launcher: launcher, openWindow: openWindow)
            }
        }
    }

    private var isActivePhase: Bool {
        switch launcher.launchState {
        case .preparingVM, .connectingBridge, .launching, .installing, .running: return true
        default: return false
        }
    }

    @ViewBuilder
    private var playButton: some View {
        switch launcher.launchState {
        case .idle, .exited:
            Button { handlePlayTapped() } label: {
                Label(primaryButtonTitle,
                      systemImage: currentGame.isInstalled ? "play.fill" : "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canLaunch)

        case .preparingVM:
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Starting VM…")
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .connectingBridge:
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Connecting…")
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .launching:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text("Launching…")
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .installing(_, let pct):
            Button {} label: {
                HStack(spacing: 8) {
                    if pct > 0 {
                        ProgressView(value: pct / 100)
                            .progressViewStyle(.linear)
                            .frame(width: 54)
                        Text("\(Int(pct))%")
                            .monospacedDigit()
                    } else {
                        ProgressView().scaleEffect(0.75)
                        Text("Installing…")
                    }
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .running:
            HStack(spacing: 8) {
                Button { openWindow(id: "game-window") } label: {
                    Label("Running", systemImage: "play.circle.fill")
                        .font(.headline)
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    Task { await launcher.stopGame() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                if isProvisioningError(msg) {
                    Button { showProvisionSheet = true } label: {
                        Label("Set Up VM…", systemImage: "arrow.down.circle")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button { handlePlayTapped() } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var currentGame: Game {
        library.games.first(where: { $0.id == game.id }) ?? game
    }

    private var primaryButtonTitle: String {
        currentGame.isInstalled ? "Play" : "Install & Play"
    }

    private var canLaunch: Bool {
        guard steamAuth.isAuthenticated else { return false }
        return !vmManager.state.isTransitioning
    }

    private var vmStatusPill: some View {
        VMStatusPill(state: vmManager.state)
    }

    // MARK: - Info
    // Simple HStack rows instead of Grid — fully predictable, no column-width edge cases.

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recent = currentGame.playtime2WeekMinutes, recent > 0 {
                infoRow("Last 2 weeks", value: "\(recent / 60) hrs")
                Divider().padding(.leading, 12)
            }
            infoRow("App ID", value: String(currentGame.id), monospaced: true)
            if currentGame.requiresProton {
                Divider().padding(.leading, 12)
                HStack {
                    Text("Compatibility")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                    ProtonBadge()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Helpers

    private func isProvisioningError(_ msg: String) -> Bool {
        msg.contains("kernel") || msg.contains("provision") || msg.contains("base image")
    }

    private func handlePlayTapped() {
        guard vmManager.imageProvider.isImageReady else {
            showProvisionSheet = true
            return
        }
        if !sessionBridge.hasInstallCredentials(auth: steamAuth) {
            passwordInput = ""
            showPasswordPrompt = true
            return
        }
        startLaunch()
    }

    private func startLaunch() {
        openWindow(id: "game-window")
        Task {
            await launcher.launch(
                game: currentGame,
                vmManager: vmManager,
                steamAuth: steamAuth,
                sessionBridge: sessionBridge,
                library: library
            )
        }
    }
}

// MARK: - Install Activity Card

/// Inline status card shown during any active launch phase.
/// Surfaces the current activity message, a live tail of the last few
/// meaningful agent log lines, an elapsed-time counter, and a shortcut
/// to the full log window.
private struct InstallActivityCard: View {
    let launcher: GameLauncher
    let openWindow: OpenWindowAction

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    private var recentLogs: [String] {
        launcher.logs
            .filter { !$0.hasPrefix("steam-log:") && !$0.hasPrefix("steam console log") }
            .suffix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Activity row
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(launcher.currentActivity ?? "Working…")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if elapsed > 5 {
                        Text(elapsedLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button {
                    openWindow(id: "launch-log")
                } label: {
                    Label("Logs", systemImage: "terminal")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            // Live log tail — last 3 non-diagnostic lines
            if !recentLogs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(recentLogs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private var elapsedLabel: String {
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return mins > 0 ? "\(mins)m \(secs)s elapsed" : "\(secs)s elapsed"
    }

    private func startTimer() {
        elapsed = launcher.installStartedAt.map { -$0.timeIntervalSinceNow } ?? 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
            Task { @MainActor in
                self.elapsed = self.launcher.installStartedAt.map { -$0.timeIntervalSinceNow } ?? self.elapsed + 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Launch Log Window

struct LaunchLogWindow: View {
    @Environment(GameLauncher.self) private var launcher

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(minWidth: 500, minHeight: 280)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Launch Log")
                .font(.headline)
            Spacer()
            if !launcher.logs.isEmpty {
                Text("\(launcher.logs.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    let text = launcher.logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            } else {
                Text("No output yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if launcher.logs.isEmpty {
                        Text("Waiting for output…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    } else {
                        ForEach(Array(launcher.logs.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .onChange(of: launcher.logs.count) { _, n in
                guard n > 0 else { return }
                proxy.scrollTo(n - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - VM Game Window

struct VMGameWindow: View {
    let vmManager: VMManager
    let launcher: GameLauncher

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VMDisplayView(vmManager: vmManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            Button {
                Task {
                    await launcher.stopGame()
                    closeGameWindow()
                }
            } label: {
                Label("Stop Game", systemImage: "stop.fill")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .padding(12)
        }
        .frame(minWidth: 1280, minHeight: 800)
        .onAppear {
            // Enter full-screen when the game window opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                closeGameWindow(toggleFullscreen: true)
            }
        }
    }

    private func closeGameWindow(toggleFullscreen: Bool = false) {
        // Find the game window by its identifier string or title.
        let window = NSApp.windows.first {
            $0.identifier?.rawValue == "game-window" ||
            $0.title == "Game" ||
            $0.contentView?.subviews.isEmpty == false && $0.title.isEmpty
        }
        if toggleFullscreen {
            window?.toggleFullScreen(nil)
        } else {
            if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    window?.close()
                }
            } else {
                window?.close()
            }
        }
    }
}

// MARK: - VZVirtualMachineView SwiftUI wrapper

/// Wraps VZVirtualMachineView as an NSViewRepresentable.
///
/// makeNSView returns the shared cached view from VMManager — this is important
/// because VZVirtualMachineView must not be recreated per SwiftUI render cycle.
///
/// updateNSView re-assigns virtualMachine so that if the VM is restarted (new
/// VZVirtualMachine instance), the view picks up the new machine without
/// requiring the window to be closed and reopened.
struct VMDisplayView: NSViewRepresentable {
    let vmManager: VMManager

    func makeNSView(context: Context) -> VZVirtualMachineView {
        vmManager.vmView
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== vmManager.virtualMachine {
            view.virtualMachine = vmManager.virtualMachine
        }
    }
}

// MARK: - Steam Password Prompt

/// One-time prompt shown before the first game install. The username is
/// auto-detected from macOS Steam's loginusers.vdf; only the password is needed.
struct SteamPasswordSheet: View {
    let accountName: String
    @Binding var password: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Steam Password Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Meridian needs your Steam password to download games inside the VM. This is stored securely in Keychain and only sent to Steam's servers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Steam account", text: .constant(accountName))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !password.isEmpty { onSave() }
                    }
            }
            .frame(width: 280)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button("Save & Continue") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 420)
    }
}
