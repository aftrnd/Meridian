import AppKit

// Bare executable (no .app) with an embedded __info_plist declaring the games category.
// Goes fullscreen; we then read gamepolicyd to see whether it is labelled a game.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!
let win = NSWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
win.title = "GM Probe"
win.contentView?.wantsLayer = true
win.contentView?.layer?.backgroundColor = NSColor.systemPurple.cgColor
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { win.toggleFullScreen(nil) }
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { app.terminate(nil) }
app.run()
