// job 檔的 ORIG_TASK 也要能對上工單原路徑；unlinked 不得當成完工
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test('jobTask 讀 ORIG_TASK，unlinked 不算完工', async () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-job-state-'));
  const dcq = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-job-dcq-'));
  process.env.DEGUARD_STATE = state;
  process.env.DEGUARD_DCQ_HOME = dcq;
  const { onLaunched, isTerminal, stopCheck } = await import('../hooks/ledger.mjs');

  const id = '1794583085-56219-wo-job-link';
  const orig = path.join(dcq, 'tickets/orig-task.md');
  const copy = path.join(dcq, '.src/1794583085-56219/wo-job-link.md');
  fs.mkdirSync(path.join(dcq, 'running'), { recursive: true });
  fs.writeFileSync(path.join(dcq, 'running', `${id}.job`), `TASK=${copy}\nORIG_TASK=${orig}\n`);

  const p = { id: 'd1', kind: 'dcq', status: 'proposed', toolUseId: 'tu1', ticket: orig, cwd: dcq, createdAt: Date.now() };
  const l = { pending: [p], orphanStops: [] };
  const launched = onLaunched(l, { toolUseId: 'tu1', tool: 'Bash', response: `LINT OK\n${id}\n` });
  assert.ok(launched.includes(p.id), JSON.stringify(launched));
  assert.equal(p.jobId, id);
  assert.equal(p.status, 'launched');
  assert.equal(isTerminal(p), false);

  fs.mkdirSync(path.join(dcq, 'done'), { recursive: true });
  fs.renameSync(path.join(dcq, 'running', `${id}.job`), path.join(dcq, 'done', `${id}.job`));
  assert.equal(isTerminal(p), true);

  const u = { id: 'd2', kind: 'dcq', status: 'unlinked', ticket: orig, cwd: dcq, createdAt: Date.now() };
  assert.equal(isTerminal(u), false);
  const msg = stopCheck({ pending: [u], orphanStops: [] }, 'sid');
  assert.match(msg, /對不上/);
  assert.doesNotMatch(msg, /已完工/);

  fs.rmSync(state, { recursive: true, force: true });
  fs.rmSync(dcq, { recursive: true, force: true });
});
