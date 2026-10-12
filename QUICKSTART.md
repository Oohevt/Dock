# DockGroups 快速开始指南

本指南将帮助您在 5 分钟内构建和运行 DockGroups。

## 前提条件

确保您的 Mac 满足以下要求：

- ✅ macOS 14.0 (Sonoma) 或更高版本
- ✅ Xcode 15.0 或更高版本（包含命令行工具）
- ✅ Apple Silicon (M1/M2/M3) 或 Intel 处理器

### 检查 Xcode 命令行工具

```bash
# 检查是否已安装
xcode-select -p

# 如果未安装，运行此命令
xcode-select --install
```

## 方法 1：一键构建（推荐）

### 1. 克隆项目

```bash
git clone <repository-url>
cd DockGroups
```

### 2. 运行构建脚本

```bash
./build.sh
```

### 3. 启动应用

```bash
open DockGroups.app
```

**提示**: 首次运行时，右键点击 → 选择"打开"以绕过安全提示。

## 方法 2：使用 Xcode

### 1. 生成 Xcode 项目

```bash
swift package generate-xcodeproj
```

### 2. 打开项目

```bash
open DockGroups.xcodeproj
```

### 3. 配置签名

在 Xcode 中：
1. 选择左侧的项目文件
2. 选择 "DockGroups" target
3. 进入 "Signing & Capabilities" 标签
4. 选择您的开发团队
5. 如果需要，修改 Bundle Identifier（例如：`com.yourname.DockGroups`）

### 4. 构建并运行

按 `⌘R` 或点击运行按钮。

## 方法 3：快速开发模式

如果您只想快速测试，无需创建 .app 包：

```bash
./dev.sh
```

这会编译 Debug 版本并直接运行。

## 首次使用

### 1. 应用启动

启动后，您会在菜单栏看到 DockGroups 图标（网格图标 ▦）。

### 2. 创建第一个分组

1. 点击菜单栏图标
2. 选择"管理分组"
3. 点击左上角的 + 按钮
4. 输入分组名称，例如"常用"
5. 点击"创建"

### 3. 添加应用

1. 在分组详情页，点击"添加应用"
2. 浏览或搜索应用
3. 选择要添加的应用
4. 点击"添加"按钮

### 4. 查看分组

1. 点击菜单栏图标
2. 点击分组名称
3. 弹出的面板中显示所有应用
4. 点击应用图标即可启动

### 5. 添加到 Dock

1. 在管理窗口中选择一个分组
2. 点击"启动器位置"按钮
3. Finder 会打开启动器文件夹
4. 将对应的 .app 文件拖到 Dock 中

现在点击 Dock 中的图标就能打开分组面板了！

## 快捷键

- **Esc** - 关闭弹出面板
- **⌘Q** - 退出应用

## 数据位置

如果需要备份或查看数据：

```bash
# 配置文件
cat ~/Library/Application\ Support/DockGroups/groups.json

# 启动器
open ~/Library/Application\ Support/DockGroups/Launchers/
```

## 常见问题

### Q: 无法打开应用，提示"无法打开，因为无法验证开发者"

**A**: 右键点击应用 → 选择"打开" → 点击"打开"按钮。

### Q: 点击 Dock 中的启动器没反应

**A**: 确保 DockGroups 主应用正在运行（菜单栏有图标）。

### Q: 应用列表为空

**A**: 
1. 检查是否授予了必要权限
2. 尝试重新启动应用
3. 查看控制台日志查找错误

### Q: 分组图标不显示

**A**: 这是正常的。当前版本使用 PNG 图标，某些情况下 macOS 会显示通用图标。功能不受影响。

### Q: 想要删除所有数据重新开始

**A**: 
```bash
rm -rf ~/Library/Application\ Support/DockGroups/
```

## 性能提示

- **应用很多时**: 首次打开"添加应用"窗口可能需要几秒钟扫描所有应用
- **分组很多时**: 建议每个分组不超过 20 个应用
- **内存占用**: 约 50-100 MB，取决于分组数量

## 下一步

- 📖 阅读完整文档：[README.md](README.md)
- 🔧 了解技术细节：[TECHNICAL.md](TECHNICAL.md)
- 📁 查看项目结构：[STRUCTURE.md](STRUCTURE.md)

## 需要帮助？

- 检查 [README.md](README.md) 中的"故障排除"部分
- 查看控制台日志：
  ```bash
  log stream --predicate 'processImagePath contains "DockGroups"' --level debug
  ```
- 提交 Issue（如果项目在 GitHub 上）

---

**祝您使用愉快！** 🎉
