import re
p='Sources/Models.swift'; s=open(p).read()
s=s.replace("let n = apps.count > 4 ? 3 : 2\n        let shown = Array(apps.prefix(n * n))","let n = 2   // 程序坞/启动器图标最多显示 4 个（2x2），弹窗仍显示全部\n        let shown = Array(apps.prefix(4))")
open(p,'w').write(s)
p='Sources/CustomDock.swift'; s=open(p).read()
a=s.index('        let style = UserDefaults.standard.string(forKey: "customDockGlassStyle") ?? "edge"')
b=s.index('        super.init(frame: frame)',a)
s=s[:a]+'''        let style = UserDefaults.standard.string(forKey: "customDockGlassStyle") ?? "liquid"
        // 容器：阴影 + 实际模糊玻璃 + 细亮边，白色和深色背景上都清晰
        let box = NSView(); box.wantsLayer = true
        let bl = box.layer!
        bl.masksToBounds = false
        bl.shadowColor = NSColor.black.cgColor; bl.shadowOpacity = 0.22; bl.shadowRadius = 10; bl.shadowOffset = CGSize(width: 0, height: -2)
        var blur: NSView
        if #available(macOS 26.0, *), style != "vibrancy" {
            let g = NSGlassEffectView()
            g.style = style == "clear" ? .clear : .regular
            let tint = UserDefaults.standard.object(forKey: "customDockGlassTint") as? Double ?? 0.10
            if tint > 0 { g.tintColor = NSColor(white: 1, alpha: tint) }
            g.cornerRadius = NativeDock.cornerRadius
            blur = g
        } else {
            let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = NativeDock.cornerRadius; v.layer?.cornerCurve = .continuous; v.layer?.masksToBounds = true
            blur = v
        }
        blur.autoresizingMask = [.width, .height]
        box.addSubview(blur)
        let edge = NSView(); edge.wantsLayer = true; edge.autoresizingMask = [.width, .height]
        let el = edge.layer!
        el.cornerRadius = NativeDock.cornerRadius; el.cornerCurve = .continuous
        el.borderWidth = 1; el.borderColor = NSColor(white: 1, alpha: 0.55).cgColor
        let ol = CALayer(); ol.cornerRadius = NativeDock.cornerRadius + 0.5; ol.cornerCurve = .continuous
        ol.borderWidth = 0.5; ol.borderColor = NSColor(white: 0, alpha: 0.18).cgColor
        ol.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        el.addSublayer(ol)
        box.addSubview(edge)
        glassBlur = blur; glassEdge = edge; glassOuter = ol
        glass = box
'''+s[b:]
s=s.replace('    private let tipBg = CALayer()','    private var glassBlur: NSView? ; private var glassEdge: NSView? ; private var glassOuter: CALayer?\n    private let tipBg = CALayer()',1)
s=s.replace('                glass.frame = gf; lastGlass = gf','''                glass.frame = gf; lastGlass = gf
                glassBlur?.frame = glass.bounds; glassEdge?.frame = glass.bounds
                glassOuter?.frame = glass.bounds.insetBy(dx: -0.5, dy: -0.5)
                glass.layer?.shadowPath = CGPath(roundedRect: glass.bounds, cornerWidth: NativeDock.cornerRadius, cornerHeight: NativeDock.cornerRadius, transform: nil)''')
# 120Hz
s=s.replace('        l.add(to: .main, forMode: .common)\n        link = l; lastTs = 0','        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)\n        l.add(to: .main, forMode: .common)\n        link = l; lastTs = 0')
# tooltip: only rebuild text when target changes
s=s.replace('''        let text = label(for: model.entries[i])
        let font''','''        let text = label(for: model.entries[i])
        if text == lastTip && tipBg.opacity == 1 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tipBg.position = CGPoint(x: il.position.x, y: il.frame.maxY + 8 + 12)
            CATransaction.commit(); return
        }
        lastTip = text
        let font''')
s=s.replace('    func updateTooltip() {','    private var lastTip = ""\n    func updateTooltip() {')
s=s.replace('            tipBg.opacity = 0; return\n','            tipBg.opacity = 0; lastTip = ""; return\n',1)
# expose check: cache dock pid, cheaper
s=s.replace('''        return list.contains { w in
            guard let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
                  (w''','''        if dockPid == 0 || NSRunningApplication(processIdentifier: dockPid) == nil {
            dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        }
        let dockPid = self.dockPid
        return list.contains { w in
            guard (w''')
s=s.replace('    private var inExpose = false','    private var inExpose = false\n    private var dockPid: pid_t = 0')
s=s.replace('if tickN % 4 == 0 {','if tickN % 6 == 0 {')
open(p,'w').write(s); print("ok")
