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

# 创建 Info.plist
echo "⚙️  生成 Info.plist..."
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
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>DockGroups 需要 Apple Events 权限来启动应用。</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>DockGroups URL Scheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>dockgroups</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

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
