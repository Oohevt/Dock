import SwiftUI
import AppKit
import Combine

// MARK: - 自定义程序坞

enum DockEntry: Identifiable, Equatable {
    case app(path: String, pinned: Bool)
    case group(UUID)
    case trash
    case divider(Int)
    var id: String {
        switch self {
        case .app(let p, _): return "app:" + p
        case .group(let id): return "group:" + id.uuidString
        case .trash: return "trash"
        case .divider(let i): return "div\(i)"
        }
    }
}

final class CustomDockModel: ObservableObject {
    static let shared = CustomDockModel()
    @Published var entries: [DockEntry] = []
    @Published var running: Set<String> = []
    private let ud = UserDefaults.standard
    private var bag = Set<AnyCancellable>()
    let finderPath = "/System/Library/CoreServices/Finder.app"

    var pinned: [String] {
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
    }

    init() {
        if ud.stringArray(forKey: "customDockPinned") == nil { importSystemDock() }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.publisher(for: n).receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        }
        GroupManager.shared.$groups.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }.store(in: &bag)
        rebuild()
    }

    static func norm(_ p: String) -> String {
        var s = URL(fileURLWithPath: p).standardizedFileURL.path
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func importSystemDock() {
        var list: [String] = []
        if let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] {
            for t in apps {
                if let td = t["tile-data"] as? [String: Any], let fd = td["file-data"] as? [String: Any],
                   let s = fd["_CFURLString"] as? String, let u = URL(string: s), u.isFileURL {
                    let p = Self.norm(u.path)
                    if p.contains("/DockGroups/Launchers/") { continue }
                    list.append(p)
                }
            }
        }
        ud.set(list, forKey: "customDockPinned")
    }

    var groupedPaths: Set<String> {
        Set(GroupManager.shared.groups.flatMap { $0.apps.map { Self.norm($0.path) } })
    }

    func rebuild() {
        let grouped = groupedPaths
        let runApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        running = Set(runApps.compactMap { $0.bundleURL.map { Self.norm($0.path) } })
        var e: [DockEntry] = [.app(path: finderPath, pinned: true)]
        var seen: Set<String> = [finderPath]
        let groups = GroupManager.shared.groups
        var seenGroups = Set<UUID>()
        for tok in order {
            if tok.hasPrefix("app:") {
                let p = String(tok.dropFirst(4))
                if !grouped.contains(p) && !seen.contains(p) && FileManager.default.fileExists(atPath: p) { e.append(.app(path: p, pinned: true)); seen.insert(p) }
            } else if tok.hasPrefix("group:"), let id = UUID(uuidString: String(tok.dropFirst(6))), groups.contains(where: { $0.id == id }), !seenGroups.contains(id) {
                e.append(.group(id)); seenGroups.insert(id)
            }
        }
        for g in groups.sorted(by: { $0.order < $1.order }) where !seenGroups.contains(g.id) { e.append(.group(g.id)) }
        var extra: [DockEntry] = []
        for r in runApps {
            guard let u = r.bundleURL else { continue }
            let p = Self.norm(u.path)
            if seen.contains(p) || grouped.contains(p) || r.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            if p.contains("/DockGroups/Launchers/") { continue }
            extra.append(.app(path: p, pinned: false)); seen.insert(p)
        }
        if !extra.isEmpty { e.append(.divider(1)); e += extra }
        e.append(.divider(2)); e.append(.trash)
        if e != entries { entries = e }
        CustomDockController.shared.relayout()
    }

    // 角标（未读数）：和系统程序坞读同一份 LaunchServices 数据，不需要任何授权
    var badges: [String: String] = [:]
    private var badgeAsking = false
    func refreshBadges(_ changed: @escaping () -> Void) {
        if badgeAsking { return }
        badgeAsking = true
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { r in r.bundleURL.map { (r.processIdentifier, Self.norm($0.path)) } }
        DispatchQueue.global(qos: .utility).async {   // 一轮约 7ms，不能放主线程（120Hz 一帧才 8ms）
            var b: [String: String] = [:]
            for (pid, path) in apps { if let l = AppBadge.label(pid: pid) { b[path] = l } }
            DispatchQueue.main.async {
                self.badgeAsking = false
                if b != self.badges { self.badges = b; changed() }
            }
        }
    }
    // 分组的角标 = 组内应用未读数之和
    func badge(for e: DockEntry) -> String? {
        switch e {
        case .app(let p, _): return badges[p]
        case .group(let gid):
            guard let g = GroupManager.shared.groups.first(where: { $0.id == gid }) else { return nil }
            let ls = g.apps.compactMap { badges[Self.norm($0.path)] }
            if ls.isEmpty { return nil }
            let nums = ls.compactMap { Int($0) }
            return nums.isEmpty ? ls[0] : String(nums.reduce(0, +))
        default: return nil
        }
    }

    func runningApp(_ path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL.map { Self.norm($0.path) } == path }
    }
    func openOrSwitch(_ path: String) {
        dgLog("openOrSwitch \(path)")
        // 用 LaunchServices 打开/激活：已运行则切换，未运行则启动（系统负责激活，避免 macOS 14+ 协作激活限制）
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { app, err in
            dgLog("openApplication result app=\(app?.bundleIdentifier ?? "nil") err=\(err?.localizedDescription ?? "nil")")
        }
    }
    func pin(_ p: String) { var l = pinned; if !l.contains(p) { l.append(p) }; pinned = l }
    func unpin(_ p: String) { pinned = pinned.filter { $0 != p } }
}


// MARK: - 原生参数（见 NATIVE_PARAMS.md；尺寸从 com.apple.dock 读取）
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

// MARK: - 原生风格程序坞视图（Core Animation 图层）

var dgCustomDockTop: CGFloat? = nil

final class DockBarView: NSView {
    let model = CustomDockModel.shared
    var S: CGFloat = 70          // 系统 tilesize
    var L: CGFloat = 89          // 系统 largesize
    var magnify = true
    let gap: CGFloat = NativeDock.iconGap
    let barPadX: CGFloat = NativeDock.barPadX
    let bottomMargin: CGFloat = NativeDock.bottomMargin
    var barH: CGFloat { S + NativeDock.barExtraH }

    private var iconLayers: [String: CALayer] = [:]
    private var dotLayers: [String: CALayer] = [:]
    private var sepLayers: [String: CALayer] = [:]
    private var badgeLayers: [String: CALayer] = [:]
    private var runningIDs = Set<String>()
    private var badgeText: [String: String] = [:]
    private var badgeAspect: [String: CGFloat] = [:]
    var dropTarget: String?              // 拖动时压在哪个图标中心上：分组 = 放进分组；应用 = 用它打开文件
    private var lastInsert = 0
    var menuOpen = false                 // 右键菜单打开期间：保持放大、不收起、不显示名称提示
    private var tipSuppressed: String?   // 刚点过的图标不再显示名称提示（会和弹跳、分组面板叠在一起），鼠标移到别处才恢复
    private let glass: NSView
    private let iconHost = NSView()
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); overlay.frame = bounds }
    func shiftX(_ dx: CGFloat) {
        guard dx != 0 else { return }
        for k in dispX.keys { dispX[k]! += dx }
        if var d = dragState { d.x += dx; d.startX += dx; dragState = d }
        lastGlass = .zero
        applyLayout()
    }
    let overlay = NSView()          // 浮层：提示
    private let tipBg = CALayer()
    private let tipText = CATextLayer()
    var mouseX: CGFloat? = nil
    private var tracking: NSTrackingArea?
    private var pressedIndex: Int? = nil
    var onWidthChange: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        // 液态玻璃条：自身裁剪圆角、无描边；通透折射靠 DockPanel.hasKeyAppearance。图标放在它上层
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .clear; g.cornerRadius = NativeDock.cornerRadius
            g.contentView = NSView()
            g.wantsLayer = true; g.layer?.borderWidth = 0; g.layer?.masksToBounds = true
            glass = g
        } else {
            let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = NativeDock.cornerRadius; v.layer?.cornerCurve = .continuous; v.layer?.masksToBounds = true
            glass = v
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        glass.wantsLayer = true
        addSubview(glass)
        iconHost.wantsLayer = true
        iconHost.layer?.masksToBounds = false
        // 图标在玻璃之上而不是玻璃里面：玻璃会裁剪内容，放大的图标顶部会被切掉
        iconHost.autoresizingMask = [.width, .height]
        addSubview(iconHost)
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = false
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        tipBg.backgroundColor = NSColor(white: 0.12, alpha: 0.72).cgColor
        tipBg.cornerRadius = 8
        tipBg.opacity = 0
        tipText.fontSize = 13
        tipText.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        tipText.foregroundColor = NSColor.white.cgColor
        tipText.alignmentMode = .center
        tipBg.addSublayer(tipText)
        overlay.layer?.addSublayer(tipBg)
        readSystemPrefs()
        setupDrop()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func readSystemPrefs() {
        let d = UserDefaults(suiteName: "com.apple.dock")
        if let t = d?.object(forKey: "tilesize") as? Double, t > 16 { S = CGFloat(t) }
        if let l = d?.object(forKey: "largesize") as? Double, l > 16 { L = CGFloat(l) }
        magnify = (d?.object(forKey: "magnification") as? Bool) ?? false
        if L < S { L = S }
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); reloadIcons() }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    // 图标图像（按屏幕倍率生成，保证清晰）
    func image(for e: DockEntry) -> NSImage {
        switch e {
        case .app(let p, _): return AppIconCache.icon(forPath: p)
        case .trash: return CustomDockModel.trashIcon()
        case .group(let gid):
            if let g = GroupManager.shared.groups.first(where: { $0.id == gid }), let img = g.generateIcon(size: CGSize(width: 512, height: 512)) {
                return img
            }
            return NSImage()
        case .divider: return NSImage()
        }
    }

    // 以目标像素尺寸高质量预渲染（避免运行时大幅缩放造成锯齿/模糊）
    static func render(_ img: NSImage, px: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    func label(for e: DockEntry) -> String {
        switch e {
        case .app(let p, _):
            var n = FileManager.default.displayName(atPath: p); if n.hasSuffix(".app") { n.removeLast(4) }; return n
        case .trash: return "废纸篓"
        case .group(let gid): return GroupManager.shared.groups.first(where: { $0.id == gid })?.name ?? ""
        case .divider: return ""
        }
    }

    func reloadIcons() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let px = L * scale
        var alive = Set<String>()
        for e in model.entries {
            alive.insert(e.id)
            if case .divider = e {
                if sepLayers[e.id] == nil {
                    let l = CALayer(); l.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
                    iconHost.layer?.addSublayer(l); sepLayers[e.id] = l
                }
                continue
            }
            let il = iconLayers[e.id] ?? {
                let l = CALayer(); l.contentsGravity = .resizeAspect; l.minificationFilter = .trilinear
                l.anchorPoint = CGPoint(x: 0.5, y: 0); iconHost.layer?.addSublayer(l); iconLayers[e.id] = l; return l
            }()
            var key = "\(e.id)@\(Int(px))#\(iconVersion)"
            if case .group(let gid) = e, let g = GroupManager.shared.groups.first(where: { $0.id == gid }) { key += g.apps.map { $0.path }.joined(separator: "|") }
            // 废纸篓空/满、应用更新后换图标：都算进缓存键，变了才重新渲染
            if case .trash = e { key += CustomDockModel.trashFull ? "F" : "E" }
            if case .app(let p, _) = e, let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date { key += "@\(d.timeIntervalSince1970)" }
            if contentKeys[e.id] != key {
                if case .app(let p, _) = e { AppIconCache.cache[p] = nil }
                il.contents = Self.render(image(for: e), px: Int(px.rounded(.up)))
                contentKeys[e.id] = key
            }
            il.contentsScale = scale
            il.minificationFilter = .linear; il.magnificationFilter = .linear
            if dotLayers[e.id] == nil {
                let d = CALayer(); d.cornerRadius = NativeDock.dotSize / 2
                // 玻璃改为透明后黑点在深色壁纸上看不见：浅色点 + 细深色描边 + 微阴影，深浅背景都可见
                d.backgroundColor = NSColor(white: 0.95, alpha: 0.95).cgColor
                d.borderWidth = 0.5; d.borderColor = NSColor(white: 0, alpha: 0.45).cgColor
                d.shadowColor = NSColor.black.cgColor; d.shadowOpacity = 0.35; d.shadowRadius = 1; d.shadowOffset = .zero
                d.zPosition = 2
                iconHost.layer?.addSublayer(d); dotLayers[e.id] = d
            }
        }
        for (k, l) in iconLayers where !alive.contains(k) { l.removeFromSuperlayer(); iconLayers[k] = nil }
        for (k, l) in dotLayers where !alive.contains(k) { l.removeFromSuperlayer(); dotLayers[k] = nil }
        for (k, l) in sepLayers where !alive.contains(k) { l.removeFromSuperlayer(); sepLayers[k] = nil }
        tipBg.zPosition = 10
        // 哪些条目要亮运行指示点：在这里算好。以前每帧都算，分组里每个应用都要规范化一次路径（一次磁盘查询），放大时占了三成多 CPU
        runningIDs = Set(model.entries.filter { e in
            if case .app(let p, _) = e { return model.running.contains(p) }
            if case .group(let gid) = e, let g = GroupManager.shared.groups.first(where: { $0.id == gid }) {
                return g.apps.contains { model.running.contains(CustomDockModel.norm($0.path)) }
            }
            return false
        }.map { $0.id })
        reloadBadges()
        onWidthChange?(baseWidth)
    }

    // 角标预渲染成位图（按放大后的最大尺寸），放大时只缩放图层
    static func badgeImage(_ text: String, h: CGFloat, scale: CGFloat) -> (CGImage, CGFloat)? {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: h * 0.62, weight: .medium), .foregroundColor: NSColor.white]
        let ts = (text as NSString).size(withAttributes: attrs)
        let w = max(h, ts.width + h * 0.56)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
            NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            (text as NSString).draw(at: NSPoint(x: (w - ts.width) / 2, y: (h - ts.height) / 2), withAttributes: attrs)
            return true
        }
        var px = NSRect(x: 0, y: 0, width: w * scale, height: h * scale)
        guard let cg = img.cgImage(forProposedRect: &px, context: nil, hints: nil) else { return nil }
        return (cg, w / h)
    }
    static let badgeRatio: CGFloat = 0.3   // 角标高度 / 图标边长

    func reloadBadges() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var alive = Set<String>()
        for e in model.entries {
            guard let t = model.badge(for: e) else { continue }
            alive.insert(e.id)
            let l = badgeLayers[e.id] ?? {
                let l = CALayer(); l.zPosition = 3
                l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = 0.3; l.shadowRadius = 1.5; l.shadowOffset = CGSize(width: 0, height: -0.5)
                iconHost.layer?.addSublayer(l); badgeLayers[e.id] = l; return l
            }()
            if badgeText[e.id] != t, let (img, aspect) = Self.badgeImage(t, h: L * Self.badgeRatio, scale: scale) {
                l.contents = img; badgeText[e.id] = t; badgeAspect[e.id] = aspect
            }
        }
        for (k, l) in badgeLayers where !alive.contains(k) { l.removeFromSuperlayer(); badgeLayers[k] = nil; badgeText[k] = nil; badgeAspect[k] = nil }
        layoutDock(animated: false)
    }

    // 放大曲线（接近原生：余弦平方衰减，影响范围约 3 个图标）
    var magAmount: CGFloat = 0
    private var magVel: CGFloat = 0
    var lastMouseX: CGFloat? = nil
    func targetScale(center: CGFloat) -> CGFloat {
        guard magnify, magAmount > 0.0005, let mx = mouseX ?? lastMouseX else { return 1 }
        let R = S * NativeDock.falloff
        let d = abs(mx - center)
        if d >= R { return 1 }
        let t = cos(.pi / 2 * d / R)
        return 1 + (L / S - 1) * t * t * magAmount
    }

    // 逐帧弹簧动画（屏幕刷新率，120Hz ProMotion 下同样 120 帧）
    private var contentKeys: [String: String] = [:]
    var iconVersion = 0
    private var dispX: [String: CGFloat] = [:]
    private var velX: [String: CGFloat] = [:]
    private var dispW: [String: CGFloat] = [:]
    private var velW: [String: CGFloat] = [:]
    var slide: CGFloat = 0          // 0=显示 1=隐藏
    var slideTarget: CGFloat = 0
    private var slideVel: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTs: CFTimeInterval = 0
    var dragState: DragState? = nil
    var dropInsert: Int? = nil       // 外部拖入时的插入位置（条目索引）

    struct DragState { var id: String; var index: Int; var x: CGFloat; var y: CGFloat; var startX: CGFloat; var startY: CGFloat; var active: Bool }

    func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(frameTick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l; lastTs = 0
    }

    // 临界阻尼弹簧，ω 越大越快（原生约 0.2s 收敛）
    static func spring(_ x: inout CGFloat, _ v: inout CGFloat, to target: CGFloat, dt: CGFloat, omega: CGFloat) {
        let f = 1 + 2 * dt * omega
        let oo = omega * omega
        let hoo = dt * oo
        let hhoo = dt * hoo
        let detInv = 1 / (f + hhoo)
        let detX = f * x + dt * v + hhoo * target
        let detV = v + hoo * (target - x)
        x = detX * detInv; v = detV * detInv
    }

    @objc func frameTick(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = CGFloat(lastTs == 0 ? 1.0 / 120 : min(now - lastTs, 1.0 / 30))
        lastTs = now
        let settled = step(dt: dt)
        applyLayout()
        if settled { l.invalidate(); link = nil }
    }

    var orderedEntries: [DockEntry] {
        var list = model.entries
        if let d = dragState, d.active, let from = list.firstIndex(where: { $0.id == d.id }) {
            let e = list.remove(at: from)
            if outsideBar(d.y) { return list }   // 拖出程序坞：其他图标合拢
            // 压在分组上时冻结排序，否则分组图标会在光标两侧来回让位
            if dropTarget == nil { lastInsert = insertIndex(for: d.x, excluding: d.id, list: list) }
            list.insert(e, at: min(lastInsert, list.count))
        } else if let ins = dropInsert {
            list.insert(.divider(99), at: min(ins, list.count))   // 占位
        }
        return list
    }

    func outsideBar(_ y: CGFloat) -> Bool { y > bottomMargin + barH + 50 }

    func insertIndex(for x: CGFloat, excluding id: String, list: [DockEntry]) -> Int {
        // 只允许插在 Finder 之后、分隔线（运行中区）之前
        var lo = 1, hi = list.firstIndex(where: { if case .divider = $0 { return true }; return false }) ?? list.count
        if hi < lo { hi = lo }
        var bestI = lo, bestD = CGFloat.greatestFiniteMagnitude
        var cx = (bounds.width - baseWidth) / 2 + barPadX
        for i in 0...list.count {
            if i >= lo && i <= hi { let d = abs(x - cx); if d < bestD { bestD = d; bestI = i } }
            if i < list.count { if case .divider = list[i] { cx += 13 } else { cx += S + gap } }
        }
        return bestI
    }

    // 欠阻尼弹簧（轻微回弹，约 0.25s 稳定）——用于拖动时位置
    static func bouncy(_ x: inout CGFloat, _ v: inout CGFloat, to t: CGFloat, dt: CGFloat, omega: CGFloat = 26, zeta: CGFloat = 0.72) {
        let steps = max(1, Int(ceil(dt / (1.0 / 240))))
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            let a = -omega * omega * (x - t) - 2 * zeta * omega * v
            v += a * h; x += v * h
        }
    }

    // 计算每个图标的目标宽度/中心，并逐帧推进；返回是否已静止
    func step(dt: CGFloat) -> Bool {
        let list = orderedEntries
        var x = (bounds.width - widthOf(list)) / 2 + barPadX
        var settled = true
        // 1) 宽度（放大）
        var targetsW: [String: CGFloat] = [:]
        for e in list {
            let isDiv: Bool = { if case .divider = e { return true }; return false }()
            let base: CGFloat = isDiv ? (e.id == "div99" ? S : 13) : S
            targetsW[e.id] = isDiv ? base : S * targetScale(center: x + S / 2)
            x += base + (isDiv ? 0 : gap)
        }
        // 悬停时宽度直接跟随光标（无弹簧滞后）；只有进入/离开用缓动
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
        if abs(magAmount - magT) < 0.001 && abs(magVel) < 0.01 { magAmount = magT; magVel = 0; if magT == 0 { lastMouseX = nil } } else { settled = false }
        // 2) 目标中心（按当前显示宽度排布），位置用欠阻尼弹簧
        var total: CGFloat = 0
        for e in list { let w = dispW[e.id] ?? S; if case .divider = e { total += w } else { total += w + gap } }
        total -= gap
        var cx = (bounds.width - total) / 2
        let dragging = dragState?.active == true ? dragState!.id : nil
        for e in list {
            let w = dispW[e.id] ?? S
            let center = cx + w / 2
            if e.id == dragging, let d = dragState {
                dispX[e.id] = d.x; velX[e.id] = 0
            } else {
                var px = dispX[e.id] ?? center, v = velX[e.id] ?? 0
                if reordering { Self.bouncy(&px, &v, to: center, dt: dt) } else { px = center; v = 0 }
                if abs(px - center) < 0.1 && abs(v) < 1 { px = center; v = 0 } else { settled = false }
                dispX[e.id] = px; velX[e.id] = v
            }
            if case .divider = e { cx += w } else { cx += w + gap }
        }
        if reordering && settled && dragState == nil { reordering = false }
        Self.spring(&slide, &slideVel, to: slideTarget, dt: dt, omega: slideOmega)
        if abs(slide - slideTarget) < 0.002 && abs(slideVel) < 0.01 { slide = slideTarget; slideVel = 0 } else { settled = false }
        if dragState?.active == true { settled = false }
        return settled
    }
    var slideOmega: CGFloat = 14   // 原生默认（autohide-time-modifier 未设置）约 0.4–0.5s
    var reordering = false   // 拖动排序/拖入期间及落位回弹期间为 true

    func widthOf(_ list: [DockEntry]) -> CGFloat {
        var w = barPadX * 2
        for e in list { if case .divider = e { w += (e.id == "div99" ? S + gap : 13) } else { w += S + gap } }
        return w - gap
    }
    var baseWidth: CGFloat { widthOf(model.entries) }

    func layoutDock(animated: Bool) { startLink() }

    // 只改图层属性（关闭隐式动画）；玻璃视图仅在尺寸变化超过半像素时调整
    var lastGlass = NSRect.zero
    func applyLayout() {
        let list = orderedEntries
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hideOffset = (barH + bottomMargin + 6) * slide
        let barY = bottomMargin - hideOffset
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        let dragging = dragState?.active == true ? dragState!.id : nil
        for e in list where e.id != dragging || !(dragState.map { outsideBar($0.y) } ?? false) {
            let w = dispW[e.id] ?? S, c = dispX[e.id] ?? 0
            if e.id == dragging { continue }
            minX = min(minX, c - w / 2); maxX = max(maxX, c + w / 2)
        }
        if minX < maxX {
            let gf = NSRect(x: ((minX - barPadX) * 2).rounded() / 2, y: (barY * 2).rounded() / 2, width: ((maxX - minX + barPadX * 2) * 2).rounded() / 2, height: barH)
            if abs(gf.minX - lastGlass.minX) > 0.25 || abs(gf.width - lastGlass.width) > 0.25 || abs(gf.minY - lastGlass.minY) > 0.25 {
                glass.frame = gf; lastGlass = gf
            }
        }
        for e in list {
            let w = dispW[e.id] ?? S, c = dispX[e.id] ?? 0
            if case .divider = e {
                if e.id != "div99" { sepLayers[e.id]?.frame = CGRect(x: c - 0.5, y: barY + 12, width: 1, height: barH - 24) }
                continue
            }
            guard let il = iconLayers[e.id] else { continue }
            if e.id == dragging, let d = dragState {
                // 被拖图标：浮层，精确跟随光标
                let ds = dropTarget == nil ? S : S * 0.7   // 要落进分组时缩小一点
                il.bounds = CGRect(x: 0, y: 0, width: ds, height: ds)
                il.position = CGPoint(x: d.x, y: d.y - ds / 2)
                il.opacity = outsideBar(d.y) ? 0.55 : (dropTarget == nil ? 1 : 0.85)
                il.zPosition = 5
                dotLayers[e.id]?.opacity = 0
                badgeLayers[e.id]?.opacity = 0
                continue
            }
            il.bounds = CGRect(x: 0, y: 0, width: w, height: w)
            il.position = CGPoint(x: c, y: barY + NativeDock.iconBaseY)
            il.opacity = 1; il.zPosition = 0
            il.setAffineTransform(e.id == dropTarget ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity)   // 拖放目标：微微鼓起
            if let b = badgeLayers[e.id] {
                // 贴在图标右上角，跟着放大一起变大
                let h = w * Self.badgeRatio, bw = h * (badgeAspect[e.id] ?? 1), inset = w * 0.02
                b.frame = CGRect(x: c + w / 2 - inset - bw, y: barY + NativeDock.iconBaseY + w - inset - h, width: bw, height: h)
                b.opacity = 1
            }
            let running = runningIDs.contains(e.id)
            if let d = dotLayers[e.id] {
                d.frame = CGRect(x: c - NativeDock.dotSize / 2, y: barY + NativeDock.dotY, width: NativeDock.dotSize, height: NativeDock.dotSize)
                d.opacity = running ? 1 : 0
            }
        }
        CATransaction.commit()
        updateTooltip()
    }

    func centerOfEntry(_ i: Int) -> NSPoint? {
        guard i < model.entries.count, let l = iconLayers[model.entries[i].id] else { return nil }
        return NSPoint(x: l.frame.midX, y: l.frame.midY)
    }

    func index(at p: NSPoint) -> Int? {
        for (i, e) in model.entries.enumerated() {
            if case .divider = e { continue }
            if let l = iconLayers[e.id], l.frame.insetBy(dx: -gap / 2, dy: -12).contains(p) { return i }
        }
        return nil
    }

    private var lastTip = ""
    func updateTooltip() {
        if mouseX == nil { tipSuppressed = nil }
        guard !menuOpen, dragState?.active != true, slide < 0.01, let mx = mouseX, let i = index(at: NSPoint(x: mx, y: bottomMargin + barH / 2)), let il = iconLayers[model.entries[i].id] else {
            tipBg.opacity = 0; lastTip = ""; return
        }
        if model.entries[i].id == tipSuppressed { tipBg.opacity = 0; lastTip = ""; return }
        tipSuppressed = nil
        let text = label(for: model.entries[i])
        if text == lastTip && tipBg.opacity == 1 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tipBg.position = CGPoint(x: il.position.x, y: il.frame.maxY + 8 + 12)
            CATransaction.commit(); return
        }
        lastTip = text
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 20
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tipText.string = text
        tipText.contentsScale = window?.backingScaleFactor ?? 2
        tipBg.frame = CGRect(x: il.position.x - w / 2, y: il.frame.maxY + 8, width: w, height: 24)
        tipText.frame = CGRect(x: 0, y: 4, width: w, height: 17)
        tipBg.opacity = 1
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        if menuOpen { return }
        let p = convert(event.locationInWindow, from: nil)
        let inBand = p.y <= bottomMargin + barH + (mouseX != nil ? (L - S) + 10 : 4) && slide < 0.5
        mouseX = inBand ? p.x : nil
        startLink()
    }
    override func mouseExited(with event: NSEvent) { if menuOpen { return }; mouseX = nil; startLink() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressedIndex = index(at: p)
        if let i = pressedIndex {
            let e = model.entries[i]
            var draggable = false
            if case .app(_, let pinned) = e, pinned, i > 0 { draggable = true }
            if case .group = e { draggable = true }
            if draggable { dragState = DragState(id: e.id, index: i, x: p.x, y: p.y, startX: p.x, startY: p.y, active: false) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = dragState else { return }
        let p = convert(event.locationInWindow, from: nil)
        d.x = p.x; d.y = p.y
        if !d.active && hypot(p.x - d.startX, p.y - d.startY) > 6 { d.active = true; reordering = true; mouseX = nil; tipBg.opacity = 0 }
        dragState = d
        dropTarget = (d.active && d.id.hasPrefix("app:") && !outsideBar(p.y)) ? centerHit(p.x, Self.isGroup) : nil
        if d.active { NSCursor.current.set(); if outsideBar(p.y) && d.id.hasPrefix("app:") { NSCursor.disappearingItem.set() } else { NSCursor.arrow.set() } }
        startLink()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dropTarget = nil }
        if let d = dragState, d.active {
            NSCursor.arrow.set()
            let dragged = model.entries.first(where: { $0.id == d.id }) ?? .trash
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
                if let g = targetGroup(), let info = AppInfo.from(url: URL(fileURLWithPath: path)) {
                    // 拖到分组上：放进分组（会从程序坞条上消失，出现在分组里）
                    dropTarget = nil; dragState = nil
                    GroupManager.shared.addApp(info, to: g)
                    startLink(); return
                }
                if outsideBar(d.y) {
                    poof(at: p)
                    dragState = nil
                    model.unpin(path)
                } else {
                    let list = orderedEntries
                    dispX[d.id] = d.x; velX[d.id] = 0
                    reordering = true
                    dragState = nil
                    commitOrder(list)
                }
            }
            dragState = nil
            startLink()
            return
        }
        dragState = nil
        let hit = index(at: p)
        dgLog("mouseUp at \(p) index=\(String(describing: hit)) pressed=\(String(describing: pressedIndex))")
        guard let i = hit ?? pressedIndex, i < model.entries.count else { return }
        let e = model.entries[i]
        tipSuppressed = e.id; tipBg.opacity = 0
        switch e {
        case .app(let path, _):
            if model.runningApp(path) == nil { bounce(e.id, path: path) }
            model.openOrSwitch(path)
        case .group(let gid): openGroup(gid)
        case .trash:
            CustomDockModel.finder("open trash\nactivate")
        case .divider: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p), let il = iconLayers[model.entries[i].id] else { return }
        let menu: NSMenu
        switch model.entries[i] {
        case .app(let path, let pinned): menu = buildAppMenu(path: path, pinned: pinned)
        case .trash: menu = buildTrashMenu()
        case .group(let gid): menu = buildGroupMenu(gid)
        default: return
        }
        // 菜单位置对每个图标固定：左边对齐图标左边缘、向右上方展开，底边在"放大到最大的图标"顶部上方 6pt。
        // 按图标的静止槽位算，不读图层当前的 frame —— 那是动画中的瞬时值（放大、切换图标时都在变），会让菜单忽左忽右
        // menu.size 把"按住 Option 才出现"的替换项（强制退出）也算成一行，要减掉，否则菜单会飘高一截
        let extra = menu.items.filter { $0.isAlternate || $0.isHidden }.count
        let h = menu.size.height - CGFloat(extra) * Self.menuRowHeight
        let inset: CGFloat = 0.095   // 图标图案在格子里四周的留白比例
        let pt = NSPoint(x: restCenter(i) - S / 2 + S * inset,
                         y: bottomMargin + NativeDock.iconBaseY + L * (1 - inset) + 6 + h - 4.5)   // AppKit 实际会把菜单再抬高约 4.5pt
        // 先把放大状态一步定到位（以当前鼠标为中心），菜单打开后图标不再变化
        mouseX = p.x; magAmount = magnify ? 1 : 0
        _ = step(dt: 1.0 / 120); applyLayout()
        // 菜单打开期间不显示名称提示：否则提示会被逐帧刷新重新显示，叠在菜单后面
        menuOpen = true; tipBg.opacity = 0
        menu.popUp(positioning: nil, at: pt, in: self)
        menuOpen = false
        // 菜单关闭后按鼠标当前位置重新决定是否放大
        if let w = window {
            let q = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            mouseX = (bounds.contains(q) && q.y <= bottomMargin + barH + (L - S) + 10) ? q.x : nil
        }
        startLink()
    }

    // 第 i 个条目不放大时的中心 x
    func restCenter(_ i: Int) -> CGFloat {
        var x = (bounds.width - baseWidth) / 2 + barPadX
        for (k, e) in model.entries.enumerated() {
            let isDiv: Bool = { if case .divider = e { return true }; return false }()
            if k == i { return x + S / 2 }
            x += isDiv ? 13 : S + gap
        }
        return x
    }

    static let menuRowHeight: CGFloat = {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "A", action: nil, keyEquivalent: "")); let one = m.size.height
        m.addItem(NSMenuItem(title: "B", action: nil, keyEquivalent: "")); return m.size.height - one
    }()

    func windowTitles(pid: pid_t) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let name = w[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    func openGroup(_ gid: UUID) {
        guard let g = GroupManager.shared.groups.first(where: { $0.id == gid }), let w = window, let il = iconLayers["group:" + gid.uuidString] else { return }
        dgCustomDockTop = w.frame.minY + bottomMargin + barH + 2
        dgPopupAnchorX = w.convertPoint(toScreen: NSPoint(x: il.position.x, y: 0)).x
        DockGroupsMain.delegate.menuBarManager?.showGroupPopup(for: g)
    }

    func buildGroupMenu(_ gid: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "打开") { [weak self] in self?.openGroup(gid) })
        menu.addItem(ClosureMenuItem(title: "重命名…") {
            guard var g = GroupManager.shared.groups.first(where: { $0.id == gid }) else { return }
            let a = NSAlert(); a.messageText = "重命名分组"
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); f.stringValue = g.name
            a.accessoryView = f; a.addButton(withTitle: "好"); a.addButton(withTitle: "取消")
            a.window.initialFirstResponder = f
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn {
                let n = f.stringValue.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { g.name = n; GroupManager.shared.updateGroup(g) }
            }
        })
        menu.addItem(ClosureMenuItem(title: "管理分组…") { NotificationCenter.default.post(name: .dgOpenSettings, object: nil) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "移除分组") {
            guard let g = GroupManager.shared.groups.first(where: { $0.id == gid }) else { return }
            let a = NSAlert(); a.messageText = "移除分组「\(g.name)」？"
            a.informativeText = "只是解散这个分组，里面的应用不会被删除。"
            a.addButton(withTitle: "移除"); a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { GroupManager.shared.deleteGroup(g) }
        })
        return menu
    }

    static func isGroup(_ e: DockEntry) -> Bool { if case .group = e { return true }; return false }
    // 光标是否压在某个图标的中心区域；已选中的目标范围放宽一点，避免在边界来回跳
    func centerHit(_ x: CGFloat, _ ok: (DockEntry) -> Bool) -> String? {
        for e in model.entries where ok(e) {
            if let c = dispX[e.id], abs(x - c) < S * (dropTarget == e.id ? 0.48 : 0.28) { return e.id }
        }
        return nil
    }
    func targetGroup() -> AppGroup? {
        guard let t = dropTarget, t.hasPrefix("group:"), let gid = UUID(uuidString: String(t.dropFirst(6))) else { return nil }
        return GroupManager.shared.groups.first { $0.id == gid }
    }

    func buildTrashMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "打开") { CustomDockModel.finder("open trash\nactivate") })
        // 是否弹确认框由访达自己的设置决定，和系统程序坞一样
        let empty = ClosureMenuItem(title: "清倒废纸篓") { [weak self] in
            CustomDockModel.finder("empty trash") { CustomDockModel.refreshTrash { self?.reloadIcons() } }
        }
        empty.isEnabled = CustomDockModel.trashFull
        menu.addItem(empty)
        return menu
    }

    func buildAppMenu(path: String, pinned: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let run = model.runningApp(path)
        func item(_ t: String, _ f: @escaping () -> Void) -> NSMenuItem { let it = ClosureMenuItem(title: t, action: f); return it }
        if let r = run {
            let titles = windowTitles(pid: r.processIdentifier)
            for t in titles.prefix(12) { menu.addItem(item(t) { [weak self] in self?.model.openOrSwitch(path) }) }
            if !titles.isEmpty { menu.addItem(.separator()) }
        }
        // 选项 子菜单
        let opt = NSMenu()
        let keep = item("保留在程序坞") { [weak self] in
            guard let self = self else { return }
            if pinned { self.model.unpin(path) } else { self.model.pin(path) }
        }
        keep.state = pinned ? .on : .off
        if path == model.finderPath { keep.isEnabled = false }
        opt.addItem(keep)
        let login = item("登录时打开") { LoginItems.toggle(path) }
        login.state = LoginItems.contains(path) ? .on : .off
        opt.addItem(login)
        if path == model.finderPath { menu.addItem(item("DockGroups 设置…") { NotificationCenter.default.post(name: .dgOpenSettings, object: nil) }); menu.addItem(.separator()) }
        opt.addItem(item("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
        let optItem = NSMenuItem(title: "选项", action: nil, keyEquivalent: ""); optItem.submenu = opt
        menu.addItem(optItem)
        menu.addItem(.separator())
        if let r = run {
            menu.addItem(item("显示所有窗口") { [weak self] in r.unhide(); self?.model.openOrSwitch(path) })
            menu.addItem(item(r.isHidden ? "显示" : "隐藏") { if r.isHidden { r.unhide() } else { r.hide() } })
            if path != model.finderPath {
                let q = item("退出") { r.terminate() }
                let fq = item("强制退出") { r.forceTerminate() }
                fq.isAlternate = true; fq.keyEquivalentModifierMask = [.option]
                q.keyEquivalentModifierMask = []
                menu.addItem(q); menu.addItem(fq)
            }
        } else {
            menu.addItem(item("打开") { [weak self] in self?.model.openOrSwitch(path) })
        }
        return menu
    }

    func commitOrder(_ list: [DockEntry]) {
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

    func poof(at p: NSPoint) {
        guard let w = window else { return }
        let sp = w.convertPoint(toScreen: convert(p, to: nil))
        NSAnimationEffect.poof.show(centeredAt: sp, size: NSSize(width: 48, height: 48))
    }

    // 从访达拖入 .app：固定到程序坞
    func setupDrop() { registerForDraggedTypes([.fileURL]) }
    private func draggedApps(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }.map { CustomDockModel.norm($0.path) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    private func draggedFiles(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard slide < 0.5 else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        if !draggedApps(sender).isEmpty {
            // .app：压在分组中心 = 放进分组（此时不再挪动占位）；否则 = 固定到程序坞的这个位置
            if let t = centerHit(p.x, Self.isGroup) { dropTarget = t; startLink(); return .copy }
            dropTarget = nil
            dropInsert = insertIndex(for: p.x, excluding: "", list: model.entries)
            reordering = true
            startLink()
            return .link
        }
        // 普通文件：拖到应用图标上 = 用这个应用打开
        if !draggedFiles(sender).isEmpty, let i = index(at: p), case .app = model.entries[i] {
            dropTarget = model.entries[i].id; startLink(); return .generic
        }
        dropTarget = nil; startLink()
        return []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropInsert = nil; dropTarget = nil; startLink() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = dropTarget, group = targetGroup()
        dropTarget = nil
        let apps = draggedApps(sender)
        if let g = group {
            dropInsert = nil
            for a in apps { if let info = AppInfo.from(url: URL(fileURLWithPath: a)) { GroupManager.shared.addApp(info, to: g) } }
            startLink(); return true
        }
        if let t = target, t.hasPrefix("app:") {
            NSWorkspace.shared.open(draggedFiles(sender), withApplicationAt: URL(fileURLWithPath: String(t.dropFirst(4))), configuration: NSWorkspace.OpenConfiguration())
            startLink(); return true
        }
        guard !apps.isEmpty else { return false }
        let ins = dropInsert ?? model.entries.count
        dropInsert = nil
        pin(apps, atEntryIndex: ins)
        startLink()
        return true
    }
    // 把应用固定到程序坞的第 ins 个条目位置
    func pin(_ apps: [String], atEntryIndex ins: Int) {
        // 插入位置换算成 pinned 列表中的位置
        let before = model.entries.prefix(ins).compactMap { e -> String? in if case .app(let p, true) = e, p != model.finderPath { return p }; return nil }
        var list = model.pinned.filter { !apps.contains($0) }
        let anchor = before.last.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        list.insert(contentsOf: apps, at: min(anchor, list.count))
        model.pinned = list
    }

    // 启动弹跳
    // 启动弹跳：和原生一样一直弹到应用启动完成（最多 15 秒），每一跳都完整落地
    func bounce(_ id: String, path: String, started: Date = Date(), chained: Bool = false) {
        guard let l = iconLayers[id], chained || l.animation(forKey: "bounce") == nil else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, S * 0.42, 0]
        a.keyTimes = [0, 0.5, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]   // 上升减速、下落加速
        a.duration = 0.6
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, !self.model.running.contains(path), Date().timeIntervalSince(started) < 15 else { return }
            self.bounce(id, path: path, started: started, chained: true)
        }
        l.add(a, forKey: "bounce")
        CATransaction.commit()
    }
}

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // 私有 AppKit 方法：NSGlassEffectView 只在窗口有"激活外观"时才通透折射，否则降级成磨砂；程序坞从不成为 key window
    @objc func hasKeyAppearance() -> Bool { true }
    override var canBecomeMain: Bool { false }
    // 允许移出屏幕底部（自动隐藏需要）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

func dgLog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DockGroups.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// 日志只增不减：启动时超过 512KB 就只留最后 256KB
func dgTrimLog() {
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DockGroups.log")
    guard let d = try? Data(contentsOf: url), d.count > 512 * 1024 else { return }
    try? d.suffix(256 * 1024).write(to: url, options: .atomic)
}

final class ClosureMenuItem: NSMenuItem {
    let fn: () -> Void
    init(title: String, action: @escaping () -> Void) {
        fn = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { fn() }
}

var dgPopupAnchorX: CGFloat? = nil

extension CustomDockModel {
    static func roundedGroupIcon(_ img: NSImage) -> NSImage {
        let s = NSSize(width: 512, height: 512)
        return NSImage(size: s, flipped: false) { r in
            let inset = r.insetBy(dx: r.width * 0.095, dy: r.height * 0.095)
            NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225).addClip()
            img.draw(in: inset)
            return true
        }
    }
    // 废纸篓空/满：系统不让直接读 ~/.Trash（要"完全磁盘访问权限"），改问访达（首次弹一次"自动化"授权）
    static var trashFull = false
    // 废纸篓的操作都交给访达（直接打开 ~/.Trash 同样会被系统拦下）
    static func finder(_ cmd: String, then: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = LoginItems.run("tell application \"Finder\"\n\(cmd)\nend tell")
            if let t = then { DispatchQueue.main.async(execute: t) }
        }
    }
    private static var trashAsking = false
    static func refreshTrash(_ changed: @escaping () -> Void) {
        if trashAsking { return }
        trashAsking = true
        DispatchQueue.global(qos: .utility).async {
            let out = LoginItems.run("tell application \"Finder\" to count items of trash").trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                trashAsking = false
                let full = (Int(out) ?? 0) > 0
                if full != trashFull { trashFull = full; dgLog("trash full=\(full)"); changed() }
            }
        }
    }
    static func trashIcon() -> NSImage {
        let name = trashFull ? "FullTrashIcon.icns" : "TrashIcon.icns"
        return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/" + name)
            ?? NSImage(named: NSImage.trashEmptyName) ?? NSImage()
    }
}

final class CustomDockController {
    static let shared = CustomDockController()
    private var panel: NSPanel?
    private var bar: DockBarView?
    private var timer: Timer?
    private var shown = true
    private var lastInside = Date()
    let ud = UserDefaults.standard

    var enabled: Bool { ud.bool(forKey: "customDockEnabled") }
    var autoHide: Bool {
        get { ud.object(forKey: "customDockAutoHide") as? Bool ?? true }
        set { ud.set(newValue, forKey: "customDockAutoHide"); if !newValue { show() } }
    }

    func start() {
        guard panel == nil else { return }
        let p = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        // 只比原生程序坞高一级：必须低于 .statusBar(25)，否则会盖在截图遮罩等全屏覆盖层上面
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]   // 全屏应用里也能推到底边唤出
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        let v = DockBarView(frame: .zero)
        if let m = CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, "com.apple.dock" as CFString) as? NSNumber, m.doubleValue > 0 {
            v.slideOmega = 14 / CGFloat(m.doubleValue)
        }
        p.contentView = v
        panel = p; bar = v
        v.onWidthChange = { [weak self] _ in self?.frameWindow() }
        frameWindow()
        _ = CustomDockModel.shared
        v.reloadIcons()
        p.orderFrontRegardless()
        shown = true
        // 30Hz 轮询鼠标位置决定显示/隐藏（唤出最多晚 33ms）。不用全局鼠标监听：
        // 那样鼠标在屏幕任何地方移动，每个事件都要投递给本进程，实测占 4% CPU
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        localMon = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in self?.tick(); return e }
        // 分辨率/显示器变化：重新定位
        screenObs = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.frameWindow(); self?.bar?.reloadIcons()
        }
    }

    private var localMon: Any?
    private var screenObs: Any?
    func stop() {
        if let o = screenObs { NotificationCenter.default.removeObserver(o); screenObs = nil }
        if let l = localMon { NSEvent.removeMonitor(l); localMon = nil }
        timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil; bar = nil; dgCustomDockTop = nil }

    // 窗口固定全屏宽、足够高（容纳放大和标签），只有图标区域接收点击
    private func frameWindow() {
        guard let p = panel, let v = bar, let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        let h = v.L + 60
        let y = f.minY
        // 窗口只比程序坞条略大（含放大余量和提示宽度），条目变化时才调整
        let w = min(f.width, (v.baseWidth + (v.L - v.S) * 3 + 300).rounded())
        let nf = NSRect(x: (f.midX - w / 2).rounded(), y: y, width: w, height: h)
        if nf == p.frame { return }
        let dx = p.frame.width > 0 ? p.frame.minX - nf.minX : 0
        p.setFrame(nf, display: true)
        v.shiftX(dx)
        p.ignoresMouseEvents = false
    }

    func relayout() { bar?.reloadIcons() }

    // 自检：向程序坞窗口投递合成的鼠标按下/抬起事件（不经过窗口服务器路由）
    func selfTest(index: Int) {
        guard let p = panel, let v = bar else { dgLog("selftest: no panel"); return }
        let pt = v.centerOfEntry(index)
        dgLog("selftest index=\(index) point=\(String(describing: pt)) ignoresMouse=\(p.ignoresMouseEvents) frame=\(p.frame)")
        guard let pt = pt else { return }
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                p.sendEvent(e)
            }
        }
    }

    private var lastExposeCheck = Date.distantPast
    private var lastTrashCheck = Date.distantPast
    private var lastBadgeCheck = Date.distantPast
    private var edgeSince: Date?
    private var inExpose = false
    private var dockPid: pid_t = 0
    // 调度中心/App Exposé/启动台：系统程序坞会创建全屏覆盖窗口
    private func exposeActive(_ screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let sw = screen.frame.width, sh = screen.frame.height
        if dockPid == 0 || NSRunningApplication(processIdentifier: dockPid) == nil {
            dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        }
        let dockPid = self.dockPid
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == dockPid,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) >= sw * 0.9 && (b["Height"] ?? 0) >= sh * 0.9 && (w[kCGWindowLayer as String] as? Int ?? 0) > 0
        }
    }

    private func tick() {
        guard let p = panel, let v = bar, let screen = NSScreen.screens.first else { return }
        let m = NSEvent.mouseLocation
        let atEdge = m.y <= screen.frame.minY + 2 && m.x >= screen.frame.minX && m.x <= screen.frame.maxX
        // 已收起且鼠标不在底边：直接返回
        if !shown && !atEdge && !inExpose && p.ignoresMouseEvents && autoHide { edgeSince = nil; return }
        // 查窗口列表一次约 1ms：只在可见或即将唤出时查，最多 0.3s 一次
        let now = Date()
        // 废纸篓状态只在程序坞看得见时才查，最多 10s 一次
        if shown && now.timeIntervalSince(lastTrashCheck) > 10 {
            lastTrashCheck = now
            CustomDockModel.refreshTrash { [weak self] in self?.bar?.reloadIcons() }
        }
        // 角标同理：只在看得见时查，1s 一次
        if shown && now.timeIntervalSince(lastBadgeCheck) > 1 {
            lastBadgeCheck = now
            CustomDockModel.shared.refreshBadges { [weak self] in self?.bar?.reloadBadges() }
        }
        if now.timeIntervalSince(lastExposeCheck) > 0.3 {
            lastExposeCheck = now
            let e = exposeActive(screen)
            if e != inExpose {
                inExpose = e
                dgLog("expose \(e)")
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; p.animator().alphaValue = e ? 0 : 1 }
                p.ignoresMouseEvents = e
            }
        }
        if inExpose { return }
        // 只让程序坞条本身拦截鼠标，透明区域放行
        let local = NSPoint(x: m.x - p.frame.minX, y: m.y - p.frame.minY)
        // 与原生一致：只看程序坞条实际范围（含放大后的图标高度），外扩 4pt
        let g = v.lastGlass
        let topY = g.maxY + (v.mouseX != nil || v.dragState?.active == true ? (v.L - v.S) + 4 : 4)
        let overBar = local.x >= g.minX - 4 && local.x <= g.maxX + 4 && local.y >= 0 && local.y <= topY
        let ign = !(overBar && shown)
        if p.ignoresMouseEvents != ign { p.ignoresMouseEvents = ign }
        if !autoHide { if !shown { show() }; return }
        if atEdge || (shown && overBar) { lastInside = Date() }
        if atEdge { if edgeSince == nil { edgeSince = Date() } } else { edgeSince = nil }
        let revealDelay = ud.object(forKey: "origAutohideDelay") as? Double ?? 0
        if !shown && atEdge && Date().timeIntervalSince(edgeSince ?? Date()) >= revealDelay { dgLog("autohide: show"); show() }
        else if shown && !overBar && !atEdge && Date().timeIntervalSince(lastInside) > 0.05 && !popupOpen() && !v.menuOpen && v.dragState == nil { dgLog("autohide: hide"); hide() }
    }
    private func popupOpen() -> Bool { NSApp.windows.contains { $0 is GroupPopupWindow && $0.isVisible } }

    // 从分组面板里拖出来的应用：落在程序坞条上就插到那个位置，否则排到最后
    func dropFromGroup(_ path: String, at screen: NSPoint) {
        guard let p = panel, let v = bar else { CustomDockModel.shared.pin(path); return }
        let local = v.convert(p.convertPoint(fromScreen: screen), from: nil)
        let onBar = p.frame.contains(screen) && local.y < v.bottomMargin + v.barH + 30
        v.pin([path], atEntryIndex: onBar ? v.insertIndex(for: local.x, excluding: "", list: v.model.entries) : v.model.entries.count)
        v.startLink()
    }

    func show() { shown = true; bar?.slideTarget = 0; bar?.startLink() }
    func hide() { shown = false; bar?.slideTarget = 1; bar?.mouseX = nil; bar?.startLink() }

    // MARK: 系统程序坞开关
    private func sh(_ cmd: String) {
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/bin/sh"); pr.arguments = ["-c", cmd]
        try? pr.run(); pr.waitUntilExit()
    }
    private func readDock(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) }

    private var restoreCmd: String {
        let delay = ud.object(forKey: "origAutohideDelay") as? Double ?? 0
        let ah = ud.object(forKey: "origAutohide") as? Bool ?? true
        return "defaults write com.apple.dock autohide -bool \(ah ? "true" : "false"); defaults write com.apple.dock autohide-delay -float \(delay); killall Dock"
    }
    // 接管：把系统程序坞的唤出延迟调到 1000 秒（等于藏起来）；已经是了就不动它
    private func suppressSystemDock() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        if ud.object(forKey: "origAutohideDelay") == nil {
            ud.set((readDock("autohide-delay") as? NSNumber)?.doubleValue ?? 0, forKey: "origAutohideDelay")
            ud.set((readDock("autohide") as? NSNumber)?.boolValue ?? false, forKey: "origAutohide")
        }
        if (readDock("autohide-delay") as? NSNumber)?.doubleValue != 1000 {
            sh("defaults write com.apple.dock autohide -bool true; defaults write com.apple.dock autohide-delay -float 1000; killall Dock")
        }
        dgRestoreDockOnCrash(restoreCmd)
    }
    // 退出时把系统程序坞还回去（保留原始设置的记录，下次启动再接管）
    func restoreSystemDock() { sh(restoreCmd) }

    func resume() { suppressSystemDock(); start() }
    func enable() {
        suppressSystemDock()
        ud.set(true, forKey: "customDockEnabled")
        start()
    }
    func disable() {
        restoreSystemDock()
        ud.removeObject(forKey: "origAutohideDelay"); ud.removeObject(forKey: "origAutohide")
        ud.set(false, forKey: "customDockEnabled")
        stop()
        GroupManager.shared.rebuildLaunchers()   // 回到系统程序坞：分组靠启动器小应用放进去
    }
}

// 崩溃时也要把系统程序坞还回去。信号处理函数里能做的事极少，所以命令行提前备好，只调 posix_spawn
private var dgCrashArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
func dgRestoreDockOnCrash(_ cmd: String) {
    let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 4)
    argv[0] = strdup("/bin/sh"); argv[1] = strdup("-c"); argv[2] = strdup(cmd); argv[3] = nil
    dgCrashArgv = argv
    for s in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
        signal(s) { sig in
            var pid: pid_t = 0
            if let a = dgCrashArgv { posix_spawn(&pid, "/bin/sh", nil, nil, a, nil) }
            signal(sig, SIG_DFL); raise(sig)
        }
    }
}


// 登录项：通过“系统事件”读写（首次会请求自动化权限）
enum LoginItems {
    static func run(_ script: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", script]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    static var cache: [String] = []
    static var cacheTime = Date.distantPast
    static func contains(_ path: String) -> Bool {
        if Date().timeIntervalSince(cacheTime) > 30 {
            cache = run("tell application \"System Events\" to get the path of every login item").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            cacheTime = Date()
        }
        return cache.contains { $0.hasPrefix(path) }
    }
    static func toggle(_ path: String) {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if contains(path) { _ = run("tell application \"System Events\" to delete login item \"\(name)\"") }
        else { _ = run("tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:false}") }
        cacheTime = .distantPast
    }
}


// 图标缓存：系统图标 / 自定义覆盖（如 ChatGPT 运行时图标），始终用最大分辨率源
// 私有 LaunchServices 接口：应用通过 dockTile.badgeLabel 设的角标存在这里的 StatusLabel 里
enum AppBadge {
    private typealias ASNCreate = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias InfoItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let lib = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
    private static let asnCreate = dlsym(lib, "_LSASNCreateWithPid").map { unsafeBitCast($0, to: ASNCreate.self) }
    private static let infoItem = dlsym(lib, "_LSCopyApplicationInformationItem").map { unsafeBitCast($0, to: InfoItem.self) }
    static func label(pid: pid_t) -> String? {
        guard let c = asnCreate, let f = infoItem, let asn = c(nil, pid)?.takeRetainedValue(),
              let d = f(-2, asn, "StatusLabel" as CFString)?.takeRetainedValue() as? [String: Any],
              let l = d["label"] as? String, !l.isEmpty else { return nil }
        return l
    }
}

enum AppIconCache {
    static var cache: [String: NSImage] = [:]
    static func icon(forPath p: String) -> NSImage {
        if let c = cache[p] { return c }
        var img = NSWorkspace.shared.icon(forFile: p)
        for g in GroupManager.shared.groups { for a in g.apps where CustomDockModel.norm(a.path) == p { if let i = a.getIcon() { img = i } } }
        cache[p] = img
        return img
    }
}
