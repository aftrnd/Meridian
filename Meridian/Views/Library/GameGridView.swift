import SwiftUI

struct GameGridView: View {
    let game: Game
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Capsule art
            AsyncImage(url: game.capsuleURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(460.0 / 215.0, contentMode: .fill)
                case .failure:
                    placeholderArt
                case .empty:
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(460.0 / 215.0, contentMode: .fill)
                        .overlay { ProgressView().scaleEffect(0.6) }
                @unknown default:
                    placeholderArt
                }
            }
            .clipped()
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))

            // Info row
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(game.playtimeFormatted)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if game.requiresProton {
                        ProtonBadge()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.15) : .clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
    }

    private var placeholderArt: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(460.0 / 215.0, contentMode: .fill)
            .overlay {
                Image(systemName: "gamecontroller")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

/// Small Proton indicator badge
struct ProtonBadge: View {
    var body: some View {
        Label("Proton", systemImage: "cpu")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.indigo, in: Capsule())
    }
}

#Preview {
    HStack {
        GameGridView(game: Game.previews[0], isSelected: false)
        GameGridView(game: Game.previews[2], isSelected: true)
    }
    .padding()
    .frame(width: 440)
}
