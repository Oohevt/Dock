// sweep y 秒 x0 x1 [每秒事件数=120]：光标在水平线 y 上来回扫 N 秒（压测悬停放大时的 CPU）。
// 来回一趟固定约 2 秒，事件数只影响上报频率（普通鼠标约 125，电竞鼠标 1000 甚至更高）
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let y = Double(a[1])!, secs = Double(a[2])!, x0 = Double(a[3])!, x1 = Double(a[4])!
let rate = a.count > 5 ? Double(a[5])! : 120
let t0 = Date()
var next = t0
while true {
  let t = Date().timeIntervalSince(t0)
  if t >= secs { break }
  let ph = abs((t.truncatingRemainder(dividingBy: 2.0)) - 1.0)      // 三角波 0→1→0，周期 2 秒
  CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x0 + (x1 - x0) * ph, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
  next = next.addingTimeInterval(1.0 / rate)
  let wait = next.timeIntervalSinceNow
  if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
}
