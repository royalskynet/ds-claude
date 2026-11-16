#!/usr/bin/env bash
# Offline checks for ds-run.sh. A stub opencode stands in for the real one.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
run="$root/skills/ds-claude/scripts/ds-run.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = models ]; then
  printf '%s\n' opencode-go/deepseek-v4-pro opencode-go/deepseek-v4.1-flash opencode-go/deepseek-v4.9-flash opencode-go/glm-5.3-flash opencode-go/kimi-k2.7-code opencode-go/kimi-k3
  exit 0
fi
echo "args: $*" >> "$FAKE_ARGS"
case " $* " in
  *" --agent plan "*)
    case "${FAKE_REVIEW:-}" in
      approve) printf 'looks fine\nREASON: ok\nVERDICT: APPROVE\n'; exit 0 ;;
      reject)  printf 'src/a.txt:1 bad\nREASON: hardcoded expected value\nVERDICT: REJECT\n'; exit 0 ;;
      silent)  echo "no decision"; exit 0 ;;
      write)   echo x > src/sneak.txt; printf 'VERDICT: APPROVE\n'; exit 0 ;;
    esac ;;
esac
mode="$FAKE_MODE"
if [ -s "${FAKE_SEQ:-/dev/null}" ]; then
  mode="$(sed -n 1p "$FAKE_SEQ")"; sed -i.bak 1d "$FAKE_SEQ"
fi
case "$mode" in
  good)    echo ok > src/a.txt ;;
  bad)     echo no > src/a.txt ;;
  nothing) : ;;
  outside) echo ok > src/a.txt; echo x > other.txt ;;
  tamper)  printf 'exit 0\n' > task/verify.sh ;;
  crash)   echo ok > src/a.txt; exit 7 ;;
  hang)    cat >/dev/null; sleep 30 ;;
  stdin)   cat >/dev/null; echo ok > src/a.txt ;;
  pycache) echo ok > src/a.txt; python3 -c "import tool" ;;
  hide)    echo ok > src/a.txt; echo x > other.txt; echo other.txt >> task/artifacts ;;
  tamper2) echo '*' > task/scope.txt; printf 'exit 0\n' > task/verify.sh ;;
  badbase) echo ok > src/a.txt; echo deadbeef > task/base ;;
  nogit)   echo ok > src/a.txt; mv .git .git.gone ;;
  snap)    for d in "$TMPDIR"/ds-run.*; do printf 'exit 0\n' > "$d/verify.sh"; done; printf 'exit 0\n' > task/verify.sh ;;
  orphan)  (sleep 2; echo late > src/late.txt) & sleep 30 ;;
  answer)  echo "src/keep.txt:1 keep" ;;
  askwrite) echo "src/keep.txt:1 keep"; echo x > src/new.txt ;;
esac
STUB
chmod +x "$tmp/bin/opencode"
export PATH="$tmp/bin:$PATH" FAKE_ARGS="$tmp/args"
unset DS_MODEL DS_REVIEW_MODEL DS_REVIEW DS_REVIEW_RECORD
fails=0; n=0

repo() {
  rm -rf "$tmp/r"; mkdir -p "$tmp/r/src" "$tmp/r/task"; cd "$tmp/r" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  echo keep > src/keep.txt; git add .; git commit -qm init
  echo '# goal' > task/SPEC.md; echo 'src/*' > task/scope.txt
  printf 'set -e\ngrep -q ok src/a.txt\n' > task/verify.sh
}
check() { # name expected-exit mode [args...]
  local name="$1" want="$2" mode="$3"; shift 3
  n=$((n+1)); : > "$FAKE_ARGS"
  FAKE_MODE="$mode" DS_TIMEOUT="${DS_TIMEOUT:-20}" bash "$run" "$tmp/r" "$@" > "$tmp/out" 2>&1 < <(sleep 60)
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: want $want got $got: $(tail -1 "$tmp/out")"; fails=$((fails+1)); fi
}
expect() { # name command...
  local name="$1"; shift; n=$((n+1))
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi
}
workers() { grep -vc -- '--agent plan' "$FAKE_ARGS" 2>/dev/null || true; }
reviews() { grep -c -- '--agent plan' "$FAKE_ARGS" 2>/dev/null || true; }

repo; check "pass" 0 good
expect "picks newest flash" grep -q 'deepseek-v4.9-flash' "$FAKE_ARGS"
expect "task/ stays out of git status" test -z "$(git status --porcelain -- task)"
expect "dispatch log written" grep -q 'pass' task/dispatch-log.tsv
repo; check "stdin is closed for the worker" 0 stdin
repo; check "verify failure" 1 nothing
expect "retry keeps base" test -s task/base
check "retry passes" 0 good --retry
expect "retry prompt mentions verify.log" grep -q 'task/verify.log' "$FAKE_ARGS"
repo; check "pro tier" 0 good --pro
expect "pro model used" grep -q 'deepseek-v4-pro' "$FAKE_ARGS"
repo; check "out of scope" 2 outside
repo; check "worker edits verify.sh" 2 tamper
expect "verify.sh restored" grep -q 'grep -q ok' task/verify.sh
repo; check "worker crash beats a passing verify" 4 crash
repo; DS_TIMEOUT=2 check "timeout" 4 hang
repo; echo dirty > src/keep.txt; check "dirty tree refused" 3 good
expect "worker not started on dirty tree" test ! -s "$FAKE_ARGS"
repo; rm task/verify.sh; check "missing verify.sh" 3 good
repo; check "retry without base" 3 good --retry
repo; printf 'exit 0\n' > task/verify.sh; check "verify already green refused" 3 good
expect "worker not started when verify is green" test ! -s "$FAKE_ARGS"
repo; printf 'exit 0\n' > task/verify.sh; check "no-baseline allows a green verify" 0 good --no-baseline
repo; printf 'mkdir -p cache; echo x > cache/o\ngrep -q ok src/a.txt\n' > task/verify.sh
check "verify artifacts: first attempt fails" 1 nothing
check "verify artifacts: not counted on retry" 0 good --retry
repo; echo "x=1" > tool.py; git add tool.py; git commit -qm tool; check "python cache is not a scope change" 0 pycache
repo; check "worker cannot hide a change in task/artifacts" 2 hide
repo; check "two tampered task files: exit" 2 tamper2
n=$((n+1)); if cmp -s task/verify.sh <(printf 'set -e\ngrep -q ok src/a.txt\n') && [ "$(cat task/scope.txt)" = 'src/*' ]; then echo "ok   two tampered task files: both restored"; else echo "FAIL both restored"; fails=$((fails+1)); fi
repo; check "worker cannot change task/base" 2 badbase
repo; check "a broken git repo is not a clean tree" 2 nogit
repo; mkdir "$tmp/t"; TMPDIR="$tmp/t" check "worker cannot edit the snapshot" 2 snap
repo; echo a > root.txt; git add root.txt; git commit -qm root; printf 'set -e\ngrep -q ok src/a.txt\necho y >> root.txt\n' > task/verify.sh; check "scope is checked again after verify" 2 good
repo; DS_TIMEOUT=1 check "timeout: exit" 4 orphan; sleep 3
n=$((n+1)); if [ ! -e src/late.txt ]; then echo "ok   timeout kills the worker's children"; else echo "FAIL orphan wrote a file"; fails=$((fails+1)); fi
if PATH="$tmp/bin:/usr/bin:/bin" command -v timeout >/dev/null; then echo "skip perl timeout: this system has timeout in /usr/bin"
else
  repo; PATH="$tmp/bin:/usr/bin:/bin" DS_TIMEOUT=1 check "perl timeout: exit" 4 orphan; sleep 3
  n=$((n+1)); if [ ! -e src/late.txt ]; then echo "ok   perl timeout kills the worker's children"; else echo "FAIL perl orphan wrote a file"; fails=$((fails+1)); fi
fi
repo; for i in $(seq 41); do echo "# line $i"; done > task/SPEC.md; printf 'src/*\na/*\nb/*\n' > task/scope.txt; check "lint: big spec with wide scope refused" 3 good
expect "lint: worker not started" test ! -s "$FAKE_ARGS"
check "lint: --no-lint allows it" 0 good --no-lint
repo; for i in $(seq 41); do echo "# line $i"; done > task/SPEC.md; check "lint: big spec alone passes" 0 good
repo; printf 'set -e\n! grep -q zzz src/keep.txt\ngrep -q ok src/a.txt\n' > task/verify.sh; check "lint: bare negation refused" 3 good
repo; rm task/SPEC.md task/scope.txt task/verify.sh; check "ask: answer saved" 0 answer --ask "where is keep"
expect "ask: logged as pass" grep -q "ask: where is keep.*pass" task/dispatch-log.tsv
expect "ask: notes has the answer" grep -q 'src/keep.txt:1' task/notes.md
expect "ask: uses the plan agent" grep -q -- '--agent plan' "$FAKE_ARGS"
n=$((n+1)); if grep -q -- '--auto' "$FAKE_ARGS"; then echo "FAIL ask: never auto-approves"; fails=$((fails+1)); else echo "ok   ask: never auto-approves"; fi
repo; check "ask: file change refused" 2 askwrite --ask "q"
repo; check "ask: empty answer refused" 4 nothing --ask "q"
expect "ask: failure logged" grep -q "ask: q.*worker" task/dispatch-log.tsv
repo; mkdir sub; check_dir="$tmp/r/sub"; n=$((n+1))
if FAKE_MODE=good bash "$run" "$check_dir" >/dev/null 2>&1; [ $? = 3 ]; then echo "ok   subdirectory refused"; else echo "FAIL subdirectory refused"; fails=$((fails+1)); fi

# --- --review (read-only reviewer) ---
export FAKE_REVIEW=approve
repo; echo ok > src/a.txt; check "review: approve" 0 good --review
expect "review: picks the newest kimi" grep -q 'opencode-go/kimi-k3' "$FAKE_ARGS"
expect "review: logs approve" grep -q 'review.*approve' task/dispatch-log.tsv
expect "review: diff includes the untracked file" grep -q 'src/a.txt' task/review.diff
expect "review: runs --pure" grep -q -- '--pure' "$FAKE_ARGS"
expect "review: uses the plan agent" grep -q -- '--agent plan' "$FAKE_ARGS"

export FAKE_REVIEW=reject
repo; echo ok > src/a.txt; check "review: reject" 5 good --review
expect "review: reject reason in the line" grep -q 'hardcoded expected value' "$tmp/out"

export FAKE_REVIEW=silent
repo; echo ok > src/a.txt; check "review: no verdict" 4 good --review
expect "review: no verdict says so" grep -q 'no verdict' "$tmp/out"

export FAKE_REVIEW=write
repo; echo ok > src/a.txt; check "review: writer caught" 2 good --review

export FAKE_REVIEW=approve
repo; echo ok > src/a.txt; rm -rf task; check "review: missing work order" 3 good --review
repo; mkdir sub; echo ok > src/a.txt; n=$((n+1))
if bash "$run" "$tmp/r/sub" --review >/dev/null 2>&1; [ $? = 3 ]; then echo "ok   review: subdirectory refused"; else echo "FAIL review subdirectory refused"; fails=$((fails+1)); fi
repo; echo ok > src/a.txt; echo '# other order' > "$tmp/order.md"
check "review: --spec and --model" 0 good --review --spec "$tmp/order.md" --model x/custom
expect "review: --spec path reaches the prompt" grep -q "$tmp/order.md" "$FAKE_ARGS"
expect "review: --model used" grep -q 'x/custom' "$FAKE_ARGS"

repo; echo ok > src/a.txt; export DS_REVIEW_MODEL=opencode-go/kimi-env
check "review: DS_REVIEW_MODEL used" 0 good --review
expect "review: env model reaches opencode" grep -q 'kimi-env' "$FAKE_ARGS"
unset DS_REVIEW_MODEL

cat > "$tmp/rec.sh" <<'REC'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$REC_OUT"
REC
chmod +x "$tmp/rec.sh"
repo; echo ok > src/a.txt; export DS_REVIEW_RECORD="$tmp/rec.sh" REC_OUT="$tmp/rec.out"
check "review: record hook" 0 good --review
expect "review: record got repo, verdict, reason" grep -q '|APPROVE|ok' "$tmp/rec.out"
unset DS_REVIEW_RECORD REC_OUT

# --- --ladder (dispatch + escalate + review) ---
repo; check "ladder: one attempt passes" 0 good --ladder
expect "ladder: says attempts 1" grep -q 'attempts 1' "$tmp/out"
expect "ladder: appends review APPROVE" grep -q 'review APPROVE' "$tmp/out"
expect "ladder: keeps the worker PASS line" grep -Eq '^PASS: [0-9]+ files changed.* \| attempts 1 \| review APPROVE$' "$tmp/out"
n=$((n+1)); if [ "$(workers)" = 1 ] && [ "$(reviews)" = 1 ]; then echo "ok   ladder: one worker, one review"; else echo "FAIL ladder call counts"; fails=$((fails+1)); fi

repo; check "ladder: quoted model kept whole" 0 good --ladder --model "x/my model"
expect "ladder: does not split a quoted --model" grep -q -- '-m x/my model ' "$FAKE_ARGS"

repo; printf 'bad\ngood\n' > "$tmp/seq"; export FAKE_SEQ="$tmp/seq"
check "ladder: retries after a verify failure" 0 good --ladder
expect "ladder: says attempts 2" grep -q 'attempts 2' "$tmp/out"
unset FAKE_SEQ

repo; printf 'bad\nbad\ngood\n' > "$tmp/seq"; export FAKE_SEQ="$tmp/seq"
check "ladder: third attempt succeeds" 0 good --ladder
n=$((n+1)); if grep -v -- '--agent plan' "$FAKE_ARGS" | sed -n 3p | grep -q 'deepseek-v4-pro'; then echo "ok   ladder: final attempt uses pro"; else echo "FAIL ladder: final attempt must use pro"; fails=$((fails+1)); fi
unset FAKE_SEQ

repo; printf 'bad\nbad\nbad\n' > "$tmp/seq"; export FAKE_SEQ="$tmp/seq"
check "ladder: exhausts three attempts" 1 good --ladder
expect "ladder: exhaust reports verify failure" grep -q 'FAIL verify' "$tmp/out"
n=$((n+1)); if [ "$(workers)" = 3 ] && [ "$(reviews)" = 0 ]; then echo "ok   ladder: exhaust runs no review"; else echo "FAIL ladder exhaust call counts"; fails=$((fails+1)); fi
unset FAKE_SEQ

repo; check "ladder: scope failure stops" 2 outside --ladder
n=$((n+1)); if [ "$(workers)" = 1 ] && [ "$(reviews)" = 0 ]; then echo "ok   ladder: scope failure runs one worker"; else echo "FAIL ladder scope call counts"; fails=$((fails+1)); fi

repo; export DS_REVIEW=0
check "ladder: DS_REVIEW=0 skips review" 0 good --ladder
expect "ladder: still says attempts 1" grep -q 'attempts 1' "$tmp/out"
n=$((n+1)); if [ "$(reviews)" = 0 ] && ! grep -q 'review' "$tmp/out"; then echo "ok   ladder: review skipped"; else echo "FAIL ladder: review not skipped"; fails=$((fails+1)); fi
unset DS_REVIEW

echo "$((n-fails))/$n passed"
[ "$fails" = 0 ]
