#!/usr/bin/env bash
# Run one DeepSeek work order through opencode, then judge it by task/verify.sh.
# Usage: ds-run.sh <workdir> [--retry] [--pro] [--no-baseline] [--model provider/model]
# Exit:  0 PASS | 1 verify failed | 2 out of scope or task/ tampered | 3 setup | 4 worker error
set -uo pipefail

finish() { echo "$2"; exit "$1"; }
setup_fail() { finish 3 "FAIL setup: $1"; }

dir=""; retry=0; baseline=1; tier=flash; model="${DS_MODEL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --retry) retry=1 ;;
    --pro) tier=pro ;;
    --no-baseline) baseline=0 ;;
    --model) [ $# -ge 2 ] || setup_fail "--model needs a value"; model="$2"; shift ;;
    -*) setup_fail "unknown flag $1" ;;
    *) dir="$1" ;;
  esac
  shift
done

[ -n "$dir" ] && [ -d "$dir" ] || setup_fail "usage: ds-run.sh <workdir> [--retry] [--pro] [--model m]"
cd "$dir" || setup_fail "cannot enter $dir"
command -v opencode >/dev/null || setup_fail "opencode not found"
git rev-parse --verify -q HEAD >/dev/null || setup_fail "need a git repo with at least one commit"
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || setup_fail "workdir must be the repo root"
for f in SPEC.md scope.txt verify.sh; do [ -s "task/$f" ] || setup_fail "missing task/$f"; done

# task/ holds logs and the work order, so it stays out of every diff.
exclude="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude")"
grep -qxF 'task/' "$exclude" 2>/dev/null || echo 'task/' >> "$exclude"

if [ "$retry" = 1 ]; then
  [ -s task/base ] || setup_fail "--retry needs task/base from an earlier run"
else
  [ -z "$(git status --porcelain)" ] || setup_fail "working tree is dirty; commit or stash first"
  git rev-parse HEAD > task/base
fi
base="$(cat task/base)"

if [ -z "$model" ]; then
  model="$(opencode models 2>/dev/null </dev/null | grep -E "^opencode-go/deepseek.*$tier" | sort -V | tail -1)"
  [ -n "$model" ] || setup_fail "no opencode-go deepseek $tier model; check opencode auth list"
fi

# verify.sh runs from a copy taken now, so the worker cannot pass by editing it.
snap="$(mktemp -d)"; trap 'rm -rf "$snap"' EXIT
cp task/SPEC.md task/scope.txt task/verify.sh "$snap/"

# Files that verify.sh itself creates (__pycache__, build output) are not worker changes.
untracked() { git -c core.quotePath=false ls-files -o --exclude-standard; }
run_verify() {
  local before; before="$(untracked)"
  bash "$snap/verify.sh" > task/verify.log 2>&1
  local code=$?
  comm -13 <(printf '%s\n' "$before" | sort) <(untracked | sort) >> task/artifacts
  return "$code"
}

if [ "$retry" = 0 ]; then
  : > task/artifacts
  if [ "$baseline" = 1 ] && run_verify; then
    setup_fail "verify.sh already passes before any work; tighten it, or use --no-baseline for a refactor"
  fi
fi

prompt="Do the work described in task/SPEC.md. Only change paths allowed by task/scope.txt. Do not edit anything under task/. Do not commit. When done, list the files you changed."
[ "$retry" = 1 ] && prompt="$prompt The previous attempt failed acceptance: read task/verify.log and fix the cause. Your earlier changes are still in the working tree."

limit="${DS_TIMEOUT:-900}"
run_limited() {
  local t; t="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$t" ]; then "$t" "$limit" "$@"; else perl -e 'alarm shift; exec @ARGV' "$limit" "$@"; fi
}

# </dev/null is required: opencode run waits for stdin EOF and hangs on an open pipe.
run_limited opencode run --auto -m "$model" "$prompt" > task/exec.log 2>&1 </dev/null
worker=$?

log() { printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$(sed -n '1p' task/SPEC.md | cut -c1-60)" "$model" "$1" "$retry" >> task/dispatch-log.tsv; }

for f in SPEC.md scope.txt verify.sh; do
  cmp -s "$snap/$f" "task/$f" || { cp "$snap/$f" "task/$f"; log "scope"; finish 2 "FAIL scope: worker edited task/$f (restored)"; }
done

if [ "$worker" -ne 0 ]; then log "worker"; finish 4 "FAIL worker: opencode exit $worker, see task/exec.log"; fi

touch task/artifacts
changed="$( { git -c core.quotePath=false diff --name-only --no-renames "$base"; untracked; } | sort -u | grep -vxFf task/artifacts )"
outside=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  ok=0
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254
    case "$path" in $glob) ok=1; break ;; esac
  done < "$snap/scope.txt"
  [ "$ok" = 1 ] || outside="$outside $path"
done <<< "$changed"
if [ -n "$outside" ]; then log "scope"; finish 2 "FAIL scope: changed outside task/scope.txt:$outside"; fi

run_verify
verified=$?
count="$(printf '%s' "$changed" | grep -c . || true)"
if [ "$verified" -ne 0 ]; then log "verify"; finish 1 "FAIL verify: exit $verified, $count files changed, see task/verify.log"; fi
log "pass"
finish 0 "PASS: $count files changed, model $model, base $base"
