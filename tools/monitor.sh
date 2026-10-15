#!/bin/bash
# 被动监视：不碰鼠标键盘、不动任何软件。每 N 秒记一行，发现异常就标出来。
# 用法: tools/monitor.sh [间隔秒=10] [总时长秒=1200] [输出文件]
INT="${1:-10}"; DUR="${2:-1200}"; OUT="${3:-${TMPDIR:-/tmp}/dockgroups-monitor.log}"
T="${TMPDIR:-/tmp}/dockgroups-tools"
cat > "$T/dockwins.swift" <<'SW'
import CoreGraphics
import Foundation
// 屏幕上属于系统程序坞(Dock)的窗口数，和 DockGroups 的窗口数
var d = 0, g = 0
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []) {
  let o = (w[kCGWindowOwnerName as String] as? String) ?? ""
  let b = w[kCGWindowBounds as String] as! [String: CGFloat]
  if (o == "Dock" || o == "程序坞") && b["Height"]! > 20 { d += 1 }
  if o == "DockGroups" { g += 1 }
}
print(d, g)
SW
[ -x "$T/dockwins-count" ] || swiftc -O "$T/dockwins.swift" -o "$T/dockwins-count" 2>/dev/null
END=$(( $(date +%s) + DUR )); LASTDOCK=""; n=0
echo "# time | DockGroups pid cpu% rss(MB) threads fds | systemDock pid | sysDock-windows ours-windows | WindowServer cpu% | flags" > "$OUT"
while [ "$(date +%s)" -lt "$END" ]; do
  P=$(pgrep -x DockGroups | head -1); D=$(pgrep -x Dock | head -1); flags=""
  if [ -n "$P" ]; then
    read -r cpu rss <<<"$(ps -o %cpu=,rss= -p "$P")"; thr=$(ps -M -p "$P" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '); fds=$(lsof -p "$P" 2>/dev/null | wc -l | tr -d ' ')
    rssmb=$(( rss / 1024 ))
    [ "$rssmb" -gt 250 ] && flags="$flags MEM>250MB"; [ "$thr" -gt 60 ] && flags="$flags THREADS>60"; [ "$fds" -gt 400 ] && flags="$flags FDS>400"
  else cpu="-"; rssmb="-"; thr="-"; fds="-"; flags="$flags DOCKGROUPS-GONE"; fi
  [ -n "$LASTDOCK" ] && [ "$D" != "$LASTDOCK" ] && flags="$flags SYSTEMDOCK-RESTARTED"; LASTDOCK="$D"
  read -r sd og <<<"$("$T/dockwins-count" 2>/dev/null || echo '? ?')"
  [ "$sd" != "0" ] && [ "$sd" != "?" ] && flags="$flags SYSTEM-DOCK-VISIBLE($sd)"
  ws=$(ps -A -o %cpu=,comm= | awk '/WindowServer/{print $1; exit}')
  [ "$P" ] && [ "$(defaults read com.apple.dock autohide-delay 2>/dev/null)" != "1000" ] && flags="$flags SYSDOCK-DELAY-NOT-1000"
  echo "$(date +%H:%M:%S) | $P $cpu $rssmb $thr $fds | $D | $sd $og | $ws | $flags" >> "$OUT"
  sleep "$INT"
done
echo "# done" >> "$OUT"
