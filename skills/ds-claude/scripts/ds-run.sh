#!/usr/bin/env bash
# Run one DeepSeek work order through opencode, then judge it by task/verify.sh.
# Usage: ds-run.sh <workdir> [--retry] [--pro] [--no-baseline] [--no-lint] [--model provider/model] [--ask "question"]
# Exit:  0 PASS | 1 verify failed | 2 out of scope or task/ tampered | 3 setup | 4 worker error
set -uo pipefail
# A worker that runs Python would otherwise leave __pycache__ and trip the scope check.
export PYTHONDONTWRITEBYTECODE=1

finish() { echo "$2"; exit "$1"; }
setup_fail() { finish 3 "FAIL setup: $1"; }

dir=""; retry=0; baseline=1; lint=1; tier=flash; model="${DS_MODEL:-}"; ask=""
while [ $# -gt 0 ]; do
  case "$1" in
    --retry) retry=1 ;;
    --pro) tier=pro ;;
    --no-baseline) baseline=0 ;;
    --no-lint) lint=0 ;;
    --model) [ $# -ge 2 ] || setup_fail "--model needs a value"; model="$2"; shift ;;
    --ask) [ $# -ge 2 ] || setup_fail "--ask needs a question"; ask="$2"; shift ;;
    -*) setup_fail "unknown flag $1" ;;
    *) dir="$1" ;;
  esac
  shift
done

[ -n "$dir" ] && [ -d "$dir" ] || setup_fail "usage: ds-run.sh <workdir> [--retry] [--pro] [--no-lint] [--model m] [--ask \"question\"]"
cd "$dir" || setup_fail "cannot enter $dir"
command -v opencode >/dev/null || setup_fail "opencode not found"

if [ -z "$model" ]; then
  model="$(opencode models 2>/dev/null </dev/null | grep -E "^opencode-go/deepseek.*$tier" | sort -V | tail -1)"
  [ -n "$model" ] || setup_fail "no opencode-go deepseek $tier model; check opencode auth list"
fi

limit="${DS_TIMEOUT:-900}"
run_limited() {
  local t; t="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$t" ]; then "$t" "$limit" "$@"; return; fi
  # macOS has no timeout. Kill the whole process group, or the worker's tools keep writing files.
  perl -e 'my $t = shift; my $p = fork; die unless defined $p;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$p; waitpid($p, 0); exit 124 };
    alarm $t; waitpid($p, 0); exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$limit" "$@"
}

if [ -n "$ask" ]; then
  mkdir -p task
  before="$(git status --porcelain 2>/dev/null | grep -v ' task/' || true)"
  prompt="Answer the question by reading files in this directory. Do not create, edit or delete any file. Reply with conclusions and path:line references only, no file dumps. Question: $ask"
  run_limited opencode run --agent plan -m "$model" "$prompt" > task/notes.md 2> task/exec.log </dev/null
  worker=$?
  after="$(git status --porcelain 2>/dev/null | grep -v ' task/' || true)"
  if [ "$worker" -ne 0 ]; then finish 4 "FAIL worker: opencode exit $worker, see task/exec.log"; fi
  [ "$after" = "$before" ] || finish 2 "FAIL scope: ask mode changed files"
  [ -s task/notes.md ] || finish 4 "FAIL worker: empty answer"
  finish 0 "PASS: answer in task/notes.md, model $model"
fi

git rev-parse --verify -q HEAD >/dev/null || setup_fail "need a git repo with at least one commit"
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || setup_fail "workdir must be the repo root"
for f in SPEC.md scope.txt verify.sh; do [ -s "task/$f" ] || setup_fail "missing task/$f"; done

if [ "$lint" = 1 ]; then
  # Threshold borrowed from dispatch-router deep-lint's split stats (168 dispatches, only 11/32 passed at 2+ points).
  if grep -Eq '^[[:space:]]*! ' task/verify.sh; then
    setup_fail "lint: task/verify.sh has a bare '! cmd' line; under set -e it never fails. Use: if cmd; then exit 1; fi"
  fi
  spec_lines="$(wc -l < task/SPEC.md)"
  scope_globs="$(grep -c '[^[:space:]]' task/scope.txt || true)"
  score=0
  [ "$spec_lines" -gt 40 ] && score=$((score + 1))
  [ "$scope_globs" -gt 2 ] && score=$((score + 1))
  if [ "$score" -ge 2 ]; then
    setup_fail "lint: work order too big (SPEC.md $spec_lines lines > 40, scope.txt $scope_globs globs > 2); split it into several orders, or pass --no-lint"
  fi
fi

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

# verify.sh runs from a copy taken now, so editing task/verify.sh does not change the result.
snap="$(mktemp -d "${TMPDIR:-/tmp}/ds-run.XXXXXX")"; trap 'rm -rf "$snap"' EXIT
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

# The checksum lives in this process, so a changed snapshot is caught too. This is a check, not a sandbox.
touch task/artifacts
cp task/artifacts task/base "$snap/"
snapsum() { (cd "$snap" && cat SPEC.md scope.txt verify.sh artifacts base) | cksum; }
sum="$(snapsum)"

prompt="Do the work described in task/SPEC.md. Only change paths allowed by task/scope.txt. Do not edit anything under task/, except task/notes.md when task/SPEC.md asks for it. Do not commit. When done, list the files you changed."
[ "$retry" = 1 ] && prompt="$prompt The previous attempt failed acceptance: read task/verify.log and fix the cause. Your earlier changes are still in the working tree."

# </dev/null is required: opencode run waits for stdin EOF and hangs on an open pipe.
run_limited opencode run --auto -m "$model" "$prompt" > task/exec.log 2>&1 </dev/null
worker=$?

log() { printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$(sed -n '1p' task/SPEC.md | cut -c1-60)" "$model" "$1" "$retry" >> task/dispatch-log.tsv; }

# Restore every edited file before reporting, so a retry never trusts a forged one.
check_task() {
  local f bad=""
  for f in "$@"; do
    cmp -s "$snap/$f" "task/$f" || { cp "$snap/$f" "task/$f"; bad="$bad task/$f"; }
  done
  [ -z "$bad" ] || { log "scope"; finish 2 "FAIL scope: worker edited$bad (restored)"; }
}

[ "$(snapsum)" = "$sum" ] || { log "scope"; finish 2 "FAIL scope: worker edited the verify snapshot"; }
check_task SPEC.md scope.txt verify.sh artifacts base

if [ "$worker" -ne 0 ]; then log "worker"; finish 4 "FAIL worker: opencode exit $worker, see task/exec.log"; fi

check_scope() {
  local tracked new path glob ok outside=""
  tracked="$(git -c core.quotePath=false diff --name-only --no-renames "$base")" &&
    new="$(untracked)" || { log "scope"; finish 2 "FAIL scope: git could not list the changes"; }
  changed="$(printf '%s\n%s\n' "$tracked" "$new" | sort -u | grep -vxFf task/artifacts)"
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
}

check_scope
run_verify
verified=$?
# verify.sh runs code the worker wrote, so check again after it.
check_task SPEC.md scope.txt verify.sh
check_scope
count="$(printf '%s' "$changed" | grep -c . || true)"
if [ "$verified" -ne 0 ]; then log "verify"; finish 1 "FAIL verify: exit $verified, $count files changed, see task/verify.log"; fi
log "pass"
finish 0 "PASS: $count files changed, model $model, base $base"
