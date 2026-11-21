#!/usr/bin/env bash
# Offline checks for ds-run.sh. A stub opencode stands in for the real one.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
run="$root/skills/ds-claude/scripts/ds-run.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/config"
export XDG_CONFIG_HOME="$tmp/config"
cat > "$tmp/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = models ]; then
  [ "${FAKE_PRIMARY:-}" != nomodels ] || exit 0
  printf '%s\n' opencode-go/deepseek-v4-pro opencode-go/deepseek-v4.1-flash opencode-go/deepseek-v4.9-flash opencode-go/glm-5.2-flash opencode-go/glm-5.3-flash opencode-go/glm-5.3 opencode-go/kimi-k2.7-code opencode-go/kimi-k3
  exit 0
fi
echo "args: $*" >> "$FAKE_ARGS"
if [ -n "${FAKE_PRIMARY_ERROR:-}" ]; then
  echo "$FAKE_PRIMARY_ERROR" >&2; exit 7
fi
case "${FAKE_PRIMARY:-}" in
  exit) echo 'QUOTA exhausted' >&2; exit 7 ;;
  hang) echo 'usage limit reached' >&2; (sleep 2; echo late > src/late.txt) & sleep 30 ;;
esac
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
  quota-progress) printf '%s\n' 'Adding quota support' 'Updating rate limit settings' 'Reviewed 429 files'; sleep 0.5; echo ok > src/a.txt ;;
  quota-crash) echo 'Adding quota support'; exit 7 ;;
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
cat > "$tmp/bin/codex" <<'CODEX'
#!/usr/bin/env bash
echo "codex: $*" >> "$FAKE_ARGS"
[ "${FAKE_CODEX_FAIL:-0}" = 0 ] || exit 7
out=""; prev=""
for a in "$@"; do [ "$prev" != -o ] || out="$a"; prev="$a"; done
if [ -n "$out" ]; then
  printf 'answer\nREASON: ok\nVERDICT: APPROVE\n' > "$out"
else
  echo ok > src/a.txt
fi
CODEX
chmod +x "$tmp/bin/codex" "$tmp/bin/opencode"
export PATH="$tmp/bin:$PATH" FAKE_ARGS="$tmp/args"
unset DS_MODEL DS_REVIEW_MODEL DS_REVIEW DS_REVIEW_RECORD DS_FALLBACK DS_FALLBACK_MODEL FAKE_PRIMARY FAKE_CODEX_FAIL
unset FAKE_PRIMARY_ERROR
fails=0; n=0

repo() {
  rm -rf "$tmp/r"; mkdir -p "$tmp/r/src" "$tmp/r/task"; cd "$tmp/r" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  echo keep > src/keep.txt; git add .; git commit -qm init
  git update-ref refs/remotes/origin/main HEAD
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
# The fixtures change one line, so the size skip is off until its own section.
export DS_REVIEW_MIN_LINES=0
export FAKE_REVIEW=approve
repo; echo ok > src/a.txt; check "review: approve" 0 good --review
expect "review: picks the newest glm flash" grep -q -- '-m opencode-go/glm-5.3-flash' "$FAKE_ARGS"
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

# --path narrows the review diff
absent() { n=$((n+1)); if grep -q "$2" task/review.diff; then echo "FAIL $1"; fails=$((fails+1)); else echo "ok   $1"; fi; }
repo; echo ok > src/a.txt; mkdir "junk dir"; echo MARKJUNK > "junk dir/s.txt"; echo MARKOTHER > other.txt
check "review: --path" 0 good --review --path src
expect "review: --path keeps the path" grep -q 'src/a.txt' task/review.diff
absent "review: --path drops other paths" 'MARKJUNK\|MARKOTHER'
check "review: --path twice, with a space" 0 good --review --path "junk dir" --path other.txt
expect "review: both paths kept" grep -q 'MARKJUNK' task/review.diff
expect "review: second path kept" grep -q 'MARKOTHER' task/review.diff
absent "review: --path twice drops src" 'src/a.txt'
check "review: no --path reviews everything" 0 good --review
expect "review: no --path has the junk file" grep -q 'MARKJUNK' task/review.diff
repo; echo MARKOTHER > other.txt; check "review: --path with nothing inside" 3 good --review --path nowhere
repo; echo MARKONE > src/a.txt; echo MARKTWO > other.txt; git add -A; git commit -qm more
check "review: --path on unpushed commits" 0 good --review --path other.txt
expect "review: --path keeps its part of the log" grep -q 'MARKTWO' task/review.diff
absent "review: --path drops the rest of the log" 'MARKONE'
# The worker needs a clean tree, so the path here holds an unpushed commit instead.
repo; mkdir "junk dir"; echo MARKJUNK > "junk dir/s.txt"; git add -A; git commit -qm junk
check "ladder: --path reaches the review" 0 good --ladder --path "junk dir"
expect "ladder: --path keeps its path" grep -q 'MARKJUNK' task/review.diff
absent "ladder: --path drops the worker's file" 'src/a.txt'

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

# --- review skip: docs-only and small changes ---
unset DS_REVIEW_MIN_LINES; export FAKE_REVIEW=reject
export DS_REVIEW_RECORD="$tmp/rec.sh" REC_OUT="$tmp/skip.out"
repo; echo ok > src/a.txt; check "skip: small change" 0 good --review
expect "skip: line says SKIP and the size" grep -q 'PASS review: SKIP, 1 changed lines, under 10' "$tmp/out"
expect "skip: no model call" test "$(reviews)" = 0
expect "skip: recorded as APPROVE" grep -q '|APPROVE|review skipped: 1 changed lines' "$tmp/skip.out"
expect "skip: logged" grep -q 'review.*skip' task/dispatch-log.tsv
repo; seq 1 9 > src/a.txt; check "skip: 9 lines" 0 good --review
repo; seq 1 10 > src/a.txt; check "skip: 10 lines are reviewed" 5 good --review
expect "skip: 10 lines call the model" test "$(reviews)" = 1
repo; seq 1 40 > NOTES.md; mkdir docs; seq 1 40 > docs/guide.RST; check "skip: docs only" 0 good --review
expect "skip: line says docs only" grep -q 'PASS review: SKIP, docs only' "$tmp/out"
repo; seq 1 12 > src/committed.sh; echo internal > task/internal.txt
git add src/committed.sh task/internal.txt; git commit -qm 'local code'
echo '# Local notes' > NOTES.md
check "review: unpushed code with untracked docs is reviewed" 5 good --review
expect "review: diff includes unpushed code" grep -q '^+++ b/src/committed.sh$' task/review.diff
expect "review: diff includes untracked docs" grep -q '^+++ b/NOTES.md$' task/review.diff
absent "review: combined diff excludes pushed history and task/" 'b/src/keep.txt\|b/task/'
echo STAGED > src/staged.txt; git add src/staged.txt
echo UNSTAGED >> src/keep.txt
echo UNTRACKED > src/untracked.txt
check "review: --path on unpushed commits and worktree changes" 5 good --review --path src
expect "review: combined --path keeps commits" grep -q '^+++ b/src/committed.sh$' task/review.diff
expect "review: combined --path keeps staged changes" grep -q '^+STAGED$' task/review.diff
expect "review: combined --path keeps unstaged changes" grep -q '^+UNSTAGED$' task/review.diff
expect "review: combined --path keeps untracked changes" grep -q '^+UNTRACKED$' task/review.diff
absent "review: combined --path drops out-of-scope docs" 'b/NOTES.md'
repo; seq 1 40 > NOTES.md; seq 1 3 > src/a.txt; check "skip: docs plus code is reviewed" 5 good --review
repo; seq 1 40 > requirements.txt; check "skip: .txt is not a doc" 5 good --review
repo; printf -- '-- a\n++ b\n' > src/keep.txt; seq 1 8 >> src/keep.txt; check "skip: added and removed lines both count" 5 good --review
repo; printf '\0\1\2' > src/b.bin; check "skip: binary file is reviewed" 5 good --review
repo; git mv src/keep.txt src/moved.txt; check "skip: rename is reviewed" 5 good --review
repo; git mv src/keep.txt src/keep.md; check "skip: rename to .md is reviewed" 5 good --review
repo; chmod +x src/keep.txt; check "skip: mode change is reviewed" 5 good --review
repo; printf -- '-- a/x\n++ b/x\n' > src/keep.txt; git add -A; git commit -qm hdr
git update-ref refs/remotes/origin/main HEAD; seq 1 8 > src/keep.txt
check "skip: content that looks like a header counts" 5 good --review
repo; echo ok > src/a.txt; export DS_REVIEW_MIN_LINES=0; check "skip: MIN_LINES=0 reviews everything" 5 good --review
export DS_REVIEW_MIN_LINES=x; check "skip: bad MIN_LINES refused" 3 good --review
unset DS_REVIEW_MIN_LINES
repo; check "skip: ladder" 0 good --ladder
expect "skip: ladder says review SKIP" grep -Eq '^PASS: .* \| attempts 1 \| review SKIP$' "$tmp/out"
unset DS_REVIEW_RECORD REC_OUT FAKE_REVIEW

export DS_POLL=0.1 DS_REVIEW_MIN_LINES=0
for primary in nomodels exit hang; do
  export FAKE_PRIMARY="$primary"
  repo; check "fallback $primary dispatch" 0 good
  expect "fallback $primary model" grep -q 'model codex' "$tmp/out"
  expect "fallback $primary workspace sandbox" grep -q -- '--sandbox workspace-write' "$FAKE_ARGS"
  expect "fallback $primary logged" grep -q 'codex.*pass' task/dispatch-log.tsv
  if [ "$primary" = hang ]; then
    sleep 3
    expect "unavailable kills children" test ! -e src/late.txt
    expect "primary log preserved" grep -q 'usage limit' task/exec.log
  fi
  repo; check "fallback $primary ask" 0 answer --ask q
  expect "fallback $primary answer" grep -q answer task/notes.md
  expect "fallback $primary read sandbox" grep -q -- '--sandbox read-only' "$FAKE_ARGS"
  repo; echo ok > src/a.txt; check "fallback $primary review" 0 good --review
  expect "fallback $primary verdict" grep -q 'APPROVE, model codex' "$tmp/out"
done
repo; DS_FALLBACK_MODEL='custom model' check "fallback model override" 0 good
expect "fallback model name" grep -q 'model codex/custom model' "$tmp/out"
expect "fallback model argument" grep -q -- '-m custom model' "$FAKE_ARGS"
repo; FAKE_CODEX_FAIL=1 check "fallback failure" 4 good
expect "fallback failure names codex" grep -q 'codex exit 7' "$tmp/out"
repo; DS_FALLBACK=0 check "unavailable disabled" 4 good
expect "unavailable no fallback message" grep -q 'primary unavailable.*no fallback' "$tmp/out"
repo; FAKE_PRIMARY=nomodels DS_FALLBACK=0 check "missing model disabled" 3 good
repo; DS_FALLBACK=unknown check "unknown fallback" 3 good
mkdir "$tmp/no-codex"
cp "$tmp/bin/opencode" "$tmp/no-codex/opencode"
if ! PATH="$tmp/no-codex:/usr/bin:/bin" command -v codex >/dev/null; then
  repo; PATH="$tmp/no-codex:/usr/bin:/bin" FAKE_PRIMARY=exit check "missing codex unavailable" 4 good
  expect "missing codex no fallback" grep -q 'no fallback' "$tmp/out"
  repo; PATH="$tmp/no-codex:/usr/bin:/bin" FAKE_PRIMARY=nomodels check "missing codex missing model" 3 good
fi
unset FAKE_PRIMARY
for error in 'HTTP/2 429' '{"statusCode":429}' 'rate limit exceeded' 'quota exceeded' 'insufficient_quota' 'Too Many Requests' 'You exceeded your current quota'; do
  repo; FAKE_PRIMARY_ERROR="$error" check "fallback on $error" 0 good
  expect "fallback on $error uses codex" grep -q 'model codex' "$tmp/out"
done
repo; DS_FALLBACK=0 check "quota progress leaves primary running" 0 quota-progress
repo; check "ordinary failure after quota progress" 4 quota-crash
expect "failure after quota progress names primary" grep -q 'opencode exit 7' "$tmp/out"
expect "failure after quota progress does not call codex" test "$(grep -c '^codex:' "$FAKE_ARGS")" = 0
repo; check "ordinary failure does not fallback" 4 crash
expect "ordinary failure names primary" grep -q 'opencode exit 7' "$tmp/out"
expect "ordinary failure no codex" test "$(grep -c '^codex:' "$FAKE_ARGS")" = 0
repo; check "primary logs enabled" 0 good
expect "primary log flags" grep -q -- '--print-logs --log-level ERROR' "$FAKE_ARGS"

echo "$((n-fails))/$n passed"
[ "$fails" = 0 ]
