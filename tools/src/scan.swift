// 被动扫描：谁的窗口压在屏幕底部 200pt（程序坞所在区域），以及谁装了会改鼠标/键盘事件的事件钩子（event tap）
import AppKit
import CoreGraphics
_ = NSApplication.shared
let screen = NSScreen.main!.frame
// 1) every on-screen window that touches the bottom 200pt (where our dock lives), by layer
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
var rows: [(Int, String, CGRect, Double)] = []
for w in list {
  let b = w[kCGWindowBounds as String] as! [String: CGFloat]
  let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
  if r.maxY > screen.height - 200 && r.width > 4 && r.height > 4 { rows.append((w[kCGWindowLayer as String] as? Int ?? 0, w[kCGWindowOwnerName as String] as? String ?? "?", r, w[kCGWindowAlpha as String] as? Double ?? 1)) }
}
print("== windows touching the bottom 200pt of the screen (layer, owner, rect, alpha)")
for r in rows.sorted(by: { $0.0 > $1.0 }) { print(String(format: "%11d  %-22@ x=%4.0f y=%4.0f w=%4.0f h=%4.0f a=%.2f", r.0, r.1 as NSString, r.2.minX, r.2.minY, r.2.width, r.2.height, r.3)) }
// 2) event taps installed by other processes
var n: UInt32 = 0; CGGetEventTapList(0, nil, &n)
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(n)); CGGetEventTapList(n, &taps, &n)
print("\n== event taps (who listens to / alters mouse & keyboard)")
for t in taps.prefix(Int(n)) {
  let name = NSRunningApplication(processIdentifier: t.tappingProcess)?.localizedName ?? "pid \(t.tappingProcess)"
  let mouse = (t.eventsOfInterest & ((1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDown.rawValue))) != 0
  print("  \(name)  options=\(t.options.rawValue == 0 ? "active(can alter)" : "listen-only")  mouse=\(mouse)  enabled=\(t.enabled)")
}
