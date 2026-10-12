import CoreGraphics
import Foundation
// drag2 x0 y0  x1 y1 dwell1ms  x2 y2 dwell2ms : press at p0, glide to p1 (e.g. bottom edge to reveal the dock), wait, glide to p2, wait, release
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
func P(_ i: Int) -> CGPoint { CGPoint(x: a[i], y: a[i+1]) }
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
func glide(_ from: CGPoint, _ to: CGPoint) { for i in 1...40 { let t = Double(i) / 40; post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)); usleep(15000) } }
post(.mouseMoved, P(0)); usleep(200000); post(.leftMouseDown, P(0)); usleep(200000)
glide(P(0), P(2)); usleep(UInt32(a[4]) * 1000)
glide(P(2), P(5)); usleep(UInt32(a[7]) * 1000)
post(.leftMouseUp, P(5))
