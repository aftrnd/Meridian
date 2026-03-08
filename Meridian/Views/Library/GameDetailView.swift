import SwiftUI
import Virtualization

struct GameDetailView: View {
    let game: Game

    @Environment(VMManager.self) private var vmManager
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self) private var launcher

    @State private var showProvisionSheet = false
    @State private var showVMView = false

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
        .navigationTitle(game.name)
        .sheet(isPresented: $showProvisionSheet) {
            VMProvisionView()
                .environment(vmManager)
        }
        .sheet(isPresented: $showVMView) {
            VMGameWindow(vmManager: vmManager)
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
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canLaunch)

        case .preparingVM, .launching:
            Button {} label: {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text(launcher.launchState == .preparingVM ? "Starting VM…" : "Launching…")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

        case .running:
            Button {
                showVMView = true
            } label: {
                Label("Running", systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    handlePlayTapped()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var canLaunch: Bool {
        steamAuth.isAuthenticated && (vmManager.state.isRunning || vmManager.state == .stopped)
    }

    private var vmStatusPill: some View {
        VMStatusPill(state: vmManager.state)
    }

    // MARK: - Info

    private var infoSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Text("Playtime").foregroundStyle(.secondary).font(.subheadline)
                Text(game.playtimeFormatted).font(.subheadline)
            }
            if let recent = game.playtime2WeekMinutes {
                GridRow {
                    Text("Last 2 weeks").foregroundStyle(.secondary).font(.subheadline)
                    Text("\(recent / 60) hrs").font(.subheadline)
                }
            }
            GridRow {
                Text("App ID").foregroundStyle(.secondary).font(.subheadline)
                Text(String(game.id)).font(.subheadline.monospaced())
            }
            if game.requiresProton {
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
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(launcher.logs.suffix(50).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 120)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Actions

    private func handlePlayTapped() {
        guard vmManager.imageProvider.isImageReady else {
            showProvisionSheet = true
            return
        }
        Task {
            await launcher.launch(game: game, vmManager: vmManager, steamAuth: steamAuth, sessionBridge: sessionBridge)
        }
    }
}

// MARK: - VM Game Window (VZVirtualMachineView wrapper)

struct VMGameWindow: View {
    let vmManager: VMManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Running in Meridian VM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { dismiss() }
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

// NSViewRepresentable wrapping VZVirtualMachineView
struct VMDisplayView: NSViewRepresentable {
    let vmManager: VMManager

    func makeNSView(context: Context) -> VZVirtualMachineView {
        vmManager.vmView
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {}
}
