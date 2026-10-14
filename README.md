# DockGroups

自绘的 macOS 程序坞：液态玻璃条 + 应用分组。接管系统程序坞（把它的唤出延迟调到 1000 秒），退出或崩溃时自动还回去。

## 功能

- 液态玻璃程序坞条：放大、自动隐藏、拖动排序、名称提示、运行指示点、启动弹跳
- 分组：点开是同款玻璃面板，组内可拖动排序；分组图标显示组内未读数之和
- 角标（未读数）、废纸篓空/满图标、废纸篓右键"清倒"
- 最小化的窗口出现在废纸篓左边，点击还原（显示应用图标，名称提示是窗口标题；靠辅助功能接口轮询，约 1 秒延迟）
- 截图遮罩等全屏覆盖层会盖住它；调度中心里推到底边也能唤出（和系统程序坞一致）

## 构建与安装

需要 macOS 26 及以上（液态玻璃）；在 macOS 27 / Xcode 27 上开发。

```bash
./build.sh      # 首次：生成 DockGroups.app，拖进 /Applications
./install.sh    # 之后每次改完：增量编译 → 替换 → 签名 → 重启
```

`install.sh` 默认用临时签名。想让系统授权在重装后不失效，把钥匙串里的证书名写进 `.signing-identity`（不进仓库）：

```bash
security find-identity -v -p codesigning
echo "Apple Development: you@example.com (XXXXXXXXXX)" > .signing-identity
```

## 数据位置

- 分组：`~/Library/Application Support/DockGroups/groups.json`
- 设置：`defaults read com.example.DockGroups`
- 日志：`~/Library/Logs/DockGroups.log`（超过 512KB 启动时自动裁剪）

## 依赖系统行为的地方（系统大版本升级后优先检查）

| 功能 | 靠什么 | 失效时的表现 |
|---|---|---|
| 玻璃通透折射 | 私有方法 `hasKeyAppearance`（`DockPanel`、`GroupPopupWindow`） | 玻璃变回磨砂 |
| 角标 | 私有 LaunchServices 接口读 `StatusLabel`（`AppBadge`） | 角标不显示 |
| 最小化窗口 | 辅助功能接口（和右键窗口列表同一套授权）；窗口号用私有 `_AXUIElementGetWindow`，没有就退回 pid+标题 | 格子不出现，或窗口改标题后被当成另一个格子 |
| 废纸篓状态 / 打开 / 清倒 | 让访达代办（AppleScript，首次需授权"自动化"） | 图标一直为空、点击无反应 |
| 隐藏系统程序坞 | `autohide-delay 1000`（普通桌面）+ `autohide-time-modifier 1000`（全屏应用里推底边时它会无视延迟弹出，只能让滑出动画慢到看不见）+ `killall Dock` | 两个程序坞同时出现 |
| 悬停时的 CPU 占用 | 鼠标位置自己读、不收移动事件；私有 SkyLight 接口 `SLSSetBackgroundEventMask` 压住 AppKit 自动打开的后台鼠标移动事件（`BackgroundMouseMoved`） | 功能不受影响，只是悬停时 CPU 高一倍，且随鼠标回报率上涨 |

## 系统升级后怎么检查

1. 看日志里应用启动时写的自检结果（每一项对应上表里的一行）：
   ```bash
   grep selfcheck ~/Library/Logs/DockGroups.log | tail -10
   ```
2. 跑回归检查（会移动鼠标、短暂唤出程序坞、右键点一下，期间别碰鼠标；需要先 `./install.sh` 装好）：
   ```bash
   ./tools/check.sh
   ```
   测试用的小工具（模拟鼠标/键盘、列窗口、模拟从访达拖文件）在 `tools/src/`，脚本会自己编译。

## 已知局限

- 最小化窗口的格子显示应用图标而不是窗口缩略图：截窗口内容要"屏幕录制"权限，而且对已最小化的窗口截取不可靠。系统设置为"最小化时收入应用图标"时原生坞也不显示缩略图，这里照常显示。
- 最小化窗口不会显示 Electron / Chromium 做的软件（Claude、Cursor、Notion、Chrome、Typeless 等）：定时用辅助功能读它们的窗口，会让它们整个切到无障碍模式直到重启，变慢、显示也会变。右键菜单的窗口列表只在你右键那一下读一次，影响小，但同样会触发。
- 在右键菜单里用"重命名 / 移除分组"的对话框之后，本应用会一直是"最前面的应用"，直到你切到别的应用；这期间鼠标移动会多占约 4% 的一个核。打开分组面板那条路径会正确把焦点还给原来的应用。
- 多显示器（程序坞跟随鼠标到另一块屏幕的底边）只写了、没在真实的多屏环境下测过。

原生程序坞的尺寸参数见 [NATIVE_PARAMS.md](NATIVE_PARAMS.md)。
