import SwiftUI

/// Safari-style circular download indicator for the window toolbar.
///
/// Renders as a standard macOS toolbar circle button (liquid glass on macOS 26)
/// with an arc-progress overlay while a download is active. Tapping shows a
/// popover listing the active download and recently completed installs.
struct DownloadsToolbarButton: View {
    let launcher: Launcher
    let library: SteamLibraryStore
    @Binding var isPresented: Bool
    var onSelectGame: (Game) -> Void

    private var isDownloading: Bool { launcher.isInstalling }

    private var hasContent: Bool {
        isDownloading || !DownloadHistory.shared.recent.isEmpty
    }

    var body: some View {
        if hasContent {
            Button { isPresented.toggle() } label: {
                // Standard SF icon — macOS adds the circular glass background automatically.
                // The progress arc is a thin trim overlay that animates on top of the icon.
                ZStack {
                    if isDownloading, let p = launcher.downloadProgress, p > 0 {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(.primary.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: p)
                    }
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: isDownloading ? .semibold : .regular))
                }
            }
            // Do NOT override buttonStyle — let macOS supply the toolbar circle / liquid glass.
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                DownloadsPopoverContent(
                    launcher: launcher,
                    library: library,
                    onSelectGame: { game in
                        isPresented = false
                        onSelectGame(game)
                    }
                )
            }
            .help(isDownloading ? "Downloads in progress" : "Recent downloads")
        }
    }
}

// MARK: - Popover content

private struct DownloadsPopoverContent: View {
    let launcher: Launcher
    let library: SteamLibraryStore
    var onSelectGame: (Game) -> Void

    private var activeGame: Game? {
        guard launcher.isInstalling, let id = launcher.activeAppID else { return nil }
        return library.games.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Downloads")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if let game = activeGame {
                activeDownloadRow(game)
            }

            let recent = DownloadHistory.shared.recent
            if !recent.isEmpty {
                if activeGame != nil { Divider().padding(.horizontal, 8) }

                Text("Recently Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ForEach(recent) { entry in
                    recentRow(entry)
                }
            }

            if activeGame == nil && DownloadHistory.shared.recent.isEmpty {
                Text("No downloads")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 320)
        .padding(.bottom, 10)
    }

    // MARK: - Active row

    private func activeDownloadRow(_ game: Game) -> some View {
        Button { onSelectGame(game) } label: {
            HStack(spacing: 10) {
                capsuleArt(for: game)

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if let activity = launcher.currentActivity {
                        Text(activity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Progress ring + percentage on the right
                VStack(spacing: 2) {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 2.5)
                        if let p = launcher.downloadProgress, p > 0 {
                            Circle()
                                .trim(from: 0, to: p)
                                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.3), value: p)
                        } else {
                            ProgressView().scaleEffect(0.45)
                        }
                    }
                    .frame(width: 22, height: 22)

                    if let p = launcher.downloadProgress, p > 0 {
                        Text("\(Int(p * 100))%")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent row

    private func recentRow(_ entry: DownloadHistory.Entry) -> some View {
        Button {
            if let game = library.games.first(where: { $0.id == entry.appID }) {
                onSelectGame(game)
            }
        } label: {
            HStack(spacing: 10) {
                if let game = library.games.first(where: { $0.id == entry.appID }) {
                    capsuleArt(for: game)
                } else {
                    // Fallback placeholder when game isn't in library
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(width: 32, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(entry.completedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capsule art

    @ViewBuilder
    private func capsuleArt(for game: Game) -> some View {
        let urls = game.newCDNCapsuleURLs
            + [game.verticalCapsuleURL]
            + game.verticalCapsuleURLFallbacks
        CachedAsyncImage(url: urls.first, fallbacks: Array(urls.dropFirst())) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 48)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 32, height: 48)
                    .overlay {
                        Image(systemName: "gamecontroller")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 32, height: 48)
    }
}

// MARK: - Download History

/// Lightweight session-scoped download history for the popover.
/// In-memory only — clears on quit. Keeps the 10 most recent unique installs.
@Observable
final class DownloadHistory: @unchecked Sendable {
    static let shared = DownloadHistory()

    struct Entry: Identifiable {
        let id = UUID()
        let appID: Int
        let name: String
        let completedAt: Date
    }

    private(set) var recent: [Entry] = []

    /// Records a completed download. Replaces any existing entry for the same
    /// game so re-downloads don't create duplicates — only the latest is kept.
    func recordCompletion(appID: Int, name: String) {
        recent.removeAll { $0.appID == appID }
        recent.insert(Entry(appID: appID, name: name, completedAt: .now), at: 0)
        if recent.count > 10 { recent.removeLast() }
    }

    private init() {}
}
