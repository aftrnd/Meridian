import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    print("\(id)\tpid=\(pid)\tlayer=\(layer)\t\(owner)\t\(name)\t\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)")
}
