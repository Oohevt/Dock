#!/bin/bash

# 快速开发脚本 - 编译并运行

set -e

echo "🔧 开发模式：编译并运行 DockGroups"
echo ""

# 编译 Debug 版本（更快）
echo "⚙️  编译中..."
swift build

echo ""
echo "🚀 启动应用..."
echo ""

# 运行
.build/debug/DockGroups
