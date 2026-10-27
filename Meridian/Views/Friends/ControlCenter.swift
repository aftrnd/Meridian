import SwiftUI

private let log = MeridianLog(category: "ControlCenter")

// MARK: - Toolbar button

/// Meridian's Control Center, as tvOS's: Control Center's own glyph in a
/// standard glass circle in Home's toolbar corner, opening the panel in the
/// window's corner below it. It's there from launch; while Steam connects,
/// the glyph's switches flip back and forth.
struct ControlCenterButton: View {
    @Binding var isPresented: Bool

    @Environment(SteamSession.self) private var session
    /// The drawn switches stand in for the symbol: from when Steam starts
    /// connecting until they're back in the symbol's pose, so the swap
    /// either way is between identical glyphs and never shows.
    @State private var drawn = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "switch.2")
                .opacity(drawn ? 0 : 1)
                .overlay {
                    if drawn {
                        ConnectingSwitches(isConnecting: session.isConnecting) {
                            drawn = session.isConnecting
                        }
                    }
                }
                // Square label frame, so the glass is a circle like Friends'.
                .frame(width: 24, height: 24)
        }
        .help(session.isConnecting ? "Control Center (connecting to Steam…)" : "Control Center")
        .accessibilityLabel("Control Center")
        .onChange(of: session.isConnecting, initial: true) { _, connecting in
            if connecting { drawn = true }
        }
    }
}

/// `switch.2` drawn so its switches can move: one after the other they flip
/// across and back while Steam connects, and once it has, they glide home
/// from wherever they are. To the symbol's own proportions (measured from a
/// 400 pt render, whose image is 473 × 439), fitted to the symbol image's
/// frame, so the resting pose is the symbol's.
private struct ConnectingSwitches: View {
    let isConnecting: Bool
    /// Called once the switches are home after Steam connects.
    var onSettled: () -> Void

    private struct Settle {
        let date: Date
        let top: Double
        let bottom: Double
    }
    private static let settleDuration = 0.35

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    /// When Steam connected, and where the switches were then.
    @State private var settle: Settle?

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let pose = pose(at: timeline.date)
            // A filled shape takes the toolbar glass's vibrant label style; a
            // Canvas can't draw it itself (glyphs drawn in glass came out blank).
            Rectangle()
                .fill(.foreground)
                .mask {
                    Canvas { context, size in
                        let scale = min(size.width / 473, size.height / 439)
                        context.translateBy(x: (size.width - 473 * scale) / 2, y: (size.height - 439 * scale) / 2)
                        context.scaleBy(x: scale, y: scale)
                        Self.draw(in: &context, top: pose.top, bottom: pose.bottom)
                    }
                }
        }
        .onChange(of: isConnecting, initial: true) { _, connecting in
            if connecting {
                start = .now
                settle = nil
            } else {
                let t = Date.now.timeIntervalSince(start)
                settle = Settle(date: .now, top: Self.flip(t), bottom: Self.flip(t - 0.25))
            }
        }
        .task(id: settle?.date) {
            guard settle != nil else { return }
            try? await Task.sleep(for: .seconds(Self.settleDuration))
            if !Task.isCancelled { onSettled() }
        }
    }

    private func pose(at date: Date) -> (top: Double, bottom: Double) {
        if reduceMotion { return (0, 0) }
        if let settle {
            let away = 1 - Self.easeOut(min(1, date.timeIntervalSince(settle.date) / Self.settleDuration))
            return (settle.top * away, settle.bottom * away)
        }
        let t = date.timeIntervalSince(start)
        return (Self.flip(t), Self.flip(t - 0.25))
    }

    /// 0 at the symbol's pose, 1 flipped. Each switch crosses in half a
    /// second and rests a beat on either side.
    private static func flip(_ t: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: 2) + (t < 0 ? 2 : 0)
        if phase < 0.5 { return easeInOut(phase / 0.5) }
        if phase < 1 { return 1 }
        if phase < 1.5 { return 1 - easeInOut((phase - 1) / 0.5) }
        return 0
    }

    /// The top switch is an outlined track with its knob on the left, the
    /// bottom one a filled track with its knob cut out on the right. Each
    /// knob keeps its gap inside the track as it travels.
    private static func draw(in context: inout GraphicsContext, top: Double, bottom: Double) {
        let track = Path(roundedRect: CGRect(x: 65, y: 50, width: 342, height: 149), cornerRadius: 74.5)
        context.stroke(track, with: .color(.black), lineWidth: 30)
        let knob = CGRect(x: 94 + 131 * top, y: 78, width: 153, height: 93)
        context.fill(Path(roundedRect: knob, cornerRadius: 46.5), with: .color(.black))

        context.drawLayer { layer in
            layer.fill(Path(roundedRect: CGRect(x: 50, y: 244, width: 372, height: 160), cornerRadius: 80), with: .color(.black))
            layer.blendMode = .destinationOut
            let hole = CGRect(x: 230 - 152 * bottom, y: 273, width: 164, height: 101)
            layer.fill(Path(roundedRect: hole, cornerRadius: 50.5), with: .color(.black))
        }
    }

    private static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

// MARK: - Panel presentation

/// The panel's place in the window: the top-right corner under the toolbar
/// button, over the page, the way tvOS opens Control Center in the screen's
/// corner rather than in a popover. As around a popover, the page still
/// scrolls while it's open, and a click anywhere else in the window closes
/// it. Esc steps back out of the statuses first, then closes.
///
/// A modifier rather than state in the window's view, so opening and
/// closing re-evaluate only this.
struct ControlCenterPresenter: ViewModifier {
    @Binding var isPresented: Bool
    var onViewProfile: () -> Void

    @Environment(SteamSession.self) private var session
    @State private var statusesOpen = false
    /// The panel's frame in the window (SwiftUI's global space).
    @State private var panelFrame: CGRect = .zero
    @State private var outsideClicks = OutsideClickMonitor()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                ZStack(alignment: .topTrailing) {
                    if isPresented {
                        Button("Close Control Center") {
                            if statusesOpen { statusesOpen = false } else { isPresented = false }
                        }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    }

                    ControlCenterPanel(isPresented: isPresented,
                                       statusesOpen: $statusesOpen,
                                       close: { isPresented = false },
                                       onViewProfile: {
                                           isPresented = false
                                           onViewProfile()
                                       })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
                    .padding(.top, ControlCenterPanel.topInset)
                    .padding(.trailing, ControlCenterPanel.trailingInset)
                }
                .animation(.smooth(duration: 0.3), value: isPresented)
                // The Steam Status capsule's glass grows into the statuses
                // card and back.
                .animation(.spring(duration: 0.4, bounce: 0.12), value: statusesOpen)
            }
            .onChange(of: isPresented) { _, presented in
                if presented {
                    // The click that opened it made this window key.
                    outsideClicks.install(window: NSApp.keyWindow) { point in
                        guard !isOnPanel(point) else { return false }
                        isPresented = false
                        return true
                    }
                    Task { await session.syncPersonaState() }
                } else {
                    outsideClicks.remove()
                    // It opens on the grid next time. The leaving panel is
                    // already frozen as it was, so this doesn't show.
                    statusesOpen = false
                }
            }
            .onChange(of: session.isReady) { _, ready in
                if !ready { statusesOpen = false }
            }
            .onDisappear { outsideClicks.remove() }
    }

    /// Whether `point` (window, y down) is on the panel's glass: the grid,
    /// or the statuses card while it's open.
    private func isOnPanel(_ point: CGPoint) -> Bool {
        CGRect(origin: panelFrame.origin,
               size: CGSize(width: Grid.width, height: statusesOpen ? StatusesCard.height : Grid.height))
            .contains(point)
    }
}

/// Closes Control Center on a click anywhere else in its window, as a menu
/// or popover closes, and spends the click on that. A local monitor rather
/// than a view over the page: the wheel goes to the view under the pointer,
/// so a view there stopped the page scrolling.
@MainActor
private final class OutsideClickMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?

    /// `handle` gets each click in `window` (SwiftUI's global space, y down)
    /// and returns whether it spent it.
    func install(window: NSWindow?, handle: @escaping @MainActor (CGPoint) -> Bool) {
        remove()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Monitors run on the main thread; assumeIsolated's result must be
            // Sendable, hence the Bool round-trip rather than returning the event.
            let spent = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window,
                      let content = window.contentView else { return false }
                let p = event.locationInWindow
                return handle(CGPoint(x: p.x, y: content.bounds.height - p.y))
            }
            return spent ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Panel

/// The panel's measurements.
private enum Grid {
    static let gap: CGFloat = 8
    /// A 30 pt well with 11 pt around it.
    static let tileHeight: CGFloat = 52
    /// Two tiles and the gap between them, so the profile is square.
    static let column = tileHeight * 2 + gap
    static let width = column * 2 + gap
    static let height = column + gap + tileHeight
}

private enum Module: Hashable, CaseIterable {
    case profile, status, hud, controllers, updates, settings, power

    /// Where it sits in the grid; the grid's stacks lay them out the same.
    var frame: CGRect {
        let right = Grid.column + Grid.gap
        let bottom = Grid.column + Grid.gap
        switch self {
        case .profile:     return CGRect(x: 0, y: 0, width: Grid.column, height: Grid.column)
        case .status:      return CGRect(x: right, y: 0, width: Grid.column, height: Grid.tileHeight)
        case .hud:         return CGRect(x: right, y: Grid.tileHeight + Grid.gap, width: Grid.column, height: Grid.tileHeight)
        // Shortcuts are one grid unit each: a circle as tall as a capsule.
        case .controllers: return CGRect(x: 0, y: bottom, width: Grid.tileHeight, height: Grid.tileHeight)
        case .updates:     return CGRect(x: Grid.tileHeight + Grid.gap, y: bottom, width: Grid.tileHeight, height: Grid.tileHeight)
        case .settings:    return CGRect(x: (Grid.tileHeight + Grid.gap) * 2, y: bottom, width: Grid.tileHeight, height: Grid.tileHeight)
        case .power:       return CGRect(x: (Grid.tileHeight + Grid.gap) * 3, y: bottom, width: Grid.tileHeight, height: Grid.tileHeight)
        }
    }

    var shape: AnyShape {
        switch self {
        case .profile:      AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .status, .hud: AnyShape(Capsule())
        default:            AnyShape(Circle())
        }
    }
}

/// What has the pointer: a module, or in the statuses card its header or a status.
private enum Hover: Hashable {
    case module(Module)
    case header
    case status(SteamSession.PersonaState)
}

/// tvOS 26's Control Center: Liquid Glass modules floating over the page, in
/// tvOS 17's grid. The player is the large square (it opens the profile).
/// Steam Status works like macOS's Focus module: one capsule with the
/// current status, whose glass grows into a card of all four. Then the
/// Metal HUD toggle, shortcuts to Game Controllers, Updates and Settings,
/// and Steam's power.
///
/// Two layers in one grid: the glass modules, which are the buttons, and
/// their content above them. Glass draws what's in it additively in dark
/// mode, which lifted a status's colour with whatever the panel was over
/// (Steam's yellow came out lemon, the green mint), and a glass container
/// draws its glass over anything else inside it. So the content sits in its
/// own layer, over the container, where its colours are exact.
///
/// The glass container stays in place while the panel is closed, so the
/// modules come and go inside it with glass's own transition. Its frame is
/// fixed: a container collapsing around its leaving modules would move them.
///
/// One module at a time has the pointer, as tvOS has one focused item. Focus
/// comes from the pointer's position over the whole grid, gaps going to the
/// nearer module, so moving between them is a single change rather than an
/// exit and an enter that can cross.
private struct ControlCenterPanel: View {
    let isPresented: Bool
    @Binding var statusesOpen: Bool
    var close: () -> Void
    var onViewProfile: () -> Void

    /// Lines the panel's edge up with the toolbar button's glass.
    static let trailingInset: CGFloat = 9
    /// The button's glass sits 7.5 pt below the window's top edge, and the
    /// page's top 9.5 pt below the button (measured at 2x, macOS 27.2): the
    /// panel rises into that so it's as far below the button as the button
    /// is below the edge.
    static let topInset: CGFloat = -2

    /// System Settings shows its Game Controllers pane only once a
    /// controller has connected (the pane's own predicate: `showGCPrefsPane`
    /// in com.apple.GameController); before that a link to it lands on
    /// General, so Bluetooth opens instead, to pair one. Both panes take
    /// x-apple.systempreferences links (their Info.plists, macOS 27.2;
    /// Bluetooth's opened from here on Oct 27 2026).
    private static var controllersPaneShown: Bool {
        UserDefaults(suiteName: "com.apple.GameController")?.bool(forKey: "showGCPrefsPane") == true
    }

    private static var controllersSettingsURL: URL {
        URL(string: "x-apple.systempreferences:" + (controllersPaneShown ? "com.apple.Game-Controller-Settings.extension" : "com.apple.BluetoothSettings"))!
    }

    @Environment(SteamSession.self) private var session
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(WineEngine.self) private var engine
    @Environment(AppUpdateChecker.self) private var updateChecker
    @Environment(Launcher.self) private var launcher
    @AppStorage("metalHUD") private var metalHUD = false
    /// Steam is on its way down (its shutdown waits up to 15 s for it).
    @State private var stoppingSteam = false
    @Namespace private var glassSpace
    @State private var hovered: Hover?
    /// The pointer's last place, out of state: it moves far more often than
    /// focus changes, and opening the statuses needs it to find the new focus.
    @State private var pointer = PointerPlace()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPresented {
                PanelHalo(statusesOpen: statusesOpen)
                    .transition(.opacity.animation(.smooth(duration: 0.35)))
            }
            glass {
                if isPresented {
                    if statusesOpen {
                        Color.clear
                            .modifier(TileGlass(shape: StatusesCard.shape, interactive: false, id: .status, space: glassSpace))
                            .frame(width: Grid.width, height: StatusesCard.height)
                    } else {
                        grid { module in
                            Button { activate(module) } label: { Color.clear }
                                .buttonStyle(TileStyle(module: module,
                                                       isFocused: hovered == .module(module) && isAvailable(module),
                                                       glassSpace: glassSpace))
                                .disabled(!isAvailable(module))
                                .help(help(for: module))
                                .accessibilityLabel(accessibilityLabel(for: module))
                        }
                    }
                }
            }
            if isPresented {
                if statusesOpen {
                    StatusesCard(hovered: hovered, onBack: { statusesOpen = false }, onPick: setStatus)
                        .transition(Self.contentTransition)
                } else {
                    grid { module in content(of: module) }
                        // The glass under it takes the pointer and speaks for it.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(Self.contentTransition)
                }
            }
        }
        .frame(width: Grid.width, height: StatusesCard.height, alignment: .topLeading)
        // A click between modules is the panel's, not the page's under it;
        // below the grid the page's own.
        .contentShape(Rectangle().size(width: Grid.width, height: statusesOpen ? StatusesCard.height : Grid.height))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointer.point = point
            case .ended: pointer.point = nil
            }
            refocus()
        }
        .allowsHitTesting(isPresented)
        .onChange(of: statusesOpen) { refocus() }
    }

    /// Content comes in once its glass has begun to, and goes at once.
    private static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.smooth(duration: 0.2).delay(0.1)),
        removal: .opacity.animation(.smooth(duration: 0.1)))

    /// The grid's layout, for both layers.
    private func grid<T: View>(@ViewBuilder _ module: (Module) -> T) -> some View {
        VStack(spacing: Grid.gap) {
            HStack(spacing: Grid.gap) {
                cell(.profile, module)
                VStack(spacing: Grid.gap) {
                    cell(.status, module)
                    cell(.hud, module)
                }
            }
            HStack(spacing: Grid.gap) {
                cell(.controllers, module)
                cell(.updates, module)
                cell(.settings, module)
                cell(.power, module)
            }
        }
    }

    private func cell<T: View>(_ module: Module, _ view: (Module) -> T) -> some View {
        view(module).frame(width: module.frame.width, height: module.frame.height)
    }

    @ViewBuilder
    private func content(of module: Module) -> some View {
        switch module {
        case .profile:
            ProfileContent(isFocused: hovered == .module(.profile))
        case .status:
            StatusModuleContent(state: session.isReady ? session.personaState : nil,
                                note: session.isConnecting ? "Starting…" : "Off")
        case .hud:
            ToggleContent(symbol: "gauge.with.needle", title: "HUD", isOn: metalHUD)
        case .controllers:
            ShortcutContent(symbol: "gamecontroller")
        case .updates:
            ShortcutContent(symbol: "arrow.down.circle", badge: updateChecker.hasUpdate)
        case .settings:
            ShortcutContent(symbol: "slider.horizontal.3")
        case .power:
            ShortcutContent(symbol: "power", isEnabled: isAvailable(.power))
        }
    }

    private func refocus() {
        let next = pointer.point.flatMap { Self.hover(at: $0, statusesOpen: statusesOpen) }
        if next != hovered { hovered = next }
    }

    /// What's under `point`: in the grid the nearest module, so gaps go to
    /// the nearer side; in the card its header or a status row.
    private static func hover(at point: CGPoint, statusesOpen: Bool) -> Hover? {
        if statusesOpen {
            guard point.x >= 0, point.x <= Grid.width else { return nil }
            let row = Int(floor((point.y - StatusesCard.inset) / StatusesCard.rowHeight))
            if row == 0 { return .header }
            return StatusesCard.order.indices.contains(row - 1) ? .status(StatusesCard.order[row - 1]) : nil
        }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        guard let nearest = Module.allCases.min(by: { distance($0.frame) < distance($1.frame) }),
              distance(nearest.frame) <= Grid.gap else { return nil }
        return .module(nearest)
    }

    private func isAvailable(_ module: Module) -> Bool {
        switch module {
        case .status:
            return session.isReady
        case .power:
            // Quitting Steam stops every Wine process, a running game's too;
            // and only a Mac signed in to Steam can start it from here.
            return !launcher.isBusy && !stoppingSteam && !session.isConnecting
                && (session.isReady || AppSettings.shared.steamClientSignedIn)
        default:
            return true
        }
    }

    private func activate(_ module: Module) {
        switch module {
        case .profile:
            onViewProfile()
        case .status:
            statusesOpen = true
        case .hud:
            metalHUD.toggle()
        case .controllers:
            close()
            NSWorkspace.shared.open(Self.controllersSettingsURL)
        case .updates:
            close()
            updateChecker.checkAndShow(installedEngineTag: engine.engineVersion)
        case .settings:
            close()
            NotificationCenter.default.post(name: .meridianOpenSettings, object: nil)
        case .power:
            if session.isReady {
                stoppingSteam = true
                Task {
                    await session.shutdown(engine: engine)
                    stoppingSteam = false
                }
            } else {
                session.warmUp(engine: engine)
            }
        }
    }

    private func setStatus(_ state: SteamSession.PersonaState) {
        do {
            try session.setPersonaState(state, engine: engine)
        } catch {
            log.error("[setStatus] couldn't set \(state.title): \(error.localizedDescription)")
        }
    }

    private func help(for module: Module) -> String {
        switch module {
        case .profile:     "View Profile"
        case .status:      session.isReady ? "Steam Status" : session.isConnecting ? "Connecting to Steam…" : "Steam isn't running"
        case .hud:         "Metal Performance HUD: frame rate and GPU statistics in the games you start"
        case .controllers: Self.controllersPaneShown ? "Game Controllers in System Settings" : "Pair a controller in Bluetooth settings"
        case .updates:     updateChecker.hasUpdate ? "An update is ready" : "Check for Updates"
        case .settings:    "Meridian Settings"
        case .power:       powerHelp
        }
    }

    private var powerHelp: String {
        if launcher.isBusy { return "Steam stays on while a game is running" }
        if stoppingSteam { return "Quitting Steam…" }
        if session.isConnecting { return "Starting Steam…" }
        return session.isReady ? "Quit Steam" : "Start Steam"
    }

    private func accessibilityLabel(for module: Module) -> String {
        switch module {
        case .profile:     "\(steamAuth.displayName), View Profile"
        case .status:      "Steam Status, \(session.personaState?.title ?? "not connected")"
        case .hud:         "Metal HUD, \(metalHUD ? "On" : "Off")"
        case .controllers: "Game Controllers"
        case .updates:     updateChecker.hasUpdate ? "Updates, update ready" : "Updates"
        case .settings:    "Settings"
        case .power:       session.isReady ? "Quit Steam" : "Start Steam"
        }
    }

    /// The modules' glass rendered together, as Apple's glass guidance asks,
    /// with no spacing so neighbours never melt into one another.
    @ViewBuilder
    private func glass(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0, content: content)
        } else {
            content()
        }
    }
}

private final class PointerPlace {
    var point: CGPoint?
}

/// The page darkens a little around the panel: from the modules' own edges
/// (the card's, while it's open), fading out over 30 pt or so. Under the
/// glass the page stays as it is, so the modules look as they do anywhere.
private struct PanelHalo: View {
    let statusesOpen: Bool

    @Environment(\.colorScheme) private var colorScheme
    /// Room for the blur's falloff past the panel's edges.
    private static let reach: CGFloat = 72

    var body: some View {
        let shapes = statusesOpen
            ? [StatusesCard.shape.path(in: CGRect(x: 0, y: 0, width: Grid.width, height: StatusesCard.height))]
            : Module.allCases.map { $0.shape.path(in: $0.frame) }
        let strength = colorScheme == .dark ? 0.5 : 0.22
        Canvas { context, _ in
            context.translateBy(x: Self.reach, y: Self.reach)
            context.drawLayer { halo in
                halo.addFilter(.blur(radius: 20))
                for shape in shapes { halo.fill(shape, with: .color(.black.opacity(strength))) }
            }
            context.blendMode = .destinationOut
            for shape in shapes { context.fill(shape, with: .color(.black)) }
        }
        .frame(width: Grid.width + Self.reach * 2, height: StatusesCard.height + Self.reach * 2)
        // Laid out as the panel, drawn past it.
        .padding(-Self.reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.smooth(duration: 0.3), value: statusesOpen)
    }
}

// MARK: - Module content

/// Steam Status, as macOS's Focus module: "Status", with the current one
/// under it and in its well. Not "Steam": the profile beside it is already
/// the Steam account. A click opens all four. Without Steam the well
/// waits, empty, and the line says why.
private struct StatusModuleContent: View {
    let state: SteamSession.PersonaState?
    /// The line under "Status" while there's none. Short: the line has
    /// 52 pt beside the well.
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            AnimatedGlyph(kind: (state ?? .online).glyph, picks: 0, revealDelay: 0.1)
                .foregroundStyle(state.map { AnyShapeStyle($0.glyphColor) } ?? AnyShapeStyle(.tertiary))
                .frame(width: 30, height: 30)
                .background(state.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.quaternary), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("Status")
                    .font(.system(size: 12, weight: .semibold))
                Text(state?.title ?? note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            .lineLimit(1)
        }
        // Leading by frame, not a Spacer: the stack's spacing would sit
        // before a Spacer too and take 8 pt from the title.
        .frame(maxWidth: .infinity, alignment: .leading)
        // The well sits 11 pt in from every edge, concentric with the capsule.
        .padding(.horizontal, 11)
        .animation(.smooth(duration: 0.25), value: state)
    }
}

/// A switch, as Control Center's: its glyph in a well that fills with the
/// accent colour while it's on.
private struct ToggleContent: View {
    let symbol: String
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

/// A shortcut, as Control Center's small buttons: a symbol alone in its
/// circle, named by its tooltip. A badge marks one waiting on you; one that
/// can't be used now (Steam's power while a game runs) is drawn dimmer.
private struct ShortcutContent: View {
    let symbol: String
    var badge = false
    var isEnabled = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .animation(.smooth(duration: 0.25), value: isEnabled)
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -2)
                }
            }
    }
}

// MARK: - Statuses card

/// All four statuses, opened from the Steam Status module as macOS's Focus
/// module opens its modes: the module's glass grows into this card. A pick
/// leaves it open, so the glyph's move plays out; its header or Esc steps
/// back, a click outside closes the panel.
private struct StatusesCard: View {
    static let inset: CGFloat = 6
    static let rowHeight: CGFloat = 44
    static let height = inset * 2 + rowHeight * 5
    static let shape = AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    static let order: [SteamSession.PersonaState] = [.online, .away, .invisible, .offline]

    let hovered: Hover?
    var onBack: () -> Void
    var onPick: (SteamSession.PersonaState) -> Void

    @Environment(SteamSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Steam Status")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: Self.rowHeight)
                .background(RowHighlight(isOn: hovered == .header))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            ForEach(Array(Self.order.enumerated()), id: \.element) { index, state in
                Button { onPick(state) } label: {
                    StatusRow(state: state,
                              isSelected: session.personaState == state,
                              revealDelay: 0.15 + Double(index) * 0.06)
                        .background(RowHighlight(isOn: hovered == .status(state)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.title)
                .accessibilityAddTraits(session.personaState == state ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .frame(width: Grid.width, height: Self.height, alignment: .top)
        // Its edges are the card's, not the page's: a click there stays.
        .contentShape(.rect)
    }
}

/// One status: its glyph in a round well, which fills with the status
/// colour once chosen, beside its name and what it means.
private struct StatusRow: View {
    let state: SteamSession.PersonaState
    let isSelected: Bool
    let revealDelay: Double

    @State private var picks = 0

    var body: some View {
        HStack(spacing: 10) {
            AnimatedGlyph(kind: state.glyph, picks: picks, revealDelay: revealDelay)
                .foregroundStyle(isSelected ? AnyShapeStyle(state.glyphColor) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background(isSelected ? AnyShapeStyle(state.color) : AnyShapeStyle(.quaternary), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(state.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The well sits 7 pt in, as in the capsule's 52 pt it sat 11 pt in.
        .padding(.horizontal, 7)
        .frame(height: StatusesCard.rowHeight)
        .contentShape(.rect)
        .animation(.smooth(duration: 0.25), value: isSelected)
        .onChange(of: isSelected) { _, selected in
            if selected { picks += 1 }
        }
    }
}

/// The pointer's row in the card: a quiet fill, as in Control Center's lists.
private struct RowHighlight: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.primary.opacity(isOn ? 0.08 : 0))
            .animation(.smooth(duration: 0.15), value: isOn)
    }
}

// MARK: - Shared pieces

/// The player: photo, persona name and the account it is. The status is
/// the Status module's. With the pointer on it the line turns into what a
/// click does.
private struct ProfileContent: View {
    let isFocused: Bool

    @Environment(SteamAuthService.self) private var steamAuth

    var body: some View {
        VStack(spacing: 0) {
            SteamAvatarView(url: steamAuth.avatarURL, size: 46)
            Text(steamAuth.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 8)
            ZStack {
                Text("Steam")
                    .opacity(isFocused ? 0 : 1)
                Text("View Profile")
                    .opacity(isFocused ? 1 : 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 1)
            .animation(.smooth(duration: 0.2), value: isFocused)
        }
        .padding(.horizontal, 8)
    }
}

/// Runs a `StatusGlyph`'s clocks: draws it in once its tile has come in, and
/// plays its move each time `picks` goes up.
private struct AnimatedGlyph: View {
    let kind: StatusGlyph.Kind
    let picks: Int
    let revealDelay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = 0.0
    @State private var pick = 0.0

    var body: some View {
        StatusGlyph(kind: kind, reveal: reveal, pick: pick)
            .onAppear {
                guard !reduceMotion else { reveal = 1; return }
                withAnimation(.linear(duration: 0.7).delay(revealDelay)) { reveal = 1 }
            }
            .onChange(of: picks) {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: kind.moveDuration)) { pick += 1 }
            }
    }
}

/// A module's glass: the same interactive glass as the app's other glass
/// buttons, in its shape, which brightens and grows with the pointer's
/// focus. Focus arrives from the panel, so the module never tracks the
/// pointer itself, and the glass gives under a click on its own.
private struct TileStyle: ButtonStyle {
    let module: Module
    let isFocused: Bool
    let glassSpace: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        let lifted = isFocused && !configuration.isPressed
        let size = module.frame.size
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FocusWash(shape: module.shape, isFocused: isFocused))
            .modifier(TileGlass(shape: module.shape, id: module == .status ? .status : nil, space: glassSpace))
            .contentShape(module.shape)
            // Focus grows the module's frame by 5 %, never a scale: the
            // container draws the glass and its shadow from the layout, so a
            // scaled module left its shadow behind (a dark band under a
            // hovered or pressed one). Its slot keeps its size, so nothing
            // around it moves.
            .padding(lifted ? EdgeInsets(top: -size.height * 0.025, leading: -size.width * 0.025,
                                         bottom: -size.height * 0.025, trailing: -size.width * 0.025)
                            : EdgeInsets())
            .animation(.spring(duration: 0.3, bounce: 0.15), value: lifted)
    }
}

/// The focused tile's brightening, in its glass: an opacity, so it
/// animates. Light glass needs more white to show it.
private struct FocusWash: View {
    let shape: AnyShape
    let isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape
            .fill(.white.opacity(isFocused ? (colorScheme == .dark ? 0.12 : 0.3) : 0))
            .animation(.smooth(duration: 0.2), value: isFocused)
    }
}

private struct TileGlass: ViewModifier {
    let shape: AnyShape
    var interactive = true
    /// The Steam Status module and its card share one, so one's glass grows
    /// into the other's.
    var id: Module?
    let space: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .glassEffectID(id, in: space)
                // Comes and goes the way glass does, never by a scale or a
                // fade, which pulled the content off its glass.
                .glassEffectTransition(id == nil ? .materialize : .matchedGeometry)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - Status presentation

private extension SteamSession.PersonaState {
    var color: Color { PlayerSummary.statusColor(personaState: rawValue) }

    /// The glyph on the chosen status's colour: white, but dark on yellow,
    /// which white barely shows on.
    var glyphColor: Color { self == .away ? .black.opacity(0.8) : .white }

    var glyph: StatusGlyph.Kind {
        switch self {
        case .online:    .presence
        case .away:      .eclipse
        case .invisible: .hide
        case .offline:   .power
        }
    }

    /// What it means, short enough for the card's row: Steam's own
    /// descriptors for Invisible and Offline (friendsui localization),
    /// shortened.
    var detail: String {
        switch self {
        case .online:    "Friends can see you"
        case .away:      "Show friends you're away"
        case .invisible: "Appear offline, still chat"
        case .offline:   "Sign out of Friends & Chat"
        }
    }
}
