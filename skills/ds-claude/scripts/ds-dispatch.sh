#!/usr/bin/env bash
# 子代理改派入口：照 policy.conf 的 order.<難度> 決定 O 派法，統一走 dcq。
# 用法：ds-dispatch.sh <cwd> <easy|mid|hard> [--ask "問題"]
#   實作：需先寫好 task/SPEC.md、scope.txt、verify.sh → dcq contract
#   唯讀：--ask → dcq ask
set -u
here="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
cwd="${1:-}"; tier="${2:-mid}"; shift 2 2>/dev/null || true
[ -d "$cwd" ] || { echo "用法：ds-dispatch.sh <cwd> <easy|mid|hard> [--ask 問題]" >&2; exit 2; }
ord="$("$here/ds-policy.sh" order "$tier")"
[ "$ord" = off ] && { echo "ds-claude: order.$tier=off，這個難度不外派，留主 session" >&2; exit 3; }
envpart="$("$here/ds-policy.sh" env "$tier")"
dcq="${DCQ_BIN:-$HOME/dev/orchestrator/bin/dcq}"
[ -x "$dcq" ] || dcq="$(command -v dcq 2>/dev/null || echo '')"
[ -n "$dcq" ] || { echo "ds-claude: 找不到 dcq" >&2; exit 2; }
if [ "${1:-}" = "--ask" ]; then
  [ -n "${2:-}" ] || { echo "--ask 後面要接問題" >&2; exit 2; }
  env $envpart "$dcq" ask "$cwd" "$2" "$tier"
else
  env $envpart "$dcq" contract "$cwd" "$tier"
fi
