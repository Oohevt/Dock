// sweep y 秒 x0 x1：光标在水平线 y 上来回扫 N 秒（压测悬停放大时的 CPU）
import CoreGraphics
import Foundation
// sweep the cursor back and forth along y for N seconds at ~120 events/s
let a = CommandLine.arguments
let y = Double(a[1])!, secs = Double(a[2])!, x0 = Double(a[3])!, x1 = Double(a[4])!
let t0 = Date(); var i = 0.0
while Date().timeIntervalSince(t0) < secs {
  let ph = abs((i.truncatingRemainder(dividingBy: 240)) / 120 - 1)
  CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x0 + (x1 - x0) * ph, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
  i += 1; usleep(8300)
}
