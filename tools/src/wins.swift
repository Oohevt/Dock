// 列出 DockGroups 的所有屏幕上窗口："层级 x y 宽 高"（21 = 程序坞条，3 = 分组面板，101 = 右键菜单）
import CoreGraphics
import Foundation
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []) where (w[kCGWindowOwnerName as String] as? String) == "DockGroups" {
  let b = w[kCGWindowBounds as String] as! [String: CGFloat]
  print(w[kCGWindowLayer as String] ?? "", b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
