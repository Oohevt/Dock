import SwiftUI
import AppKit

class MenuBarManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var groupManager = GroupManager.shared
    
    override init() {
        super.init()
        setupMenuBar()
        
        // 注册 URL Scheme 处理
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.autosaveName = "com.example.DockGroups.status"
        if UserDefaults.standard.object(forKey: "hideMenuBarIcon") == nil { UserDefaults.standard.set(true, forKey: "hideMenuBarIcon") }
        statusItem?.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        NotificationCenter.default.addObserver(forName: .dgOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.statusItem?.isVisible = true
            self?.openManageWindow()
        }
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DockGroups")
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }
        
        updateMenu()
    }
    
    @objc private func statusBarButtonClicked() {
        updateMenu()
    }
    
    private func updateMenu() {
        let menu = NSMenu()
        
        // 分组列表
        if groupManager.groups.isEmpty {
            menu.addItem(NSMenuItem(title: "暂无分组", action: nil, keyEquivalent: ""))
        } else {
            for group in groupManager.groups.sorted(by: { $0.order < $1.order }) {
                let item = NSMenuItem(
                    title: "\(group.name) (\(group.apps.count))",
                    action: #selector(openGroup(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = group
                menu.addItem(item)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 管理菜单
        let manageItem = NSMenuItem(title: "管理分组", action: #selector(openManageWindow), keyEquivalent: "m")
        manageItem.target = self
        menu.addItem(manageItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let dockItem = NSMenuItem(title: "使用 DockGroups 程序坞", action: #selector(toggleCustomDock), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = CustomDockController.shared.enabled ? .on : .off
        menu.addItem(dockItem)
        let ahItem = NSMenuItem(title: "自动隐藏程序坞", action: #selector(toggleAutoHide), keyEquivalent: "")
        ahItem.target = self
        ahItem.state = CustomDockController.shared.autoHide ? .on : .off
        menu.addItem(ahItem)
        let reimport = NSMenuItem(title: "从系统程序坞重新导入", action: #selector(reimportDock), keyEquivalent: "")
        reimport.target = self
        menu.addItem(reimport)
        menu.addItem(NSMenuItem.separator())
        
        // 帮助和关于
        let helpItem = NSMenuItem(title: "使用说明", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.target = self
        menu.addItem(helpItem)
        
        let aboutItem = NSMenuItem(title: "关于 DockGroups", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let hideItem = NSMenuItem(title: "隐藏菜单栏图标", action: #selector(toggleHideIcon), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = UserDefaults.standard.bool(forKey: "hideMenuBarIcon") ? .on : .off
        menu.addItem(hideItem)
        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func openGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? AppGroup else { return }
        showGroupPopup(for: group)
    }
    
    private var currentPopup: GroupPopupWindow?

    func showGroupPopup(for group: AppGroup) {
        dgLog("popup show \(group.name) current=\(currentPopup.map { "\($0.group.name) vis=\($0.isVisible)" } ?? "nil") lastClose=\(dgLastPopupClose.map { String(format: "%.2fs ago", Date().timeIntervalSince($0.time)) } ?? "nil")")
        if let p = currentPopup, p.isVisible {
            let same = p.group.id == group.id
            p.close()
            currentPopup = nil
            if same { return }
        }
        if let last = dgLastPopupClose, last.id == group.id, Date().timeIntervalSince(last.time) < 0.6 {
            dgLastPopupClose = nil
            return
        }
        let window = GroupPopupWindow(group: group)
        currentPopup = window
        dgRememberFrontApp()
        // 淡入 + 从下方 8pt 升上来，而不是突然出现
        let final = window.frame
        window.alphaValue = 0
        window.setFrame(final.offsetBy(dx: 0, dy: -8), display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in dgLog("popup opened active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false) visible=\(window?.isVisible ?? false)") }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.14; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(final, display: true)
        }
    }
    
    @objc private func toggleHideIcon() {
        let h = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        UserDefaults.standard.set(h, forKey: "hideMenuBarIcon")
        statusItem?.isVisible = !h
        if h {
            let a = NSAlert(); a.messageText = "菜单栏图标已隐藏"
            a.informativeText = "重新打开 DockGroups（启动台/访达双击），或在程序坞的访达图标上右键 → DockGroups 设置…，即可打开设置并恢复图标。"
            a.runModal()
        }
        updateMenu()
    }
    @objc private func openManageWindow() {
        let window = ManageGroupsWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "DockGroups 使用说明"
        alert.informativeText = """
        DockGroups 让您可以将应用分组管理，类似于 iOS 的文件夹功能。
        
        使用方法：
        1. 点击菜单栏图标查看所有分组
        2. 点击分组名称打开该分组的应用面板
        3. 在应用面板中点击应用图标即可启动
        4. 点击"管理分组"可以创建、编辑和删除分组
        
        Dock 集成：
        - 每个分组会在 ~/Library/Application Support/DockGroups/Launchers/ 中创建一个启动器应用
        - 将启动器拖到 Dock 中，点击即可打开对应分组
        
        提示：
        - 使用 Esc 键或点击面板外部可关闭分组面板
        - 悬停在应用图标上可以看到删除按钮
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DockGroups"
        alert.informativeText = """
        版本 1.0
        
        为 macOS Dock 添加应用分组功能
        
        © 2024 DockGroups
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
    
    @objc private func toggleCustomDock() {
        if CustomDockController.shared.enabled { CustomDockController.shared.disable() } else { CustomDockController.shared.enable() }
        updateMenu()
    }
    @objc private func toggleAutoHide() {
        CustomDockController.shared.autoHide.toggle(); updateMenu()
    }
    @objc private func reimportDock() {
        CustomDockModel.shared.importSystemDock(); CustomDockModel.shared.rebuild()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {}

    @objc private func quit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - URL Scheme 处理
    
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        
        if url.scheme == "dockgroups" && url.host == "selfcheck" { SelfCheck.run(); return }
        if url.scheme == "dockgroups" && url.host == "selftest" {
            CustomDockController.shared.selfTest(index: Int(url.lastPathComponent) ?? 0)
            return
        }
        // dockgroups://group/{groupId}
        if url.scheme == "dockgroups" && url.host == "group" {
            let groupId = url.lastPathComponent
            if let uuid = UUID(uuidString: groupId),
               let group = groupManager.groups.first(where: { $0.id == uuid }) {
                showGroupPopup(for: group)
            }
        }
    }
}
