import SwiftUI
import ServiceManagement

@main
enum DockGroupsMain {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// 记录最近一次关闭的弹窗，用于"再点一次关闭"
var dgLastPopupClose: (id: UUID, time: Date)? = nil

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarManager: MenuBarManager?
    private var signalSources: [DispatchSourceSignal] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，只显示菜单栏
        NSApp.setActivationPolicy(.accessory)
        
        // 主菜单：提供 ⌘W 关闭窗口等标准快捷键（附属应用不显示菜单栏，但快捷键生效）
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "退出 DockGroups", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件"); fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"); fileItem.submenu = fileMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = main
        
        // 初始化菜单栏管理器
        menuBarManager = MenuBarManager()
        
        // 初始化分组管理器
        GroupManager.shared.loadGroups()
        
        if CustomDockController.shared.enabled { CustomDockController.shared.resume() }
        // kill / 注销发来的 SIGTERM 默认直接杀进程，不走 applicationWillTerminate：转成正常退出
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume(); signalSources.append(src)
        }
        // 登录时启动
        if #available(macOS 13.0, *) {
            do { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }; dgLog("login item status \(SMAppService.mainApp.status.rawValue)") }
            catch { dgLog("SMAppService register failed: \(error)") }
        }
        print("DockGroups 已启动")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 菜单栏图标隐藏时：再次打开应用 → 打开设置（管理分组）并临时显示菜单栏图标
        NotificationCenter.default.post(name: .dgOpenSettings, object: nil); return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        GroupManager.shared.saveGroups()
        if CustomDockController.shared.enabled { CustomDockController.shared.restoreSystemDock() }
    }
}

extension Notification.Name { static let dgOpenSettings = Notification.Name("dgOpenSettings") }
