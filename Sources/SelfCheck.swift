import AppKit
import ApplicationServices

// 依赖系统私有行为的地方，启动时（和收到 dockgroups://selfcheck 时）逐项检查一遍，结果写进日志。
// 系统升级后先看日志里有没有 FAIL，再决定修哪里（对照 README 的表）。
enum SelfCheck {
    static func run() {
        var lines: [(String, Bool, String)] = []
        func add(_ name: String, _ ok: Bool, _ detail: String = "") { lines.append((name, ok, detail)) }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        add("os", true, "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        // 玻璃：类还在；窗口的"激活外观"私有方法还在（DockPanel 靠它让玻璃保持通透）
        add("glass.class", NSClassFromString("NSGlassEffectView") != nil)
        add("glass.hasKeyAppearance", NSWindow.instancesRespond(to: NSSelectorFromString("hasKeyAppearance")), "NSWindow 上的私有方法")
        // 角标：两个 LaunchServices 私有符号都能解析，并且对自己的进程能取到句柄
        add("badge.symbols", AppBadge.available, "_LSASNCreateWithPid / _LSCopyApplicationInformationItem")
        // 显示所有窗口：App Exposé 的私有通知函数
        add("expose.symbol", AppWindows.exposeAvailable, "CoreDockSendNotification")
        // 后台不收鼠标移动事件（悬停时省一半 CPU）
        // 系统程序坞被意外关掉自动隐藏时的自动修复
        add("sysdock.heal", SystemDockAPI.available, "CoreDockGetAutoHideEnabled / CoreDockSetAutoHideEnabled")
        add("pointer.bgmask", BackgroundMouseMoved.available, "SLSGetBackgroundEventMask / SLSSetBackgroundEventMask")
        // 窗口列表需要辅助功能授权
        add("accessibility", AppWindows.trusted, AppWindows.trusted ? "" : "未授权：右键菜单里不会列出窗口")
        // 系统程序坞是否已被压下去（延迟 1000 秒）
        if CustomDockController.shared.enabled {
            CFPreferencesAppSynchronize("com.apple.dock" as CFString)
            let d = (CFPreferencesCopyAppValue("autohide-delay" as CFString, "com.apple.dock" as CFString) as? NSNumber)?.doubleValue
            let t = (CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, "com.apple.dock" as CFString) as? NSNumber)?.doubleValue
            add("systemdock.suppressed", d == 1000 && t == 1000, "autohide-delay=\(d.map { String($0) } ?? "nil") time-modifier=\(t.map { String($0) } ?? "nil")")
        }
        add("screens", !NSScreen.screens.isEmpty, "\(NSScreen.screens.count)")

        let bad = lines.filter { !$0.1 }.count
        for (n, ok, d) in lines { dgLog("selfcheck: \(ok ? "OK  " : "FAIL") \(n)\(d.isEmpty ? "" : " — " + d)") }
        dgLog("selfcheck: done, \(bad) failed")
    }
}
