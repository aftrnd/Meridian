import SwiftUI

// MARK: - Toolbar button

/// Safari-style circular download indicator for the window toolbar.
///
/// The button itself is a fixed square so macOS 26 renders it as the standard
/// liquid-glass circle — not an oval. Placement is handled by the caller
/// inserting a Spacer() before this item so it sits on the trailing side.
struct DownloadsToolbarButton: View {
    let launcher: GameLauncher
    let library: SteamLibraryStore
    @Binding var isPresented: Bool
    var onSelectGame: (Game) -> Void

    private var isDownloading: Bool {
        if case .awaitingInstallConfirmation = launcher.launchState { return true }
        return false
    }

    var body: some View {
        if isDownloading || !DownloadHistory.shared.recent.isEmpty {
            Button { isPresented.toggle() } label: {
                ZStack {
                    // Track ring
                    Circle()
                        .stroke(.tertiary, lineWidth: 2)

                    // Filled arc proportional to download progress
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
                // Fixed square — keeps macOS from stretching the button into an oval
                .frame(width: 18, height: 18)
            }
            // No explicit buttonStyle: macOS 26 applies liquid-glass automatically to toolbar items
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
                    .padding(.bottom, 4)

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
        .padding(.bottom, 8)
    }

    // MARK: - Active row

    private func activeDownloadRow(_ game: Game) -> some View {
        Button { onSelectGame(game) } label: {
            HStack(spacing: 10) {
                // Capsule thumbnail
                capsuleThumbnail(for: game)

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

                // Circular progress on the right
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    if let p = launcher.downloadProgress, p > 0 {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(p * 100))")
                            .font(.system(size: 7, weight: .bold))
                            .monospacedDigit()
                    } else {
                        ProgressView().scaleEffect(0.45)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent row

    private func recentRow(_ entry: DownloadHistory.Entry) -> some View {
        let game = library.games.first { $0.id == entry.appID }
        return Button {
            if let game { onSelectGame(game) }
        } label: {
            HStack(spacing: 10) {
                // Capsule thumbnail (uses game if found, else placeholder)
                if let game {
                    capsuleThumbnail(for: game)
                } else {
                    placeholderThumbnail
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

    // MARK: - Thumbnail helpers

    private func capsuleThumbnail(for game: Game) -> some View {
        let urls = game.newCDNCapsuleURLs + [game.verticalCapsuleURL] + game.verticalCapsuleURLFallbacks
        let fallbacks = urls.count > 1 ? Array(urls[1...]) : []
        return CachedAsyncImage(url: urls.first, fallbacks: fallbacks) { phase in
            switch phase {
            case .success(let image):
                image.resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            default:
                placeholderThumbnail
            }
        }
        .frame(width: 36, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var placeholderThumbnail: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: 36, height: 48)
            .overlay {
                Image(systemName: "gamecontroller")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Download History

/// Session-scoped (in-memory) download history.
/// Deduplicates by appID — re-downloading a game replaces the old entry.
/// Keeps the last 10 unique games, most recent first.
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
        // Remove any prior entry for this game so re-downloads don't duplicate
        recent.removeAll { $0.appID == appID }
        recent.insert(Entry(appID: appID, name: name, completedAt: .now), at: 0)
        if recent.count > 10 { recent.removeLast() }
    }

    private init() {}
}
