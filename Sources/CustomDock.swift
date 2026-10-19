import SwiftUI
import AppKit
import Combine

// MARK: - 自定义程序坞

enum DockEntry: Identifiable, Equatable {
    case app(path: String, pinned: Bool)
    case group(UUID)
    case folder(String)     // 固定的文件夹：和应用、分组一起排在固定区
    case trash
    case divider(Int)
    var id: String {
        switch self {
        case .app(let p, _): return "app:" + p
        case .group(let id): return "group:" + id.uuidString
        case .folder(let p): return "folder:" + p
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
    // 统一顺序（应用、分组、文件夹可自由交错）："app:<path>" / "group:<uuid>" / "folder:<path>"
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
        watchRunningApps()
    }

    // 访达里开着的文件夹：固定的文件夹在这里面就亮指示点。
    // 用辅助功能监听访达的窗口事件（开/关窗口；切换目录时访达会改窗口标题），收到事件再问访达各窗口在看哪个文件夹。
    // 路径只能问访达（AppleScript，和废纸篓共用"自动化"授权）：macOS 27 的访达窗口 AXDocument 是空的。
    // 不轮询，只在访达窗口变化时问一次；只认每个窗口当前那个标签页
    @Published var openFolders: Set<String> = []
    private var finderObs: AXObserver?
    private var finderPid: pid_t = 0
    private let axQueue = DispatchQueue(label: "dg.finder.ax")
    private var finderScanPending = false
    func watchFinder() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              app.processIdentifier != finderPid else { return }
        if let old = finderObs { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode); finderObs = nil }
        finderPid = app.processIdentifier
        var obs: AXObserver?
        guard AXObserverCreate(finderPid, { _, _, _, ctx in
            guard let ctx = ctx else { return }
            Unmanaged<CustomDockModel>.fromOpaque(ctx).takeUnretainedValue().scanFinder()
        }, &obs) == .success, let obs = obs else { dgLog("finder watch: observer failed"); return }
        let el = AXUIElementCreateApplication(finderPid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification] { AXObserverAddNotification(obs, el, n as CFString, me) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        finderObs = obs
        scanFinder()
    }
    // 一次切目录会连着来好几个事件，合并成 0.15 秒后问一次；放后台线程，访达卡住也不拖住程序坞
    func scanFinder() {
        if finderScanPending { return }
        finderScanPending = true
        axQueue.asyncAfter(deadline: .now() + 0.15) {
            // 先在访达里整体转成 alias list 再取路径；在访达里逐个窗口取 POSIX path 实测拿不到
            let out = LoginItems.run("""
            tell application "Finder" to set ts to target of every Finder window as alias list
            set out to ""
            repeat with t in ts
            set out to out & POSIX path of t & linefeed
            end repeat
            return out
            """)
            let found = Set(out.split(separator: "\n").map { Self.norm(String($0)) }.filter { !$0.isEmpty })
            DispatchQueue.main.async {
                self.finderScanPending = false
                if found != self.openFolders { dgLog("finder open folders: \(found.count)"); self.openFolders = found; CustomDockController.shared.relayout() }
            }
        }
    }

    // "启动/退出"通知不够：有些应用启动时不带程序坞图标，过一会儿才变成普通应用（或反过来）；
    // 纯后台应用启动时系统根本不发启动通知。所以还要盯着"运行中的应用列表"，并且每 2 秒核对一次（见 tick）。
    // 注意：不要对单个 NSRunningApplication 做 KVO —— 应用退出时系统回调会访问到已释放的对象，连续开关应用必崩（实测 50 次内崩）
    private var appsObs: NSKeyValueObservation?
    private func watchRunningApps() {
        appsObs = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in DispatchQueue.main.async { self?.rebuildIfAppsChanged() } }
    }
    // 该显示的应用集合没变就什么都不做（后台进程来来去去很频繁）
    // 当前在运行的普通应用（会显示在程序坞里的那种）。逐个问系统"它是不是普通应用"很慢（一轮约 30ms），只能在后台线程调用
    static func regularApps() -> [(pid_t, String)] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { r in r.bundleURL.map { (r.processIdentifier, norm($0.path)) } }
    }
    private var regularPids: [(pid_t, String)] = []
    private var appsChecking = false
    func rebuildIfAppsChanged() {
        if appsChecking { return }
        appsChecking = true
        DispatchQueue.global(qos: .utility).async {
            let now = Set(Self.regularApps().map { $0.1 })
            DispatchQueue.main.async {
                self.appsChecking = false
                if now != self.running { self.rebuild() }
            }
        }
    }

    // 规范化路径要查磁盘，而它每秒被调用几十次（角标、运行状态、应用列表核对），所以结果记下来
    private static var normCache: [String: String] = [:]
    private static let normLock = NSLock()
    static func norm(_ p: String) -> String {
        normLock.lock(); defer { normLock.unlock() }
        if let c = normCache[p] { return c }
        var s = URL(fileURLWithPath: p).standardizedFileURL.path
        if s.hasSuffix("/") { s.removeLast() }
        normCache[p] = s
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
        // 走 setter：它会把显示顺序（customDockOrder）一起同步。直接写 pinned 的话旧的顺序还在、优先被读，重新导入等于没导入
        pinned = list
    }

    var groupedPaths: Set<String> {
        Set(GroupManager.shared.groups.flatMap { $0.apps.map { Self.norm($0.path) } })
    }

    func rebuild() {
        watchFinder()   // 访达重启后 pid 变了，要重新挂监听（只比较 pid，平时几乎没开销）
        let grouped = groupedPaths
        let runApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        running = Set(runApps.compactMap { $0.bundleURL.map { Self.norm($0.path) } })
        regularPids = runApps.compactMap { r in r.bundleURL.map { (r.processIdentifier, Self.norm($0.path)) } }
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
            } else if tok.hasPrefix("folder:") {
                // 文件夹暂时不在（外接盘没插、被改名）只是不显示，不从顺序里删
                let p = String(tok.dropFirst(7)); var dir: ObjCBool = false
                if !seen.contains(tok) && FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue { e.append(.folder(p)); seen.insert(tok) }
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
        e.append(.divider(2))
        e.append(.trash)
        if e != entries { entries = e }
        CustomDockController.shared.relayout()
    }

    // 角标（未读数）：和系统程序坞读同一份 LaunchServices 数据，不需要任何授权
    var badges: [String: String] = [:]
    private var badgeAsking = false
    func refreshBadges(_ changed: @escaping () -> Void) {
        if badgeAsking { return }
        badgeAsking = true
        let apps = regularPids   // 用上次整理应用列表时记下的进程号，不用每秒把所有运行中的应用重新问一遍（那一步要 25ms）
        DispatchQueue.global(qos: .utility).async {
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

    // Electron / Chromium 做的软件（Claude、Cursor、Notion、Chrome、Typeless 等）：别用辅助功能去读它们的窗口。
    // 它们一发现有程序在读，就会整个切到"无障碍模式"并保持到重启 —— 变慢，显示也会变（实测 Typeless 的语音气泡下面多出一块阴影）
    private static var chromiumCache: [String: Bool] = [:]
    private static let chromiumLock = NSLock()
    static func isChromiumBased(_ appPath: String) -> Bool {
        chromiumLock.lock(); defer { chromiumLock.unlock() }
        if let c = chromiumCache[appPath] { return c }
        let fw = (try? FileManager.default.contentsOfDirectory(atPath: appPath + "/Contents/Frameworks")) ?? []
        let hit = fw.contains { n in
            let l = n.lowercased()
            return l.hasSuffix(".framework") && (l.contains("electron") || l.contains("chromium") || l.contains("chrome") || l.contains("edge framework") || l.contains("brave") || l.contains("vivaldi") || l.contains("opera"))
        }
        chromiumCache[appPath] = hit
        return hit
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
    func unpinFolder(_ p: String) { order = order.filter { $0 != "folder:" + p } }
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
    private var blankRetries: [String: Int] = [:]
    private var runningIDs = Set<String>()
    private var badgeText: [String: String] = [:]
    private var badgeAspect: [String: CGFloat] = [:]
    var dropTarget: String?              // 拖动时压在哪个图标中心上：分组 = 放进分组；应用 = 用它打开文件
    private var lastInsert = 0
    var menuOpen = false                 // 右键菜单打开期间：保持放大、不收起、不显示名称提示
    private var tipSuppressed: String?   // 刚点过的图标不再显示名称提示（会和弹跳、分组面板叠在一起），鼠标移到别处才恢复
    private let glass: NSView
    // 玻璃条放在单独一个窗口里，垫在图标窗口下面。原因：玻璃控件内部每次所在窗口刷新都要重算一遍（不管它自己变没变），
    // 和图标同一个窗口的话，悬停放大时每帧都重算，实测 CPU 是系统程序坞的 4 倍。两个窗口大小位置完全相同，所以坐标可以直接通用
    let glassHost = NSView()
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
    // 名称提示：毛玻璃胶囊 + 朝下的小箭头（整体一个形状，用遮罩图裁出来）
    private let tip = NSVisualEffectView()
    // 文字用图层而不是文本控件：提示每帧都跟着图标移动，文本控件会每帧重画文字（实测占了悬停时一半的 CPU），图层只在换字时画一次
    private let tipLabel = CALayer()   // 内容是预先画好的文字图片（按 外观+文字 缓存），换字时只换图，不用重新排版绘制
    private var tipTextCache: [String: CGImage] = [:]
    static let tipFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let tipOutline = CAShapeLayer()
    static let tipPillH: CGFloat = 26, tipArrowH: CGFloat = 6
    var mouseX: CGFloat? = nil
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
        glassHost.wantsLayer = true; glassHost.layer?.masksToBounds = false
        glassHost.addSubview(glass)
        iconHost.wantsLayer = true
        iconHost.layer?.masksToBounds = false
        // 图标在玻璃之上而不是玻璃里面：玻璃会裁剪内容，放大的图标顶部会被切掉
        iconHost.autoresizingMask = [.width, .height]
        addSubview(iconHost)
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = false
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        tip.material = .menu; tip.blendingMode = .behindWindow; tip.state = .active
        tip.isHidden = true
        tip.wantsLayer = true
        tipLabel.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        tip.layer?.addSublayer(tipLabel)
        tipOutline.fillColor = nil; tipOutline.lineWidth = 0.5
        tipOutline.strokeColor = NSColor(white: 0.5, alpha: 0.45).cgColor   // 中性灰：浅色、深色背景上都看得见
        tip.layer?.addSublayer(tipOutline)
        overlay.addSubview(tip)
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

    // 图标图像（按屏幕倍率生成，保证清晰）
    func image(for e: DockEntry) -> NSImage {
        switch e {
        case .app(let p, _): return AppIconCache.icon(forPath: p)
        case .trash: return CustomDockModel.trashIcon()
        case .folder(let p): return AppIconCache.icon(forPath: p)
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
        if isBlank(rep) { return nil }
        return rep.cgImage
    }

    // 整张图都是透明的 = 没画出东西。新装的应用第一次打开时，系统还没备好它的图标，这一刻要到的就是这样一张空图
    static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard let d = rep.bitmapData, rep.samplesPerPixel == 4 else { return false }
        let w = rep.pixelsWide, h = rep.pixelsHigh, row = rep.bytesPerRow
        for gy in 1..<16 { for gx in 1..<16 {
            if d[(h * gy / 16) * row + (w * gx / 16) * 4 + 3] > 8 { return false }
        } }
        return true
    }

    // 名称提示每帧都要用到名字，而取应用显示名要查磁盘：记下来，图标列表刷新时清空
    private var labelCache: [String: String] = [:]
    func label(for e: DockEntry) -> String {
        if let c = labelCache[e.id] { return c }
        let l = computeLabel(for: e); labelCache[e.id] = l; return l
    }
    private func computeLabel(for e: DockEntry) -> String {
        switch e {
        case .app(let p, _):
            var n = FileManager.default.displayName(atPath: p); if n.hasSuffix(".app") { n.removeLast(4) }; return n
        case .trash: return "废纸篓"
        case .folder(let p): return FileManager.default.displayName(atPath: p)
        case .group(let gid): return GroupManager.shared.groups.first(where: { $0.id == gid })?.name ?? ""
        case .divider: return ""
        }
    }

    func reloadIcons() {
        restyleFrames = 4
        labelCache.removeAll()
        entryIDCache = model.entries.map { $0.id }
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
            if case .group(let gid) = e, let g = GroupManager.shared.groups.first(where: { $0.id == gid }) { key += g.installedApps.map { $0.path }.joined(separator: "|") }
            // 废纸篓空/满、应用更新后换图标：都算进缓存键，变了才重新渲染
            if case .trash = e { key += CustomDockModel.trashFull ? "F" : "E" }
            if case .app(let p, _) = e, let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date { key += "@\(d.timeIntervalSince1970)" }
            if contentKeys[e.id] != key || il.contents == nil {   // 图层是空的就一定要画，不管记录怎么说
                if case .app(let p, _) = e { AppIconCache.cache[p] = nil }
                let cg = Self.render(image(for: e), px: Int(px.rounded(.up)))
                if let cg = cg { il.contents = cg }
                var ready = cg != nil
                // 分组图标是拿成员图标拼出来的，整体不会是空白，但其中某一格可能是：成员里有空图也算"还没准备好"
                if ready, case .group(let gid) = e, let g = GroupManager.shared.groups.first(where: { $0.id == gid }),
                   g.installedApps.prefix(4).contains(where: { a in a.getIcon().map { Self.render($0, px: 32) == nil } ?? false }) { ready = false }
                if ready {
                    contentKeys[e.id] = key
                    blankRetries[e.id] = nil
                } else {
                    // 没准备好的不保存（否则会一直显示空白）；过一会儿再要，间隔逐次加倍：0.5、1、2、4、8、16 秒
                    let n = blankRetries[e.id] ?? 0
                    if n < 6 {
                        blankRetries[e.id] = n + 1
                        dgLog("icon for \(e.id) came back blank, retry #\(n + 1)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * pow(2, Double(n))) { [weak self] in self?.reloadIcons() }
                    }
                }
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
        // 图层删掉时，"这个图标已经画过"的记录也要一起删。否则同一个应用退出后再打开，会拿到一个新的空图层，
        // 却因为记录还在而跳过绘制 —— 位置和小圆点都在，图标是空的
        for (k, l) in iconLayers where !alive.contains(k) { l.removeFromSuperlayer(); iconLayers[k] = nil; contentKeys[k] = nil; blankRetries[k] = nil }
        for (k, l) in dotLayers where !alive.contains(k) { l.removeFromSuperlayer(); dotLayers[k] = nil }
        for (k, l) in sepLayers where !alive.contains(k) { l.removeFromSuperlayer(); sepLayers[k] = nil }
        // 哪些条目要亮运行指示点：在这里算好。以前每帧都算，分组里每个应用都要规范化一次路径（一次磁盘查询），放大时占了三成多 CPU
        runningIDs = Set(model.entries.filter { e in
            if case .app(let p, _) = e { return model.running.contains(p) }
            if case .folder(let p) = e { return model.openFolders.contains(p) }
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

    // x/y = 被拖图标的中心；offX/offY = 按下时光标相对图标中心的偏移（抓哪儿就拖哪儿，图标不会跳到光标正中）
    struct DragState { var id: String; var index: Int; var x: CGFloat; var y: CGFloat; var startX: CGFloat; var startY: CGFloat; var active: Bool; var offX: CGFloat = 0; var offY: CGFloat = 0 }

    // 有东西变了就调它。刷新定时器在鼠标移动期间一直开着，静止 0.3 秒后才关：
    // 以前是"来一个鼠标事件 → 新建定时器 → 跑一帧 → 销毁"，建和拆比干活本身还贵（悬停时占主线程三分之一）
    private var dirty = false
    private var idleSince: CFTimeInterval = 0   // 从哪一刻起画面没再变过（0 = 还在变）
    func startLink() {
        dirty = true
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(frameTick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l; lastTs = 0; idleSince = 0
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
        pollPointer()   // 定时器开着的时候每帧读一次鼠标位置
        if !dirty && idleSince > 0 {
            // 上一帧已经静止，之后也没有新变化：这一帧什么都不用做；静止满 0.3 秒就关掉定时器
            if now - idleSince > 0.3 { l.invalidate(); link = nil }
            return
        }
        dirty = false
        let dt = CGFloat(lastTs == 0 ? 1.0 / 120 : min(now - lastTs, 1.0 / 30))
        // 整帧包在一个事务里：applyLayout 和名字提示各自的 begin/commit 变成嵌套的，不再各自向系统提交一次（原来一帧提交 3 次）
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frameOrder = nil; frameOrder = ordered()
        let settled = step(dt: dt)
        applyLayout()
        frameOrder = nil
        CATransaction.commit()
        if settled { idleSince = now; lastTs = 0; settleAt = CACurrentMediaTime() + 0.25 }   // lastTs 清零：下次再动时不要把静止的这段时间算进步长
        else { idleSince = 0; lastTs = now }
    }

    // 每个条目的 id 是现拼出来的字符串（"app:" + 路径）。一帧里要用上百次，每次都拼一遍很浪费（悬停时占了近三成的计算），
    // 所以一帧开头算好一份（条目 + 对应的 id），step 和 applyLayout 共用
    private var frameOrder: (list: [DockEntry], ids: [String])?
    func ordered() -> (list: [DockEntry], ids: [String]) {
        if let c = frameOrder { return c }
        if dragState?.active != true && dropInsert == nil { return (model.entries, entryIDs) }   // 没在拖动：顺序就是原样，id 用现成的
        let l = orderedEntries
        return (l, l.map { $0.id })
    }
    private var entryIDCache: [String] = []
    var entryIDs: [String] {
        if entryIDCache.count != model.entries.count { entryIDCache = model.entries.map { $0.id } }
        return entryIDCache
    }

    var orderedEntries: [DockEntry] {
        var list = model.entries
        if let d = dragState, d.active, let from = list.firstIndex(where: { $0.id == d.id }) {
            // 没固定的应用：只有拖进固定区才让别的图标让位；压在分组上、拖出程序坞、还在右边时，它原来的位置原样留着
            if isUnpinned(d.id) && (dropTarget != nil || outsideBar(d.y) || !inPinnedZone(d.x)) { return list }
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

    func isUnpinned(_ id: String) -> Bool {
        model.entries.contains { e in if case .app(_, false) = e { return e.id == id }; return false }
    }
    // 固定区 = 第一条分隔线的左边
    func inPinnedZone(_ x: CGFloat) -> Bool { dispX["div1"].map { x < $0 } ?? true }

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
        let (list, ids) = ordered()
        var x = (bounds.width - widthOf(list)) / 2 + barPadX
        var settled = true
        // 1) 宽度（放大）。悬停时宽度直接跟随光标（无弹簧滞后）；只有进入/离开（占位 div99）用缓动
        for (i, e) in list.enumerated() {
            let id = ids[i]
            let isDiv: Bool = { if case .divider = e { return true }; return false }()
            let base: CGFloat = isDiv ? (id == "div99" ? S : 13) : S
            let target = isDiv ? base : S * targetScale(center: x + S / 2)
            x += base + (isDiv ? 0 : gap)
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
        for (i, e) in list.enumerated() { let w = dispW[ids[i]] ?? S; if case .divider = e { total += w } else { total += w + gap } }
        total -= gap
        var cx = (bounds.width - total) / 2
        let dragging = dragState?.active == true ? dragState!.id : nil
        for (i, e) in list.enumerated() {
            let id = ids[i]
            let w = dispW[id] ?? S
            let center = cx + w / 2
            if id == dragging, let d = dragState {
                dispX[id] = d.x; velX[id] = 0
            } else {
                var px = dispX[id] ?? center, v = velX[id] ?? 0
                if reordering { Self.bouncy(&px, &v, to: center, dt: dt) } else { px = center; v = 0 }
                if abs(px - center) < 0.1 && abs(v) < 1 { px = center; v = 0 } else { settled = false }
                dispX[id] = px; velX[id] = v
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
    var lastGlass = NSRect.zero           // 玻璃条现在看起来的位置和大小
    private var glassBase = NSRect.zero   // 玻璃视图真实的 frame（动画期间不动）
    private var glassStretched = false
    var restyleFrames = 4
    private var wantGlass = NSRect.zero   // 玻璃条按图标位置算出来"应该在"的精确位置（lastGlass 在悬停时允许有 1.5pt 以内的偏差）
    private var settleAt: CFTimeInterval = 0
    // 鼠标停下 0.25 秒后：把玻璃对齐到精确位置、去掉变形。必须延后做 —— 鼠标移动时动画是"每来一个事件跑一帧就停"，
    // 如果一停就对齐，等于每帧都在改玻璃的真实尺寸，比不优化还慢。由控制器的定时器（60Hz）来调
    func settleGlassIfDue() {
        guard settleAt > 0, !dirty, link == nil || idleSince > 0, CACurrentMediaTime() >= settleAt else { return }
        settleAt = 0
        guard glassStretched || wantGlass != lastGlass, wantGlass.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.layer?.setAffineTransform(.identity); glass.frame = wantGlass; glassBase = wantGlass; lastGlass = wantGlass; glassStretched = false
        CATransaction.commit()
    }
    func applyLayout() {
        let (list, ids) = ordered()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hideOffset = (barH + bottomMargin + 6) * slide
        let barY = bottomMargin - hideOffset
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        let dragging = dragState?.active == true ? dragState!.id : nil
        // 拖动期间以及结束后的几帧、图标列表刚刷新后：把样式类属性也重设一遍
        if dragState != nil || dropTarget != nil || dropInsert != nil { restyleFrames = 4 }
        let restyle = restyleFrames > 0
        if restyle { restyleFrames -= 1 }
        for id in ids where id != dragging {
            let w = dispW[id] ?? S, c = dispX[id] ?? 0
            minX = min(minX, c - w / 2); maxX = max(maxX, c + w / 2)
        }
        if minX < maxX {
            let gf = NSRect(x: ((minX - barPadX) * 2).rounded() / 2, y: (barY * 2).rounded() / 2, width: ((maxX - minX + barPadX * 2) * 2).rounded() / 2, height: barH)
            // 鼠标在条上滑动时，条的宽度每帧只变零点几个点（肉眼看不出），但每动一次玻璃都要重算；所以悬停期间攒够 1.5pt 才动。
            // 进出放大、滑出滑入、拖动排序这些"真的在变"的时候不设门槛，保证跟手
            wantGlass = gf
            let steady = mouseX != nil && magAmount > 0.98 && slide == slideTarget && !reordering && dragState == nil
            let tol: CGFloat = steady ? 1.5 : 0.25
            // 拉伸会让玻璃的圆角跟着变形（宽 5% 就差 1 个多点），边缘看着发虚。所以拉伸只在放大/滑动的过渡动画里用；
            // 一进入稳定悬停就立刻换回真实尺寸，之后每次更新（1.5pt 的门槛下大约每秒一次）也直接改真实尺寸
            if steady && glassStretched {
                glass.layer?.setAffineTransform(.identity); glass.frame = gf; glassBase = gf; lastGlass = gf; glassStretched = false
            }
            if abs(gf.minX - lastGlass.minX) > tol || abs(gf.maxX - lastGlass.maxX) > tol || abs(gf.minY - lastGlass.minY) > 0.25 {
                lastGlass = gf
                // 动画过程中不改玻璃的真实尺寸，只做拉伸/平移变形：NSGlassEffectView 每改一次尺寸内部都要重新布局一遍（约 1ms），
                // 悬停时宽度每帧都在微调，实测让 CPU 是系统程序坞的 4 倍（21% 对 5%）。拉伸幅度只有百分之几，圆角看不出变形；动画停下时再对齐真实尺寸
                let sx = glassBase.width > 0 ? gf.width / glassBase.width : 0
                if steady || glassBase.width == 0 || abs(sx - 1) > 0.12 || abs(gf.height - glassBase.height) > 0.01 {
                    glass.layer?.setAffineTransform(.identity); glass.frame = gf; glassBase = gf; glassStretched = false
                } else if let gl = glass.layer {
                    let ax = gl.anchorPoint.x * glassBase.width
                    gl.setAffineTransform(CGAffineTransform(a: sx, b: 0, c: 0, d: 1, tx: gf.minX - glassBase.minX + ax * (sx - 1), ty: gf.minY - glassBase.minY))
                    glassStretched = true
                }
            }
        }
        for (i, e) in list.enumerated() {
            let id = ids[i]
            let w = dispW[id] ?? S, c = dispX[id] ?? 0
            if case .divider = e {
                if id != "div99" { sepLayers[id]?.frame = CGRect(x: c - 0.5, y: barY + 12, width: 1, height: barH - 24) }
                continue
            }
            guard let il = iconLayers[id] else { continue }
            if id == dragging, let d = dragState {
                // 被拖图标：浮层，精确跟随光标
                let ds = dropTarget == nil ? S : S * 0.7   // 要落进分组时缩小一点
                il.bounds = CGRect(x: 0, y: 0, width: ds, height: ds)
                il.position = CGPoint(x: d.x, y: d.y - ds / 2)
                il.opacity = outsideBar(d.y) ? 0.55 : (dropTarget == nil ? 1 : 0.85)
                il.zPosition = 5
                dotLayers[id]?.opacity = 0
                badgeLayers[id]?.opacity = 0
                continue
            }
            il.bounds = CGRect(x: 0, y: 0, width: w, height: w)
            il.position = CGPoint(x: c, y: barY + NativeDock.iconBaseY)
            if pressDim.superlayer === il { pressDim.frame = il.bounds; pressMask.frame = il.bounds }
            // 透明度/层级/鼓起/指示点显隐 这几样只在拖动前后才会变：平时每帧重设一遍是白费（每个图标每帧少 5 次图层调用）
            if restyle {
                il.opacity = 1; il.zPosition = 0
                il.setAffineTransform(id == dropTarget ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity)   // 拖放目标：微微鼓起
                badgeLayers[id]?.opacity = 1
                dotLayers[id]?.opacity = runningIDs.contains(id) ? 1 : 0
            }
            if let b = badgeLayers[id] {
                // 贴在图标右上角，跟着放大一起变大
                let h = w * Self.badgeRatio, bw = h * (badgeAspect[id] ?? 1), inset = w * 0.02
                b.frame = CGRect(x: c + w / 2 - inset - bw, y: barY + NativeDock.iconBaseY + w - inset - h, width: bw, height: h)
            }
            if let d = dotLayers[id] {
                d.frame = CGRect(x: c - NativeDock.dotSize / 2, y: barY + NativeDock.dotY, width: NativeDock.dotSize, height: NativeDock.dotSize)
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
        let ids = entryIDs
        for (i, e) in model.entries.enumerated() {
            if case .divider = e { continue }
            if let l = iconLayers[ids[i]], l.frame.insetBy(dx: -gap / 2, dy: -12).contains(p) { return i }
        }
        return nil
    }

    private var tipShapeCache: [CGFloat: (mask: NSImage, outline: CGPath)] = [:]
    static func makeTipShape(width w: CGFloat, scale: CGFloat) -> (mask: NSImage, outline: CGPath) {
        let pillH = tipPillH, arrowH = tipArrowH
        // 胶囊 + 箭头是同一条轮廓：既当遮罩，也描一圈很淡的边（浅色背景上胶囊和背景同色，没有边就看不出来）
        let shape = CGMutablePath(); let cx = w / 2, by = arrowH
        shape.addRoundedRect(in: CGRect(x: 0.25, y: by, width: w - 0.5, height: pillH - 0.25), cornerWidth: pillH / 2 - 0.25, cornerHeight: pillH / 2 - 0.25)
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: cx - 8, y: by + 0.5))
        arrow.addCurve(to: CGPoint(x: cx, y: 0.25), control1: CGPoint(x: cx - 4, y: by + 0.5), control2: CGPoint(x: cx - 2.5, y: 0.25))
        arrow.addCurve(to: CGPoint(x: cx + 8, y: by + 0.5), control1: CGPoint(x: cx + 2.5, y: 0.25), control2: CGPoint(x: cx + 4, y: by + 0.5))
        arrow.closeSubpath()
        let size = NSSize(width: w, height: pillH + arrowH)
        let drawn = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor); ctx.addPath(shape); ctx.fillPath(); ctx.addPath(arrow); ctx.fillPath()
            return true
        }
        // 转成位图再存：带绘制闭包的图片每次用到都可能重新画一遍
        var px = NSRect(x: 0, y: 0, width: w * scale, height: size.height * scale)
        let mask = drawn.cgImage(forProposedRect: &px, context: nil, hints: nil).map { NSImage(cgImage: $0, size: size) } ?? drawn
        // 外轮廓 = 胶囊上半圈 + 两侧 + 箭头两条边（胶囊底边在箭头处断开）
        let outline = CGMutablePath(); let rr = pillH / 2 - 0.25, top = by + pillH - 0.25
        outline.move(to: CGPoint(x: cx + 8, y: by + 0.25))
        outline.addLine(to: CGPoint(x: w - 0.25 - rr, y: by + 0.25))
        outline.addArc(center: CGPoint(x: w - 0.25 - rr, y: by + rr + 0.25), radius: rr, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        outline.addLine(to: CGPoint(x: 0.25 + rr, y: top + 0.25))
        outline.addArc(center: CGPoint(x: 0.25 + rr, y: by + rr + 0.25), radius: rr, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
        outline.addLine(to: CGPoint(x: cx - 8, y: by + 0.25))
        outline.addCurve(to: CGPoint(x: cx, y: 0.25), control1: CGPoint(x: cx - 4, y: by + 0.25), control2: CGPoint(x: cx - 2.5, y: 0.25))
        outline.addCurve(to: CGPoint(x: cx + 8, y: by + 0.25), control1: CGPoint(x: cx + 2.5, y: 0.25), control2: CGPoint(x: cx + 4, y: by + 0.25))
        return (mask, outline)
    }

    private var lastTip = ""
    // 立刻收起名称提示（不等下一帧）
    func hideTip() { tip.isHidden = true; lastTip = ""; tip.layer?.setAffineTransform(.identity) }
    var tipVisible: Bool { !tip.isHidden }
    func updateTooltip() {
        if mouseX == nil { tipSuppressed = nil }
        guard !menuOpen, dragState?.active != true, slide < 0.01, let mx = mouseX, let i = index(at: NSPoint(x: mx, y: bottomMargin + barH / 2)), let il = iconLayers[entryIDs[i]] else {
            tip.isHidden = true; lastTip = ""; return
        }
        if entryIDs[i] == tipSuppressed { tip.isHidden = true; lastTip = ""; return }
        tipSuppressed = nil
        let text = labelCache[entryIDs[i]] ?? label(for: model.entries[i])
        // 箭头尖离图标顶 4pt
        let origin = { (w: CGFloat) in NSPoint(x: il.position.x - w / 2, y: il.frame.maxY + 4) }
        if text == lastTip && !tip.isHidden {
            // 跟着图标走：只挪图层（平移变形），不改视图的 frame —— 改 frame 会让整个窗口重新走一遍布局
            let o = origin(tip.frame.width)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            tip.layer?.setAffineTransform(CGAffineTransform(translationX: o.x - tip.frame.minX, y: o.y - tip.frame.minY))
            CATransaction.commit()
            return
        }
        lastTip = text
        let pillH = Self.tipPillH, arrowH = Self.tipArrowH
        let w = ((text as NSString).size(withAttributes: [.font: Self.tipFont]).width + 26).rounded(.up)
        let scale = window?.backingScaleFactor ?? 2
        let textKey = "\(tip.effectiveAppearance.name.rawValue)|\(Int(scale))|\(text)"   // 颜色跟随浅色/深色外观
        if tipTextCache[textKey] == nil {
            if tipTextCache.count > 200 { tipTextCache.removeAll() }
            let size = NSSize(width: w, height: 17)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(17 * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                tip.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let attrs: [NSAttributedString.Key: Any] = [.font: Self.tipFont, .foregroundColor: NSColor.labelColor]
                    let ts = (text as NSString).size(withAttributes: attrs)
                    (text as NSString).draw(at: NSPoint(x: (w - ts.width) / 2, y: (17 - ts.height) / 2), withAttributes: attrs)
                }
                NSGraphicsContext.restoreGraphicsState()
                tipTextCache[textKey] = rep.cgImage
            }
        }
        tipLabel.contents = tipTextCache[textKey]
        tipLabel.contentsScale = scale
        tipLabel.frame = CGRect(x: 0, y: arrowH + (pillH - 17) / 2, width: w, height: 17)
        tip.layer?.setAffineTransform(.identity)
        tip.frame = NSRect(origin: origin(w), size: NSSize(width: w, height: pillH + arrowH))
        // 遮罩图和描边只跟宽度有关：同一个宽度做过一次就记下来（每次换字都重画一遍遮罩要 1ms 多）
        let shapes = tipShapeCache[w] ?? {
            let made = Self.makeTipShape(width: w, scale: window?.backingScaleFactor ?? 2)
            tipShapeCache[w] = made; return made
        }()
        tip.maskImage = shapes.mask
        let outline = shapes.outline
        tipOutline.frame = tip.bounds; tipOutline.path = outline
        tip.isHidden = false
    }

    // 鼠标位置自己去读，不接收"鼠标移动"事件 —— 和系统程序坞的做法一样（它的主线程在悬停时几乎是闲的）。
    // 走事件的话：每次移动都要经过 窗口服务器 → 事件线程 → 主线程分发 → 跟踪区域 才到这里，实测占了悬停时近三分之一的 CPU，
    // 而且鼠标回报率越高越费（每秒 1000 次的鼠标：18%；系统程序坞：7.8%）。读位置本身不到 0.1 微秒，每帧读一次，和鼠标回报率无关。
    var pointerOwned = false   // 由控制器的定时器更新：程序坞显示着、鼠标在条的范围内、而且鼠标正下方最上面的窗口是我们
    func pollPointer() {
        guard !menuOpen, dragState == nil, let w = window else { return }   // 菜单开着：保持放大不动；按住/拖动图标：由拖动事件处理
        var newX: CGFloat? = nil
        if pointerOwned {
            let m = NSEvent.mouseLocation
            let px = m.x - w.frame.minX, py = m.y - w.frame.minY   // 内容视图铺满窗口，窗口坐标就是视图坐标
            if py >= 0 && py <= bottomMargin + barH + (mouseX != nil ? (L - S) + 10 : 4) && slide < 0.5 { newX = px }
        }
        if newX != mouseX { mouseX = newX; startLink() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressedIndex = index(at: p)
        if let i = pressedIndex {
            let e = model.entries[i]
            var draggable = false
            if case .app = e, i > 0 { draggable = true }   // 包括分隔线右边"在运行但没固定"的应用；访达（第 0 个）不能动
            if case .group = e { draggable = true }
            if case .folder = e { draggable = true }
            if draggable {
                var d = DragState(id: e.id, index: i, x: p.x, y: p.y, startX: p.x, startY: p.y, active: false)
                if let il = iconLayers[e.id], il.bounds.width > 1 {
                    let k = S / il.bounds.width   // 按下时图标可能是放大的，拖起来会缩回原大小，偏移按比例缩
                    d.offX = (p.x - il.position.x) * k; d.offY = (p.y - il.frame.midY) * k
                }
                dragState = d
            }
            setPressed(e.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = dragState else { return }
        let p = convert(event.locationInWindow, from: nil)
        d.x = p.x - d.offX; d.y = p.y - d.offY
        if !d.active && hypot(p.x - d.startX, p.y - d.startY) > 6 { d.active = true; reordering = true; mouseX = nil; tip.isHidden = true; setPressed(nil) }
        dragState = d
        dropTarget = (d.active && d.id.hasPrefix("app:") && !outsideBar(p.y)) ? centerHit(p.x, Self.isGroup) : nil
        if d.active { NSCursor.current.set(); if outsideBar(p.y) && (d.id.hasPrefix("app:") || d.id.hasPrefix("folder:")) && !isUnpinned(d.id) { NSCursor.disappearingItem.set() } else { NSCursor.arrow.set() } }
        startLink()
    }

    // 按下时把图标压暗一点（和系统程序坞一样），松手或开始拖动时恢复
    private let pressDim = CALayer(), pressMask = CALayer()
    func setPressed(_ id: String?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pressDim.removeFromSuperlayer()
        if let id = id, let il = iconLayers[id] {
            pressDim.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
            pressMask.contents = il.contents; pressMask.contentsGravity = il.contentsGravity   // 只压暗图标本身的形状，不是整个方块
            pressDim.frame = il.bounds; pressMask.frame = il.bounds
            pressDim.mask = pressMask
            il.addSublayer(pressDim)
        }
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(nil)
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
            if case .folder(let path) = dragged {
                // 文件夹：拖出 = 从程序坞移除（文件夹本身不动）；在条内 = 保存新顺序
                if outsideBar(d.y) { poof(at: p); dragState = nil; model.unpinFolder(path) }
                else { let list = orderedEntries; dispX[d.id] = d.x; velX[d.id] = 0; reordering = true; dragState = nil; commitOrder(list) }
                dragState = nil; startLink(); return
            }
            if case .app(let path, _) = dragged {
                if let g = targetGroup(), let info = AppInfo.from(url: URL(fileURLWithPath: path)) {
                    // 拖到分组上：放进分组（会从程序坞条上消失，出现在分组里）
                    dropTarget = nil; dragState = nil
                    GroupManager.shared.addApp(info, to: g)
                    startLink(); return
                }
                if isUnpinned(d.id) {
                    // 在运行但没固定的应用：拖进固定区 = 固定在那个位置；否则弹回原位
                    let pinHere = !outsideBar(d.y) && inPinnedZone(d.x)
                    if pinHere { _ = orderedEntries }   // 刷新 lastInsert
                    dispX[d.id] = d.x; velX[d.id] = 0; reordering = true
                    dragState = nil
                    if pinHere { pin([path], atEntryIndex: lastInsert) }
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
        tipSuppressed = e.id; tip.isHidden = true
        switch e {
        case .app(let path, _):
            if model.runningApp(path) == nil { bounce(e.id, path: path) }
            model.openOrSwitch(path)
        case .group(let gid): openGroup(gid)
        case .folder(let p): NSWorkspace.shared.open(URL(fileURLWithPath: p, isDirectory: true))
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
        case .folder(let p): menu = buildFolderMenu(p)
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
        menuOpen = true; tip.isHidden = true
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
            dgRememberFrontApp(); NSApp.activate(ignoringOtherApps: true)
            if dgRunAlert(a) == .alertFirstButtonReturn {
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
            dgRememberFrontApp(); NSApp.activate(ignoringOtherApps: true)
            if dgRunAlert(a) == .alertFirstButtonReturn { GroupManager.shared.deleteGroup(g) }
        })
        return menu
    }

    func buildFolderMenu(_ p: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "打开") { NSWorkspace.shared.open(URL(fileURLWithPath: p, isDirectory: true)) })
        menu.addItem(ClosureMenuItem(title: "在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "从程序坞中移除") { [weak self] in self?.model.unpinFolder(p) })
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

    private static func isChromiumBasedPublic(_ p: String) -> Bool { CustomDockModel.isChromiumBased(p) }

    func buildAppMenu(path: String, pinned: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let run = model.runningApp(path)
        func item(_ t: String, _ f: @escaping () -> Void) -> NSMenuItem { let it = ClosureMenuItem(title: t, action: f); return it }
        if let r = run {
            let pid = r.processIdentifier
            if Self.isChromiumBasedPublic(path) {
                // Electron / Chromium 软件：不读窗口（见 isChromiumBased 的说明），菜单里就没有窗口列表
            } else if AppWindows.trusted {
                // 窗口列表：点哪个切到哪个（已最小化的会还原）
                let ws = AppWindows.list(pid: pid)
                for w in ws.prefix(12) {
                    let t = w.title.count > 36 ? String(w.title.prefix(36)) + "…" : w.title
                    menu.addItem(item(w.minimized ? t + "（已最小化）" : t) { AppWindows.focus(w, pid: pid) })
                }
                if !ws.isEmpty { menu.addItem(.separator()) }
            } else {
                menu.addItem(item("允许显示窗口列表…") { AppWindows.requestTrust() })
                menu.addItem(.separator())
            }
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
        if path == model.finderPath {
            // 菜单栏图标默认隐藏，所以设置和退出的入口放在访达图标的右键菜单里
            menu.addItem(item("DockGroups 设置…") { NotificationCenter.default.post(name: .dgOpenSettings, object: nil) })
            menu.addItem(item("退出 DockGroups") { NSApp.terminate(nil) })   // 正常退出：会把系统程序坞还回去
            menu.addItem(.separator())
        }
        opt.addItem(item("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
        let optItem = NSMenuItem(title: "选项", action: nil, keyEquivalent: ""); optItem.submenu = opt
        menu.addItem(optItem)
        menu.addItem(.separator())
        if let r = run {
            menu.addItem(item("显示所有窗口") { [weak self] in
                if !AppWindows.exposeWindows(of: r) { r.unhide(); self?.model.openOrSwitch(path) }
            })
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
            case .folder(let p): toks.append("folder:" + p)
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
    // 拖进来的全是文件夹（不含 .app 这类包）时才算"固定文件夹"；混着普通文件就按普通文件处理
    private func draggedFolders(_ info: NSDraggingInfo) -> [String] {
        let urls = draggedFiles(info)
        let dirs = urls.filter { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }
        return dirs.count == urls.count ? dirs.map { CustomDockModel.norm($0.path) } : []
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
        // 文件夹：压在应用/文件夹图标中心 = 用它打开 / 移进去；压在废纸篓上 = 扔掉；其他位置 = 固定到程序坞
        if !draggedFolders(sender).isEmpty {
            dropInsert = nil
            if let t = centerHit(p.x, { if case .app = $0 { return true }; if case .folder = $0 { return true }; return false }) {
                dropTarget = t; startLink(); return t.hasPrefix("app:") ? .generic : .move
            }
            if let i = index(at: p), case .trash = model.entries[i] { dropTarget = "trash"; startLink(); return .delete }
            dropTarget = nil
            dropInsert = insertIndex(for: p.x, excluding: "", list: model.entries)
            reordering = true
            startLink()
            return .link
        }
        // 普通文件：拖到应用图标上 = 用这个应用打开；拖到文件夹上 = 移进去；拖到废纸篓上 = 扔进废纸篓
        if !draggedFiles(sender).isEmpty, let i = index(at: p) {
            switch model.entries[i] {
            case .app: dropTarget = model.entries[i].id; startLink(); return .generic
            case .folder: dropTarget = model.entries[i].id; startLink(); return .move
            case .trash: dropTarget = "trash"; startLink(); return .delete
            default: break
            }
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
        if target == "trash" {
            // 交给访达删（进废纸篓，可以"放回原处"）：访达自带各文件夹的权限，也不会弹我们自己的授权
            let list = draggedFiles(sender).map { "POSIX file " + CustomDockModel.asQuote($0.path) }.joined(separator: ", ")
            CustomDockModel.finder("delete {\(list)}") { CustomDockModel.refreshTrash { [weak self] in self?.reloadIcons() } }
            startLink(); return true
        }
        if let t = target, t.hasPrefix("app:") {
            NSWorkspace.shared.open(draggedFiles(sender), withApplicationAt: URL(fileURLWithPath: String(t.dropFirst(4))), configuration: NSWorkspace.OpenConfiguration())
            startLink(); return true
        }
        if let t = target, t.hasPrefix("folder:") {
            // 交给访达移动：同一个盘是移动、跨盘是拷贝，重名会照常弹访达自己的确认
            let list = draggedFiles(sender).map { "POSIX file " + CustomDockModel.asQuote($0.path) }.joined(separator: ", ")
            CustomDockModel.finder("move {\(list)} to (POSIX file \(CustomDockModel.asQuote(String(t.dropFirst(7)))) as alias)")
            startLink(); return true
        }
        let folders = draggedFolders(sender)
        guard !apps.isEmpty || !folders.isEmpty else { dropInsert = nil; return false }
        let ins = dropInsert ?? model.entries.count
        dropInsert = nil
        if apps.isEmpty { pinFolders(folders, atEntryIndex: ins) } else { pin(apps, atEntryIndex: ins) }
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

    // 把文件夹固定到第 ins 个条目位置：条目 id 和顺序里的记号是同一套写法，直接在顺序里找它前面最近的那个
    func pinFolders(_ paths: [String], atEntryIndex ins: Int) {
        let toks = paths.map { "folder:" + $0 }
        var ord = model.order.filter { !toks.contains($0) }
        let anchor = model.entries.prefix(ins).reversed().lazy.compactMap { e in ord.firstIndex(of: e.id) }.first.map { $0 + 1 } ?? 0
        ord.insert(contentsOf: toks, at: anchor)
        model.order = ord
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
    var allowKey = true   // 玻璃窗口不允许成为键盘窗口（它不接收任何输入）
    override var canBecomeKey: Bool { allowKey }
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
    static func asQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
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
    // 每个 tick 都要读：缓存起来，只通过 setter 改（读 UserDefaults 比想象的贵）
    private lazy var autoHideValue: Bool = ud.object(forKey: "customDockAutoHide") as? Bool ?? true
    var autoHide: Bool {
        get { autoHideValue }
        set { autoHideValue = newValue; ud.set(newValue, forKey: "customDockAutoHide"); if !newValue { show() } }
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
        p.acceptsMouseMovedEvents = false   // 鼠标位置靠 pollPointer 自己读
        let v = DockBarView(frame: .zero)
        // 我们自己的滑出速度跟随用户原来的设置（系统里现在那个值被我们故意改成了 1000，不能读它）
        if let m = ud.object(forKey: "origTimeModifier") as? Double, m > 0 { v.slideOmega = 14 / CGFloat(m) }
        p.contentView = v
        // 玻璃窗口：同样的层级和行为，不接收鼠标，作为子窗口垫在下面（跟着主窗口一起移动和排序）
        let gp = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        gp.isReleasedWhenClosed = false
        gp.isOpaque = false; gp.backgroundColor = .clear; gp.hasShadow = false
        gp.level = p.level; gp.collectionBehavior = p.collectionBehavior
        gp.hidesOnDeactivate = false; gp.ignoresMouseEvents = true; gp.allowKey = false
        gp.contentView = v.glassHost
        glassPanel = gp
        panel = p; bar = v
        v.onWidthChange = { [weak self] _ in self?.frameWindow() }
        frameWindow()
        _ = CustomDockModel.shared
        v.reloadIcons()
        p.orderFrontRegardless()
        gp.orderFrontRegardless()
        p.addChildWindow(gp, ordered: .below)
        shown = true
        // 60Hz 轮询鼠标位置决定显示/隐藏（唤出最多晚 17ms；收起状态下每次只是取一下鼠标位置）。不用全局鼠标监听：
        // 那样鼠标在屏幕任何地方移动，每个事件都要投递给本进程，实测占 4% CPU
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        // 分辨率/显示器变化：重新读屏幕信息、重新定位
        refreshScreens()
        screenObs = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshScreens(); self?.frameWindow(); self?.bar?.reloadIcons()
        }
    }

    private var screenObs: Any?
    private var glassPanel: NSPanel?
    func stop() {
        if let o = screenObs { NotificationCenter.default.removeObserver(o); screenObs = nil }
        if let g = glassPanel { panel?.removeChildWindow(g); g.orderOut(nil); glassPanel = nil }
        timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil; bar = nil; dgCustomDockTop = nil }

    // 窗口固定全屏宽、足够高（容纳放大和标签），只有图标区域接收点击
    private var dockDisplay: CGDirectDisplayID?
    static func displayID(_ s: NSScreen) -> CGDirectDisplayID { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    // 屏幕信息缓存：tick 每秒跑 30 次，每次现取 NSScreen.screens + deviceDescription 很贵；屏幕变化时（通知）才刷新
    private var screenInfo: [(screen: NSScreen, id: CGDirectDisplayID, frame: NSRect)] = []
    private func refreshScreens() { screenInfo = NSScreen.screens.map { ($0, Self.displayID($0), $0.frame) } }
    // 程序坞当前在哪块屏幕上（那块屏幕被拔掉就回到主屏）
    private var dockInfo: (screen: NSScreen, id: CGDirectDisplayID, frame: NSRect) {
        if screenInfo.isEmpty { refreshScreens() }
        return screenInfo.first { $0.id == dockDisplay } ?? screenInfo.first ?? (NSScreen.main!, 0, NSScreen.main!.frame)
    }
    private var dockScreen: NSScreen { dockInfo.screen }
    // 鼠标是否贴在某块屏幕的底边（上下叠放的两块屏幕之间的交界不算），返回那块屏幕的 ID
    private func edgeDisplay(_ m: NSPoint) -> CGDirectDisplayID? {
        screenInfo.first { s in
            let f = s.frame
            return m.x >= f.minX && m.x <= f.maxX && m.y <= f.minY + 2 && m.y >= f.minY - 1
                && !screenInfo.contains { $0.id != s.id && $0.frame.contains(NSPoint(x: m.x, y: f.minY - 1)) }
        }?.id
    }

    private func frameWindow(moved: Bool = false) {
        guard let p = panel, let v = bar else { return }
        let screen = dockScreen
        let f = screen.frame
        let h = v.L + 60
        let y = f.minY
        // 窗口只比程序坞条略大（含放大余量和提示宽度），条目变化时才调整
        let w = min(f.width, (v.baseWidth + (v.L - v.S) * 3 + 300).rounded())
        let nf = NSRect(x: (f.midX - w / 2).rounded(), y: y, width: w, height: h)
        if nf == p.frame { return }
        let dx = (moved || p.frame.width == 0) ? 0 : p.frame.minX - nf.minX   // 换屏幕时图标的窗口内坐标不变，不用补偿
        p.setFrame(nf, display: true)
        glassPanel?.setFrame(nf, display: true)
        v.shiftX(dx)
        if moved { v.startLink() }
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

    private var lastTrashCheck = Date.distantPast
    private var lastBadgeCheck = Date.distantPast
    private var lastAppsCheck = Date.distantPast
    private var lastSysDockCheck = Date.distantPast
    private var sysDockOffSince: Date?
    private var sysDockHealAttempt = 0
    // 自动修复：出现过一次系统程序坞"卡在显示"——它的运行时"自动隐藏"被关掉了（设置文件里还是开着），而且不再读设置。
    // 原因没查到（启动台复现不了），所以不猜原因，直接修：关掉超过 15 秒（排除启动台/调度中心时它自己临时关一下的情况），
    // 先让它把自动隐藏打开；10 秒后还是关的，就强制重启它
    private func healSystemDock() {
        guard enabled, let on = SystemDockAPI.autoHideEnabled() else { return }
        if on { sysDockOffSince = nil; sysDockHealAttempt = 0; return }
        let since = sysDockOffSince ?? Date(); sysDockOffSince = since
        let off = Date().timeIntervalSince(since)
        if off > 15 && sysDockHealAttempt == 0 {
            sysDockHealAttempt = 1
            dgLog("system Dock autohide found OFF for \(Int(off))s — turning it back on")
            SystemDockAPI.setAutoHide(true)
        } else if off > 25 && sysDockHealAttempt == 1 {
            sysDockHealAttempt = 2
            dgLog("system Dock still not hiding — force restarting it")
            sh("defaults write com.apple.dock autohide -bool true; P=$(pgrep -x Dock); killall Dock; sleep 1.5; [ -n \"$P\" ] && [ \"$(pgrep -x Dock)\" = \"$P\" ] && killall -KILL Dock")
        }
    }
    // 鼠标离开程序坞附近后，等多久才收起（原来 0.05 秒，蹭出去一下就收，容易闪）
    static let hideGrace: TimeInterval = 0.15
    private var lastTopCheck: CFTimeInterval = 0
    private var topIsOurs = true
    private var edgeSince: Date?

    private func tick() {
        guard let p = panel, let v = bar else { return }
        let m = NSEvent.mouseLocation
        // 自动隐藏时：鼠标推到另一块屏幕的底边，程序坞跟过去（和系统一样）
        if autoHide, let ed = edgeDisplay(m), ed != dockInfo.id, v.dragState == nil, !v.menuOpen {
            dockDisplay = ed
            shown = false; v.slide = 1; v.slideTarget = 1; v.mouseX = nil
            frameWindow(moved: true)
            edgeSince = nil
        }
        parkIfHidden()
        // 系统程序坞的"自动隐藏"被谁关掉了：5 秒查一次（读一下不到 1 微秒）。放在"收起时提前返回"之前，收起时也要查
        if Date().timeIntervalSince(lastSysDockCheck) > 5 { lastSysDockCheck = Date(); healSystemDock() }
        let dock = dockInfo
        let atEdge = edgeDisplay(m) == dock.id
        // 兜底：程序坞已经收起（或正在收起）时，名称提示绝不该还在。出现过一次"程序坞没了、提示还留在屏幕底边"，原因没查明，
        // 所以这里强制收掉并记一笔，下次能从日志里看到当时的状态
        if !shown && v.tipVisible {
            dgLog("stray tooltip while hidden: slide=\(v.slide) target=\(v.slideTarget) mouseX=\(String(describing: v.mouseX)) owned=\(v.pointerOwned) menu=\(v.menuOpen) drag=\(v.dragState != nil)")
            v.mouseX = nil; v.hideTip()
        }
        let now = Date()
        // 已收起且鼠标不在底边：直接返回
        if !shown && !atEdge && p.ignoresMouseEvents && autoHide {
            edgeSince = nil
            // 鼠标离底边还远（> 150pt）就查慢一点（20Hz），靠近了才用 60Hz：空闲时少被唤醒，唤出照样跟手
            if m.y - dock.frame.minY > 150 { timer?.fireDate = Date(timeIntervalSinceNow: 1.0 / 20) }
            v.pointerOwned = false
            return
        }
        // 废纸篓状态只在程序坞看得见时才查，最多 10s 一次
        if shown && now.timeIntervalSince(lastTrashCheck) > 10 {
            lastTrashCheck = now
            CustomDockModel.refreshTrash { [weak self] in self?.bar?.reloadIcons() }
        }
        v.settleGlassIfDue()

        // 有没有应用中途变成（或不再是）普通应用：3s 核对一次
        if now.timeIntervalSince(lastAppsCheck) > 3 { lastAppsCheck = now; CustomDockModel.shared.rebuildIfAppsChanged() }
        // 角标同理：只在看得见时查，1s 一次
        if shown && now.timeIntervalSince(lastBadgeCheck) > 1 {
            lastBadgeCheck = now
            CustomDockModel.shared.refreshBadges { [weak self] in self?.bar?.reloadBadges() }
        }
        // 这里以前会在"系统程序坞有全屏窗口"时让位（当成调度中心）。删掉了：
        // 全屏应用里把鼠标推到底边，系统程序坞自己也会弹出并带着同样的窗口，两者分不出来，结果是我们的程序坞被顶掉、有时很久不回来。
        // 现在调度中心里推到底边也能唤出我们的程序坞，和系统程序坞在调度中心里的表现一致。
        // 只让程序坞条本身拦截鼠标，透明区域放行
        let local = NSPoint(x: m.x - p.frame.minX, y: m.y - p.frame.minY)
        // 与原生一致：只看程序坞条实际范围（含放大后的图标高度），外扩 4pt
        let g = v.lastGlass
        let topY = g.maxY + (v.mouseX != nil || v.dragState?.active == true ? (v.L - v.S) + 4 : 4)
        let overBar = local.x >= g.minX - 4 && local.x <= g.maxX + 4 && local.y >= 0 && local.y <= topY
        // 决定"要不要收起"用宽一点的范围：鼠标在条外 16pt、条上方 16pt 以内都算还在附近，蹭出去一点不会立刻收
        let nearBar = local.x >= g.minX - 16 && local.x <= g.maxX + 16 && local.y >= -2 && local.y <= topY + 16
        let ign = !(overBar && shown)
        if p.ignoresMouseEvents != ign { p.ignoresMouseEvents = ign }
        // 鼠标归不归我们：除了在条的范围内，还要求鼠标正下方最上面的窗口是我们（别的应用的菜单/浮层盖在程序坞上时不放大）。
        // 在应用里问一次窗口服务器实测要 0.5 毫秒左右，所以确认是我们之后 0.5 秒才复查一次；问不出结果时按"是我们"处理
        var owned = !ign
        if owned {
            let t = CACurrentMediaTime()
            if !topIsOurs || t - lastTopCheck > 0.5 {
                lastTopCheck = t
                let top = NSWindow.windowNumber(at: m, belowWindowWithWindowNumber: 0)
                topIsOurs = top == 0 || top == p.windowNumber
            }
            owned = topIsOurs
        }
        v.pointerOwned = owned
        v.pollPointer()   // 刷新定时器没开的时候，靠这里（60Hz）发现鼠标动了并把它叫起来
        // 鼠标一进我们的窗口，AppKit 就会向系统登记"后台也要鼠标移动事件"，之后每次移动都投递过来（我们已经不用它了）。
        // 这里把它压回去。右键菜单开着时不压（菜单要靠它跟随鼠标高亮）；应用是活动状态时（分组面板、设置窗口）走的是另一套，不受影响
        // 设置之类的普通窗口开着时也不压（它们在后台时的悬停效果要靠这些事件）
        if !v.menuOpen && !NSApp.isActive && !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { BackgroundMouseMoved.suppress() }
        if !autoHide { if !shown { show() }; return }
        if atEdge || (shown && nearBar) { lastInside = Date() }
        if atEdge { if edgeSince == nil { edgeSince = Date() } } else { edgeSince = nil }
        let revealDelay = ud.object(forKey: "origAutohideDelay") as? Double ?? 0
        if !shown && atEdge && Date().timeIntervalSince(edgeSince ?? Date()) >= revealDelay { dgLog("autohide: show"); show() }
        else if shown && !overBar && !atEdge && Date().timeIntervalSince(lastInside) > Self.hideGrace && !popupOpen() && !v.menuOpen && v.dragState == nil { dgLog("autohide: hide m=\(m) local=\(local) glass=\(g) topY=\(topY) panel=\(p.frame) parked=\(parked) visible=\(p.isVisible) slide=\(v.slide)"); hide() }
    }
    private func popupOpen() -> Bool { NSApp.windows.contains { $0 is GroupPopupWindow && $0.isVisible } }

    // 从分组面板里往外拖应用。拖动中：光标在程序坞条上就让其他图标让出空位（at 为 nil 表示拖动结束/回到面板内）
    func groupDragMoved(at screen: NSPoint?) {
        guard let p = panel, let v = bar else { return }
        var ins: Int? = nil
        if let s = screen {
            let local = v.convert(p.convertPoint(fromScreen: s), from: nil)
            if p.frame.contains(s) && local.y < v.bottomMargin + v.barH + 30 { ins = v.insertIndex(for: local.x, excluding: "", list: v.model.entries) }
        }
        if ins != v.dropInsert { v.dropInsert = ins; v.reordering = true; v.startLink() }
    }
    // 松手：落在程序坞条上就插到让出的空位，否则排到最后
    func dropFromGroup(_ path: String, at screen: NSPoint) {
        guard let v = bar else { CustomDockModel.shared.pin(path); return }
        groupDragMoved(at: screen)
        let ins = v.dropInsert ?? v.model.entries.count
        v.dropInsert = nil
        v.pin([path], atEntryIndex: ins)
        v.startLink()
    }

    func show() { shown = true; putBack(); bar?.slideTarget = 0; bar?.startLink() }

    // 收起后把两块窗口从屏幕上撤掉。它们比玻璃条高（要给放大和名字提示留位置），收起后虽然看不见，
    // 但别的软件（比如 Typeless 的语音气泡）会把它当成"底下有东西"，把自己挪到它上面去
    private var parked = false
    private func parkIfHidden() {
        guard !shown, !parked, let p = panel, let v = bar, v.slide >= 1, v.slideTarget >= 1, v.dragState == nil, !popupOpen() else { return }
        parked = true
        glassPanel?.orderOut(nil); p.orderOut(nil)
    }
    private func putBack() {
        guard parked, let p = panel else { return }
        parked = false
        p.orderFrontRegardless()
        if let g = glassPanel { g.orderFrontRegardless(); p.addChildWindow(g, ordered: .below) }
    }
    func hide() { shown = false; bar?.pointerOwned = false; bar?.slideTarget = 1; bar?.mouseX = nil; bar?.hideTip(); bar?.startLink() }

    // MARK: 系统程序坞开关
    private func sh(_ cmd: String) {
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/bin/sh"); pr.arguments = ["-c", cmd]
        try? pr.run(); pr.waitUntilExit()
    }
    private func readDock(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) }

    // 命令里重启系统程序坞的写法：先正常让它退出；1.5 秒后如果还是同一个进程（它卡死了，不理普通退出请求——实测出现过一次，
    // 界面卡在显示状态、也不读新设置），就强制结束，系统会马上把它重新拉起来
    private var restoreCmd: String {
        let delay = ud.object(forKey: "origAutohideDelay") as? Double ?? 0
        let ah = ud.object(forKey: "origAutohide") as? Bool ?? true
        let tm = ud.object(forKey: "origTimeModifier") as? Double ?? 0
        let tmCmd = tm > 0 ? "defaults write com.apple.dock autohide-time-modifier -float \(tm)" : "defaults delete com.apple.dock autohide-time-modifier"
        return "defaults write com.apple.dock autohide -bool \(ah ? "true" : "false"); defaults write com.apple.dock autohide-delay -float \(delay); \(tmCmd); P=$(pgrep -x Dock); killall Dock; sleep 1.5; [ -n \"$P\" ] && [ \"$(pgrep -x Dock)\" = \"$P\" ] && killall -KILL Dock"
    }
    // 接管系统程序坞，两个设置都要改（已经是了就不动它）：
    //  - autohide-delay = 1000：鼠标停在底边 1000 秒才唤出，普通桌面上等于藏起来
    //  - autohide-time-modifier = 1000：滑出动画拉长到 1000 秒。全屏应用里把鼠标推到底边时系统程序坞会无视上面的延迟直接弹出，
    //    这个关不掉，只能让它滑得慢到看不见
    private func suppressSystemDock() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let delay = (readDock("autohide-delay") as? NSNumber)?.doubleValue
        let tm = (readDock("autohide-time-modifier") as? NSNumber)?.doubleValue
        if ud.object(forKey: "origAutohideDelay") == nil {
            ud.set(delay ?? 0, forKey: "origAutohideDelay")
            ud.set((readDock("autohide") as? NSNumber)?.boolValue ?? false, forKey: "origAutohide")
        }
        // 0 表示"用户没设过"；读到 1000 说明是我们上次留下的，不能当成用户的原值
        if ud.object(forKey: "origTimeModifier") == nil { ud.set((tm == nil || tm == 1000) ? 0 : tm!, forKey: "origTimeModifier") }
        if delay != 1000 || tm != 1000 {
            sh("defaults write com.apple.dock autohide -bool true; defaults write com.apple.dock autohide-delay -float 1000; defaults write com.apple.dock autohide-time-modifier -float 1000; P=$(pgrep -x Dock); killall Dock; sleep 1.5; [ -n \"$P\" ] && [ \"$(pgrep -x Dock)\" = \"$P\" ] && killall -KILL Dock")
        }
        dgRestoreDockOnCrash(restoreCmd)
        dgStartDockWatchdog(restoreCmd)
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
        ud.removeObject(forKey: "origAutohideDelay"); ud.removeObject(forKey: "origAutohide"); ud.removeObject(forKey: "origTimeModifier")
        ud.set(false, forKey: "customDockEnabled")
        stop()
        GroupManager.shared.rebuildLaunchers()   // 回到系统程序坞：分组靠启动器小应用放进去
    }
}

// 崩溃时也要把系统程序坞还回去。信号处理函数里能做的事极少，所以命令行提前备好，只调 posix_spawn
private var dgCrashArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
// 看门进程：被强制退出（活动监视器"强制退出"、kill -9）时本进程什么都来不及做，信号处理也收不到。
// 所以启动时另起一个独立的小进程盯着本进程：本进程一消失、并且 2 秒内没有新的 DockGroups 起来（重装时会马上重开），
// 就把系统程序坞还回去。它不是本进程的子任务，本进程被杀它也照常运行
private var dgWatchdogStarted = false
func dgStartDockWatchdog(_ restoreCmd: String) {
    if dgWatchdogStarted { return }
    dgWatchdogStarted = true
    let pid = ProcessInfo.processInfo.processIdentifier
    let script = """
    while kill -0 \(pid) 2>/dev/null; do sleep 1; done
    sleep 2
    pgrep -x DockGroups >/dev/null && exit 0
    \(restoreCmd)
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
    p.arguments = ["/bin/sh", "-c", script]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    do { try p.run(); dgLog("dock watchdog started pid=\(p.processIdentifier)") } catch { dgLog("dock watchdog failed: \(error)") }
}

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
        // asQuote：应用名/路径里带引号会把 AppleScript 拼断，静默失败
        if contains(path) { _ = run("tell application \"System Events\" to delete login item \(CustomDockModel.asQuote(name))") }
        else { _ = run("tell application \"System Events\" to make login item at end with properties {path:\(CustomDockModel.asQuote(path)), hidden:false}") }
        cacheTime = .distantPast
    }
}


// 图标缓存：系统图标 / 自定义覆盖（如 ChatGPT 运行时图标），始终用最大分辨率源
// 窗口列表和"显示所有窗口"
enum AppWindows {
    struct Item { let title: String; let element: AXUIElement; let minimized: Bool }
    static var trusted: Bool { AXIsProcessTrusted() }
    // 弹出系统的"辅助功能"授权提示（授权一次即可；签名固定后重装不丢）
    static func requestTrust() { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }

    // 应用卡死时最多等 0.25s，不能把程序坞也拖住
    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success, let wins = raw as? [AXUIElement] else { return [] }
        return wins
    }
    private static func attr(_ w: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?; return AXUIElementCopyAttributeValue(w, a as CFString, &v) == .success ? v : nil
    }

    static func list(pid: pid_t) -> [Item] {
        windows(of: pid).compactMap { w in
            guard (attr(w, kAXRoleAttribute) as? String) == kAXWindowRole, let t = attr(w, kAXTitleAttribute) as? String, !t.isEmpty else { return nil }
            return Item(title: t, element: w, minimized: (attr(w, kAXMinimizedAttribute) as? Bool) ?? false)
        }
    }

    static func focus(_ item: Item, pid: pid_t) {
        if item.minimized { AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // 和系统程序坞的"显示所有窗口"一样：进入这个应用的 App Exposé（私有接口，不需要授权；找不到就返回 false 走普通切换）
    private typealias CoreDockSend = @convention(c) (CFString, Int32) -> Void
    static var exposeAvailable: Bool {
        _ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") != nil
    }
    static func exposeWindows(of app: NSRunningApplication) -> Bool {
        _ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return false }
        let send = unsafeBitCast(sym, to: CoreDockSend.self)
        app.unhide(); app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { send("com.apple.expose.front.awake" as CFString, 0) }
        return true
    }
}

// 系统程序坞运行时的"自动隐藏"状态（私有 CoreDock 接口，系统偏好里的那个开关就是调它）
enum SystemDockAPI {
    private typealias G = @convention(c) () -> Bool
    private typealias S = @convention(c) (Bool) -> Void
    private static let getFn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: G.self) }
    private static let setFn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: S.self) }
    static var available: Bool { getFn != nil && setFn != nil }
    static func autoHideEnabled() -> Bool? { getFn?() }
    static func setAutoHide(_ on: Bool) { setFn?(on) }
}

// 私有 SkyLight 接口：应用在后台时，窗口服务器还给它投递哪些事件。
// 实测（最小程序，鼠标每秒上报 1000 次扫过窗口）：不压 → 收到 791 个移动事件、进程占 4.5% CPU；压住 → 2 个、0%。点击不受影响
enum BackgroundMouseMoved {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias GetFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias SetFn = @convention(c) (Int32, UInt32) -> Int32
    private static let handle = UnsafeMutableRawPointer(bitPattern: -2)
    private static let conn = dlsym(handle, "SLSMainConnectionID").map { unsafeBitCast($0, to: ConnFn.self) }
    private static let get = dlsym(handle, "SLSGetBackgroundEventMask").map { unsafeBitCast($0, to: GetFn.self) }
    private static let set = dlsym(handle, "SLSSetBackgroundEventMask").map { unsafeBitCast($0, to: SetFn.self) }
    static var available: Bool { conn != nil && get != nil && set != nil }
    private static let mouseMoved: UInt32 = 1 << 5
    // 读一次不到 0.5 微秒（本地缓存），所以可以每个 tick 都看一眼；只有位被打开了才真的去改
    static func suppress() {
        guard let c = conn?(), let g = get, let s = set else { return }
        var m: UInt32 = 0
        guard g(c, &m) == 0, m & mouseMoved != 0 else { return }
        _ = s(c, m & ~mouseMoved)
    }
}

// 私有 LaunchServices 接口：应用通过 dockTile.badgeLabel 设的角标存在这里的 StatusLabel 里
enum AppBadge {
    private typealias ASNCreate = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias InfoItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let lib = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
    private static let asnCreate = dlsym(lib, "_LSASNCreateWithPid").map { unsafeBitCast($0, to: ASNCreate.self) }
    private static let infoItem = dlsym(lib, "_LSCopyApplicationInformationItem").map { unsafeBitCast($0, to: InfoItem.self) }
    static var available: Bool { asnCreate != nil && infoItem != nil && asnCreate?(nil, getpid()) != nil }
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
