#!/bin/bash
# 系统升级 / 大改动之后的回归检查。会：移动鼠标、短暂唤出程序坞、右键点一下（结束后把鼠标放回原处）。
# 用法：./tools/check.sh      （DockGroups 需要已经装好并在运行；检查期间请别碰鼠标）
cd "$(dirname "$0")/.." || exit 2   # 仓库根目录
T="${TMPDIR:-/tmp}/dockgroups-tools"; mkdir -p "$T"
LOG="$HOME/Library/Logs/DockGroups.log"
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
chk()  { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

echo "编译测试小工具…"
for f in warp mv rc wins sweep drag; do
  [ "$T/$f" -nt "tools/src/$f.swift" ] 2>/dev/null || swiftc -O "tools/src/$f.swift" -o "$T/$f" 2>&1 | grep error
  [ -x "$T/$f" ] || { echo "❌ 测试小工具 $f 编译失败，无法继续（否则检查会假通过）"; exit 2; }
done

echo "1) 进程"
P=$(pgrep -x DockGroups); [ -n "$P" ]; chk $? "DockGroups 在运行"
[ -n "$P" ] || { echo "没有在运行，先 ./install.sh"; exit 1; }

echo "2) 系统私有接口自检（来自应用自己的日志）"
MARK=$(wc -l < "$LOG")
# 用 URL 触发会让 DockGroups 变成最前面的应用（之后鼠标移动会多约 4% CPU），测完把焦点还给原来的应用
FRONT=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
open "dockgroups://selfcheck"; sleep 1.5
[ -n "$FRONT" ] && [ "$FRONT" != "DockGroups" ] && osascript -e "tell application \"$FRONT\" to activate" 2>/dev/null; sleep 1
tail -n +$((MARK+1)) "$LOG" | grep "selfcheck:" | while read -r l; do echo "     ${l#* +0000 }"; done
tail -n +$((MARK+1)) "$LOG" | grep -q "selfcheck: done, 0 failed"; chk $? "自检全部通过（accessibility 未授权会算失败）"

echo "3) 性能"
O=$("$T/warp"); read -r W H < <("$T/warp" size); EDGE=$((H-1))
"$T/mv" $((W/2)) $((H/2)); sleep 2
C=$(top -l 2 -s 3 -pid "$P" -stats cpu | tail -1 | tr -d ' '); awk -v c="$C" 'BEGIN{exit !(c<3)}'; chk $? "空闲 CPU ${C}%（要求 < 3）"
"$T/sweep" $((H/2)) 4 200 $((W-200)) & S1=$!; sleep 1
C=$(top -l 2 -s 2 -pid "$P" -stats cpu | tail -1 | tr -d ' '); wait $S1; awk -v c="$C" 'BEGIN{exit !(c<3)}'; chk $? "鼠标在屏幕上移动、没碰程序坞时 CPU ${C}%（要求 < 3）"

echo "4) 程序坞显示与右键菜单"
"$T/mv" $((W/2)) $EDGE; sleep 1.5
"$T/wins" | awk '$1==21' | grep -q .; chk $? "鼠标推到底边后程序坞出现"
read -r _ X Y WW HH < <("$T/wins" | awk '$1==21'); CY=$((${Y%.*}+${HH%.*}-60))
"$T/mv" $((W/2)) $CY; sleep 0.8
"$T/sweep" $CY 4 $((W/2-250)) $((W/2+250)) & S2=$!; sleep 1
C=$(top -l 2 -s 2 -pid "$P" -stats cpu | tail -1 | tr -d ' '); wait $S2; awk -v c="$C" 'BEGIN{exit !(c<20)}'; chk $? "程序坞上悬停放大时 CPU ${C}%（要求 < 20）"
GOT=0
for dx in 0 -120 120 -240 240; do
  "$T/mv" $((W/2+dx)) $CY; sleep 0.6; "$T/rc" $((W/2+dx)) $CY; sleep 1.0
  if "$T/wins" | awk '$1==101' | grep -q .; then GOT=1; "$T/rc" esc; sleep 0.5; break; fi
done
[ $GOT = 1 ]; chk $? "右键图标能弹出菜单"
"$T/wins" | awk '$1==101' | grep -q .; [ $? -ne 0 ]; chk $? "Esc 后菜单已关闭"

echo "5) 系统程序坞"
D=$(defaults read com.apple.dock autohide-delay 2>/dev/null); [ "$D" = 1000 ]; chk $? "系统程序坞已压下去（autohide-delay=$D）"

"$T/mv" ${O% *} ${O#* } 2>/dev/null; "$T/warp" ${O% *} ${O#* }
echo; echo "通过 $PASS，失败 $FAIL"; [ $FAIL = 0 ]
