#!/bin/bash
# 拖动排序（拖过去再拖回来）、分组面板（打开/悬停/关闭）。会改动图标顺序再还原；结束后核对顺序是否和开始一致
T="${TMPDIR:-/tmp}/dockgroups-tools"; "$T/warp" > "$T/orig.txt"; f() { lsappinfo info -only name "$(lsappinfo front)" | head -1 | cut -d: -f1; }
ord() { defaults read com.example.DockGroups customDockOrder | grep -o 'app:[^"]*' | sed 's|.*/||; s|\.app||' | tr '\n' ','; }
B="${TMPDIR:-/tmp}/dg-backup-basics"; mkdir -p "$B"; defaults export com.example.DockGroups "$B/prefs.plist"
O0=$(ord); echo "order before: $O0"
"$T/mv" 960 1079; sleep 1.5
# icon centres at rest (dock 1124 wide at x=398): WeChat≈1064, TaskConsole≈1138
"$T/drag" 1064 1040 1100 1040 100 1150 1040 500; sleep 1.2; O1=$(ord); echo "after drag →:  $O1"
"$T/mv" 960 1079; sleep 1.2; "$T/drag" 1138 1040 1100 1040 100 1050 1040 500; sleep 1.2; O2=$(ord); echo "after drag ←:  $O2"
[ "$O1" != "$O0" ] && echo "  drag reorders: yes" || echo "  drag reorders: NO"
# group popup
"$T/mv" 960 1079; sleep 1.3; "$T/click" 770 1040; sleep 1.2
read -r _ PX PY PW PH < <("$T/wins" | awk '$1==3'); echo "popup: $PX $PY $PW $PH  front=$(f)"
if [ -n "$PX" ]; then PX=${PX%.*}; PY=${PY%.*}
  screencapture -x -R $PX,$PY,${PW%.*},${PH%.*} "$T/pop-rest.png"
  "$T/mv" $((PX+18+46+92)) $((PY+40+34)); sleep 0.8; screencapture -x -R $PX,$PY,${PW%.*},${PH%.*} "$T/pop-hover.png"
  "$T/mv" 960 1079; sleep 0.3; "$T/click" 770 1040; sleep 1.2; echo "popup closed: $("$T/wins" | awk '$1==3' | wc -l | tr -d ' ') left, front=$(f)"
  python3 -c "
from PIL import Image
a=Image.open('$T/pop-rest.png'); b=Image.open('$T/pop-hover.png'); m=Image.new('RGB',(a.width*2+6,a.height),'red'); m.paste(a,(0,0)); m.paste(b,(a.width+6,0)); m.save('$T/pop-both.png')"
fi
# restore exact order if the two drags did not cancel out
if [ "$(ord)" != "$O0" ]; then pkill -9 -x DockGroups; while pgrep -x DockGroups >/dev/null; do sleep 0.1; done; defaults import com.example.DockGroups "$B/prefs.plist"; open -g /Applications/DockGroups.app; sleep 4; echo "order restored from backup"; fi
echo "order after:  $(ord)"; O=$(cat "$T/orig.txt"); "$T/mv" ${O% *} ${O#* }
