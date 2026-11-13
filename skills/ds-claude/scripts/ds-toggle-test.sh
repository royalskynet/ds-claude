#!/usr/bin/env bash
# ds-toggle.sh 最小檢查：在假 HOME 裡跑 off → refresh → on，驗旗標、副本內容、route_ext table 切換。
set -euo pipefail
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S="$(cd "$(dirname "$0")" && pwd)/ds-toggle.sh"
mkdir -p "$T/.claude" "$T/.genie"
cat > "$T/.claude/routes.md" <<'MD'
| 情境 | 動作 | 關鍵字 |
|------|------|------|
| 其他 | **`other` skill** | other |
| 派工 | **`ds-claude` skill**：派 DeepSeek | 派工\|ds-claude |
MD
echo '{"hosts":["claude"],"table":"~/.claude/routes.md"}' > "$T/.genie/route_ext.json"
run() { HOME="$T" GENIE_ROUTE_EXT="$T/.genie/route_ext.json" bash "$S" "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
tbl() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["table"])' "$T/.genie/route_ext.json"; }

run status | grep -q ON || fail "初始應為 ON"
run off >/dev/null
[ -f "$T/.claude/ds-claude.off" ] || fail "off 沒建旗標"
[ "$(tbl)" = "$T/.claude/routes.ds-off.md" ] || fail "off 沒切 table：$(tbl)"
grep -q 'ds-claude 已關' "$T/.claude/routes.ds-off.md" || fail "副本沒改寫 ds-claude 列"
grep -q '派工\\|ds-claude |$' "$T/.claude/routes.ds-off.md" || fail "副本弄壞了關鍵字欄"
grep -q '`other` skill' "$T/.claude/routes.ds-off.md" || fail "副本動到不相干的列"
grep -q '派 DeepSeek' "$T/.claude/routes.md" && true || fail "原 routes.md 被改"
run status | grep -q OFF || fail "status 應為 OFF"
echo '| 新列 | **`ds-claude` skill** | x |' >> "$T/.claude/routes.md"
run refresh >/dev/null
[ "$(grep -c 'ds-claude 已關' "$T/.claude/routes.ds-off.md")" = 2 ] || fail "refresh 沒重產副本"
run on >/dev/null
[ ! -f "$T/.claude/ds-claude.off" ] || fail "on 沒刪旗標"
[ ! -f "$T/.claude/routes.ds-off.md" ] || fail "on 沒刪副本"
[ "$(tbl)" = "~/.claude/routes.md" ] || fail "on 沒切回 table：$(tbl)"
run bogus >/dev/null 2>&1 && fail "未知參數應失敗"
rm "$T/.claude/routes.md"
run off >/dev/null || fail "沒有 routes.md 時 off 應成功"
[ -f "$T/.claude/ds-claude.off" ] || fail "沒有 routes.md 時 off 沒建旗標"
run on >/dev/null
echo "PASS ds-toggle"
