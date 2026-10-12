import re
s=open("CustomDock.swift").read()
open("/tmp/CustomDock.v7.swift","w").write(s)
s=s.replace("// MARK: - 原生风格程序坞视图（Core Animation 图层）",'''// MARK: - 原生参数（见 NATIVE_PARAMS.md；尺寸从 com.apple.dock 读取）
enum NativeDock {
    static let iconGap: CGFloat = 4
    static let barPadX: CGFloat = 9
    static let barExtraH: CGFloat = 20
    static let bottomMargin: CGFloat = 5.5
    static let cornerRadius: CGFloat = 26
    static let iconBaseY: CGFloat = 10
    static let dotSize: CGFloat = 4, dotY: CGFloat = 3
    static let falloff: CGFloat = 3.0
    static let magEnterOmega: CGFloat = 30
    static let slideOmega: CGFloat = 14
    static let tooltipGap: CGFloat = 8, tooltipFont: CGFloat = 13
    static let menuGap: CGFloat = 10
    static let bounceDuration: CFTimeInterval = 1.4
}

// MARK: - 原生风格程序坞视图（Core Animation 图层）''')
s=s.replace("    let gap: CGFloat = 4\n    let barPadX: CGFloat = 9\n    let bottomMargin: CGFloat = 6\n    var barH: CGFloat { S + 16 }",
            "    let gap: CGFloat = NativeDock.iconGap\n    let barPadX: CGFloat = NativeDock.barPadX\n    let bottomMargin: CGFloat = NativeDock.bottomMargin\n    var barH: CGFloat { S + NativeDock.barExtraH }")
assert "NativeDock.barExtraH" in s
s=s.replace('''    func targetScale(center: CGFloat) -> CGFloat {
        guard magnify, let mx = mouseX else { return 1 }
        let R = S * 3.0''','''    var magAmount: CGFloat = 0
    private var magVel: CGFloat = 0
    var lastMouseX: CGFloat? = nil
    func targetScale(center: CGFloat) -> CGFloat {
        guard magnify, magAmount > 0.0005, let mx = mouseX ?? lastMouseX else { return 1 }
        let R = S * NativeDock.falloff''')
s=s.replace('''        return 1 + (L / S - 1) * t * t
    }''','''        return 1 + (L / S - 1) * t * t * magAmount
    }''',1)
old='''        for (id, target) in targetsW {
            var w = dispW[id] ?? target, v = velW[id] ?? 0
            Self.spring(&w, &v, to: target, dt: dt, omega: 28)
            if abs(w - target) < 0.05 && abs(v) < 0.5 { w = target; v = 0 } else { settled = false }
            dispW[id] = w; velW[id] = v
        }'''
assert old in s
s=s.replace(old,'''        // 悬停时宽度直接跟随光标（无弹簧滞后）；只有进入/离开用缓动
        for (id, target) in targetsW {
            if id == "div99" {
                var w = dispW[id] ?? 0, v = velW[id] ?? 0
                Self.spring(&w, &v, to: target, dt: dt, omega: 28)
                if abs(w - target) > 0.05 { settled = false }
                dispW[id] = w; velW[id] = v
            } else { dispW[id] = target; velW[id] = 0 }
        }
        if let m = mouseX { lastMouseX = m }
        let magT: CGFloat = mouseX == nil ? 0 : 1
        Self.spring(&magAmount, &magVel, to: magT, dt: dt, omega: NativeDock.magEnterOmega)
        if abs(magAmount - magT) < 0.001 && abs(magVel) < 0.01 { magAmount = magT; magVel = 0; if magT == 0 { lastMouseX = nil } } else { settled = false }''')
# step: widths computed using targetScale which needs magAmount updated first -> fine (one frame lag on enter only)
old='''        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()'''
assert old in s
s=s.replace(old,'''        let style = UserDefaults.standard.string(forKey: "customDockGlassStyle") ?? "edge"
        if style == "edge" {
            // 原生 macOS 27 程序坞用私有 DockGlassMaterialLayerController（折射、几乎无模糊/着色、亮细边）
            // 公开 API 无法复刻折射；用几乎透明的底 + 亮细边 + 顶部高光贴近观感
            let v = NSView(); v.wantsLayer = true
            let l = v.layer!
            l.cornerRadius = NativeDock.cornerRadius; l.cornerCurve = .continuous
            l.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
            l.borderWidth = 1; l.borderColor = NSColor(white: 1, alpha: 0.50).cgColor
            let hl = CAGradientLayer()
            hl.colors = [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0.0).cgColor]
            hl.startPoint = CGPoint(x: 0.5, y: 1); hl.endPoint = CGPoint(x: 0.5, y: 0.55)
            hl.cornerRadius = NativeDock.cornerRadius; hl.cornerCurve = .continuous
            hl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            hl.frame = l.bounds
            l.addSublayer(hl)
            glass = v
        } else if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()''')
s=s.replace("il.position = CGPoint(x: c, y: barY + 9)","il.position = CGPoint(x: c, y: barY + NativeDock.iconBaseY)")
s=s.replace("d.frame = CGRect(x: c - 2, y: barY + 2.5, width: 4, height: 4)","d.frame = CGRect(x: c - NativeDock.dotSize / 2, y: barY + NativeDock.dotY, width: NativeDock.dotSize, height: NativeDock.dotSize)")
s=s.replace("g.cornerRadius = 26","g.cornerRadius = NativeDock.cornerRadius")

# ---- unified order: apps + groups
old='''    var pinned: [String] {
        get { ud.stringArray(forKey: "customDockPinned") ?? [] }
        set { ud.set(newValue, forKey: "customDockPinned"); rebuild() }
    }'''
assert old in s
s=s.replace(old,'''    var pinned: [String] {
        get { ud.stringArray(forKey: "customDockPinned") ?? [] }
        set {
            ud.set(newValue, forKey: "customDockPinned")
            // 同步到统一顺序：保留分组位置，按新顺序替换应用
            var ord = order.filter { !$0.hasPrefix("app:") || newValue.contains(String($0.dropFirst(4))) }
            let present = Set(ord)
            var it = newValue.makeIterator()
            ord = ord.map { $0.hasPrefix("app:") ? "app:" + (it.next() ?? String($0.dropFirst(4))) : $0 }
            while let p = it.next() { if !present.contains("app:" + p) { ord.append("app:" + p) } }
            ud.set(ord, forKey: "customDockOrder")
            rebuild()
        }
    }
    // 统一顺序（应用和分组可自由交错）："app:<path>" / "group:<uuid>"
    var order: [String] {
        get {
            if let o = ud.stringArray(forKey: "customDockOrder") { return o }
            return pinned.map { "app:" + $0 } + GroupManager.shared.groups.sorted { $0.order < $1.order }.map { "group:" + $0.id.uuidString }
        }
        set { ud.set(newValue, forKey: "customDockOrder"); ud.set(newValue.filter { $0.hasPrefix("app:") }.map { String($0.dropFirst(4)) }, forKey: "customDockPinned"); rebuild() }
    }''')
old='''        for p in pinned where !grouped.contains(p) && !seen.contains(p) && FileManager.default.fileExists(atPath: p) {
            e.append(.app(path: p, pinned: true)); seen.insert(p)
        }
        for g in GroupManager.shared.groups.sorted(by: { $0.order < $1.order }) { e.append(.group(g.id)) }'''
assert old in s
s=s.replace(old,'''        let groups = GroupManager.shared.groups
        var seenGroups = Set<UUID>()
        for tok in order {
            if tok.hasPrefix("app:") {
                let p = String(tok.dropFirst(4))
                if !grouped.contains(p) && !seen.contains(p) && FileManager.default.fileExists(atPath: p) { e.append(.app(path: p, pinned: true)); seen.insert(p) }
            } else if tok.hasPrefix("group:"), let id = UUID(uuidString: String(tok.dropFirst(6))), groups.contains(where: { $0.id == id }), !seenGroups.contains(id) {
                e.append(.group(id)); seenGroups.insert(id)
            }
        }
        for g in groups.sorted(by: { $0.order < $1.order }) where !seenGroups.contains(g.id) { e.append(.group(g.id)) }''')
# draggable groups
old='''            if case .app(_, let pinned) = e, pinned, i > 0 { draggable = true }'''
assert old in s
s=s.replace(old,'''            if case .app(_, let pinned) = e, pinned, i > 0 { draggable = true }
            if case .group = e { draggable = true }''')
# drop handling
old='''            if case .app(let path, _) = model.entries.first(where: { $0.id == d.id }) ?? .trash {
                if outsideBar(d.y) {'''
assert old in s
s=s.replace(old,'''            let dragged = model.entries.first(where: { $0.id == d.id }) ?? .trash
            if case .group = dragged {
                // 分组：拖出不删除，回弹归位；在条内则保存新顺序
                if !outsideBar(d.y) {
                    let list = orderedEntries
                    dispX[d.id] = d.x; velX[d.id] = 0; reordering = true
                    dragState = nil
                    commitOrder(list)
                } else { dispX[d.id] = d.x; velX[d.id] = 0; reordering = true }
                dragState = nil; startLink(); return
            }
            if case .app(let path, _) = dragged {
                if outsideBar(d.y) {''')
old='''                    let newPinned = list.compactMap { e -> String? in if case .app(let pp, true) = e, pp != model.finderPath { return pp }; return nil }
                    let hidden = model.pinned.filter { !newPinned.contains($0) }   // 分组内等未显示的保留
                    model.pinned = newPinned + hidden'''
assert old in s
s=s.replace(old,'''                    commitOrder(list)''')
s=s.replace('''    func poof(at p: NSPoint) {''','''    func commitOrder(_ list: [DockEntry]) {
        var toks: [String] = []
        for e in list {
            switch e {
            case .app(let p, true) where p != model.finderPath: toks.append("app:" + p)
            case .group(let id): toks.append("group:" + id.uuidString)
            default: break
            }
        }
        let hidden = model.order.filter { !toks.contains($0) }   // 分组内等未显示的保留
        model.order = toks + hidden
    }

    func poof(at p: NSPoint) {''')
# grouping drag cursor: no poof cursor for groups
s=s.replace('''if outsideBar(p.y) { NSCursor.disappearingItem.set() } else { NSCursor.arrow.set() }''','''if outsideBar(p.y) && d.id.hasPrefix("app:") { NSCursor.disappearingItem.set() } else { NSCursor.arrow.set() }''')
open("CustomDock.swift","w").write(s)

m=open("Models.swift").read()
old='''        for (idx, app) in shown.enumerated() {
            guard let icon = app.getIcon() else { continue }
            let row = idx / n, col = idx % n
            let x = area.minX + CGFloat(col) * (cell + gap)
            let y = area.maxY - CGFloat(row + 1) * cell - CGFloat(row) * gap'''
assert old in m
m=m.replace(old,'''        // 网格在框内上下左右居中（不满行时整体垂直居中）
        let rows = max(1, Int(ceil(Double(shown.count) / Double(n))))
        let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        let top = area.midY + gridH / 2
        for (idx, app) in shown.enumerated() {
            guard let icon = app.getIcon() else { continue }
            let row = idx / n, col = idx % n
            let x = area.minX + CGFloat(col) * (cell + gap)
            let y = top - CGFloat(row + 1) * cell - CGFloat(row) * gap''')
open("Models.swift","w").write(m)
print("ok")
