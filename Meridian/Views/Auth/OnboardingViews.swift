import SwiftUI

private let log = MeridianLog(category: "Onboarding")

// MARK: - Step dots

/// Page indicator: the current step stretches into a pill.
struct OnboardingStepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.35), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Hero art

/// The Meridian logo coming into focus on the plain window background
/// (Welcome step). The logo itself never moves.
struct OnboardingLogoHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Image("MeridianLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 110)
            .foregroundStyle(.primary)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .blur(radius: shown || reduceMotion ? 0 : 10)
            .opacity(shown ? 1 : 0)
            .frame(height: 130)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { shown = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Entrance

/// One-time entrance: content settles in (fade, a slight rise, focus pull).
/// A plain fade under Reduce Motion.
private struct OnboardingEntrance: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .blur(radius: shown || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(.easeOut(duration: 0.7).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func onboardingEntrance(delay: Double = 0) -> some View {
        modifier(OnboardingEntrance(delay: delay))
    }
}

// MARK: - Page layout

enum OnboardingMetrics {
    /// Height of every step's bottom action bar; `SetupSheet` centres the
    /// page dots on it.
    static let actionBarHeight: CGFloat = 32
}

/// One onboarding step, laid out like macOS Setup Assistant: hero, title,
/// subtitle and the step's content centred as one group, actions pinned to
/// the bottom (secondary leading, primary trailing). Each part settles in
/// a beat after the one above it.
struct OnboardingPage<Hero: View, Content: View, Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let hero: Hero
    private let content: Content
    private let actions: Actions

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.hero = hero()
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                if Hero.self != EmptyView.self {
                    hero.onboardingEntrance(delay: 0.05)
                }

                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 400)
                            .contentTransition(.opacity)
                    }
                }
                .onboardingEntrance(delay: 0.15)

                if Content.self != EmptyView.self {
                    content.onboardingEntrance(delay: 0.25)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 20)

            HStack(spacing: 12) { actions }
                .frame(height: OnboardingMetrics.actionBarHeight)
        }
    }
}

// MARK: - Checkmark

/// A tick drawn as one stroke, for `trim`-based drawing.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.36))
        return path
    }
}

/// A disc that springs in, then a tick that draws itself across it.
struct DrawnCheckmark: View {
    var size: CGFloat = 64
    var tint: Color = .green
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.gradient)
                .shadow(color: tint.opacity(0.4), radius: size * 0.2, y: size * 0.06)
            CheckmarkShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .onAppear {
            if reduceMotion {
                shown = true
                drawn = true
                return
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58).delay(delay)) { shown = true }
            withAnimation(.easeOut(duration: 0.32).delay(delay + 0.2)) { drawn = true }
        }
        .accessibilityHidden(true)
    }
}

/// A ring that flashes out from behind a success mark and fades.
struct RippleBurst: View {
    var tint: Color = .green
    var size: CGFloat
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fired = false

    private struct Values {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 2)
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: Values(), trigger: fired) { ring, value in
                ring.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: 0)
                    CubicKeyframe(2.1, duration: 1.0)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.7, duration: 0)
                    CubicKeyframe(0, duration: 1.0)
                }
            }
            .task {
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .seconds(delay))
                fired = true
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Complete step: the tick draws itself while two rings ripple outward.
struct OnboardingCompleteHero: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.gradient)
                .frame(width: 120, height: 120)
                .blur(radius: 44)
                .opacity(0.35)
            RippleBurst(size: 96, delay: 0.3)
            RippleBurst(size: 96, delay: 0.55)
            DrawnCheckmark(size: 96, delay: 0.1)
        }
        .frame(height: 140)
    }
}

// MARK: - QR code

/// The sign-in QR drawn module by module, so it can assemble itself: the
/// first code grows in from the centre outward, and once the phone has
/// scanned it the modules dissolve outward the same way. At rest every
/// module is a plain, pixel-aligned black square, so scanning is never
/// affected. Steam rotates the code about every 30 s; rotations swap in
/// place.
struct OnboardingQRCode: View {
    let payload: String?
    let scanned: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modules: [[Bool]] = []
    @State private var revealStart = Date.distantPast
    @State private var dissolveStart: Date?
    @State private var animating = false
    @State private var animationID = 0

    private static let revealDuration = 0.9
    private static let dissolveDuration = 0.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { context in
            // Outside an animation everything is settled: fully drawn, or
            // fully dissolved once scanned.
            let now = animating ? context.date : .distantFuture
            Canvas { canvas, size in draw(in: &canvas, size: size, now: now) }
        }
        .onChange(of: payload, initial: true) { _, newPayload in
            let assemble = modules.isEmpty
            modules = newPayload.flatMap(QRCodeRenderer.modules(for:)) ?? []
            guard assemble, !modules.isEmpty, !reduceMotion else { return }
            // A beat after the step slides in.
            revealStart = Date().addingTimeInterval(0.3)
            animate(for: 0.3 + Self.revealDuration)
        }
        .onChange(of: scanned) { _, isScanned in
            dissolveStart = isScanned ? Date() : nil
            if isScanned { animate(for: Self.dissolveDuration) }
        }
        .accessibilityHidden(true)
    }

    private func animate(for duration: Double) {
        guard !reduceMotion else { return }
        animationID &+= 1
        let id = animationID
        animating = true
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.1))
            if animationID == id { animating = false }
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let count = modules.count
        guard count > 0 else { return }
        // Whole-point modules land on device pixels: no seams between them.
        let module = (min(size.width, size.height) / CGFloat(count)).rounded(.down)
        let side = module * CGFloat(count)
        let originX = ((size.width - side) / 2).rounded()
        let originY = ((size.height - side) / 2).rounded()

        let reveal = Self.progress(since: revealStart, duration: Self.revealDuration, now: now)
        let dissolve = dissolveStart.map { Self.progress(since: $0, duration: Self.dissolveDuration, now: now) } ?? 0
        let mid = Double(count - 1) / 2
        let farthest = max((2 * mid * mid).squareRoot(), 1)

        var settled = Path()
        for (row, cells) in modules.enumerated() {
            for (col, dark) in cells.enumerated() where dark {
                let distance = hypot(Double(col) - mid, Double(row) - mid) / farthest
                let amount = Self.wave(reveal, at: distance) * (1 - Self.wave(dissolve, at: distance))
                guard amount > 0 else { continue }
                let x = originX + CGFloat(col) * module
                let y = originY + CGFloat(row) * module
                if amount >= 1 {
                    settled.addRect(CGRect(x: x, y: y, width: module, height: module))
                } else {
                    let s = module * CGFloat(amount)
                    let rect = CGRect(x: x + (module - s) / 2, y: y + (module - s) / 2, width: s, height: s)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: s * 0.35), with: .color(.black.opacity(amount)))
                }
            }
        }
        canvas.fill(settled, with: .color(.black))
    }

    private static func progress(since start: Date, duration: Double, now: Date) -> Double {
        min(max(now.timeIntervalSince(start) / duration, 0), 1)
    }

    /// 0 → 1 as a wave front travelling outward passes `distance`
    /// (0 = centre, 1 = corner), smoothstepped.
    private static func wave(_ t: Double, at distance: Double) -> Double {
        let x = min(max((t * 1.6 - distance) / 0.6, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// Camera-style corners framing the QR card. They breathe while waiting for
/// a scan, then snap in and turn green when the phone has scanned.
private struct ScanBrackets: View {
    let scanned: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scanned)) { context in
            let breath = reduceMotion || scanned ? 0 : (sin(context.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
            BracketCorners()
                .stroke(scanned ? Color.green : Color.accentColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .opacity(scanned ? 1 : 0.5 + 0.5 * breath)
                .scaleEffect(scanned ? 0.96 : 1 + 0.016 * breath)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.55), value: scanned)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BracketCorners: Shape {
    var length: CGFloat = 50
    var radius: CGFloat = 40

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addArc(tangent1End: corner, tangent2End: CGPoint(x: corner.x + dx * length, y: corner.y), radius: radius)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// The QR on a white card inside the scan corners: a spinner while the
/// first code loads, "New Code" once a session has ended, and a drawn tick
/// over the dissolving code after the phone scans it.
struct OnboardingQRCard: View {
    let payload: String?
    let scanned: Bool
    let ended: Bool
    let onNewCode: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)

            OnboardingQRCode(payload: payload, scanned: scanned)
                .frame(width: 174, height: 174)

            if payload == nil {
                if ended {
                    Button("New Code", systemImage: "arrow.clockwise", action: onNewCode)
                        .controlSize(.large)
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .transition(.opacity)
                }
            }

            if scanned {
                VStack(spacing: 12) {
                    DrawnCheckmark(size: 64, delay: 0.25)
                    Text("Approve on your phone")
                        .font(.headline)
                        .foregroundStyle(.black.opacity(0.85))
                        .onboardingEntrance(delay: 0.45)
                }
            }
        }
        .frame(width: 220, height: 220)
        // White in both appearances; keep its contents legible.
        .environment(\.colorScheme, .light)
        .padding(16)
        .overlay { ScanBrackets(scanned: scanned) }
        .animation(.smooth(duration: 0.3), value: payload == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(scanned ? "Code scanned. Approve on your phone." : "Sign-in code for the Steam Mobile App")
    }
}

// MARK: - Online Play art

/// Meridian's mark on a still glass disc inside a ring that tells the story
/// of connecting Steam. Idle, a faint light circles the ring; it fills with
/// the Steam download, sweeps while Steam starts and signs in, and closes in
/// green with a burst and a drawn tick when done.
struct OnlinePlayArt: View {
    enum Stage: Equatable {
        case idle
        case downloading(Double)
        case waiting
        case done
    }

    let stage: Stage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ring: CGFloat = 132

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.14), lineWidth: 5)
                    .frame(width: Self.ring, height: Self.ring)
                progressRing(spin: t)
                    .frame(width: Self.ring, height: Self.ring)
                if stage == .done {
                    RippleBurst(size: Self.ring)
                }
                disc
            }
            .frame(width: 170, height: 150)
        }
        .animation(.smooth(duration: 0.6), value: stage)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func progressRing(spin t: TimeInterval) -> some View {
        let style = StrokeStyle(lineWidth: 5, lineCap: .round)
        let comet = AngularGradient(colors: [Color.accentColor.opacity(0), Color.accentColor], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(108))
        switch stage {
        case .idle:
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(comet, style: style)
                .opacity(0.45)
                .rotationEffect(.degrees(t * 45))
        case .downloading(let fraction):
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.accentColor, style: style)
                .rotationEffect(.degrees(-90))
        case .waiting:
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(comet, style: style)
                .rotationEffect(.degrees(t * 170))
        case .done:
            Circle()
                .stroke(Color.green, style: style)
        }
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            Image("MeridianLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52)
                .foregroundStyle(.primary)
        }
        .frame(width: 112, height: 112)
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .overlay(alignment: .bottomTrailing) {
            if stage == .done {
                DrawnCheckmark(size: 34, delay: 0.15)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-3))
                    .offset(x: 6, y: 6)
            }
        }
    }
}

// MARK: - Online Play step

/// Connects the real Steam client once: Steam's own sign-in opens over
/// Meridian (`SteamSession.signInInteractively` + `SteamWindow.beginSignIn`),
/// and Steam persists its session so every later launch is silent. A live
/// checklist follows `SteamSession.signInPhase`, `SteamSession.clientDownload`
/// and `SteamWindow.isSignInWindowShown`.
struct OnlinePlayStepContent: View {
    let onDone: () -> Void
    let onSkip: () -> Void

    @Environment(SteamSession.self) private var session
    @Environment(WineEngine.self) private var engine
    @Environment(SteamWindow.self) private var steamWindow

    private enum Phase: Equatable { case intro, connecting, connected, failed }

    /// Checklist rows, in the order a first sign-in goes through them.
    private enum Row: Int, CaseIterable {
        case download, install, start, scan, save
    }

    private enum RowState { case pending, active, done, failed }

    @State private var phase: Phase = .intro
    @State private var connectTask: Task<Void, Never>?
    /// Furthest row reached. Latched so a row never un-ticks, e.g. while
    /// Steam's window hides between signing in and saving its session.
    @State private var reached: Row = .download

    /// The row the running sign-in is on. Steps a returning Mac doesn't need
    /// (Steam already downloaded) are skipped, so they show as done.
    private var liveRow: Row {
        if session.signInPhase == .finishing { return .save }
        if steamWindow.isSignInWindowShown { return .scan }
        switch session.signInPhase {
        case .installing: return .install
        case .starting, .updating: return .start
        case .downloading, .finishing, nil: return .download
        }
    }

    private var artStage: OnlinePlayArt.Stage {
        switch phase {
        case .intro, .failed: return .idle
        case .connected: return .done
        case .connecting:
            if let download = session.clientDownload { return .downloading(download.fraction) }
            return .waiting
        }
    }

    var body: some View {
        OnboardingPage(phase == .connected ? "Steam is signed in" : "Sign in to Steam", subtitle: message) {
            OnlinePlayArt(stage: artStage)
        } content: {
            if phase != .intro {
                checklist
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        } actions: {
            controls
        }
        .animation(.smooth(duration: 0.4), value: phase)
        .animation(.smooth(duration: 0.3), value: reached)
        .onChange(of: liveRow) { _, row in
            if phase == .connecting, row.rawValue > reached.rawValue { reached = row }
        }
        .onDisappear { connectTask?.cancel() }
    }

    private var message: String {
        switch phase {
        case .intro:
            return "Your games run through Steam, so Steam signs in once on this Mac. After that it signs itself in and stays out of sight."
        case .connecting:
            return reached == .scan
                ? "Use the Steam Mobile App to scan the code in Steam's window."
                : "Getting Steam ready. This only happens once."
        case .connected:
            return "From now on Steam signs itself in."
        case .failed:
            return "Steam's sign-in didn't finish. Try again, or sign in later when a game needs Steam."
        }
    }

    // MARK: Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(visibleRows.enumerated()), id: \.element) { index, row in
                checklistRow(row)
                    .onboardingEntrance(delay: 0.05 * Double(index))
            }
        }
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var visibleRows: [Row] {
        Row.allCases.filter { $0 != .scan || reached.rawValue >= Row.scan.rawValue }
    }

    private func checklistRow(_ row: Row) -> some View {
        let state = state(of: row)
        return HStack(spacing: 10) {
            ZStack {
                switch state {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                case .active:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 15, weight: .medium))
            .frame(width: 18, height: 18)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: state)

            Text(title(of: row))
                .font(.system(size: 13))
                .foregroundStyle(state == .pending ? HierarchicalShapeStyle.tertiary : .primary)

            Spacer(minLength: 8)

            if state == .active, let detail = detail(of: row) {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func state(of row: Row) -> RowState {
        if phase == .connected || row.rawValue < reached.rawValue { return .done }
        if row.rawValue > reached.rawValue { return .pending }
        return phase == .failed ? .failed : .active
    }

    private func title(of row: Row) -> String {
        switch row {
        case .download: return "Download Steam"
        case .install: return "Install Steam"
        case .start: return "Start Steam"
        case .scan: return "Scan the code in Steam's window"
        case .save: return "Save your sign-in"
        }
    }

    private func detail(of row: Row) -> String? {
        switch row {
        case .download:
            guard let download = session.clientDownload else { return nil }
            return "\(download.received.formatted(.byteCount(style: .file))) of \(download.total.formatted(.byteCount(style: .file)))"
        case .start:
            return session.signInPhase == .updating ? "Updating" : nil
        case .install, .scan, .save:
            return nil
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .intro, .failed:
            Button("Later") { onSkip() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(phase == .intro ? "Sign In to Steam" : "Try Again") { connect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .connecting:
            Button("Cancel") { connectTask?.cancel() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if steamWindow.isSignInWindowShown {
                Button("Show Steam's Window") { steamWindow.bringSignInForward() }
                    .buttonStyle(.link)
            }
        case .connected:
            Spacer()
            Button("Continue") { onDone() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func connect() {
        reached = .download
        phase = .connecting
        connectTask = Task {
            do {
                try await session.signInInteractively(engine: engine)
                phase = .connected
                try? await Task.sleep(for: .seconds(1.8))
                if !Task.isCancelled { onDone() }
            } catch {
                // Cancel (or a cancelled wait surfacing as steamNotReady):
                // tear Steam down so no sign-in window is left on screen.
                if Task.isCancelled || error is CancellationError {
                    await session.shutdown(engine: engine)
                    phase = .intro
                    return
                }
                log.warning("[onlinePlay] Steam sign-in failed: \(error.localizedDescription)")
                phase = .failed
            }
        }
    }
}
