p='Sources/DockGroupsApp.swift'; s=open(p).read()
s=s.replace('import SwiftUI','import SwiftUI\nimport ServiceManagement',1) if 'ServiceManagement' not in s else s
s=s.replace('''        if CustomDockController.shared.enabled { CustomDockController.shared.start() }''','''        if CustomDockController.shared.enabled { CustomDockController.shared.start() }
        // 登录时启动
        if #available(macOS 13.0, *) {
            do { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }; dgLog("login item status \\(SMAppService.mainApp.status.rawValue)") }
            catch { dgLog("SMAppService register failed: \\(error)") }
        }''')
s=s.replace('func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }',
 'func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {\n        // 菜单栏图标隐藏时：再次打开应用 → 打开设置（管理分组）并临时显示菜单栏图标\n        NotificationCenter.default.post(name: .dgOpenSettings, object: nil); return false\n    }')
s+='\nextension Notification.Name { static let dgOpenSettings = Notification.Name("dgOpenSettings") }\n'
open(p,'w').write(s)
p='Sources/MenuBarManager.swift'; s=open(p).read()
s=s.replace('''        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
''','''        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.autosaveName = "com.example.DockGroups.status"
        if UserDefaults.standard.object(forKey: "hideMenuBarIcon") == nil { UserDefaults.standard.set(true, forKey: "hideMenuBarIcon") }
        statusItem?.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        NotificationCenter.default.addObserver(forName: .dgOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.statusItem?.isVisible = true
            self?.openManageWindow()
        }
''')
s=s.replace('''        // 退出
        let quitItem''','''        let hideItem = NSMenuItem(title: "隐藏菜单栏图标", action: #selector(toggleHideIcon), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = UserDefaults.standard.bool(forKey: "hideMenuBarIcon") ? .on : .off
        menu.addItem(hideItem)
        // 退出
        let quitItem''')
s=s.replace('    @objc private func openManageWindow() {','''    @objc private func toggleHideIcon() {
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
    @objc private func openManageWindow() {''')
open(p,'w').write(s)
p='Sources/CustomDock.swift'; s=open(p).read()
s=s.replace('''        opt.addItem(item("在访达中显示")''','''        if path == model.finderPath { menu.addItem(item("DockGroups 设置…") { NotificationCenter.default.post(name: .dgOpenSettings, object: nil) }); menu.addItem(.separator()) }
        opt.addItem(item("在访达中显示")''',1)
open(p,'w').write(s); print("ok")
