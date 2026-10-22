import SwiftUI

/// Steam couldn't sync a game's cloud saves before starting it. Meridian
/// asks here instead of Steam's dialog, which opens Steam's whole library
/// window. Try Again and Cancel close Steam's hidden dialog by quitting
/// Steam; only Play Anyway needs Steam's own window (Pattern 66).
struct CloudSyncSheet: View {
    let prompt: Launcher.CloudSyncPrompt
    let onTryAgain: () -> Void
    let onCancel: () -> Void
    let onPlayAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unable to Sync")
                        .font(.title2.weight(.semibold))
                    Text("Steam couldn't sync your \(prompt.game.name) saves with Steam Cloud.")
                        .font(.callout)
                    Text("If you play now, you may not have your latest progress, and you could lose it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()

            HStack {
                // The risky answer: Steam takes it in its own dialog.
                Button("Play Anyway in Steam…", action: onPlayAnyway)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again", action: onTryAgain)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
    }
}

#Preview {
    CloudSyncSheet(
        prompt: Launcher.CloudSyncPrompt(game: Game(id: 881100, name: "Noita")),
        onTryAgain: {}, onCancel: {}, onPlayAnyway: {}
    )
}
