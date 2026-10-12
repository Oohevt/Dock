import CoreGraphics
import Foundation
// warp            → 打印当前光标位置 "x y"
// warp x y        → 把光标瞬移到 (x, y)（左上角为原点）
// warp size       → 打印主屏幕尺寸 "w h"
let a = CommandLine.arguments
if a.count == 1 { let p = CGEvent(source: nil)!.location; print("\(p.x) \(p.y)") }
else if a[1] == "size" { let b = CGDisplayBounds(CGMainDisplayID()); print("\(Int(b.width)) \(Int(b.height))") }
else { CGWarpMouseCursorPosition(CGPoint(x: Double(a[1])!, y: Double(a[2])!)) }
