import CoreGraphics
import Foundation

// mousewiggle <cx> <cy> <count> — posts HID-level mouse-moved events sweeping around (cx,cy).
let a = CommandLine.arguments
let cx = Double(a[1])!, cy = Double(a[2])!, n = Int(a[3])!
var x = cx, y = cy
for i in 0..<n {
    let dx = (i % 40) < 20 ? 3.0 : -3.0
    let dy = (i % 80) < 40 ? 1.0 : -1.0
    x += dx; y += dy
    guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { continue }
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
    e.post(tap: .cghidEventTap)
    usleep(8000)
}
