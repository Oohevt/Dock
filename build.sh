#!/bin/bash

# DockGroups 构建脚本
# 用于创建完整的 macOS 应用包

set -e

echo "🚀 开始构建 DockGroups..."

# 清理旧的构建
echo "🧹 清理旧构建..."
rm -rf DockGroups.app
rm -rf .build

# 构建 Release 版本
echo "🔨 编译项目..."
swift build -c release

# 创建应用包结构
echo "📦 创建应用包..."
mkdir -p DockGroups.app/Contents/MacOS
mkdir -p DockGroups.app/Contents/Resources

# 复制可执行文件
echo "📋 复制可执行文件..."
cp .build/release/DockGroups DockGroups.app/Contents/MacOS/

# Info.plist 在仓库根目录，build.sh 和 install.sh 共用
cp Info.plist DockGroups.app/Contents/Info.plist

# 设置可执行权限
chmod +x DockGroups.app/Contents/MacOS/DockGroups
swiftc -O LauncherStub/main.swift -o DockGroups.app/Contents/Resources/launcher-stub

echo "✅ 构建完成！"
echo ""
echo "📍 应用位置: $(pwd)/DockGroups.app"
echo ""
echo "运行方式："
echo "  方法 1: open DockGroups.app"
echo "  方法 2: 拖到 /Applications 文件夹后启动"
echo ""
echo "💡 提示："
echo "  - 首次运行可能需要右键 → 打开"
echo "  - 查看 README.md 了解更多使用说明"
