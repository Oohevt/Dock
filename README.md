# DockGroups - macOS Dock 应用分组工具

DockGroups 是一款为 macOS Dock 添加应用分组功能的原生应用，类似于 iOS 的文件夹功能。使用 Swift 和 SwiftUI 开发。

## 功能特性

- ✨ **创建应用分组** - 将常用应用组织到命名分组中
- 🎯 **一键启动** - 点击分组图标弹出毛玻璃面板，快速启动应用
- 🎨 **智能图标** - 自动生成包含应用缩略图的复合图标
- 🔄 **拖拽管理** - 支持拖拽重排应用顺序
- 💾 **数据持久化** - 分组配置自动保存到本地
- 🚀 **Dock 集成** - 为每个分组创建启动器，可拖到 Dock 中

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Apple Silicon (M1/M2/M3) 或 Intel 处理器
- Xcode 15.0 或更高版本（用于构建）

## 构建与运行

### 方法一：使用 Xcode（推荐）

1. **生成 Xcode 项目**

```bash
swift package generate-xcodeproj
open DockGroups.xcodeproj
```

2. **配置签名**

在 Xcode 中：
- 选择项目 → Targets → DockGroups
- 进入 "Signing & Capabilities" 标签
- 选择你的开发团队
- 确保 Bundle Identifier 是唯一的（例如：`com.yourname.DockGroups`）

3. **构建运行**

- 选择目标设备：My Mac
- 点击运行按钮（⌘R）或选择 Product → Run

### 方法二：使用命令行

```bash
# 构建项目
swift build -c release

# 运行
.build/release/DockGroups
```

### 创建应用包

创建一个完整的 .app 包：

```bash
# 构建
swift build -c release

# 创建应用包结构
mkdir -p DockGroups.app/Contents/MacOS
mkdir -p DockGroups.app/Contents/Resources

# 复制可执行文件
cp .build/release/DockGroups DockGroups.app/Contents/MacOS/

# 创建 Info.plist
cat > DockGroups.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DockGroups</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.DockGroups</string>
    <key>CFBundleName</key>
    <string>DockGroups</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>DockGroups 需要 Apple Events 权限来打开应用。</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>DockGroups URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>dockgroups</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# 打开应用
open DockGroups.app
```

## 使用说明

### 首次启动

1. 启动应用后，菜单栏会出现 DockGroups 图标（网格图标）
2. 应用会自动创建示例分组（如果检测到对应应用）
3. 分组数据保存在：`~/Library/Application Support/DockGroups/groups.json`

### 管理分组

**通过菜单栏：**

1. 点击菜单栏的 DockGroups 图标
2. 查看所有分组列表
3. 点击分组名称打开应用面板
4. 选择"管理分组"打开管理窗口

**创建新分组：**

1. 打开管理窗口
2. 点击左上角的 + 按钮
3. 输入分组名称
4. 添加应用到分组

**添加应用：**

1. 在分组详情中点击"添加应用"
2. 浏览已安装应用列表
3. 选择要添加的应用
4. 点击"添加"按钮

### 集成到 Dock

每个分组会在以下位置创建启动器：

```
~/Library/Application Support/DockGroups/Launchers/
```

**将分组添加到 Dock：**

1. 打开管理窗口
2. 选择一个分组
3. 点击"启动器位置"按钮
4. 在 Finder 中打开启动器文件夹
5. 将对应的 .app 文件拖到 Dock 中

**使用 Dock 启动器：**

- 点击 Dock 中的分组图标
- 会弹出应用面板
- 点击应用图标即可启动

### 快捷操作

- **Esc** - 关闭应用面板
- **点击面板外** - 关闭应用面板
- **拖拽应用** - 在管理窗口中重排应用顺序
- **右键分组** - 重命名或删除分组
- **悬停应用** - 在面板中显示删除按钮

## 权限说明

DockGroups 可能需要以下权限：

### 辅助功能权限（可选）

用于高级拖拽功能（拖拽创建分组）：

1. 打开"系统设置" → "隐私与安全性" → "辅助功能"
2. 添加 DockGroups 到允许列表

**注意：** 基本功能无需此权限。

### Apple Events 权限

用于启动应用，首次使用时会自动请求。

## 数据位置

- **分组配置**: `~/Library/Application Support/DockGroups/groups.json`
- **启动器应用**: `~/Library/Application Support/DockGroups/Launchers/`
- **应用图标**: 缓存在分组配置中

## 功能说明与限制

### ✅ 已实现功能

- ✅ 创建、编辑、删除分组
- ✅ 添加、移除、重排应用
- ✅ 生成复合图标
- ✅ 弹出式应用面板（毛玻璃效果）
- ✅ 菜单栏管理
- ✅ 数据持久化
- ✅ 为每个分组创建 Dock 启动器
- ✅ URL Scheme 支持（`dockgroups://`）

### ⚠️ 已知限制

1. **Dock 图标不是真正的 Dock 整合**
   - 使用独立的启动器 .app 文件
   - 需要手动拖到 Dock
   - 不能通过代码自动添加到 Dock（macOS 限制）

2. **拖拽创建分组（DragDropOverlay）**
   - 框架代码已实现
   - 需要辅助功能权限
   - 全局拖拽检测可能不够可靠
   - 建议通过管理窗口创建分组

3. **图标生成**
   - 复合图标使用代码绘制
   - 不能完美复制 iOS 风格
   - 最多显示 4 个应用图标

### 💡 改进建议

如果需要更接近原生 Dock 的体验，可以考虑：

1. **使用私有 API**（不推荐，无法上架 App Store）
2. **创建 Dock 插件**（需要 SIP 关闭，不适合普通用户）
3. **使用 Automator 工作流**（替代启动器的另一种方案）

## 技术细节

### 架构组件

- **DockGroupsApp.swift** - 应用入口和生命周期
- **Models.swift** - 数据模型（AppInfo, AppGroup）
- **GroupManager.swift** - 分组管理和持久化
- **GroupPopupWindow.swift** - 应用面板弹出窗口
- **ManageGroupsWindow.swift** - 分组管理界面
- **AddAppsWindow.swift** - 添加应用界面
- **MenuBarManager.swift** - 菜单栏集成
- **DragDropOverlay.swift** - 拖拽放置区（可选功能）

### URL Scheme

应用注册了 `dockgroups://` URL Scheme：

```
dockgroups://group/{group-uuid}
```

启动器通过此 URL 触发对应分组的面板。

### 启动器工作原理

每个分组的启动器是一个小型 .app 包，包含：

1. **Info.plist** - 包含分组 ID 和 URL Scheme 配置
2. **可执行脚本** - 调用 `open dockgroups://group/{id}`
3. **应用图标** - 分组的复合图标

## 故障排除

### 应用无法启动

**问题**: 双击 DockGroups.app 无响应

**解决方法**:
- 检查是否有安全警告（右键→打开）
- 确保系统版本 ≥ macOS 14
- 查看控制台日志查找错误

### 启动器不工作

**问题**: 点击 Dock 中的启动器无反应

**解决方法**:
- 确保 DockGroups 主应用正在运行
- 重新创建启动器（删除分组后重新添加）
- 检查 URL Scheme 注册（系统设置中查看）

### 分组数据丢失

**问题**: 重启后分组消失

**解决方法**:
- 检查 `~/Library/Application Support/DockGroups/groups.json` 是否存在
- 确保应用有读写权限
- 查看控制台日志

### 应用图标不显示

**问题**: 分组或应用图标显示为灰色方块

**解决方法**:
- 某些应用的图标提取可能失败
- 尝试重新添加应用
- 检查应用路径是否有效

## 开发说明

### 添加新功能

项目使用标准的 Swift Package Manager 结构。要添加新功能：

1. 在 `Sources/` 下创建新的 Swift 文件
2. 遵循现有的架构模式
3. 更新 `GroupManager` 如果涉及数据模型变更
4. 测试新功能

### 调试技巧

```swift
// 在代码中添加调试输出
print("调试信息: \(variable)")

// 查看分组数据
let groupsPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("DockGroups/groups.json")
print("分组文件: \(groupsPath.path)")
```

### 构建变体

Debug 构建（更多日志）:
```bash
swift build -c debug
```

Release 构建（优化性能）:
```bash
swift build -c release
```

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

本项目仅供学习和个人使用。

## 致谢

灵感来源：
- DockPops
- BetterTouchTool
- iOS 文件夹功能

---

**作者**: Cursor AI Agent  
**版本**: 1.0.0  
**最后更新**: 2024-10-12
