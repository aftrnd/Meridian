import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

private let log = MeridianLog(category: "GamePerformance")

/// Subscribes to MetricKit and records frame-rate / GPU telemetry for
/// diagnostics and data-driven compat ranking (Phase B4).
///
/// ## What MetricKit gives us
///
/// `MXMetricManager` delivers `MXMetricPayload`s that include animation
/// frame-rate (`MXAnimationMetric.scrollHitchTimeRatio`), GPU time
/// (`MXGPUMetric.cumulativeGPUTime`), and — on macOS 27 / GPTK 4 (WWDC26) —
/// Metal frame-rate information. Payloads are delivered by the OS at most once
/// per day and are AGGREGATED across the whole app process, not per game
/// session. So MetricKit is authoritative for "how is Meridian performing
/// overall" but cannot, on its own, attribute a frame rate to a specific
/// game launch.
///
/// ## What we do with it
///
/// 1. Log every received payload's JSON to `logs/metrics/<date>.json` and a
///    one-line summary to `meridian.log`, so overall performance regressions
///    are visible post-hoc without Xcode/Instruments attached.
/// 2. Expose `lastMetalFPS` for the UI/diagnostics.
///
/// Per-game FPS for compat ranking is recorded separately via
/// `CompatVerdictStore.recordFPS` — a developer reading the Metal HUD during a
/// verified play session, or a future `gpucapture`-driven measurement (B5).
/// We deliberately do NOT fabricate per-game attribution from MetricKit's
/// app-level aggregates (development-standards: act on fact, never assume).
@MainActor
final class GamePerformanceMonitor: NSObject {
    static let shared = GamePerformanceMonitor()

    /// The most recent Metal/animation frame-rate MetricKit reported for the
    /// app, if any. App-level aggregate — see the type doc.
    private(set) var lastMetalFPS: Double?

    private var subscribed = false

    private static let metricsDir: URL = {
        LogFileWriter.logsDir.appending(path: "metrics", directoryHint: .isDirectory)
    }()

    /// Begins receiving MetricKit payloads. Idempotent. Call once at launch.
    func start() {
        #if canImport(MetricKit)
        guard !subscribed else { return }
        subscribed = true
        MXMetricManager.shared.add(self)
        log.info("[start] subscribed to MetricKit")
        #else
        log.debug("[start] MetricKit unavailable on this platform")
        #endif
    }

    func stop() {
        #if canImport(MetricKit)
        guard subscribed else { return }
        MXMetricManager.shared.remove(self)
        subscribed = false
        #endif
    }
}

#if canImport(MetricKit)
extension GamePerformanceMonitor: MXMetricManagerSubscriber {
    // MXMetricManagerSubscriber is nonisolated; hop back to the main actor to
    // touch `lastMetalFPS` and shared state.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            Task { @MainActor in self.persist(json) }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            Task { @MainActor in self.persist(json, prefix: "diagnostic") }
        }
    }

    private func persist(_ json: Data, prefix: String = "metric") {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.metricsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = Self.metricsDir.appending(path: "\(prefix)-\(stamp).json")
        try? json.write(to: dest, options: .atomic)

        // Best-effort: pull an animation/GPU frame-rate hint out of the JSON so
        // a one-liner lands in meridian.log without hand-opening the payload.
        // Field names differ across OS versions, so we scan defensively rather
        // than decode a fixed schema (which would break across macOS releases).
        if let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let fps = Self.extractFPS(from: obj) {
            lastMetalFPS = fps
            log.info("[metric] avg frame rate ≈ \(String(format: "%.1f", fps)) fps (app-level aggregate) → \(dest.lastPathComponent)")
        } else {
            log.info("[metric] payload saved → \(dest.lastPathComponent)")
        }
    }

    /// Defensive FPS extraction: walks the payload dictionary for any key that
    /// looks like a frames-per-second average. MetricKit's Metal frame-rate
    /// schema is new (macOS 27) and may shift, so we don't hard-code a path.
    private static func extractFPS(from obj: [String: Any]) -> Double? {
        var found: Double?
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                for (k, v) in dict {
                    let lk = k.lowercased()
                    if found == nil, lk.contains("framerate") || lk.contains("frames_per_second") || lk.contains("fps") {
                        if let d = v as? Double { found = d }
                        else if let n = v as? NSNumber { found = n.doubleValue }
                    }
                    walk(v)
                }
            } else if let arr = any as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(obj)
        return found
    }
}
#endif
