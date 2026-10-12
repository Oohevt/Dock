import AppKit
// backdrop 灰度(0黑~1白) 秒数：盖一层纯色全屏窗口（普通窗口层级，在分组面板和程序坞下面），用来看浅色/深色壁纸下的观感
let a = CommandLine.arguments
let gray = CGFloat(Double(a.count > 1 ? a[1] : "1") ?? 1), secs = Double(a.count > 2 ? a[2] : "8") ?? 8
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let w = NSWindow(contentRect: NSScreen.main!.frame, styleMask: [.borderless], backing: .buffered, defer: false)
w.backgroundColor = NSColor(white: gray, alpha: 1); w.level = .normal; w.ignoresMouseEvents = true; w.hasShadow = false
w.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
app.run()
