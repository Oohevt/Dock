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
        
        dgTrimLog()
        // 初始化菜单栏管理器
        menuBarManager = MenuBarManager()
        
        // 初始化分组管理器
        GroupManager.shared.loadGroups()
        
        if CustomDockController.shared.enabled { CustomDockController.shared.resume() }
        SelfCheck.run()   // 要在接管系统程序坞之后，才能检查它是否已被压下去
        // 面板/对话框/设置窗口都关了就把"活动应用"的身份交还出去：
        // 本应用一直是活动应用的话，系统会把每一次鼠标移动都投递给它，实测让 CPU 从 0.04 涨到 0.3（每 6 秒的 CPU 秒数）
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // 从一个分组直接切到另一个分组时，新面板还开着：这次不还焦点，也别把"原来的应用"忘掉
            DispatchQueue.main.async { if dgYieldActivationIfIdle() { dgPreviousFrontApp = nil } }
        }
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

// 返回 false = 还有自己的窗口开着，这次没还
@discardableResult
func dgYieldActivationIfIdle(prev: NSRunningApplication? = dgPreviousFrontApp) -> Bool {
    guard NSApp.isActive else { return true }
    // 还有带标题栏的窗口（设置、添加应用、对话框）或分组面板开着，就别放手
    if NSApp.windows.contains(where: { $0.isVisible && ($0.styleMask.contains(.titled) || $0 is GroupPopupWindow) }) { return false }
    // NSApp.deactivate() 在这里不管用（应用仍是最前面的应用），所以直接把焦点还给之前在前面的那个应用
    if let prev = prev, !prev.isTerminated, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier, let url = prev.bundleURL {
        // prev.activate() 返回 true 但系统不一定执行（macOS 14 协作式激活）；走 LaunchServices，和点程序坞图标一样
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    } else {
        NSApp.deactivate()
    }
    return true
}

// 模态对话框：结束后交还焦点（模态窗口关闭不会发窗口关闭通知，所以不能靠上面的观察者）。
// 已知局限：对话框之后这一步在实测中不生效（本应用在 LaunchServices 里仍是最前面的应用，直到用户切到别的应用），
// 代价是鼠标移动时多约 4% CPU；分组面板那条路径是生效的。
func dgRunAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
    dgRememberFrontApp()
    NSApp.activate(ignoringOtherApps: true)
    let r = a.runModal()
    let prev = dgPreviousFrontApp
    dgPreviousFrontApp = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dgYieldActivationIfIdle(prev: prev) }
    return r
}

// 打开分组面板/对话框前在前面的应用
var dgPreviousFrontApp: NSRunningApplication? = nil
func dgRememberFrontApp() {
    if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != ProcessInfo.processInfo.processIdentifier { dgPreviousFrontApp = f }
}

extension Notification.Name { static let dgOpenSettings = Notification.Name("dgOpenSettings") }
