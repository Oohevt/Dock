import SwiftUI
import AppKit

class ManageGroupsWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        
        self.title = "管理分组"
        self.center()
        self.contentView = NSHostingView(rootView: ManageGroupsView())
        self.setFrameAutosaveName("ManageGroupsWindow.v2")
        self.minSize = NSSize(width: 680, height: 420)
    }
}

struct ManageGroupsView: View {
    @ObservedObject private var groupManager = GroupManager.shared
    @State private var selectedGroup: AppGroup?
    @State private var showingCreateGroup = false
    @State private var showingDeleteConfirm = false
    @State private var groupToDelete: AppGroup?
    @State private var newGroupName = ""
    
    var body: some View {
        HSplitView {
            // 左侧：分组列表
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("分组列表")
                        .font(.headline)
                    Spacer()
                    Button(action: { showingCreateGroup = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                // 分组列表
                if groupManager.groups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("暂无分组")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("点击右上角 + 按钮创建分组")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedGroup) {
                        ForEach(groupManager.groups.sorted(by: { $0.order < $1.order })) { group in
                            GroupListRow(group: group)
                                .tag(group)
                                .contextMenu {
                                    Button("重命名") {
                                        renameGroup(group)
                                    }
                                    Button("删除", role: .destructive) {
                                        groupToDelete = group
                                        showingDeleteConfirm = true
                                    }
                                    Divider()
                                    Button("在 Finder 中显示启动器") {
                                        showInFinder(group)
                                    }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            
            // 右侧：分组详情
            if let group = selectedGroup {
                GroupDetailView(group: group)
                    .id(group.id)   // 换分组要当新视图重建，否则 @State 里的应用列表还是上一个分组的
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("选择一个分组查看详情")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingCreateGroup) {
            CreateGroupSheet(
                groupName: $newGroupName,
                onCreate: {
                    if !newGroupName.isEmpty {
                        groupManager.addGroup(name: newGroupName)
                        newGroupName = ""
                        showingCreateGroup = false
                    }
                },
                onCancel: {
                    newGroupName = ""
                    showingCreateGroup = false
                }
            )
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                if let group = groupToDelete {
                    groupManager.deleteGroup(group)
                    if selectedGroup?.id == group.id {
                        selectedGroup = nil
                    }
                }
            }
        } message: {
            if let group = groupToDelete {
                Text("确定要删除分组 '\(group.name)' 吗？这不会删除应用本身。")
            }
        }
    }
    
    private func renameGroup(_ group: AppGroup) {
        let alert = NSAlert()
        alert.messageText = "重命名分组"
        alert.informativeText = "为分组输入新名称："
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = group.name
        alert.accessoryView = textField
        
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                var updated = group
                updated.name = newName
                groupManager.updateGroup(updated)
            }
        }
    }
    
    private func showInFinder(_ group: AppGroup) {
        if let url = groupManager.getLauncherURL(for: group) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct GroupListRow: View {
    let group: AppGroup
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = group.generateIcon(size: CGSize(width: 128, height: 128)) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 14, weight: .medium))
                Text("\(group.apps.count) 个应用")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GroupDetailView: View {
    let group: AppGroup
    
    @State private var apps: [AppInfo]
    
    init(group: AppGroup) {
        self.group = group
        self._apps = State(initialValue: group.apps)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                if let icon = group.generateIcon(size: CGSize(width: 256, height: 256)) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.title2.bold()).lineLimit(1).truncationMode(.tail)
                    Text("\(apps.count) 个应用")
                        .font(.subheadline)
                        .foregroundColor(.secondary).lineLimit(1).fixedSize()
                }
                
                Spacer()
                
                Button(action: addApps) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("添加应用")
                    }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                
                Button(action: openLauncherFolder) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("启动器位置")
                    }
                }
                .fixedSize()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // 应用列表
            if apps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("分组中暂无应用")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button("添加应用") {
                        addApps()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(apps) { app in
                        AppDetailRow(
                            app: app,
                            onDelete: {
                                removeApp(app)
                            },
                            onLaunch: {
                                app.launch()
                            }
                        )
                    }
                    .onMove { from, to in
                        apps.move(fromOffsets: from, toOffset: to)
                        GroupManager.shared.reorderApps(apps, in: group)
                    }
                }
            }
        }
    }
    
    private func addApps() {
        let window = AddAppsWindow(group: group)
        window.makeKeyAndOrderFront(nil)
    }
    
    private func removeApp(_ app: AppInfo) {
        apps.removeAll { $0.id == app.id }
        GroupManager.shared.removeApp(app, from: group)
    }
    
    private func openLauncherFolder() {
        if let url = GroupManager.shared.getLauncherURL(for: group) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct AppDetailRow: View {
    let app: AppInfo
    let onDelete: () -> Void
    let onLaunch: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.getIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                if !app.bundleIdentifier.isEmpty {
                    Text(app.bundleIdentifier)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            
            Spacer()
            
            Button(action: onLaunch) {
                Image(systemName: "play.circle")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .help("启动应用")
            
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("从分组中移除")
        }
        .padding(.vertical, 4)
    }
}

struct CreateGroupSheet: View {
    @Binding var groupName: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("创建新分组")
                .font(.title2.bold())
            
            TextField("分组名称", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            
            HStack(spacing: 12) {
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("创建") {
                    onCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(30)
        .frame(width: 400)
    }
}
