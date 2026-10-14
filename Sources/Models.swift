import Foundation
import AppKit

// MARK: - 应用信息
struct AppInfo: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let bundleIdentifier: String
    let path: String
    var iconData: Data?
    var customIconPath: String?
    
    // 显示名称：始终从应用包本身读取（与访达/Dock 一致）
    var displayName: String {
        var n = FileManager.default.displayName(atPath: path)
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n.isEmpty ? name : n
    }
    
    init(id: UUID = UUID(), name: String, bundleIdentifier: String, path: String, iconData: Data? = nil) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.iconData = iconData
    }
    
    // 从应用路径创建
    static func from(url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url) else { return nil }
        
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String 
                   ?? url.deletingPathExtension().lastPathComponent
        let bundleId = bundle.bundleIdentifier ?? ""

        return AppInfo(
            name: name,
            bundleIdentifier: bundleId,
            path: url.path
        )
    }
    
    // 获取图标：与 Dock 一致，直接问系统（不使用缓存数据）
    func getIcon() -> NSImage? {
        if let p = customIconPath, let img = NSImage(contentsOfFile: p) { return img }
        return NSWorkspace.shared.icon(forFile: path)
    }
    
    // 启动应用
    func launch() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                          configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - 应用分组
struct AppGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var apps: [AppInfo]
    var order: Int
    
    init(id: UUID = UUID(), name: String, apps: [AppInfo] = [], order: Int = 0) {
        self.id = id
        self.name = name
        self.apps = apps
        self.order = order
    }
    
    // 生成分组图标（复合图标）
    // 还装在电脑上的成员。已卸载的应用只是不显示，不从分组数据里删：应用更新时文件会短暂消失，外接盘上的应用也可能暂时不在
    var installedApps: [AppInfo] { apps.filter { FileManager.default.fileExists(atPath: $0.path) } }

    func generateIcon(size: CGSize = CGSize(width: 1024, height: 1024)) -> NSImage? {
        // macOS 26+ 会给非标准图标自动加一层圆角底板，所以这里画满整个画布，
        // 让系统底板成为唯一的一层；小图标直接居中排列在上面。
        let image = NSImage(size: size)
        image.lockFocus()
        // 自定义图标是单张 1024px 大图，缩到小格子时默认插值会糊；系统图标自带多档尺寸不受影响
        NSGraphicsContext.current?.imageInterpolation = .high
        let W = size.width
        let full = NSRect(origin: .zero, size: size)
        // 与普通应用图标同尺寸的圆角框：半透明玻璃色填充 + 细亮边（不是乳白色）
        let frameR = full.insetBy(dx: W * 0.095, dy: W * 0.095)
        let fp = NSBezierPath(roundedRect: frameR, xRadius: frameR.width * 0.225, yRadius: frameR.width * 0.225)
        NSColor(white: 1, alpha: 0.16).setFill(); fp.fill()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0.0)])?.draw(in: fp, angle: -90)
        NSColor(white: 1, alpha: 0.55).setStroke(); fp.lineWidth = W * 0.008; fp.stroke()
        let n = 2   // 程序坞/启动器图标最多显示 4 个（2x2），弹窗仍显示全部
        let shown = Array(installedApps.prefix(4))
        let area = frameR.insetBy(dx: frameR.width * 0.16, dy: frameR.width * 0.16)
        let gap = area.width * (n == 2 ? 0.12 : 0.08)
        let cell = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
        // 网格在框内上下左右居中（不满行时整体垂直居中）
        let rows = max(1, Int(ceil(Double(shown.count) / Double(n))))
        let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        let top = area.midY + gridH / 2
        for (idx, app) in shown.enumerated() {
            guard let icon = app.getIcon() else { continue }
            let row = idx / n, col = idx % n
            let x = area.minX + CGFloat(col) * (cell + gap)
            let y = top - CGFloat(row + 1) * cell - CGFloat(row) * gap
            icon.draw(in: NSRect(x: x, y: y, width: cell, height: cell), from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        return image
    }
}
