#!/bin/bash
# 增量编译 → 替换 /Applications 里的可执行文件 → 重签名 → 重启
set -e
cd "$(dirname "$0")"
swift build -c release
APP=/Applications/DockGroups.app
cp .build/release/DockGroups "$APP/Contents/MacOS/DockGroups"
# 用固定证书签名：签名身份不变，系统授过的权限（自动化等）重装后不会失效。
# 证书名写在 .signing-identity 里（不进仓库）；没有这个文件就用临时签名
codesign -f -s "$(cat .signing-identity 2>/dev/null || echo -)" "$APP"
# SIGKILL：故意跳过"退出时归还系统程序坞"，否则每次重装系统程序坞都要重启两次
pkill -9 -x DockGroups || true
while pgrep -x DockGroups >/dev/null; do sleep 0.1; done
open "$APP"
