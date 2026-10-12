import Foundation
import AppKit

class GroupManager: ObservableObject {
    static let shared = GroupManager()
    
    @Published var groups: [AppGroup] = []
    
    private let storageURL: URL
    private var dockLauncherApps: [UUID: URL] = [:]
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("DockGroups", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        storageURL = appFolder.appendingPathComponent("groups.json")
        
        print("数据存储路径: \(storageURL.path)")
    }
    
    // MARK: - 持久化
    
    func loadGroups() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            print("未找到保存的分组数据，创建示例分组")
            createSampleGroups()
            return
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            groups = try JSONDecoder().decode([AppGroup].self, from: data)
            pruneLaunchers()
            print("成功加载 \(groups.count) 个分组")
            
            // 为每个分组创建 Dock 启动器
            for group in groups {
                createDockLauncher(for: group)
            }
        } catch {
            print("加载分组失败: \(error)")
            createSampleGroups()
        }
    }
    
    // 删掉不属于任何现有分组的启动器小应用（分组被删除或改名后会留下）
    func pruneLaunchers() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("DockGroups/Launchers", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let keep = Set(groups.map { $0.name + ".app" })
        for n in items where n.hasSuffix(".app") && !keep.contains(n) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            dgLog("pruned orphan launcher \(n)")
        }
    }

    func saveGroups() {
        pruneLaunchers()
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: storageURL, options: .atomic)   // 先写临时文件再替换：写到一半断电/崩溃也不会把分组文件写坏
            print("成功保存 \(groups.count) 个分组")
        } catch {
            print("保存分组失败: \(error)")
        }
    }
    
    // MARK: - 分组管理
    
    func addGroup(name: String, apps: [AppInfo] = []) {
        let order = groups.map { $0.order }.max() ?? -1
        let group = AppGroup(name: name, apps: apps, order: order + 1)
        groups.append(group)
        
        createDockLauncher(for: group)
        saveGroups()
    }
    
    func updateGroup(_ group: AppGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            createDockLauncher(for: group)
            saveGroups()
        }
    }
    
    func deleteGroup(_ group: AppGroup) {
        groups.removeAll { $0.id == group.id }
        removeDockLauncher(for: group)
        saveGroups()
    }
    
    func reorderGroups(_ groups: [AppGroup]) {
        self.groups = groups.enumerated().map { index, group in
            var updated = group
            updated.order = index
            return updated
        }
        saveGroups()
    }
    
    // MARK: - 应用管理
    
    func addApp(_ app: AppInfo, to group: AppGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        
        // 检查是否已存在
        if !groups[index].apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            groups[index].apps.append(app)
            createDockLauncher(for: groups[index])
            saveGroups()
        }
    }
    
    func removeApp(_ app: AppInfo, from group: AppGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].apps.removeAll { $0.id == app.id }
        createDockLauncher(for: groups[index])
        saveGroups()
    }
    
    func reorderApps(_ apps: [AppInfo], in group: AppGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].apps = apps
        saveGroups()
    }
    
    // MARK: - Dock 启动器
    
    func rebuildLaunchers() { for g in groups { createDockLauncher(for: g) } }

    private func createDockLauncher(for group: AppGroup) {
        // 启动器只在用系统程序坞时才有用；生成一个要画 10 张图 + iconutil + codesign，启动时每个分组都来一遍会卡近 2 秒
        if CustomDockController.shared.enabled { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let launchersFolder = appSupport.appendingPathComponent("DockGroups/Launchers", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchersFolder, withIntermediateDirectories: true)
        
        let launcherURL = launchersFolder.appendingPathComponent("\(group.name).app")
        
        // 删除旧的启动器
        try? FileManager.default.removeItem(at: launcherURL)
        
        // 创建 .app 目录结构
        let contentsURL = launcherURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        
        try? FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        
        // 每次用新图标文件名，迫使 Dock 刷新缓存
        let iconName = "AppIcon-\(Int(Date().timeIntervalSince1970))"
        // 创建 Info.plist
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>launcher</string>
            <key>CFBundleIdentifier</key>
            <string>com.dockgroups.launcher.\(group.id.uuidString)</string>
            <key>CFBundleName</key>
            <string>\(group.name)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleIconFile</key>
            <string>\(iconName)</string>
            <key>LSUIElement</key>
            <true/>
            <key>DockGroupID</key>
            <string>\(group.id.uuidString)</string>
        </dict>
        </plist>
        """
        
        try? infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"),
                            atomically: true,
                            encoding: .utf8)
        
        // 启动器：复制编译好的小程序（脚本型 .app 无法被 Dock 重复启动）
        let scriptURL = macOSURL.appendingPathComponent("launcher")
        if let stub = Bundle.main.url(forResource: "launcher-stub", withExtension: nil) {
            try? FileManager.default.copyItem(at: stub, to: scriptURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 保存图标（真正的 icns）
        if let icon = group.generateIcon(size: CGSize(width: 1024, height: 1024)) {
            writeICNS(icon, to: resourcesURL.appendingPathComponent("\(iconName).icns"))
        }
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--force", "--deep", "-s", "-", launcherURL.path]
        try? cs.run(); cs.waitUntilExit()
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: launcherURL.path)
        NSWorkspace.shared.noteFileSystemChanged(launcherURL.path)

        dockLauncherApps[group.id] = launcherURL
        
        print("为分组 '\(group.name)' 创建了 Dock 启动器: \(launcherURL.path)")
    }
    
    private func writeICNS(_ image: NSImage, to url: URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: tmp.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", tmp.path, "-o", url.path]
        try? p.run(); p.waitUntilExit()
        try? fm.removeItem(at: tmp)
    }

    private func removeDockLauncher(for group: AppGroup) {
        if let url = dockLauncherApps[group.id] {
            try? FileManager.default.removeItem(at: url)
            dockLauncherApps.removeValue(forKey: group.id)
        }
    }
    
    func getLauncherURL(for group: AppGroup) -> URL? {
        return dockLauncherApps[group.id]
    }
    
    // MARK: - 示例数据
    
    private func createSampleGroups() {
        // 创建示例分组
        let commonApps = findCommonApps()
        if !commonApps.isEmpty {
            addGroup(name: "常用", apps: Array(commonApps.prefix(6)))
        }
        
        let devApps = findDevelopmentApps()
        if !devApps.isEmpty {
            addGroup(name: "开发", apps: devApps)
        }
    }
    
    private func findCommonApps() -> [AppInfo] {
        let commonAppNames = ["Safari", "Mail", "Messages", "Calendar", "Notes", "Reminders",
                             "Photos", "Music", "Podcasts", "TV", "Books"]
        return findApps(matching: commonAppNames)
    }
    
    private func findDevelopmentApps() -> [AppInfo] {
        let devAppNames = ["Xcode", "Visual Studio Code", "Terminal", "Simulator", "GitHub Desktop",
                          "Postman", "Docker", "iTerm", "Sublime Text", "IntelliJ IDEA"]
        return findApps(matching: devAppNames)
    }
    
    private func findApps(matching names: [String]) -> [AppInfo] {
        var apps: [AppInfo] = []
        let applicationsURL = URL(fileURLWithPath: "/Applications")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles]
        ) else { return apps }
        
        for url in contents {
            guard url.pathExtension == "app" else { continue }
            let appName = url.deletingPathExtension().lastPathComponent
            
            if names.contains(where: { appName.localizedCaseInsensitiveContains($0) }),
               let appInfo = AppInfo.from(url: url) {
                apps.append(appInfo)
            }
        }
        
        return apps
    }
    
    // 获取所有已安装的应用
    func getAllInstalledApps() -> [AppInfo] {
        var apps: [AppInfo] = []
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        
        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            
            for appURL in contents where appURL.pathExtension == "app" {
                if let appInfo = AppInfo.from(url: appURL) {
                    apps.append(appInfo)
                }
            }
        }
        
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
