#!/bin/bash
# 右键菜单：鼠标悬停要有高亮、悬停"选项"要弹出子菜单。用法: menu.sh <图标的屏幕 x> <"选项"距菜单顶部的像素>
# 注意：只在菜单确实开着时才按 Esc —— 否则 Esc 会落到前台应用上
T="${TMPDIR:-/tmp}/dockgroups-tools"; "$T/warp" > "$T/orig.txt"; f() { lsappinfo info -only name "$(lsappinfo front)" | head -1 | cut -d: -f1; }
menus() { "$T/wins" | awk '$1==101' | wc -l | tr -d ' '; }
closemenus() { for i in 1 2 3; do [ "$(menus)" = 0 ] && break; "$T/rc" esc; sleep 0.4; done; }
echo "front: $(f)"; "$T/mv" 960 1079; sleep 1.5; "$T/mv" $1 1040; sleep 0.8; "$T/rc" $1 1040; sleep 1.2
read -r _ MX MY MW MH < <("$T/wins" | awk '$1==101'); MX=${MX%.*}; MY=${MY%.*}; MW=${MW%.*}; MH=${MH%.*}; echo "menu rect: $MX $MY $MW $MH"
[ -z "$MX" ] && { echo "no menu"; exit 1; }
"$T/mv" $((MX+40)) $((MY+MH-18)); sleep 0.7; screencapture -x -R $((MX-20)),$((MY-20)),$((MW+280)),$((MH+60)) "$T/menu-hover1.png"
"$T/mv" $((MX+40)) $((MY+$2)); sleep 1.0; screencapture -x -R $((MX-20)),$((MY-20)),$((MW+280)),$((MH+60)) "$T/menu-hover2.png"; echo "menus on screen (incl. submenu): $(menus)"
closemenus; echo "after esc: menus=$(menus) front=$(f)"
python3 -c "
from PIL import Image
a=Image.open('$T/menu-hover1.png'); b=Image.open('$T/menu-hover2.png'); m=Image.new('RGB',(a.width+b.width+6,max(a.height,b.height)),'red'); m.paste(a,(0,0)); m.paste(b,(a.width+6,0)); m.save('$T/menu-hover.png')"
O=$(cat "$T/orig.txt"); "$T/mv" ${O% *} ${O#* }
