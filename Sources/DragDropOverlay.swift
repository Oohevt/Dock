import SwiftUI
import AppKit

// MARK: - 拖拽放置区窗口（可选功能）

class DragDropOverlayWindow: NSPanel {
    static let shared = DragDropOverlayWindow()
    
    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        self.contentView = NSHostingView(rootView: DragDropOverlayView(window: self))
    }
    
    func show() {
        guard let screen = NSScreen.main else { return }
        
        // 覆盖 Dock 区域上方
        let screenFrame = screen.visibleFrame
        let fullFrame = screen.frame
        let dockHeight = fullFrame.height - screenFrame.maxY
        
        let overlayHeight: CGFloat = 150
        let frame = NSRect(
            x: fullFrame.minX,
            y: fullFrame.minY + dockHeight - 20,
            width: fullFrame.width,
            height: overlayHeight
        )
        
        self.setFrame(frame, display: true)
        self.orderFrontRegardless()
        self.alphaValue = 0
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1
        }
    }
    
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}

struct DragDropOverlayView: View {
    weak var window: NSWindow?
    
    @ObservedObject private var groupManager = GroupManager.shared
    @State private var dragOver = false
    @State private var dragOverGroupId: UUID?
    
    var body: some View {
        HStack(spacing: 20) {
            Spacer()
            
            // 现有分组
            ForEach(groupManager.groups.sorted(by: { $0.order < $1.order })) { group in
                GroupDropZone(group: group, isDragOver: dragOverGroupId == group.id)
                    .onDrop(of: [.fileURL], isTargeted: Binding(
                        get: { dragOverGroupId == group.id },
                        set: { if $0 { dragOverGroupId = group.id } else if dragOverGroupId == group.id { dragOverGroupId = nil } }
                    )) { providers in
                        handleDrop(providers: providers, group: group)
                        return true
                    }
            }
            
            // 创建新分组区域
            NewGroupDropZone(isDragOver: dragOverGroupId == nil && dragOver)
                .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                    handleNewGroupDrop(providers: providers)
                    return true
                }
            
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.3))
        )
    }
    
    private func handleDrop(providers: [NSItemProvider], group: AppGroup) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url = url, url.pathExtension == "app" else { return }
                
                DispatchQueue.main.async {
                    if let appInfo = AppInfo.from(url: url) {
                        GroupManager.shared.addApp(appInfo, to: group)
                        
                        // 显示通知
                        showNotification(title: "已添加到 \(group.name)", message: appInfo.name)
                    }
                }
            }
        }
        
        DragDropOverlayWindow.shared.hide()
    }
    
    private func handleNewGroupDrop(providers: [NSItemProvider]) {
        var apps: [AppInfo] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                defer { group.leave() }
                
                guard let url = url, url.pathExtension == "app" else { return }
                
                if let appInfo = AppInfo.from(url: url) {
                    apps.append(appInfo)
                }
            }
        }
        
        group.notify(queue: .main) {
            if !apps.isEmpty {
                // 显示对话框让用户输入分组名称
                let alert = NSAlert()
                alert.messageText = "创建新分组"
                alert.informativeText = "为包含 \(apps.count) 个应用的新分组命名："
                
                let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                textField.placeholderString = "新分组"
                textField.stringValue = "新分组"
                alert.accessoryView = textField
                
                alert.addButton(withTitle: "创建")
                alert.addButton(withTitle: "取消")
                
                if alert.runModal() == .alertFirstButtonReturn {
                    let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        GroupManager.shared.addGroup(name: name, apps: apps)
                        showNotification(title: "已创建分组", message: "\(name) - \(apps.count) 个应用")
                    }
                }
            }
            
            DragDropOverlayWindow.shared.hide()
        }
    }
    
    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
}

struct GroupDropZone: View {
    let group: AppGroup
    let isDragOver: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            if let icon = group.generateIcon(size: CGSize(width: 256, height: 256)) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            Text(group.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .frame(width: 100, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDragOver ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(isDragOver ? 1 : 0.5), lineWidth: isDragOver ? 3 : 2)
                )
        )
        .scaleEffect(isDragOver ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isDragOver)
    }
}

struct NewGroupDropZone: View {
    let isDragOver: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.square.dashed")
                .font(.system(size: 40))
                .foregroundColor(.white)
            
            Text("创建新分组")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .frame(width: 100, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isDragOver ? 3 : 2, dash: [8])
                )
                .foregroundColor(.white.opacity(isDragOver ? 1 : 0.6))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isDragOver ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1))
                )
        )
        .scaleEffect(isDragOver ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isDragOver)
    }
}

// MARK: - 拖拽监控器

class DragDropMonitor {
    static let shared = DragDropMonitor()
    
    private var monitor: Any?
    private var isDragging = false
    
    private init() {
        startMonitoring()
    }
    
    private func startMonitoring() {
        // 注意：检测全局拖拽需要辅助功能权限
        // 这里提供基本框架，实际实现可能需要更复杂的方法
        
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            
            if !self.isDragging {
                self.isDragging = true
                
                // 检查是否拖拽了 .app 文件
                // 实际检测需要使用 NSPasteboard 或其他方法
                // 这里仅作示例
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // DragDropOverlayWindow.shared.show()
                }
            }
        }
        
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self = self else { return }
            
            if self.isDragging {
                self.isDragging = false
                // DragDropOverlayWindow.shared.hide()
            }
        }
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
