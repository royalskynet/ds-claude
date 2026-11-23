// gateDispatch: `dcq add <wo> 2>&1` must not record the redirect token `2>` as the job cwd.
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.DEGUARD_STATE = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-state-'));
const { gateDispatch } = await import('../hooks/ledger.mjs');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-wo-'));
const wo = path.join(dir, 'wo.md');
fs.writeFileSync(wo, '# t\n工作目錄：/tmp\n\n## 驗收\n\n```bash\ntest -f /tmp/x\n```\n');

test('redirect after ticket path is not taken as cwd', () => {
  for (const tail of ['2>&1 | tail -3', '2>/dev/null', '>/tmp/log', '<in']) {
    const r = gateDispatch({ tool: 'Bash', input: { command: `dcq add ${wo} ${tail}` }, cwd: '/work' });
    assert.equal(r.entries[0].cwd, '/work', tail);
  }
});

test('only command-position dcq add counts as dispatch', () => {
  for (const c of [`dcq add ${wo}`, `cd /x && dcq add ${wo}`, `A=1 B=2 dcq add ${wo}`, `true; dcq add ${wo}`]) {
    assert.equal(gateDispatch({ tool: 'Bash', input: { command: c }, cwd: '/work' })?.entries?.length, 1, c);
  }
  for (const c of ['git commit -m "fix: dcq add 後面的重導向"', 'echo see dcq add docs']) {
    assert.equal(gateDispatch({ tool: 'Bash', input: { command: c }, cwd: '/work' }), null, c);
  }
});

test('explicit cwd argument is still recorded', () => {
  const r = gateDispatch({ tool: 'Bash', input: { command: `dcq add ${wo} /repo 2>&1` }, cwd: '/work' });
  assert.equal(r.entries[0].cwd, '/repo');
});
