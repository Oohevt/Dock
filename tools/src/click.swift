import CoreGraphics
import Foundation
// click x y：在 (x, y) 左键点一下（先滑过去，让悬停状态就位）
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(300000)
// 带上点击次数：SwiftUI 的点击手势靠它识别，不带的话面板里的点击没反应（真实鼠标会带）
for t in [CGEventType.leftMouseDown, .leftMouseUp] {
  let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
  e?.setIntegerValueField(.mouseEventClickState, value: 1); e?.post(tap: .cghidEventTap); usleep(60000)
}
