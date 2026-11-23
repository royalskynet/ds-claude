import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

test('stale fingerprint: invalidate/stopCheck 行為', async () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-fp-state-'));
  const dcq = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-fp-dcq-'));
  process.env.DEGUARD_STATE = state;
  process.env.DEGUARD_DCQ_HOME = dcq;
  const { cwdFingerprint, invalidate, stopCheck } = await import('../hooks/ledger.mjs');

  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-fp-repo-'));
  const run = (args) => {
    const r = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr || r.stdout);
  };
  run(['init']);
  run(['config', 'user.email', 't@example.com']);
  run(['config', 'user.name', 'T']);
  fs.writeFileSync(path.join(repo, 'a.txt'), 'one\n');
  run(['add', 'a.txt']);
  run(['commit', '-m', 'init']);

  const fp = cwdFingerprint(repo);
  assert.ok(fp, 'fp should be set');

  const makePending = () => ({
    pending: [{
      id: 'p1', kind: 'agent', status: 'terminal',
      cwd: repo, createdAt: Date.now(),
      verified: { rc: 0, at: Date.now(), fp },
    }],
    orphanStops: [],
  });

  // 1) invalidate 對 fp 非 null 項目跳過
  let l = makePending();
  assert.equal(invalidate(l, { tool: 'Bash', input: { command: `dcq add /tmp/x.md ${repo}` }, cwd: repo }), 0);
  assert.equal(l.pending[0].stale, undefined);
  assert.equal(stopCheck(l, 'sid'), '');

  l = makePending();
  assert.equal(invalidate(l, { tool: 'Bash', input: { command: `git push m2 main; m2ssh 'ls'` }, cwd: repo }), 0);
  assert.equal(l.pending[0].stale, undefined);
  assert.equal(stopCheck(l, 'sid'), '');

  // 2) 改動被追蹤檔後 stopCheck 偵測
  l = makePending();
  fs.writeFileSync(path.join(repo, 'a.txt'), 'two\n');
  let msg = stopCheck(l, 'sid');
  assert.match(msg, /驗過之後 cwd 又被改/);
  assert.equal(l.pending[0].stale, true);

  // 3) 新 commit 後（還原工作樹）同樣偵測
  run(['add', 'a.txt']);
  run(['commit', '-m', 'change']);
  assert.equal(fs.readFileSync(path.join(repo, 'a.txt'), 'utf8'), 'two\n');
  l = makePending();
  msg = stopCheck(l, 'sid');
  assert.match(msg, /驗過之後 cwd 又被改/);
  assert.equal(l.pending[0].stale, true);

  // 4) cwd 非 git repo（fp:null）維持原 invalidate 行為
  const nonrepo = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-fp-norepo-'));
  assert.equal(cwdFingerprint(nonrepo), null);
  const nl = {
    pending: [{
      id: 'p2', kind: 'agent', status: 'terminal',
      cwd: nonrepo, createdAt: Date.now(),
      verified: { rc: 0, at: Date.now(), fp: null },
    }],
    orphanStops: [],
  };
  assert.equal(invalidate(nl, { tool: 'Bash', input: { command: 'touch a' }, cwd: nonrepo }), 1);
  assert.equal(nl.pending[0].stale, true);

  fs.rmSync(state, { recursive: true, force: true });
  fs.rmSync(dcq, { recursive: true, force: true });
  fs.rmSync(repo, { recursive: true, force: true });
  fs.rmSync(nonrepo, { recursive: true, force: true });
});
