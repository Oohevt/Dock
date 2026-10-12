// 诊断：完全照抄 CommandB 的面板+玻璃设置，放在程序坞位置。用法: ./GlassTest [key|nokey] [秒数]
import AppKit
let args = CommandLine.arguments
let makeKey = args.count > 1 ? args[1] == "key" : false
let secs = args.count > 2 ? Double(args[2]) ?? 20 : 20
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let card = NSSize(width: 900, height: 90), m: CGFloat = 36
let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: card.width + m*2, height: card.height + m*2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
p.isOpaque = false; p.backgroundColor = .clear; p.level = NSWindow.Level(rawValue: 28)
p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isMovable = false; p.hasShadow = false
let container = NSView(frame: NSRect(origin: .zero, size: p.frame.size)); container.wantsLayer = true
let g = NSGlassEffectView(); g.frame = NSRect(x: m, y: m, width: card.width, height: card.height)
g.cornerRadius = 26; g.style = .clear
let content = NSTextField(labelWithString: makeKey ? "GlassTest (key/active)" : "GlassTest (not key)")
content.frame = NSRect(x: 30, y: 30, width: 400, height: 30)
let holder = NSView(frame: g.bounds); holder.addSubview(content); g.contentView = holder
g.wantsLayer = true; g.layer?.borderWidth = 0; g.layer?.masksToBounds = true
container.addSubview(g); p.contentView = container
let sf = NSScreen.main!.frame
p.setFrameOrigin(NSPoint(x: sf.midX - p.frame.width/2, y: sf.minY + 120))
if makeKey { NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil) } else { p.orderFrontRegardless() }
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
app.run()
