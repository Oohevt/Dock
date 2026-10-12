// mv x y：用真实的鼠标移动事件把光标滑到 (x, y)（程序坞靠这些事件触发，warp 不行）
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let to = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let from = CGEvent(source: nil)!.location
for i in 1...12 { let t = Double(i) / 12
  CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(15000) }
