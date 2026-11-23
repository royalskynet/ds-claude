// cwdFingerprint 只算工作樹內容：commit 前後指紋不變，改檔才變；不碰真正的 .git/index。
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const { cwdFingerprint } = await import('../hooks/ledger.mjs');

test('commit 不改變指紋，改檔才改變，且不更動真 index', () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-fp-commit-'));
  const run = (args) => {
    const r = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr || r.stdout);
    return r.stdout ?? '';
  };
  const status = () => run(['status', '--porcelain=v1', '-uall']);

  try {
    run(['init']);
    run(['config', 'user.email', 't@example.com']);
    run(['config', 'user.name', 'T']);
    fs.writeFileSync(path.join(repo, 'a.txt'), 'one\n');
    run(['add', '-A']);
    run(['commit', '-m', 'init']);

    // 未 commit 的改動：A 已含新內容
    fs.writeFileSync(path.join(repo, 'a.txt'), 'two\n');
    const statusBeforeA = status();
    const A = cwdFingerprint(repo);
    assert.ok(A, 'fingerprint A should be set');
    assert.equal(status(), statusBeforeA, '真 index 的 porcelain 輸出在算指紋前後要一樣');

    // 內容不變，只 commit：B === A
    run(['add', '-A']);
    run(['commit', '-m', 'same content']);
    const statusBeforeB = status();
    const B = cwdFingerprint(repo);
    assert.equal(B, A, 'commit 不應改變指紋');
    assert.equal(status(), statusBeforeB, '真 index 的 porcelain 輸出在算指紋前後要一樣');

    // 再改內容：C !== B
    fs.writeFileSync(path.join(repo, 'a.txt'), 'three\n');
    const C = cwdFingerprint(repo);
    assert.notEqual(C, B, '改檔後指紋要變');
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});
