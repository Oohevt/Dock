import SwiftUI
import AppKit

class GroupPopupWindow: NSWindow {
    private(set) var group: AppGroup
    private var hostingView: FirstMouseHostingView<GroupPopupView>?
    private var monitor: Any?
    
    init(group: AppGroup) {
        self.group = group
        
        // 窗口配置
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        setupContent()
        setupEventMonitor()
    }
    
    static let cols = 3
    static let cellW: CGFloat = 92, cellH: CGFloat = 94, pad: CGFloat = 18, titleH: CGFloat = 40, radius: CGFloat = 26
    
    private func setupContent() {
        let rows = max(1, Int(ceil(Double(group.apps.count) / Double(Self.cols))))
        let cols = min(Self.cols, max(group.apps.count, 1))
        let w = max(CGFloat(cols) * Self.cellW + Self.pad * 2, 220)
        let h = Self.titleH + CGFloat(rows) * Self.cellH + Self.pad + 18
        // 锚点：点击时鼠标位置（Dock 图标处）
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main!
        let vf = screen.visibleFrame, ff = screen.frame
        var dockTop = vf.minY
        if dockTop - ff.minY < 20 { dockTop = ff.minY + 80 } // Dock 自动隐藏时
        var anchorX = mouse.x
        if let t = dgCustomDockTop { dockTop = t - 26 }
        if let ax = dgPopupAnchorX { anchorX = ax; dgPopupAnchorX = nil }
        var x = anchorX - w / 2
        x = min(max(x, ff.minX + 8), ff.maxX - w - 8)
        self.setFrame(NSRect(x: x, y: dockTop + 40, width: w, height: h), display: false)
        let swiftUIView = GroupPopupView(group: group, window: self)
        let host = FirstMouseHostingView(rootView: swiftUIView)
        hostingView = host
        let size = NSSize(width: w, height: h)
        host.frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            // 与程序坞条同款：通透折射的液态玻璃，自身圆角裁剪
            let g = NSGlassEffectView(frame: host.frame)
            g.style = .clear; g.cornerRadius = Self.radius
            g.tintColor = NSColor(white: 0, alpha: 0.22)   // 面板里有文字：压暗一点保证白字在亮背景上可读
            g.contentView = host
            g.wantsLayer = true; g.layer?.borderWidth = 0; g.layer?.masksToBounds = true
            self.contentView = g
        } else {
            let blur = NSVisualEffectView(frame: host.frame)
            blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
            blur.wantsLayer = true; blur.layer?.cornerRadius = Self.radius; blur.layer?.cornerCurve = .continuous; blur.layer?.masksToBounds = true
            host.autoresizingMask = [.width, .height]
            blur.addSubview(host)
            self.contentView = blur
        }
    }
    
    private func setupEventMonitor() {
        // 监听外部点击和 Esc 键
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { // Esc key
                self?.close()
            } else if event.type == .leftMouseDown || event.type == .rightMouseDown {
                // 检查点击是否在窗口外
                if let window = self, let clickLocation = self?.mouseLocationOutsideOfEventStream {
                    let windowFrame = window.frame
                    let clickInWindow = windowFrame.contains(clickLocation)
                    if !clickInWindow {
                        window.close()
                    }
                }
            }
        }
    }
    
    override var canBecomeKey: Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }   // 同 DockPanel：保证玻璃不降级成磨砂
    override func cancelOperation(_ sender: Any?) { close() }
    override func performClose(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func close() {
        dgLastPopupClose = (group.id, Date())
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.close()
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - 弹出视图

struct GroupPopupView: View {
    let group: AppGroup
    weak var window: NSWindow?
    @State private var apps: [AppInfo]
    // 图标只在打开面板时取一次：getIcon() 每次都返回新图片对象，悬停变化重绘时会让所有图标闪一下
    private let icons: [UUID: NSImage]
    @State private var hoveredApp: UUID?
    @State private var draggingID: UUID?            // 拖动排序中的应用
    @State private var dragLocation: CGPoint = .zero
    @State private var draggedOut = false           // 已拖到面板外
    @State private var runningPaths: Set<String> = GroupPopupView.currentRunningPaths()
    
    static func currentRunningPaths() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }
    private func runningApp(_ app: AppInfo) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: app.path).standardizedFileURL.path
                || (!app.bundleIdentifier.isEmpty && $0.bundleIdentifier == app.bundleIdentifier)
        }
    }
    private func isRunning(_ app: AppInfo) -> Bool {
        runningPaths.contains(URL(fileURLWithPath: app.path).standardizedFileURL.path)
    }
    private func openOrSwitch(_ app: AppInfo) {
        // 单击即打开/切换（与原生一致）：统一用 openApplication(activates)，运行中则激活
        runningApp(app)?.unhide()
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        let path = app.path
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, err in
            dgLog("popup open \(path) err=\(String(describing: err))")
        }
        window?.close()
    }
    
    init(group: AppGroup, window: NSWindow?) {
        self.group = group
        self.window = window
        self._apps = State(initialValue: group.apps)
        self.icons = Dictionary(group.apps.compactMap { a in a.getIcon().map { (a.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
    
    var body: some View {
        let cols = min(GroupPopupWindow.cols, max(apps.count, 1))
        VStack(spacing: 0) {
            Text(group.name)
                .font(.system(size: 15, weight: .semibold))
                .frame(height: GroupPopupWindow.titleH)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(GroupPopupWindow.cellW), spacing: 0), count: cols), spacing: 0) {
                ForEach(apps) { app in
                    VStack(spacing: 6) {
                        if let icon = icons[app.id] {
                            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 56, height: 56)
                                .overlay(alignment: .topTrailing) {
                                    if let b = CustomDockModel.shared.badges[CustomDockModel.norm(app.path)] {
                                        Text(b).font(.system(size: 11, weight: .medium)).padding(.horizontal, 5)
                                            .frame(minWidth: 18, minHeight: 18)
                                            .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.19)))
                                            .offset(x: 5, y: -5)
                                    }
                                }
                                // 悬停反馈和程序坞一致：图标从底边向上微微放大，不加底色
                                .scaleEffect(hoveredApp == app.id ? 1.25 : 1, anchor: .bottom)
                                .animation(.easeOut(duration: 0.12), value: hoveredApp)
                        }
                        Text(app.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail).frame(width: 84)
                        Circle().fill(Color.white.opacity(isRunning(app) ? 0.9 : 0)).frame(width: 4, height: 4)
                    }
                    .frame(width: GroupPopupWindow.cellW, height: GroupPopupWindow.cellH)
                    .opacity(draggingID == app.id ? 0 : 1)   // 拖动时原位置留空，图标由下面的浮层跟着光标画
                    .contentShape(Rectangle())
                    // 从 A 移到 B 时，A 的"离开"可能晚于 B 的"进入"：只清掉自己的悬停状态
                    .onHover { if $0 { hoveredApp = app.id } else if hoveredApp == app.id { hoveredApp = nil } }
                    .onTapGesture { openOrSwitch(app) }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
                        .onChanged { v in
                            draggingID = app.id; dragLocation = v.location; hoveredApp = nil
                            // 拖出面板：面板内的内容出不了窗口，改用一个跟着光标的小浮窗显示图标；此时不再排序
                            let mouse = NSEvent.mouseLocation
                            draggedOut = !(window?.frame.contains(mouse) ?? true)
                            if draggedOut { DragGhost.show(icons[app.id], at: mouse); return } else { DragGhost.hide() }
                            guard let from = apps.firstIndex(where: { $0.id == app.id }) else { return }
                            let col = min(max(Int(v.location.x / GroupPopupWindow.cellW), 0), cols - 1)
                            let row = max(Int(v.location.y / GroupPopupWindow.cellH), 0)
                            let to = min(row * cols + col, apps.count - 1)
                            if to != from {
                                withAnimation(.easeOut(duration: 0.18)) { apps.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
                            }
                        }
                        .onEnded { _ in
                            draggingID = nil
                            DragGhost.hide()
                            if draggedOut {
                                // 松手在面板外：移出分组，放回程序坞
                                draggedOut = false
                                apps.removeAll { $0.id == app.id }
                                GroupManager.shared.removeApp(app, from: group)
                                CustomDockController.shared.dropFromGroup(CustomDockModel.norm(app.path), at: NSEvent.mouseLocation)
                            } else {
                                GroupManager.shared.reorderApps(apps, in: group)
                            }
                        })
                    .contextMenu {
                        Button(isRunning(app) ? "切换到" : "打开") { openOrSwitch(app) }
                        if isRunning(app) {
                            Button("退出") { runningApp(app)?.terminate() }
                            Button("强制退出") { runningApp(app)?.forceTerminate() }
                        }
                        Divider()
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                            window?.close()
                        }
                        Button("从分组移除") {
                            apps.removeAll { $0.id == app.id }
                            GroupManager.shared.removeApp(app, from: group)
                        }
                    }
                }
            }
            .coordinateSpace(name: "grid")
            .overlay(alignment: .topLeading) {
                if let id = draggingID, !draggedOut, let icon = icons[id] {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 56, height: 56).scaleEffect(1.12)
                        .position(dragLocation).allowsHitTesting(false)
                }
            }
            Text("点击打开 · 右键更多").font(.system(size: 10)).opacity(0.75).frame(height: 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 通透玻璃后面是任意壁纸：白字加阴影，和桌面图标标签同一思路
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            runningPaths = GroupPopupView.currentRunningPaths()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            runningPaths = GroupPopupView.currentRunningPaths()
        }
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// 跟随光标的图标小浮窗：应用从分组面板拖到面板外时用
enum DragGhost {
    private static let panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .popUpMenu; p.ignoresMouseEvents = true
        let v = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)); v.imageScaling = .scaleProportionallyUpOrDown
        p.contentView = v
        return p
    }()
    static func show(_ image: NSImage?, at mouse: NSPoint) {
        (panel.contentView as? NSImageView)?.image = image
        panel.setFrameOrigin(NSPoint(x: mouse.x - 32, y: mouse.y - 32))
        panel.orderFrontRegardless()
    }
    static func hide() { panel.orderOut(nil) }
}
