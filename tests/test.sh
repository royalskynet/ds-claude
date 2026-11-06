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
  printf '%s\n' opencode-go/deepseek-v4-pro opencode-go/deepseek-v4.1-flash opencode-go/deepseek-v4.9-flash opencode-go/glm-5.3-flash
  exit 0
fi
echo "args: $*" >> "$FAKE_ARGS"
case "$FAKE_MODE" in
  good)    echo ok > src/a.txt ;;
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
esac
STUB
chmod +x "$tmp/bin/opencode"
export PATH="$tmp/bin:$PATH" FAKE_ARGS="$tmp/args"
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
repo; mkdir sub; check_dir="$tmp/r/sub"; n=$((n+1))
if FAKE_MODE=good bash "$run" "$check_dir" >/dev/null 2>&1; [ $? = 3 ]; then echo "ok   subdirectory refused"; else echo "FAIL subdirectory refused"; fails=$((fails+1)); fi

echo "$((n-fails))/$n passed"
[ "$fails" = 0 ]
