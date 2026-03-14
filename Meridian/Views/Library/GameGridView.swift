import SwiftUI

// MARK: - Game Card State

enum GameCardState: Equatable {
    case idle
    case notInstalled
    case launching
    case running
    case stopping
}

struct GameGridView: View {
    let game: Game
    let isSelected: Bool
    var isFavorite: Bool = false
    var gameState: GameCardState = .idle

    @State private var isHovered = false
    @State private var runningPulse = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var cardSize: CGSize = .zero

    private var isRunning: Bool { gameState == .running }
    private var isLaunching: Bool { gameState == .launching || gameState == .stopping }

    private let maxTilt: Double = 6
    private let perspective: CGFloat = 0.4

    private var tiltX: Double {
        guard isHovered, cardSize.height > 0 else { return 0 }
        let normalized = (hoverLocation.y / cardSize.height) - 0.5
        return -normalized * maxTilt
    }

    private var tiltY: Double {
        guard isHovered, cardSize.width > 0 else { return 0 }
        let normalized = (hoverLocation.x / cardSize.width) - 0.5
        return normalized * maxTilt
    }

    private var highlightOffset: UnitPoint {
        guard isHovered, cardSize.width > 0, cardSize.height > 0 else {
            return .center
        }
        return UnitPoint(
            x: hoverLocation.x / cardSize.width,
            y: hoverLocation.y / cardSize.height
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artSection
            infoRow
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cardBackgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.12), .clear],
                        center: highlightOffset,
                        startRadius: 0,
                        endRadius: max(cardSize.width, cardSize.height) * 0.8
                    )
                )
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { cardSize = geo.size }
            }
        )
        .rotation3DEffect(
            .degrees(tiltX),
            axis: (x: 1, y: 0, z: 0),
            perspective: perspective
        )
        .rotation3DEffect(
            .degrees(tiltY),
            axis: (x: 0, y: 1, z: 0),
            perspective: perspective
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(
            color: .black.opacity(isHovered ? 0.25 : 0.0),
            radius: isHovered ? 12 : 0,
            y: isHovered ? 6 : 0
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.7), value: hoverLocation)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .contentShape(Rectangle())
        .onAppear { updatePulse() }
        .onChange(of: gameState) { _, _ in updatePulse() }
    }

    private var cardBackgroundFill: Color {
        if isRunning { return .green.opacity(0.08) }
        if isSelected { return .accentColor.opacity(0.1) }
        return .clear
    }

    private var cardBorderColor: Color {
        if isRunning { return .green.opacity(runningPulse ? 0.9 : 0.5) }
        if isSelected { return .accentColor }
        if isHovered { return .primary.opacity(0.12) }
        return .clear
    }

    private var cardBorderWidth: CGFloat {
        (isRunning || isSelected) ? 1.5 : 1
    }

    private func updatePulse() {
        if isRunning {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                runningPulse = true
            }
        } else {
            runningPulse = false
        }
    }

    // MARK: - Art

    private var artSection: some View {
        CachedAsyncImage(url: game.capsuleURL, fallbacks: game.capsuleURLFallbacks) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Color.primary.opacity(0.05)
                    .overlay { ProgressView().scaleEffect(0.6) }
            case .failure:
                artPlaceholder
            @unknown default:
                artPlaceholder
            }
        }
        .aspectRatio(460.0 / 215.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) { statusBadge }
        .overlay(alignment: .topTrailing) { trailingBadges }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch gameState {
        case .running:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .scaleEffect(runningPulse ? 1.3 : 0.8)
                Text("Now Playing")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)

        case .launching, .stopping:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text(gameState == .launching ? "Launching" : "Stopping")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)

        case .notInstalled, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingBadges: some View {
        if isFavorite {
            Image(systemName: "heart.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(.pink.opacity(0.85), in: Circle())
                .padding(6)
        }
    }

    private var artPlaceholder: some View {
        Color.primary.opacity(0.05)
            .overlay {
                Image(systemName: "gamecontroller")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Info Row (blurred art background)

    private var infoRow: some View {
        ZStack(alignment: .leading) {
            CachedAsyncImage(url: game.capsuleURL, fallbacks: game.capsuleURLFallbacks) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 20)
                        .saturation(1.3)
                        .brightness(-0.15)
                } else {
                    Color(white: 0.15)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.5), .black.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(game.name)

                HStack(spacing: 6) {
                    Text(game.playtimeFormatted)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    if game.windowsOnly {
                        WindowsBadge()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: 52)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }
}

// MARK: - Windows badge

struct WindowsBadge: View {
    var body: some View {
        Label("Windows", systemImage: "desktopcomputer")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.indigo, in: Capsule())
    }
}

#Preview {
    HStack {
        GameGridView(game: Game.previews[0], isSelected: false, isFavorite: true, gameState: .running)
        GameGridView(game: Game.previews[2], isSelected: true, isFavorite: false, gameState: .notInstalled)
        GameGridView(game: Game.previews[4], isSelected: false, isFavorite: false, gameState: .launching)
    }
    .padding()
    .frame(width: 660)
}
