#!/usr/bin/env bash
# ds-claude 政策查寫。用法：
#   ds-policy.sh show              印整份政策
#   ds-policy.sh agent <名>        印 on|off（agent.<名> → agent.default → cc 預設 on、其他 off）
#   ds-policy.sh order <難度>      印 of|os|od|off（order.<難度> → order.default → of）
#   ds-policy.sh env <難度>        印對應 env 前綴（of=DCQ_ORDER=free；os=DCQ_ORDER=sub；od=DCQ_MODELS=flash）
#   ds-policy.sh set <key> <值>    改政策（agent.devin on／order.mid od …）
set -u
CFG="${DS_POLICY:-$HOME/.config/ds-claude/policy.conf}"
get() { # $1=key $2=fallback-key（可空）$3=最終預設
  v="$(awk -F= -v k="$1" '!/^[[:space:]]*#/ && $1==k{print $2}' "$CFG" 2>/dev/null | tail -1)"
  [ -n "$v" ] || { [ -n "${2:-}" ] && { v="$(awk -F= -v k="$2" '!/^[[:space:]]*#/ && $1==k{print $2}' "$CFG" 2>/dev/null | tail -1)"; }; }
  printf '%s' "${v:-$3}"
}
case "${1:-show}" in
  show) cat "$CFG" 2>/dev/null ;;
  agent)
    a="${2:-cc}"
    d=off; [ "$a" = cc ] && d=on
    get "agent.$a" agent.default "$d"; echo ;;
  order) get "order.${2:-}" order.default of; echo ;;
  env)
    case "$(get "order.${2:-}" order.default of)" in
      of) echo 'DCQ_ORDER=free' ;;
      os) echo 'DCQ_ORDER=sub' ;;
      od) echo 'DCQ_MODELS=opencode-go/deepseek-v4.1-flash' ;;
      oo) echo 'DCQ_ORDER=oo' ;;
      *)  echo 'DCQ_ORDER=free' ;;
    esac ;;
  set)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "用法：ds-policy.sh set <key> <值>" >&2; exit 2; }
    mkdir -p "$(dirname "$CFG")" || exit 1
    touch "$CFG" || exit 1
    if grep -q "^$2=" "$CFG"; then
      tmp="$(mktemp)"; awk -F= -v k="$2" -v v="$3" '$1==k{$0=k"="v}1' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
    else echo "$2=$3" >> "$CFG"; fi
    echo "$2=$3" ;;
  *) echo "未知子指令：$1" >&2; exit 2 ;;
esac
