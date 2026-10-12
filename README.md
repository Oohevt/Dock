# DockGroups

自绘的 macOS 程序坞：液态玻璃条 + 应用分组。接管系统程序坞（把它的唤出延迟调到 1000 秒），退出或崩溃时自动还回去。

## 功能

- 液态玻璃程序坞条：放大、自动隐藏、拖动排序、名称提示、运行指示点、启动弹跳
- 分组：点开是同款玻璃面板，组内可拖动排序；分组图标显示组内未读数之和
- 角标（未读数）、废纸篓空/满图标、废纸篓右键"清倒"
- 调度中心 / 截图遮罩等全屏覆盖层出现时自动让位

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
| 废纸篓状态 / 打开 / 清倒 | 让访达代办（AppleScript，首次需授权"自动化"） | 图标一直为空、点击无反应 |
| 调度中心让位 | 识别系统程序坞进程的全屏窗口（`exposeActive`） | 调度中心里程序坞不隐藏 |
| 隐藏系统程序坞 | `defaults write com.apple.dock autohide-delay 1000` + `killall Dock` | 两个程序坞同时出现 |

原生程序坞的尺寸参数见 [NATIVE_PARAMS.md](NATIVE_PARAMS.md)。
