import SwiftUI
import AppKit

class AddAppsWindow: NSWindow {
    private var group: AppGroup
    
    init(group: AppGroup) {
        self.group = group
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        
        self.title = "添加应用到 \(group.name)"
        self.center()
        self.contentView = NSHostingView(rootView: AddAppsView(group: group, window: self))
    }
}

struct AddAppsView: View {
    let group: AppGroup
    weak var window: NSWindow?
    
    @State private var allApps: [AppInfo] = []
    @State private var searchText = ""
    @State private var selectedApps: Set<UUID> = []
    @State private var isLoading = true
    
    var filteredApps: [AppInfo] {
        if searchText.isEmpty {
            return allApps
        }
        return allApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索应用...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // 应用列表
            if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("正在加载应用...")
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            AppRow(
                                app: app,
                                isSelected: selectedApps.contains(app.id),
                                isAlreadyInGroup: group.apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier })
                            ) {
                                toggleSelection(app)
                            }
                            Divider()
                        }
                    }
                }
            }
            
            Divider()
            
            // 底部按钮
            HStack {
                Text("\(selectedApps.count) 个应用已选择")
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("取消") {
                    window?.close()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("添加") {
                    addSelectedApps()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedApps.isEmpty)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear(perform: loadApps)
    }
    
    private func loadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = GroupManager.shared.getAllInstalledApps()
            DispatchQueue.main.async {
                self.allApps = apps
                self.isLoading = false
            }
        }
    }
    
    private func toggleSelection(_ app: AppInfo) {
        if selectedApps.contains(app.id) {
            selectedApps.remove(app.id)
        } else {
            selectedApps.insert(app.id)
        }
    }
    
    private func addSelectedApps() {
        for appId in selectedApps {
            if let app = allApps.first(where: { $0.id == appId }) {
                GroupManager.shared.addApp(app, to: group)
            }
        }
        window?.close()
    }
}

struct AppRow: View {
    let app: AppInfo
    let isSelected: Bool
    let isAlreadyInGroup: Bool
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // 应用图标
            if let icon = app.getIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 48, height: 48)
            }
            
            // 应用信息
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 14, weight: .medium))
                
                if !app.bundleIdentifier.isEmpty {
                    Text(app.bundleIdentifier)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 状态指示
            if isAlreadyInGroup {
                Text("已添加")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary.opacity(0.3))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture {
            if !isAlreadyInGroup {
                onTap()
            }
        }
    }
}
