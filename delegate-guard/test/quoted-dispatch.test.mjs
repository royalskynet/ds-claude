// 引號內含空白的派工字樣不算派工；不含空白的引號路徑照常算派工。
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.DEGUARD_STATE = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-q-state-'));
const { gateDispatch } = await import('../hooks/ledger.mjs');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-q-wo-'));
const wo = path.join(dir, 'wo.md');
fs.writeFileSync(wo, '# t\n工作目錄：/tmp\n\n## 驗收\n\n```bash\ntest -f /tmp/x\n```\n');

test('引號內含空白的派工字樣不誤判', () => {
  const cmd = 'bash send.sh "x && DCQ_MODELS=a dcq add /tmp/wo.md /tmp"';
  assert.equal(gateDispatch({ tool: 'Bash', input: { command: cmd }, cwd: dir }), null);
});

test('不含空白的引號路徑仍算派工', () => {
  const r = gateDispatch({ tool: 'Bash', input: { command: `dcq add "${wo}"` }, cwd: '/work' });
  assert.equal(r.entries.length, 1);
  assert.equal(r.entries[0].ticket, wo);
  assert.equal(r.entries[0].cwd, '/work');
});
