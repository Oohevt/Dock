// topwin：打印鼠标当前位置正下方"会接到点击"的最上层窗口属于哪个应用（用来查程序坞上有没有点得穿的地方）
import AppKit
_ = NSApplication.shared
let m = NSEvent.mouseLocation
let n = NSWindow.windowNumber(at: m, belowWindowWithWindowNumber: 0)
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let w = all.first { ($0[kCGWindowNumber as String] as? Int) == n }
print("\(w?[kCGWindowOwnerName as String] as? String ?? "?") layer=\(w?[kCGWindowLayer as String] ?? "?")")
