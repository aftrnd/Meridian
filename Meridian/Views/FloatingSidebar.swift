import SwiftUI

// MARK: - Floating sidebar

/// Developer › Feature Flags › Floating Sidebar: the sidebar as a glass panel
/// floating over the pages, as macOS 26 drew it. macOS 27 dropped that style
/// (NavigationSplitView's sidebar is a full-height glass column with no API
/// to inset it), so this replaces the split view instead of styling it.
///
/// The pages run the full window underneath. Their leading safe area clears
/// the panel (`width`, applied by ContentView), so layout starts beside it,
/// while art that ignores the leading edge (Home's banner, under
/// `floatingSidebarActive`) bleeds under the glass to the window's edge.
enum FloatingSidebar {
    /// The classic column's width, so pages lay out exactly as beside it.
    static let width: CGFloat = 215
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
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content

    /// Gap between the panel and the window's edges. The corners follow the
    /// window's (16 pt on macOS 27), concentric, never under 12 pt.
    private static var inset: CGFloat { 8 }

    var body: some View {
        content
            .environment(\.floatingSidebarActive, true)
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
            .padding(.horizontal, Self.inset)
            .padding(.bottom, Self.inset)
            .background {
                Color.clear
                    .glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true))
                    .padding(Self.inset)
                    .ignoresSafeArea()
            }
            .frame(width: FloatingSidebar.width)
            .ignoresSafeArea(edges: .top)
    }
}

extension EnvironmentValues {
    /// True under FloatingSidebarLayout: art meant to run under the panel
    /// ignores the leading safe area. False (the classic column) leaves
    /// every layout exactly as it was.
    @Entry var floatingSidebarActive: Bool = false
}
