#!/usr/bin/env bash
# /ds-claude on|off|status [agent名]：per-agent 開關，寫 ~/.config/ds-claude/policy.conf 的 agent.<名>。
# 不給 agent 名時：Claude Code 裡用 cc。舊全域旗標 ~/.claude/ds-claude.off 仍被 hook 相容讀取，但不再由這裡產生。
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
pol="$here/ds-policy.sh"
agent="${2:-cc}"
case "${1:-status}" in
  off)
    "$pol" set "agent.$agent" off >/dev/null
    echo "ds-claude: $agent OFF（實作由主 session 自己做；/ds-claude on 重開）" ;;
  on)
    "$pol" set "agent.$agent" on >/dev/null
    echo "ds-claude: $agent ON（實作照 policy.conf 的 order.<難度> 派 O/dcq）" ;;
  status)
    cur="$("$pol" agent "$agent")"
    echo "ds-claude: $agent $(printf '%s' "$cur" | tr a-z A-Z)（policy.conf；show 看全表）" ;;
  *) echo "用法：ds-toggle.sh on|off|status [agent名]" >&2; exit 2 ;;
esac
