# DockGroups 技术说明

本文档详细说明 DockGroups 的技术实现、设计决策和已知限制。

## 架构概览

### 组件层次

```
DockGroupsApp (应用入口)
    ├── AppDelegate
    │   ├── MenuBarManager (菜单栏)
    │   └── GroupManager (数据管理)
    │
    ├── Windows (窗口)
    │   ├── GroupPopupWindow (分组弹出面板)
    │   ├── ManageGroupsWindow (管理界面)
    │   ├── AddAppsWindow (添加应用)
    │   └── DragDropOverlayWindow (拖拽覆盖层)
    │
    └── Models (数据模型)
        ├── AppGroup (分组)
        └── AppInfo (应用信息)
```

### 数据流

1. 用户操作 → MenuBarManager 或窗口界面
2. 调用 GroupManager 修改数据
3. GroupManager 更新数据并保存到 JSON
4. 更新 UI（通过 @ObservedObject）
5. 生成/更新 Dock 启动器

## 核心功能实现

### 1. 应用信息获取 (AppInfo)

```swift
// 从 .app 包获取信息
static func from(url: URL) -> AppInfo?
```

**实现方式**:
- 使用 `Bundle` 读取应用元数据
- 从 Info.plist 获取图标文件名
- 使用 `NSWorkspace.shared.icon(forFile:)` 作为后备
- 图标数据编码为 TIFF 后存储

**限制**:
- 某些系统应用可能无法读取图标
- 大量应用会占用较多内存（图标缓存）

### 2. 分组图标生成 (AppGroup.generateIcon)

```swift
func generateIcon(size: CGSize) -> NSImage?
```

**实现方式**:
- 创建 512x512 画布
- 绘制圆角矩形背景 + 渐变
- 2x2 网格显示最多 4 个应用图标
- 如果超过 4 个，右下角显示 "+N" 徽章

**特性**:
- 实时生成，不缓存图片文件
- 每次分组更新时重新生成
- 导出为 PNG 用于启动器

**可改进**:
- 添加图标缓存避免重复生成
- 支持自定义背景颜色/渐变
- 更精美的设计（阴影、高光等）

### 3. Dock 启动器 (createDockLauncher)

**问题**: macOS 不允许应用直接修改 Dock

**解决方案**: 创建独立的启动器 .app 文件

**启动器结构**:
```
{GroupName}.app/
├── Contents/
    ├── Info.plist (包含 DockGroupID 和 URL Scheme)
    ├── MacOS/
    │   └── launcher (Shell 脚本)
    └── Resources/
        └── AppIcon.icns (分组图标)
```

**启动器脚本**:
```bash
#!/bin/bash
GROUP_ID="uuid"
open "dockgroups://group/$GROUP_ID"
```

**工作流程**:
1. 用户点击 Dock 中的启动器
2. macOS 执行 launcher 脚本
3. 脚本触发 `dockgroups://` URL
4. DockGroups 应用接收 URL 事件
5. 解析 UUID 并打开对应分组面板

**限制**:
- 需要用户手动拖到 Dock
- 启动器图标可能显示为通用图标（需要 .icns 格式）
- 不能响应右键菜单（系统限制）

**已知问题**:
- PNG 图标可能不被识别，应该使用 .icns
- 可以用 `iconutil` 转换：
  ```bash
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  ```

### 4. URL Scheme 处理

**注册**:
- Info.plist 中声明 `dockgroups://` scheme
- 系统自动关联到应用

**处理**:
```swift
NSAppleEventManager.shared().setEventHandler(
    self,
    andSelector: #selector(handleURLEvent(_:replyEvent:)),
    forEventClass: AEEventClass(kInternetEventClass),
    andEventID: AEEventID(kAEGetURL)
)
```

**URL 格式**:
```
dockgroups://group/{group-uuid}
```

### 5. 分组弹出面板 (GroupPopupWindow)

**窗口特性**:
- `styleMask: .borderless` - 无边框
- `level: .floating` - 浮动在其他窗口之上
- `backgroundColor: .clear` - 透明背景
- `collectionBehavior` - 全屏辅助窗口

**定位算法**:
```swift
// 获取 Dock 高度
let dockHeight = screen.frame.height - screen.visibleFrame.maxY

// 定位在 Dock 上方
let y = screen.frame.minY + dockHeight + 20
```

**毛玻璃效果**:
```swift
VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
```

**关闭机制**:
- 监听全局鼠标事件（点击外部）
- 监听 Esc 键
- 使用 `NSEvent.addGlobalMonitorForEvents`

**限制**:
- 多显示器可能定位不准确
- Dock 隐藏时需要特殊处理
- 全屏应用下可能不显示

### 6. 数据持久化 (GroupManager)

**存储位置**:
```
~/Library/Application Support/DockGroups/groups.json
```

**格式**:
```json
[
  {
    "id": "uuid",
    "name": "常用",
    "apps": [
      {
        "id": "uuid",
        "name": "Safari",
        "bundleIdentifier": "com.apple.Safari",
        "path": "/Applications/Safari.app",
        "iconData": "base64..."
      }
    ],
    "order": 0
  }
]
```

**操作**:
- 使用 `Codable` 自动序列化
- 每次修改后自动保存
- 启动时加载

**改进空间**:
- 添加备份机制
- 版本迁移支持
- 错误恢复

### 7. 拖拽放置区 (DragDropOverlay)

**设计**: 用户拖拽应用时显示半透明覆盖层

**实现状态**: ⚠️ 部分实现

**挑战**:
1. **全局拖拽检测**
   - 需要辅助功能权限
   - `NSEvent.addGlobalMonitorForEvents` 有限制
   - 无法直接获取拖拽的文件类型

2. **拖拽源判断**
   - 难以判断是否在拖拽 .app 文件
   - 可能需要使用私有 API

3. **实现方案**:
   ```swift
   // 监听拖拽开始
   NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged)
   
   // 问题：无法访问 NSPasteboard
   // 解决：延迟显示 + 检查拖拽类型
   ```

**当前状态**:
- 框架代码已实现
- DragDropOverlayWindow 可以显示
- 但拖拽检测不可靠
- 建议通过管理窗口添加应用

**可能的改进**:
- 使用 Accessibility API
- 监听 Finder 窗口事件
- 或者完全移除此功能

## 权限需求

### Apple Events (必需)

**用途**: 启动应用

**请求时机**: 首次调用 `NSWorkspace.shared.openApplication`

**Info.plist**:
```xml
<key>NSAppleEventsUsageDescription</key>
<string>DockGroups 需要 Apple Events 权限来启动应用。</string>
```

### 辅助功能 (可选)

**用途**: 全局拖拽检测（DragDropOverlay）

**请求方式**: 需要用户手动在系统设置中添加

**检测代码**:
```swift
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
```

**说明**: 当前实现不依赖此权限

## 已知限制与约束

### macOS 系统限制

1. **无法编程控制 Dock**
   - Dock 是系统组件，第三方应用无法修改
   - 只能创建启动器让用户手动拖入

2. **启动器图标格式**
   - 系统偏好 .icns 格式
   - PNG 可能显示为通用图标
   - 需要完整的 iconset 结构

3. **沙盒限制**
   - 如果启用沙盒，需要额外权限
   - 访问 /Applications 需要 `com.apple.security.files.user-selected.read-only`

4. **全屏应用**
   - 浮动窗口可能不显示
   - 需要特殊的 `collectionBehavior` 设置

### 实现限制

1. **图标质量**
   - 代码生成的图标不如原生设计
   - 缩小后可能模糊
   - 建议使用矢量绘制工具

2. **性能**
   - 加载所有应用图标可能较慢
   - 大量分组会占用内存
   - 可以通过延迟加载优化

3. **多显示器**
   - 窗口定位基于主显示器
   - 多屏幕下可能位置不对
   - 需要检测鼠标所在屏幕

4. **Dock 位置**
   - 假设 Dock 在底部
   - 侧边 Dock 需要特殊处理

## 改进建议

### 短期改进

1. **图标转换为 .icns**
   ```swift
   // 使用 NSImage 创建 .icns
   // 或调用 iconutil 工具
   ```

2. **添加图标缓存**
   ```swift
   private var iconCache: [UUID: NSImage] = [:]
   ```

3. **优化应用扫描**
   ```swift
   // 后台线程扫描
   DispatchQueue.global(qos: .userInitiated).async { }
   ```

4. **多显示器支持**
   ```swift
   // 检测鼠标位置
   let mouseLocation = NSEvent.mouseLocation
   let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
   ```

### 长期改进

1. **iCloud 同步**
   - 使用 CloudKit 同步分组配置
   - 跨设备共享设置

2. **主题自定义**
   - 自定义分组图标背景
   - 多种图标风格

3. **智能分组**
   - 根据应用类别自动分组
   - 最近使用的应用

4. **快捷键支持**
   - 全局快捷键打开分组
   - 键盘导航

5. **统计功能**
   - 应用使用频率
   - 分组使用统计

## 调试技巧

### 查看日志

```bash
# 控制台查看日志
log stream --predicate 'processImagePath contains "DockGroups"' --level debug
```

### 手动测试 URL Scheme

```bash
open "dockgroups://group/YOUR-UUID-HERE"
```

### 检查数据文件

```bash
cat ~/Library/Application\ Support/DockGroups/groups.json | python -m json.tool
```

### 重置数据

```bash
rm -rf ~/Library/Application\ Support/DockGroups/
```

### Xcode 调试

1. 打开项目：`swift package generate-xcodeproj`
2. 设置断点
3. 运行并查看变量

## 代码风格

### Swift 约定

- 使用 4 空格缩进
- 类型名称使用 PascalCase
- 函数和变量使用 camelCase
- 私有成员使用 `private` 前缀

### 注释

```swift
// MARK: - 主要功能区块

/// 文档注释用于公开 API
/// - Parameter name: 参数说明
/// - Returns: 返回值说明
func publicFunction(name: String) -> Bool {
    // 内联注释解释复杂逻辑
}
```

## 测试建议

### 手动测试清单

- [ ] 创建分组
- [ ] 添加多个应用到分组
- [ ] 点击分组打开面板
- [ ] 在面板中启动应用
- [ ] 删除应用
- [ ] 重命名分组
- [ ] 删除分组
- [ ] 重启应用，数据保持
- [ ] 将启动器拖到 Dock
- [ ] 点击 Dock 中的启动器
- [ ] 多显示器测试
- [ ] Dock 在侧边测试

### 边界测试

- 空分组
- 单个应用的分组
- 超过 100 个应用的分组
- 分组名称非常长
- 应用路径无效
- 应用已被删除

## 性能优化

### 内存

- 图标数据可以延迟加载
- 使用弱引用避免循环引用
- 及时释放不用的窗口

### CPU

- 图标生成在后台线程
- 避免频繁的文件读写
- 批量更新 UI

### 启动时间

- 延迟加载非关键功能
- 异步初始化
- 缓存常用数据

## 总结

DockGroups 是一个功能完整的 macOS 应用分组工具，实现了大部分核心功能。主要限制来自 macOS 系统本身的约束，而不是实现问题。

**优点**:
- ✅ 纯 Swift/SwiftUI 实现
- ✅ 不依赖私有 API
- ✅ 数据完全本地化
- ✅ 用户友好的界面

**缺点**:
- ⚠️ 不能完全集成到 Dock
- ⚠️ 启动器需要手动拖入
- ⚠️ 拖拽功能不够完善

**适用场景**:
- 个人应用组织工具
- 学习 macOS 应用开发
- 作为更复杂工具的原型

---

**文档版本**: 1.0  
**最后更新**: 2024-10-12
