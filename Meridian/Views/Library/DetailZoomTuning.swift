import SwiftUI
import AppKit

// MARK: - Tunable parameters

/// Every knob of the card ↔ detail zoom, in one value type so the tuning
/// window can bind to it and the whole set can be copied as a Swift literal.
/// Progress-domain values (`…Start`/`…End`/`…Until`) are 0…1 fractions of the
/// flight; durations are seconds; kicks are whole-distances per second.
struct DetailZoomParameters: Codable, Equatable, Sendable {
    // Open. Curve mode = cubic Bézier (ease-in → ease-out, no bounce);
    // spring mode uses duration/bounce/kick.
    var openUsesCurve: Bool   = false
    var openEaseIn: Double    = 0.8
    var openEaseOut: Double   = 0.35
    var openDuration: Double  = 0.535
    var openBounce: Double    = 0.125
    var openKick: Double      = 12

    // Close spring
    var closeDuration: Double = 0.65
    var closeBounce: Double   = 0.15
    var closeKick: Double     = 12

    // Ghost (card art) → page dissolve
    var posterFadeStart: Double = 0.08
    var posterFadeEnd: Double   = 0.4

    // Clip
    var cornerRadius: Double       = 12
    var cornerHoldUntil: Double    = 0.3
    var clipOverreachStart: Double = 0.23
    var clipRestInset: Double      = 200

    // Card geometry
    var hoverLift: Double = 0.015

    // Fallback (no card on screen)
    var fallbackInset: Double       = 0.06
    var fallbackPageFadeEnd: Double = 0.5

    // Hand-offs
    var ambientFade: Double = 1.5
    /// Fraction of the open flight after which the bleeds start fading in
    /// (the `.removed` settle trails the visible landing by ~0.5 s).
    var ambientLead: Double = 0.85
    /// Library dissolve (ease-in-out), seconds — its own clock, not the spring.
    var rootFadeDuration: Double = 0.3
    var chromeSwap: Double  = 0.611
    var landingFade: Double = 0.25

    /// Swift literal of the current values, for pasting back as new defaults.
    var swiftLiteral: String {
        let m = Mirror(reflecting: self)
        let fields = m.children.compactMap { child -> String? in
            guard let label = child.label else { return nil }
            if let v = child.value as? Double {
                return "    var \(label): Double = \(v.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)))"
            }
            if let b = child.value as? Bool {
                return "    var \(label): Bool = \(b)"
            }
            return nil
        }
        return "struct DetailZoomParameters {\n" + fields.joined(separator: "\n") + "\n}"
    }
}

/// Live parameter store. UserDefaults-backed so a tuning session survives a
/// relaunch; reset restores the compiled defaults.
@MainActor
@Observable
final class DetailZoomTuning {
    static let shared = DetailZoomTuning()

    private static let key = "meridian.detailZoomTuning"

    var params: DetailZoomParameters {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(DetailZoomParameters.self, from: data) {
            params = saved
        } else {
            params = DetailZoomParameters()
        }
    }

    func reset() { params = DetailZoomParameters() }

    private func persist() {
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Tuning window

/// Sliders + exact numeric entry for every zoom parameter. Changes apply live
/// to the next open/close.
struct DetailZoomTuningWindow: View {
    @Bindable private var tuning = DetailZoomTuning.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section("Open") {
                Toggle("Ease curve (no bounce) instead of spring", isOn: $tuning.params.openUsesCurve)
                row("Duration (s)",          \.openDuration,  0.15...1.2)
                if tuning.params.openUsesCurve {
                    row("Ease in",           \.openEaseIn,    0...1)
                    row("Ease out",          \.openEaseOut,   0...1)
                } else {
                    row("Bounce",            \.openBounce,    0...0.7)
                    row("Initial kick (dist/s)", \.openKick,  0...12)
                }
            }
            Section("Close spring") {
                row("Duration (s)",          \.closeDuration, 0.15...1.2)
                row("Bounce",                \.closeBounce,   0...0.7)
                row("Initial kick (dist/s)", \.closeKick,     0...12)
            }
            Section("Card art → page dissolve (progress)") {
                row("Fade start",            \.posterFadeStart, 0...1)
                row("Fade end",              \.posterFadeEnd,   0...1)
            }
            Section("Clip") {
                row("Corner radius (pt)",    \.cornerRadius,       0...40)
                row("Hold corners until",    \.cornerHoldUntil,    0...1)
                row("Overreach start",       \.clipOverreachStart, 0...1)
                row("Rest inset (pt)",       \.clipRestInset,      0...600)
            }
            Section("Card & fallback") {
                row("Hover lift (fraction)", \.hoverLift,           0...0.06)
                row("Fallback inset",        \.fallbackInset,       0...0.3)
                row("Fallback page fade end",\.fallbackPageFadeEnd, 0...1)
            }
            Section("Hand-offs (s)") {
                row("Ambient bleed fade",    \.ambientFade, 0...1.5)
                row("Ambient lead (× open)", \.ambientLead, 0...1.5)
                row("Library dissolve",      \.rootFadeDuration, 0.05...1)
                row("Toolbar swap",          \.chromeSwap,  0...1)
                row("Landing crossfade",     \.landingFade, 0...0.6)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(copied ? "Copied" : "Copy as Swift") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tuning.params.swiftLiteral, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Reset", role: .destructive) { tuning.reset() }
            }
        }
        .navigationTitle("Zoom Tuning")
        .frame(minWidth: 520, minHeight: 560)
    }

    private func row(_ title: String,
                     _ key: WritableKeyPath<DetailZoomParameters, Double>,
                     _ range: ClosedRange<Double>) -> some View {
        TuningRow(title: title, value: $tuning.params[dynamicMember: key], range: range)
    }
}

private struct TuningRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 168, alignment: .leading)
            Slider(value: $value, in: range)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
        }
    }
}
