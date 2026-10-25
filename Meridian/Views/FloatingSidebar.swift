import SwiftUI

// MARK: - Floating sidebar

/// Developer › Feature Flags › Floating Sidebar (on by default): the sidebar
/// as a glass panel floating over the pages, as macOS 26 drew it. macOS 27 dropped that style
/// (NavigationSplitView's sidebar is a full-height glass column with no API
/// to inset it), so this replaces the split view instead of styling it.
///
/// The pages run the full window underneath. Their leading safe area ends at
/// the glass (`edge(width:)`, applied by ContentView), so everything sits as
/// far from the panel as it does from the classic column, and Home's banner
/// meets the glass exactly: its background extension mirrors the art into
/// that safe area, under the panel, unshaded, as macOS 26 and 27 draw it.
enum FloatingSidebar {
    /// The glass's width: the classic column's, until its edge is dragged.
    static let defaultWidth: Double = 215
    static let widthRange: ClosedRange<Double> = 180...360
    /// UserDefaults key for the dragged width.
    static let widthKey = "floatingSidebar.width"
    /// Gap between the glass and the window's edges.
    static let inset: CGFloat = 8
    /// The glass's corners, concentric with the window's
    /// (`AppSettings.mainWindowCornerRadius`): 26 − 8 = 18 pt.
    static let cornerRadius = AppSettings.mainWindowCornerRadius - inset

    /// Where glass this wide ends; the pages start here.
    static func edge(width: Double) -> CGFloat {
        inset + min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Beside the classic column the game page's Back sits 8 pt past the
    /// column's edge (x 223 for 215 on macOS 27.0.1 and 27.2), in 36 pt
    /// glass centred on its chevron.
    private static let backInsetFromEdge: CGFloat = 8
    private static let backGlassWidth: CGFloat = 36

    /// Where Back's chevron centres beside glass this wide: its classic spot.
    static func backMidX(width: Double) -> CGFloat {
        edge(width: width) + backInsetFromEdge + backGlassWidth / 2
    }

    /// How far past an invisible leading toolbar item's width the item after
    /// it centres. That's the toolbar's own leading layout, and macOS moves
    /// it between releases: 122 pt on 27.0.1, 114 on 27.2, which dropped the
    /// 8 pt gap after an item with no glass (probed Oct 24). So Back measures
    /// it where it lands (`ToolbarMidXReader`), and it's kept for the session.
    @MainActor static var toolbarLeadingOffset: CGFloat = 114
    /// UserDefaults key for View › Show/Hide Sidebar (⌃⌘S). There is no
    /// toolbar button: the system's is too large for the panel's top band.
    static let shownKey = "floatingSidebar.shown"

    /// The panel needs macOS 26's glass and concentric shapes.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

@available(macOS 26.0, *)
struct FloatingSidebarLayout<Sidebar: View, Content: View>: View {
    var isPresented: Bool
    /// The glass's width (`FloatingSidebar.widthKey`); its edge drags it.
    @Binding var width: Double
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content

    /// The width when the current drag began.
    @State private var dragStartWidth: Double?

    var body: some View {
        content
            .environment(\.toolbarBackMidX, isPresented ? FloatingSidebar.backMidX(width: width) : nil)
            .overlay(alignment: .leading) {
                if isPresented {
                    panel.transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: isPresented)
    }

    private var panel: some View {
        sidebar
            .scrollContentBackground(.hidden)
            // Rows start below the traffic lights, as in the classic column;
            // the panel itself runs to the top of the window.
            .safeAreaPadding(.top, 44)
            .padding(.horizontal, FloatingSidebar.inset)
            .padding(.bottom, FloatingSidebar.inset)
            .background {
                glass
                    .padding(FloatingSidebar.inset)
                    .ignoresSafeArea()
            }
            .frame(width: FloatingSidebar.edge(width: width) + FloatingSidebar.inset)
            .ignoresSafeArea(edges: .top)
            // Centred on the glass's edge, half over the pages, like a split
            // view's divider.
            .overlay(alignment: .trailing) {
                resizeHandle.padding(.trailing, FloatingSidebar.inset - 5)
            }
    }

    /// macOS 27's own sidebar glass where this macOS has it, else SwiftUI's.
    @ViewBuilder private var glass: some View {
        if SidebarGlass.isSupported {
            SidebarGlass(cornerRadius: FloatingSidebar.cornerRadius)
        } else {
            Color.clear
                .glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true))
        }
    }

    /// Drag the glass's edge to resize it, as the classic column did; the
    /// pages reflow live. The width is kept across launches.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 10)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        let range = FloatingSidebar.widthRange
                        // Whole points: drag translations are fractional, and
                        // the pages start at the glass's edge (`edge(width:)`),
                        // so a fractional width left them between pixels.
                        width = min(max((start + drag.translation.width).rounded(), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

extension EnvironmentValues {
    /// Set while the floating panel shows: where the game page's Back
    /// centres in the window (`FloatingSidebar.backMidX`), beside the pages
    /// as beside the classic column. nil: no panel, the toolbar's own layout.
    @Entry var toolbarBackMidX: CGFloat? = nil
}

/// Reports where the view it backs centres in the window, one runloop after
/// it lands there: toolbar items are laid out by then (probe, macOS 27.2:
/// settled at the next runloop, no insertion animation). Reports only on
/// landing; a toolbar item that just moves sideways isn't re-read.
struct ToolbarMidXReader: NSViewRepresentable {
    let report: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.report = report
        return v
    }

    func updateNSView(_ v: ReaderView, context: Context) {
        v.report = report
    }

    final class ReaderView: NSView {
        var report: (@MainActor (CGFloat) -> Void)?

        // Never take the button's clicks (see ScrollViewLanding).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                report?(convert(bounds, to: nil).midX)
            }
        }
    }
}

/// The glass macOS 27 puts behind NavigationSplitView's sidebar:
/// NSGlassEffectView in its sidebar variant (`_variant` 17, read off a native
/// sidebar on 27.0.1; toolbar buttons are 0). There's no public way to pick a
/// variant, and SwiftUI's `.glassEffect` draws far lighter (#3b3b39 against
/// the native #2b2a28 over the dark window background; the variant matches it
/// exactly). Private, so it's only used while the setter exists; a macOS
/// without it gets SwiftUI's glass instead.
@available(macOS 26.0, *)
private struct SidebarGlass: NSViewRepresentable {
    let cornerRadius: CGFloat

    static var isSupported: Bool {
        NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:"))
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.setValue(17, forKey: "_variant")
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}
