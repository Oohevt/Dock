// 列出主屏底部 400pt 内的所有屏幕上窗口："层级 | 属主 | x 顶y 宽 高 | 底边y"（排查别的应用被什么窗口顶开时用）
import AppKit
import CoreGraphics

for s in NSScreen.screens {
    print("SCREEN frame=\(s.frame) visible=\(s.visibleFrame)")
}
let H = NSScreen.screens.first?.frame.height ?? 0
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []) {
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let topY = b["Y"] ?? 0, h = b["Height"] ?? 0, x = b["X"] ?? 0, wd = b["Width"] ?? 0
    let bottom = H - topY - h
    if bottom < 400 && h > 0 {
        print(layer, "|", owner, "|", Int(x), Int(topY), Int(wd), Int(h), "| bottom=\(Int(bottom))")
    }
}
// 指定属主的全部窗口（含不在屏幕上的）：swift bottomwins.swift Typeless
if CommandLine.arguments.count > 1 {
    let key = CommandLine.arguments[1].lowercased()
    for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []) {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owner.lowercased().contains(key) else { continue }
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
        let h = b["Height"] ?? 0, topY = b["Y"] ?? 0
        print("ALL", layer, "|", owner, "|", Int(b["X"] ?? 0), Int(topY), Int(b["Width"] ?? 0), Int(h), "| bottom=\(Int(H - topY - h))", "| onscreen=\(onscreen) alpha=\(alpha)")
    }
}
