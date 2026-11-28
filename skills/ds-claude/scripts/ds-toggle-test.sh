#!/usr/bin/env bash
# ds-toggle.sh 最小檢查：在假 HOME 驗 per-agent 預設、policy.conf 寫入、設定目錄自動建立、錯誤會向外傳。
set -euo pipefail
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S="$(cd "$(dirname "$0")" && pwd)/ds-toggle.sh"
run() { HOME="$T" bash "$S" "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
CFG="$T/.config/ds-claude/policy.conf"

run status | grep -q 'ds-claude: cc ON' || fail "初始應為 ON"
run off >/dev/null
[ -f "$CFG" ] || fail "off 沒建 policy.conf"
grep -qxF 'agent.cc=off' "$CFG" || fail "off 沒寫 agent.cc=off"
[ ! -e "$T/.claude/ds-claude.off" ] || fail "off 不應再建舊旗標"
run status | grep -q 'ds-claude: cc OFF' || fail "status 應為 OFF"
run on >/dev/null
grep -qxF 'agent.cc=on' "$CFG" || fail "on 沒寫 agent.cc=on"
run status | grep -q 'ds-claude: cc ON' || fail "on 後 status 應為 ON"

run off devin >/dev/null
grep -qxF 'agent.devin=off' "$CFG" || fail "off devin 沒寫 agent.devin=off"
run status devin | grep -q 'ds-claude: devin OFF' || fail "devin status 應為 OFF"
run status | grep -q 'ds-claude: cc ON' || fail "devin off 不應影響 cc"

run bogus >/dev/null 2>&1 && fail "未知參數應失敗"
rm -rf "$T/.config"
echo x > "$T/.config"
if run off >"$T/off.out" 2>&1; then fail "config 路徑不是目錄時 off 應失敗"; fi
rm "$T/.config"
run off >/dev/null
[ -f "$CFG" ] || fail "config 目錄不存在時 off 應自動建立"
grep -qxF 'agent.cc=off' "$CFG" || fail "重建後 off 沒寫 agent.cc=off"
echo "PASS ds-toggle"
