// 派工憑證（p-*.md／p-*.sh）寫完要是唯讀，事後 Write／Edit／`>` 改不了
import { test } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test('gateDispatch 寫出的 p-* 憑證是 0444', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-pin-'));
  process.env.DEGUARD_STATE = dir;
  const { gateDispatch } = await import('../hooks/ledger.mjs');
  const prompt = '工作目錄：/tmp\n\n## 驗收\n\n```bash\ntest -f /tmp/dg-pin-never-exists\n```\n';
  const r = gateDispatch({ tool: 'Agent', input: { subagent_type: 'o-worker', prompt } });
  assert.ok(r && r.entries, JSON.stringify(r));
  const { ticket, snapshot } = r.entries[0];
  for (const f of [ticket, snapshot]) {
    assert.equal(fs.statSync(f).mode & 0o777, 0o444, f);
    assert.throws(() => fs.writeFileSync(f, 'tampered'), /EACCES/, f);
  }
  fs.rmSync(dir, { recursive: true, force: true });
});
