import CoreGraphics
import Foundation
// key text "内容"     → 逐字输入（支持中文）
// key press 名称 ...   → 依次按键：return esc down up tab space delete
// key cmd a            → ⌘+字母
let codes: [String: CGKeyCode] = ["return": 36, "esc": 53, "down": 125, "up": 126, "tab": 48, "space": 49, "delete": 51,
  "a": 0, "s": 1, "d": 2, "f": 3, "c": 8, "v": 9, "w": 13, "q": 12, "m": 46]
func tap(_ k: CGKeyCode, flags: CGEventFlags = []) {
  for d in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: d); e?.flags = flags; e?.post(tap: .cghidEventTap); usleep(40000) }
}
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "text":
  for ch in a[2] { var u = Array(String(ch).utf16)
    for d in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: d); e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); e?.post(tap: .cghidEventTap); usleep(30000) } }
case "press": for n in a.dropFirst(2) { if let c = codes[n] { tap(c); usleep(120000) } }
case "cmd": if let c = codes[a[2]] { tap(c, flags: .maskCommand) }
default: print("usage: key text|press|cmd …")
}
