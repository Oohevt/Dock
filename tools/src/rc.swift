// rc x y：在 (x, y) 右键点一下；rc esc：给 DockGroups 进程发一个 Esc（关它的右键菜单）。
// Esc 必须直接发给 DockGroups：它在后台，走系统键盘的话 Esc 会落到前台应用上（实测曾因此打断前台应用正在做的事）
import AppKit
let a = CommandLine.arguments
if a[1] == "esc" {
  guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.example.DockGroups").first?.processIdentifier else { exit(1) }
  for d in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: d)?.postToPid(pid); usleep(30000) }
} else {
  let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
  for t in [CGEventType.rightMouseDown, .rightMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right)?.post(tap: .cghidEventTap); usleep(40000) }
}
