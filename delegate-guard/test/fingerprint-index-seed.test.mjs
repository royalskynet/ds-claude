import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { cwdFingerprint } from '../hooks/ledger.mjs';

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

function reference(cwd) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-reference-'));
  try {
    let tree;
    for (const args of [['read-tree', 'HEAD'], ['add', '-A'], ['write-tree']]) {
      const r = spawnSync('git', args, {
        cwd, encoding: 'utf8',
        env: { ...process.env, GIT_INDEX_FILE: path.join(tmp, 'index') },
      });
      if (r.status !== 0) return null;
      tree = r.stdout;
    }
    return crypto.createHash('sha256').update(tree.trim()).digest('hex');
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}

for (const scenario of ['clean', 'dirty', 'untracked', 'deleted', 'staged-but-reverted', 'staged-new', 'linked-worktree', 'split-index', 'skip-worktree', 'assume-unchanged', 'missing-index', 'unborn', 'copy-failure', 'subdir-skip-worktree', 'subdir-assume-unchanged', 'ignored-forced', 'ignored-removed', 'filemode']) {
  test(`HEAD 參考指紋一致且真 index 不變：${scenario}`, () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-index-seed-'));
    let repo = path.join(root, 'repo');
    fs.mkdirSync(repo);
    try {
      git(repo, 'init', '-q');
      git(repo, 'config', 'user.name', 'T');
      git(repo, 'config', 'user.email', 't@example.com');
      fs.writeFileSync(path.join(repo, 'a'), 'one\n');
      fs.writeFileSync(path.join(repo, 'b'), 'two\n');
      if (scenario !== 'unborn') {
        git(repo, 'add', '-A');
        git(repo, 'commit', '-qm', 'init');
      } else git(repo, 'add', '-A');
      if (scenario === 'linked-worktree') {
        git(repo, 'worktree', 'add', '-qb', 'linked', path.join(root, 'linked'));
        repo = path.join(root, 'linked');
      }
      if (['dirty', 'linked-worktree', 'staged-but-reverted'].includes(scenario)) fs.writeFileSync(path.join(repo, 'a'), 'changed\n');
      if (scenario === 'staged-but-reverted') {
        git(repo, 'add', 'a');
        fs.writeFileSync(path.join(repo, 'a'), 'one\n');
      }
      if (['untracked', 'staged-new'].includes(scenario)) fs.writeFileSync(path.join(repo, 'new'), 'new\n');
      if (scenario === 'staged-new') git(repo, 'add', 'new');
      if (scenario === 'deleted') fs.unlinkSync(path.join(repo, 'a'));
      if (scenario === 'split-index') {
        git(repo, 'config', 'core.splitIndex', 'true');
        git(repo, 'update-index', '--split-index');
        fs.writeFileSync(path.join(repo, 'a'), 'split dirty\n');
      }
      if (['skip-worktree', 'assume-unchanged'].includes(scenario)) {
        git(repo, 'update-index', `--${scenario}`, 'a');
        fs.writeFileSync(path.join(repo, 'a'), 'hidden dirty\n');
      }
      if (scenario.startsWith('subdir-')) {
        git(repo, 'update-index', `--${scenario.slice(7)}`, 'a');
        fs.writeFileSync(path.join(repo, 'a'), 'hidden outside cwd\n');
        repo = path.join(repo, 'subdir');
        fs.mkdirSync(repo);
      }
      if (scenario.startsWith('ignored-')) {
        fs.writeFileSync(path.join(repo, '.gitignore'), 'ignored\n');
        fs.writeFileSync(path.join(repo, 'ignored'), 'original\n');
        git(repo, 'add', '.gitignore');
        if (scenario === 'ignored-removed') git(repo, 'add', '-f', 'ignored');
        git(repo, 'commit', '-qm', 'ignore fixture');
        if (scenario === 'ignored-forced') git(repo, 'add', '-f', 'ignored');
        else {
          git(repo, 'rm', '--cached', 'ignored');
          fs.writeFileSync(path.join(repo, 'ignored'), 'changed ignored\n');
        }
      }
      if (scenario === 'filemode') {
        git(repo, 'config', 'core.filemode', 'false');
        git(repo, 'update-index', '--chmod=+x', 'a');
      }
      const index = path.resolve(repo, git(repo, 'rev-parse', '--git-path', 'index').trim());
      if (scenario === 'missing-index') fs.unlinkSync(index);
      const before = fs.existsSync(index) ? fs.readFileSync(index) : null;
      const shared = () => fs.readdirSync(path.dirname(index)).filter((f) => f.startsWith('sharedindex.')).sort();
      const expected = reference(repo);
      const sharedBefore = shared();
      let readTree = false;
      const options = {
        spawn(command, args, options) {
          if (args[0] === 'rev-parse') {
            assert.equal(options.env.GIT_INDEX_FILE, undefined);
            if (scenario === 'copy-failure') return { status: 0, stdout: 'missing-index\nhead\n' };
          }
          if (args.includes('read-tree') && !args.includes('-m')) readTree = true;
          const result = spawnSync(command, args, options);
          if (args.includes('read-tree') && args.includes('-m') && result.status === 0) {
            const tree = spawnSync('git', ['write-tree'], options);
            assert.equal(tree.status, 0, tree.stderr);
            assert.equal(tree.stdout.trim(), git(repo, 'rev-parse', 'HEAD^{tree}').trim());
          }
          return result;
        },
      };
      const actual = cwdFingerprint(repo, options);
      assert.equal(actual, expected);
      if (scenario === 'clean') assert.equal(readTree, false, '應使用真 index 的 stat cache');
      if (scenario.includes('skip-worktree') || scenario.includes('assume-unchanged')) assert.equal(readTree, true, '旗標仍保留時應回退');
      assert.deepEqual(fs.existsSync(index) ? fs.readFileSync(index) : null, before);
      assert.deepEqual(shared(), sharedBefore);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  });
}
