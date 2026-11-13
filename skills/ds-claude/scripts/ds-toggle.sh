#!/usr/bin/env bash
# /ds-claude on|off|status：本機「預設派給 ds-claude」的開關。
# off：建旗標 ~/.claude/ds-claude.off，產一份把 ds-claude 列改成「Claude 自己動手」的路由表副本，
#      讓 ~/.genie/route_ext.json 的 table 指向副本（原 routes.md 不動，install.sh 照常覆蓋它）。
# on ：刪旗標，table 指回 ~/.claude/routes.md，刪副本。
# refresh：旗標在就重產副本（install.sh 部署新 routes.md 後呼叫，免得副本過期）。
set -euo pipefail
C="$HOME/.claude"
FLAG="$C/ds-claude.off"
SRC="$C/routes.md"
OFFCOPY="$C/routes.ds-off.md"
EXT="${GENIE_ROUTE_EXT:-$HOME/.genie/route_ext.json}"

set_table() {  # $1 = 新的 table 路徑；route_ext.json 不存在就略過（Genie 沒裝）
  [ -f "$EXT" ] || { echo "WARN: 找不到 ${EXT}，Genie 路由注入不受影響"; return 0; }
  python3 - "$EXT" "$1" <<'PY'
import json, sys
p, t = sys.argv[1], sys.argv[2]
d = json.load(open(p, encoding="utf-8"))
d["table"] = t
open(p, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
}

build_copy() {  # 動作欄含 ds-claude 的列 → 動作改寫；情境與關鍵字欄保留，照樣命中、照樣告知
  [ -f "$SRC" ] || { echo "FAIL: 找不到 $SRC"; exit 1; }
  python3 - "$SRC" "$OFFCOPY" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
NEW = "**ds-claude 已關**（`/ds-claude on` 重開）：Claude 自己動手，不派 DeepSeek；使用者這則明確點名 ds-claude 才派"
out = []
for line in open(src, encoding="utf-8").read().split("\n"):
    cells = line.split(" | ")
    if line.startswith("| ") and len(cells) >= 3 and "ds-claude" in cells[1]:
        cells[1] = NEW
        line = " | ".join(cells)
    out.append(line)
open(dst, "w", encoding="utf-8").write("\n".join(out))
PY
}

case "${1:-status}" in
  off)
    : > "$FLAG"; if [ -f "$SRC" ]; then build_copy; set_table "$OFFCOPY"; fi
    echo "ds-claude: OFF（實作由 Claude 自己做；/ds-claude on 重開）" ;;
  on)
    rm -f "$FLAG" "$OFFCOPY"; set_table "~/.claude/routes.md"
    echo "ds-claude: ON（實作預設派 DeepSeek）" ;;
  refresh)
    if [ -f "$FLAG" ] && [ -f "$SRC" ]; then build_copy; set_table "$OFFCOPY"; echo "ds-claude: OFF（路由副本已重產）"; else echo "ds-claude: ON（無需重產）"; fi ;;
  status)
    if [ -f "$FLAG" ]; then echo "ds-claude: OFF"; else echo "ds-claude: ON"; fi ;;
  *) echo "用法: ds-toggle.sh on|off|status|refresh" >&2; exit 64 ;;
esac
