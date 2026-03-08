import SwiftUI
import Virtualization

struct GameDetailView: View {
    let game: Game

    @Environment(SteamLibraryStore.self)  private var library
    @Environment(VMManager.self)          private var vmManager
    @Environment(SteamAuthService.self)   private var steamAuth
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self)       private var launcher

    @State private var showProvisionSheet = false
    @State private var showVMView         = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 24) {
                    launchSection
                    infoSection
                    if !launcher.logs.isEmpty { logsSection }
                }
                .padding(24)
            }
        }
        .navigationTitle(currentGame.name)
        .sheet(isPresented: $showProvisionSheet) {
            VMProvisionView()
                .environment(vmManager)
        }
        .sheet(isPresented: $showVMView) {
            VMGameWindow(vmManager: vmManager, launcher: launcher)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        AsyncImage(url: game.heroURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipped()
                    .overlay(heroGradient)
            default:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: .controlBackgroundColor), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 120)
            }
        }
    }

    private var heroGradient: some View {
        LinearGradient(
            colors: [.clear, Color(nsColor: .windowBackgroundColor)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 120)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Launch

    @ViewBuilder
    private var launchSection: some View {
        HStack(alignment: .center, spacing: 14) {
            playButton
            vmStatusPill
            Spacer()
        }
    }

    @ViewBuilder
    private var playButton: some View {
        switch launcher.launchState {
        case .idle, .exited:
            Button {
                handlePlayTapped()
            } label: {
                Label(primaryButtonTitle, systemImage: currentGame.isInstalled ? "play.fill" : "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canLaunch)

        case .preparingVM, .connectingBridge:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text(launcher.launchState == .preparingVM ? "Starting VM…" : "Connecting…")
                }
                .frame(minWidth: 120)
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
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .installing(_, let pct):
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView(value: pct / 100).frame(width: 60)
                    Text("Installing \(Int(pct))%")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .running:
            HStack(spacing: 8) {
                Button {
                    showVMView = true
                } label: {
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
            VStack(alignment: .leading, spacing: 4) {
                if isProvisioningError(msg) {
                    Button {
                        showProvisionSheet = true
                    } label: {
                        Label("Set Up VM…", systemImage: "arrow.down.circle")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        handlePlayTapped()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(minWidth: 120)
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

    /// Play is always tappable — handlePlayTapped() decides what to show:
    ///   - not provisioned  → provision sheet
    ///   - not authenticated → shown on the auth screen anyway, but guard here too
    ///   - transitioning     → disable so rapid double-taps don't queue launches
    private var canLaunch: Bool {
        guard steamAuth.isAuthenticated else { return false }
        // Disable while the VM is actively transitioning (starting/stopping/downloading)
        // so rapid taps don't queue multiple launches.
        return !vmManager.state.isTransitioning
    }

    private var vmStatusPill: some View {
        VMStatusPill(state: vmManager.state)
    }

    // MARK: - Info

    private var infoSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Text("Playtime").foregroundStyle(.secondary).font(.subheadline)
                Text(currentGame.playtimeFormatted).font(.subheadline)
            }
            if let recent = currentGame.playtime2WeekMinutes {
                GridRow {
                    Text("Last 2 weeks").foregroundStyle(.secondary).font(.subheadline)
                    Text("\(recent / 60) hrs").font(.subheadline)
                }
            }
            GridRow {
                Text("App ID").foregroundStyle(.secondary).font(.subheadline)
                Text(String(currentGame.id)).font(.subheadline.monospaced())
            }
            if currentGame.requiresProton {
                GridRow {
                    Text("Compatibility").foregroundStyle(.secondary).font(.subheadline)
                    ProtonBadge()
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launch Log")
                .font(.subheadline)
                .fontWeight(.semibold)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(launcher.logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: 120)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: launcher.logs.count) { _, newCount in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func isProvisioningError(_ msg: String) -> Bool {
        msg.contains("kernel") || msg.contains("provision") || msg.contains("base image")
    }

    private func handlePlayTapped() {
        guard vmManager.imageProvider.isImageReady else {
            showProvisionSheet = true
            return
        }
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

// MARK: - VM Game Window (full-screen VM view)

struct VMGameWindow: View {
    let vmManager: VMManager
    let launcher: GameLauncher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Running in Meridian VM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        await launcher.stopGame()
                        dismiss()
                    }
                } label: {
                    Label("Stop Game", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            VMDisplayView(vmManager: vmManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1280, minHeight: 800)
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
/// requiring the sheet to be dismissed and re-shown.
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
