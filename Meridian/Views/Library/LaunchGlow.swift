import SwiftUI

/// In-place launch loader (HANDOFF-2026-07-03-v8, revision 4 — native pass).
///
/// When the user clicks Play, the Play button itself becomes the loading
/// surface — no modal, no sheet, the wait happens exactly where the click
/// landed. Design follows Apple's HIG for progress indicators and Liquid
/// Glass adoption guidance:
///
///  - Progress is a system `ProgressView(value:)` restyled through the
///    `ProgressViewStyle` protocol (the HIG-sanctioned customization path —
///    keeps accessibility, animation, and platform behavior) into the
///    App-Store-style ring: quiet track, accent arc, staged SF Symbol in
///    the center.
///  - The capsule is real Liquid Glass (`glassEffect`) on macOS 26, with a
///    material fallback on macOS 15 — same gating pattern as
///    `GlassCapsuleBackground` in ContentView.
///  - Motion is limited to system transitions: `.blurReplace` for status
///    text swaps, `.numericText` for the percent, symbol-replace for the
///    stage icon, springs on the ring fraction. No custom orbiting
///    elements, no looping animation state, no Metal shader files.
struct LaunchGlowButton: View {
    let game: Game
    let launcher: Launcher

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: min(max(launcher.launchStageFraction, 0), 1))
                .progressViewStyle(StageRingProgressStyle(icon: launcher.launchStageIcon))

            ZStack(alignment: .leading) {
                // id + blurReplace: each status swap is a smooth blur morph
                // rather than a hard text change.
                Text(statusText)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(statusText)
                    .transition(.blurReplace)
            }
            .animation(.easeInOut(duration: 0.3), value: statusText)

            Text("\(progressPercent)%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: progressPercent)
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 140, maxWidth: 340, minHeight: 24)
        .padding(.vertical, 5)
        .modifier(LaunchGlassCapsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Launching \(game.name)")
        .accessibilityValue("\(progressPercent) percent")
    }

    private var statusText: String {
        launcher.currentActivity ?? "Launching \(game.name)…"
    }

    private var progressPercent: Int {
        Int((min(max(launcher.launchStageFraction, 0), 1) * 100).rounded())
    }
}

// MARK: - Stage ring progress style

/// App-Store-download-style determinate ring with the staged SF Symbol in
/// the center. Implemented as a `ProgressViewStyle` (per HIG: customize the
/// system component rather than rebuilding it) so VoiceOver announces it as
/// a progress indicator and the fraction animates with standard springs.
private struct StageRingProgressStyle: ProgressViewStyle {
    let icon: String

    func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0
        return ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2)

            Circle()
                .trim(from: 0, to: max(fraction, 0.03))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: fraction)

            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.4), value: icon)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Liquid Glass capsule

/// The loader sits on real Liquid Glass on macOS 26+
/// (`glassEffect(.regular.interactive(), in: .capsule)`). macOS 15 falls
/// back to a material capsule.
private struct LaunchGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}
