import SwiftUI

/// Safari-style circular download indicator for the toolbar.
///
/// Shows a circular progress arc when a download is active. Always visible
/// (as a static arrow icon) when there are recent downloads to display.
/// Tapping shows a popover listing the active download and recently completed installs.
struct DownloadsToolbarButton: View {
    let launcher: GameLauncher
    let library: SteamLibraryStore
    @Binding var isPresented: Bool
    var onSelectGame: (Game) -> Void

    private var isDownloading: Bool {
        if case .awaitingInstallConfirmation = launcher.launchState { return true }
        return false
    }

    private var hasContent: Bool {
        isDownloading || !DownloadHistory.shared.recent.isEmpty
    }

    var body: some View {
        if hasContent {
            Button { isPresented.toggle() } label: {
                downloadIcon
            }
            .buttonStyle(.plain)
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

    @ViewBuilder
    private var downloadIcon: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2)

            if isDownloading, let p = launcher.downloadProgress, p > 0 {
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: p)
            }

            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isDownloading ? .primary : .secondary)
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Popover content

private struct DownloadsPopoverContent: View {
    let launcher: GameLauncher
    let library: SteamLibraryStore
    var onSelectGame: (Game) -> Void

    private var activeGame: Game? {
        guard case .awaitingInstallConfirmation = launcher.launchState,
              let id = launcher.activeAppID else { return nil }
        return library.games.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Downloads")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Active download
            if let game = activeGame {
                activeDownloadRow(game)
            }

            // Recently completed
            let recent = DownloadHistory.shared.recent
            if !recent.isEmpty {
                if activeGame != nil {
                    Divider().padding(.horizontal, 8)
                }

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

            if activeGame == nil && recent.isEmpty {
                Text("No downloads")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 300)
        .padding(.bottom, 10)
    }

    private func activeDownloadRow(_ game: Game) -> some View {
        Button { onSelectGame(game) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(.tertiary, lineWidth: 2.5)
                    if let p = launcher.downloadProgress, p > 0 {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .frame(width: 24, height: 24)

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

                if let p = launcher.downloadProgress, p > 0 {
                    Text("\(Int(p * 100))%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ entry: DownloadHistory.Entry) -> some View {
        Button {
            if let game = library.games.first(where: { $0.id == entry.appID }) {
                onSelectGame(game)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(entry.completedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Download History (lightweight session-scoped store)

/// Tracks recently completed downloads for the popover's "Recently Installed" section.
/// Session-scoped (in-memory only) — clears on app quit. Keeps the last 10 entries.
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

    func recordCompletion(appID: Int, name: String) {
        let entry = Entry(appID: appID, name: name, completedAt: .now)
        recent.insert(entry, at: 0)
        if recent.count > 10 { recent.removeLast() }
    }

    private init() {}
}
