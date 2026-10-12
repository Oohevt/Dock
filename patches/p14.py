p='Sources/CustomDock.swift'; s=open(p).read()
def R(a,b,c=1):
    global s
    assert a in s, a[:60]
    s=s.replace(a,b,c)
# 1) hierarchy: in commandb style, iconHost lives inside glass.contentView; overlay view for floating layers
R('''        iconHost.wantsLayer = true
        iconHost.layer?.masksToBounds = false
        iconHost.autoresizingMask = [.width, .height]
        addSubview(iconHost)''','''        iconHost.wantsLayer = true
        iconHost.layer?.masksToBounds = false
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            // 与 CommandB 一致：图标视图放进玻璃的 contentView；用负偏移保持坐标系与本视图一致
            let holder = NSView(); holder.wantsLayer = true
            g.contentView = holder
            holder.addSubview(iconHost)
            insideGlass = true
        } else {
            iconHost.autoresizingMask = [.width, .height]
            addSubview(iconHost)
        }
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = false
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)''')
R('    private let tipBg = CALayer()','''    let overlay = NSView()          // 浮层：提示、拖动中的图标、弹跳（不被玻璃裁剪）
    var insideGlass = false
    var floating = Set<String>()
    private let tipBg = CALayer()''')
R('        iconHost.layer?.addSublayer(tipBg)','        overlay.layer?.addSublayer(tipBg)')
R('override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); iconHost.frame = bounds }',
  'override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); overlay.frame = bounds; syncHost() }\n    func syncHost() { iconHost.frame = insideGlass ? NSRect(x: -glass.frame.minX, y: -glass.frame.minY, width: bounds.width, height: bounds.height) : bounds }')
R('''                glass.frame = gf; lastGlass = gf''','''                glass.frame = gf; lastGlass = gf; syncHost()''')
# floating reparent in applyLayout: before CATransaction.commit in applyLayout
R('''        CATransaction.commit()
        updateTooltip()''','''        if insideGlass {
            for (id, il) in iconLayers {
                let want = floating.contains(id) || dragState.map { $0.active && $0.id == id } == true
                let parent = want ? overlay.layer : iconHost.layer
                if il.superlayer !== parent { parent?.addSublayer(il) }
            }
        }
        CATransaction.commit()
        updateTooltip()''')
R('        if settled { l.invalidate(); link = nil }','        if settled { l.invalidate(); link = nil; if !floating.isEmpty { floating.removeAll(); applyLayout() } }')
# dropped icon floats until settled
s=s.replace('''dispX[d.id] = d.x; velX[d.id] = 0; reordering = true
                    dragState = nil''','''dispX[d.id] = d.x; velX[d.id] = 0; reordering = true; floating.insert(d.id)
                    dragState = nil''')
s=s.replace('''else { dispX[d.id] = d.x; velX[d.id] = 0; reordering = true }''','''else { dispX[d.id] = d.x; velX[d.id] = 0; reordering = true; floating.insert(d.id) }''')
R('''                    dispX[d.id] = d.x; velX[d.id] = 0
                    reordering = true''','''                    dispX[d.id] = d.x; velX[d.id] = 0
                    reordering = true; floating.insert(d.id)''')
# bounce floats
R('''        guard let l = iconLayers[id] else { return }
        let a = CAKeyframeAnimation''','''        guard let l = iconLayers[id] else { return }
        floating.insert(id); applyLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in
            guard let self = self else { return }
            if self.link == nil { self.floating.remove(id); self.applyLayout() }
        }
        let a = CAKeyframeAnimation''')
R('''        layoutDock(animated: false)
    }''','''        layoutDock(animated: false)
        onWidthChange?(baseWidth)
    }''')
# shift helper
R('    func syncHost() {','''    func shiftX(_ dx: CGFloat) {
        guard dx != 0 else { return }
        for k in dispX.keys { dispX[k]! += dx }
        if var d = dragState { d.x += dx; d.startX += dx; dragState = d }
        lastGlass = .zero
        applyLayout()
    }
    func syncHost() {''')
# 2) bar-sized window + level 28
R('''        let f = screen.frame
        let h = v.L + 60
        let y = f.minY
        p.setFrame(NSRect(x: f.minX, y: y, width: f.width, height: h), display: true)''','''        let f = screen.frame
        let h = v.L + 60
        let y = f.minY
        // 窗口只比程序坞条略大（含放大余量和提示宽度），条目变化时才调整
        let w = min(f.width, (v.baseWidth + (v.L - v.S) * 3 + 300).rounded())
        let nf = NSRect(x: (f.midX - w / 2).rounded(), y: y, width: w, height: h)
        if nf == p.frame { return }
        let dx = p.frame.width > 0 ? p.frame.minX - nf.minX : 0
        p.setFrame(nf, display: true)
        v.shiftX(dx)''')
R('p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)','p.level = NSWindow.Level(rawValue: max(28, Int(CGWindowLevelForKey(.dockWindow)) + 1))   // 同 CommandB')
R('''        panel = p; bar = v''','''        panel = p; bar = v
        v.onWidthChange = { [weak self] _ in self?.frameWindow() }''')
open(p,'w').write(s); print("ok")
