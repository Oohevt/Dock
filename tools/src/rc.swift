// rc x y：在 (x, y) 右键点一下；rc esc：按一下 Esc
import CoreGraphics
import Foundation
// rc x y  → right click;  rc esc → Escape key
let a = CommandLine.arguments
if a[1] == "esc" {
  for d in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: d)?.post(tap: .cghidEventTap); usleep(30000) }
} else {
  let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
  for t in [CGEventType.rightMouseDown, .rightMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right)?.post(tap: .cghidEventTap); usleep(40000) }
}
