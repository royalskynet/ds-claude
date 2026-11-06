# ds-claude

A Claude skill that keeps Claude's hands off the keyboard. Claude writes the spec and the acceptance script. DeepSeek does the work through [OpenCode](https://opencode.ai) Go. An exit code decides whether it passed, and Claude makes the final call.

讓 Claude 盡量不動手的 skill：Claude 寫規格和驗收腳本，DeepSeek 經 OpenCode Go 動手，exit code 判定通過與否，最後由 Claude 裁決。

```
Claude: task/SPEC.md + task/scope.txt + task/verify.sh
   │
   ▼
ds-run.sh ── baseline: verify.sh must fail before the work
   │
   ├─ opencode run (DeepSeek flash)
   ├─ scope check: every changed path must match scope.txt
   └─ verify.sh, run from a copy the worker cannot edit
   │
   ▼
Claude: read the diff, then accept, retry, escalate to pro, or take over
```

## Install

**Claude Code**

```bash
git clone https://github.com/royalskynet/ds-claude
cp -R ds-claude/skills/ds-claude ~/.claude/skills/
opencode auth login   # choose OpenCode Go
```

**claude.ai / Cowork**: upload `ds-claude.skill` from [Releases](https://github.com/royalskynet/ds-claude/releases) under Settings → Capabilities → Skills. The sandbox has no stored login, so the skill needs `OPENCODE_API_KEY`.

## Status

| Environment | State |
|---|---|
| Claude Code on macOS | Tested with a real dispatch to `opencode-go/deepseek-v4.1-flash` on opencode v2.2.5 |
| claude.ai / Cowork | Not tested. It needs the sandbox to reach opencode and to install it with npm |

## Warnings

- **The worker is not sandboxed.** `opencode run --auto` wrote outside the repo in testing, and `OPENCODE_PERMISSION={"external_directory":"deny"}` did not stop it. The scope check only sees changes inside the repo. Do not dispatch in a directory or on an account you cannot afford to have touched.
- **Your code goes to a third-party model.** Keep secrets and personal data out of dispatched work.

## Why a script instead of a second model as reviewer

A reviewer from the same model shares the worker's blind spots, and it costs a second run. `verify.sh` is written by Claude before the work starts, and it gives the same answer every time.

## Test

```bash
bash tests/test.sh
```

The tests run offline with a stub `opencode`.

## Related

[aashahin/claude-opencode-delegate](https://github.com/aashahin/claude-opencode-delegate) is an MCP server that gives Claude every OpenCode model as a delegate. Use it if you want many models and no acceptance gate.

## License

MIT
