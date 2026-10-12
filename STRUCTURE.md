# DockGroups 项目结构

```
DockGroups/
├── Package.swift                 # Swift Package Manager 配置
├── README.md                     # 用户文档（中文）
├── TECHNICAL.md                  # 技术文档
├── LICENSE                       # MIT 许可证
├── .gitignore                    # Git 忽略配置
│
├── build.sh                      # Release 构建脚本
├── dev.sh                        # 开发调试脚本
│
└── Sources/                      # 源代码目录
    ├── DockGroupsApp.swift       # 应用入口和生命周期
    ├── Models.swift              # 数据模型 (AppInfo, AppGroup)
    ├── GroupManager.swift        # 分组管理和持久化
    ├── MenuBarManager.swift      # 菜单栏集成和 URL Scheme
    ├── GroupPopupWindow.swift    # 分组弹出面板（毛玻璃效果）
    ├── ManageGroupsWindow.swift  # 分组管理主界面
    ├── AddAppsWindow.swift       # 添加应用界面
    └── DragDropOverlay.swift     # 拖拽放置区（可选功能）
```

## 构建产物

构建后会生成：

```
.build/                           # SPM 构建缓存
├── debug/                        # Debug 版本
│   └── DockGroups
└── release/                      # Release 版本
    └── DockGroups

DockGroups.app/                   # 应用包（build.sh 创建）
├── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── DockGroups
    └── Resources/
```

## 运行时文件

应用运行时会创建：

```
~/Library/Application Support/DockGroups/
├── groups.json                   # 分组配置
└── Launchers/                    # Dock 启动器
    ├── 常用.app/
    ├── 开发.app/
    └── ...
```

## 组件说明

### 核心组件

1. **DockGroupsApp.swift**
   - @main 入口
   - AppDelegate 管理应用生命周期
   - 初始化菜单栏和分组管理器

2. **Models.swift**
   - `AppInfo`: 应用信息（名称、路径、图标）
   - `AppGroup`: 分组信息（名称、应用列表、顺序）
   - 图标生成逻辑

3. **GroupManager.swift**
   - 单例模式 (`shared`)
   - 分组 CRUD 操作
   - JSON 持久化
   - Dock 启动器生成

### UI 组件

4. **MenuBarManager.swift**
   - 菜单栏图标和菜单
   - URL Scheme 处理器
   - 分组快速访问

5. **GroupPopupWindow.swift**
   - 无边框浮动窗口
   - 毛玻璃效果（VisualEffectView）
   - 应用网格布局
   - 外部点击/Esc 关闭

6. **ManageGroupsWindow.swift**
   - 分组列表（侧边栏）
   - 分组详情（主区域）
   - 创建/编辑/删除操作

7. **AddAppsWindow.swift**
   - 所有已安装应用列表
   - 搜索过滤
   - 多选添加

8. **DragDropOverlay.swift**
   - 拖拽时的半透明覆盖层
   - 显示现有分组和"新建"区域
   - 处理应用拖放

### 辅助工具

9. **build.sh**
   - 编译 Release 版本
   - 创建 .app 包
   - 生成 Info.plist

10. **dev.sh**
    - 快速编译运行
    - Debug 模式

## 数据流

```
用户交互
    ↓
MenuBar / Window
    ↓
GroupManager (单一数据源)
    ↓
├─→ 更新内存中的 groups[]
├─→ 保存到 groups.json
├─→ 生成/更新启动器
└─→ 通知 UI 更新 (@Published)
    ↓
UI 重新渲染
```

## 关键技术

- **SwiftUI**: 现代 UI 框架
- **AppKit**: 窗口管理、系统集成
- **Codable**: JSON 序列化
- **NSWorkspace**: 应用信息和启动
- **NSVisualEffectView**: 毛玻璃效果
- **URL Scheme**: 启动器通信
- **ObservableObject**: 数据绑定

## 扩展点

如果要添加新功能，可以考虑：

1. **新窗口**: 参考现有窗口类创建
2. **新数据字段**: 更新 Models.swift 和 GroupManager
3. **新菜单项**: 修改 MenuBarManager
4. **新视图**: 在对应窗口的 SwiftUI 代码中添加

## 依赖关系

```
DockGroupsApp
    └── AppDelegate
        ├── MenuBarManager
        │   └── GroupManager (shared)
        └── GroupManager (shared)

各窗口
    └── GroupManager (shared)
        └── Models (AppInfo, AppGroup)
```

GroupManager 是单例，所有组件共享同一实例。

---

**说明**: 这是一个标准的 Swift Package Manager 项目，可以用 Xcode 打开或命令行构建。
