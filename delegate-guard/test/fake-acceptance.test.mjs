// fakeAcceptance: HEAD-bound assertions break pinned re-verify once more commits land.
import { test } from 'node:test';
import assert from 'node:assert';
import { fakeAcceptance, maskedPipe } from '../hooks/ledger.mjs';

for (const fallback of [
  'echo "tests failed"',
  'true  # comment',
  'true; echo done',
  ':;',
  'exit 0 # ok',
  '{ echo fail; }',
  '\n  # fallback\n  echo "tests failed"',
  '{\n  echo "exit 1;"\n  :\n}',
]) {
  test(`rejects a status-masking fallback: ${JSON.stringify(fallback)}`, () => {
    assert.match(fakeAcceptance(`npm test || ${fallback}`), /吞掉失敗/);
  });
}

test('accepts nonzero fallbacks and quoted fallback text', () => {
  for (const s of [
    'npm test || exit 1',
    'npm test || { tail log; exit 1; }',
    'npm test || { echo fail; exit 1; }',
    'npm test || { tail log; }',
    'npm test || run_tests_again',
    'npm test || echo recovered | grep -q expected',
    'grep -F \'|| echo "tests failed"\' README.md',
  ]) assert.equal(fakeAcceptance(s), '', s);
});

test('rejects a trailing fallback even after a heredoc with an unmatched apostrophe', () => {
  assert.match(fakeAcceptance("cat <<'EOF' > f\nit's data\nEOF\nnpm test || true"), /吞掉失敗/);
});

test('rejects a status-masking fallback inside a shell interpreter heredoc', () => {
  assert.match(fakeAcceptance("bash -e <<'EOF'\nfalse || echo failed\nEOF"), /吞掉失敗/);
});

test('rejects acceptance bound to the latest commit', () => {
  for (const l of [
    "git log -1 --format=%s | grep -qi 502",
    "git log -1 --name-only --format= | grep -q bin/x.sh",
    "git -C /r log -n 1 --format=%s",
    "git show --name-only HEAD | grep -q x",
    "git diff --stat HEAD~1 | grep -q x",
  ]) assert.match(fakeAcceptance(`set -e\nnode --test t.mjs\n${l}`), /最新一筆 commit/, l);
});

test('accepts history-window and content checks', () => {
  for (const l of [
    "git log --format=%s -20 | grep -qi 502",
    "grep -q errorStatus gateway/src/cascade-server.js",
    "git diff --stat",
  ]) assert.equal(fakeAcceptance(`set -e\nnode --test t.mjs\n${l}`), '', l);
});

test('rejects a check whose failure is masked by a trailing pipe', () => {
  for (const l of [
    "npm test 2>&1 | tail -20",
    "pytest -q | tee out.log",
    "node --test t.mjs | head -5",
  ]) assert.match(fakeAcceptance(`set -e\n${l}`), /pipefail/, l);
});

test('accepts pipes that still check, pipefail, and quoted pipe text', () => {
  for (const s of [
    "set -e\nnode --test t.mjs | grep -q 'pass 3'",
    "set -euo pipefail\nnpm test | tail -20",
    "set -e\ngrep -q 'a | tail' README.md",
  ]) assert.equal(fakeAcceptance(s), '', s);
});

test('masked-pipe edge cases from review', () => {
  for (const s of [
    "set -e\n# set -o pipefail\nnpm test | tail -20",
    "set -e\nnpm test | tail -20\nset -o pipefail",
    "set -e\nnpm test |\n  tail -20",
    "set -e\nnpm test \\\n  | tail -20",
    "set -e\nnpm test |& tail -20",
  ]) assert.match(fakeAcceptance(s), /pipefail/, s);
  for (const s of [
    "set -e\ngrep -Eq 'passed|tail' results.txt",
    "set -e\ngrep -q ok out.txt # | tail",
    "set -e\nset -o pipefail\nnpm test |\n  tail -20",
  ]) assert.equal(fakeAcceptance(s), '', s);
});

test('masked-pipe second-round review cases', () => {
  assert.match(fakeAcceptance("set -e\n# don't skip\nnpm test | tail -20\necho 'done'"), /pipefail/);
  for (const s of [
    "set -e; set -o pipefail\nnpm test | tail -20",
    "set -e\nset -o 'pipefail'\nnpm test | tail -20",
    "set -e\ntest -s out.txt ||\n  cat fallback.txt",
  ]) assert.equal(fakeAcceptance(s), '', s);
});

test('masked-pipe third-round review cases', () => {
  for (const s of [
    "set -e\nnpm test | tail -20; set -o pipefail",
    "set -e\necho 'x; set -o pipefail; y'\nnpm test | tail -20",
    "set -e\necho it\\'s\nnpm test | tail -20",
  ]) assert.match(fakeAcceptance(s), /pipefail/, s);
  assert.equal(maskedPipe("set -e; set -o pipefail; npm test | tail -20"), "");
});

test('masked-pipe fourth-round review cases', () => {
  assert.equal(maskedPipe('set -e\nmy_cli --help | "$GREP" tail'), '');
  assert.equal(maskedPipe('set -e\ngen | "$PYTHON"\nset -o pipefail\nnpm test | tee out.log'), '');
  assert.match(maskedPipe('set -e\ngen | "$PYTHON"\nnpm test | tee out.log\nset -o pipefail'), /tee/);
});

test('masked-pipe keeps a pipeline across blank and comment lines', () => {
  assert.match(maskedPipe('set -e\nnpm test |\n\n  tail -20'), /tail/);
  assert.match(maskedPipe('set -e\nnpm test |\n  # keep the end\n  tee out.log'), /tee/);
});
