# ds-claude

**English** | [繁體中文](README.zh-TW.md)

A Claude skill that keeps Claude's hands off the keyboard. Claude writes the spec and the acceptance script. DeepSeek does the work through [OpenCode](https://opencode.ai) Go. An exit code decides whether the work passed, and Claude makes the final call.

## Why

Claude's tokens are the expensive part of most coding sessions, and much of that work is typing out a plan that is already clear. This skill moves the typing to a cheaper model and keeps Claude on the parts that need judgment.

A cheap worker needs a check it cannot talk its way past. So the acceptance script is written before the work starts, and the result comes from an exit code. The worker's own report does not count.

## How it works

```
Claude writes task/SPEC.md, task/scope.txt, task/verify.sh
   │
   ▼
ds-run.sh
   ├─ 1. refuse a dirty working tree
   ├─ 2. baseline: verify.sh must fail before any work
   ├─ 3. opencode run with DeepSeek flash
   ├─ 4. tamper check: the task files must be unchanged
   ├─ 5. scope check: every changed path must match scope.txt
   └─ 6. verify.sh from a copy taken before the worker starts, then checks 4 and 5 again
   │
   ▼
Claude reads the diff, then accepts, retries, escalates, or takes over
```

Work with secrets or personal data, and irreversible or public actions, is dispatched only after the user agrees to that job. Without agreement, Claude does it. Claude also does pure judgment calls and jobs of a single command or a one-line edit.

## Install

### Claude Code

```bash
git clone https://github.com/royalskynet/ds-claude
cp -R ds-claude/skills/ds-claude ~/.claude/skills/
npm i -g opencode-ai
opencode auth login   # choose OpenCode Go
```

### claude.ai / Cowork

1. Build the package: `cd skills && zip -r ds-claude.skill ds-claude`
2. Upload `ds-claude.skill` in the Skills section of your Claude settings.
3. Give Claude an `OPENCODE_API_KEY` when it asks. The cloud sandbox has no stored login.

## Requirements

- An [OpenCode Go](https://opencode.ai) subscription
- `git`, `bash` 3.2 or newer, and `opencode` v2 or newer
- A work directory that is the root of a git repo with at least one commit

## Usage

Ask Claude for an implementation job, or name the skill: "use ds-claude to add CSV export". Claude writes three files in the work directory.

`task/SPEC.md` holds the goal, the key decisions, and what the worker must not do:

```markdown
# Implement slug(s) in slug.py
Lowercase the string, replace every run of non-alphanumeric characters
with one hyphen, strip leading and trailing hyphens. Standard library only.
```

`task/scope.txt` lists the paths the worker may change, one glob per line. A `*` also matches across directories.

```
slug.py
```

`task/verify.sh` is the acceptance script. It runs from the work directory, and exit 0 means pass:

```bash
set -e
python3 -c "from slug import slug; assert slug('  Hello, World!! ')=='hello-world'"
```

Then Claude runs the dispatcher:

```bash
bash skills/ds-claude/scripts/ds-run.sh <workdir>
```

| Flag | Effect |
|---|---|
| `--retry` | Keep the earlier changes and tell the worker to read `task/verify.log` |
| `--pro` | Use the newest DeepSeek pro model instead of flash |
| `--no-baseline` | Skip the "must fail first" check. Use it for refactors that keep behavior |
| `--model <provider/model>` | Use a specific model |

| Environment variable | Default | Effect |
|---|---|---|
| `DS_TIMEOUT` | `900` | Worker time limit in seconds |
| `DS_MODEL` | newest flash | Same as `--model` |

### Results

| Exit | Last line | Meaning |
|---|---|---|
| 0 | `PASS` | Acceptance passed and all changes are in scope |
| 1 | `FAIL verify` | Acceptance failed. See `task/verify.log` |
| 2 | `FAIL scope` | A change is out of scope, or the worker edited a task file |
| 3 | `FAIL setup` | A precondition failed. The worker did not start |
| 4 | `FAIL worker` | opencode failed or timed out. See `task/exec.log` |

### Read-only questions

```bash
bash skills/ds-claude/scripts/ds-run.sh <workdir> --ask "question"
```

The worker reads files and writes its answer to `task/notes.md`. No task files and no git repo are needed. The script fails the run if the answer is empty or if `git status` shows a changed file.

### Order size check

Before dispatch the script refuses an order whose `SPEC.md` is over 40 lines and whose `scope.txt` has more than 2 globs, and a `verify.sh` with a bare `! cmd` line. Split the order, or pass `--no-lint`.

### When a job fails

Claude moves up one step at a time:

1. Fix the spec, if the spec caused the failure.
2. Retry once with flash.
3. Retry once with pro.
4. Take over and finish the job itself. To set the worker's changes aside first, it runs `git stash push -u -m ds-claude-rollback`, which can be restored later.

### On/off switch and subagent redirect

`/ds-claude off` turns ds-claude off until `/ds-claude on` (flag file `~/.claude/ds-claude.off`). It is on by default.

`scripts/subagent-redirect.sh` is an optional Claude Code `PreToolUse` hook for `Agent|Task`. While ds-claude is on, it denies a subagent call that its config maps to another executor and tells Claude the command to run instead, so the work does not burn Claude tokens. Out of the box, `model: sonnet` goes to `ds-run.sh` and `model: haiku` goes to `ds-run.sh --ask`. Calls without a model, and the `Explore`, `Plan`, and `statusline-setup` agents, pass.

The executor is your choice, not limited to OpenCode. Put your own map in `~/.config/ds-claude/redirect.json` (or point `DS_REDIRECT_CONFIG` at it), using `scripts/redirect.default.json` as the template:

```json
{
  "exempt_types": ["Explore"],
  "keep_marker": "ds-keep",
  "hint": "shown after the command",
  "rules": {
    "default": {"to": "my queue", "cmd": "myq add <task.md> <cwd>"},
    "sonnet":  {"to": "my queue", "cmd": "myq add <task.md> <cwd>"},
    "haiku":   {"to": "free tier", "cmd": "myq add --free <task.md> <cwd>"}
  }
}
```

`rules` keys are model names; `default` matches a call with no model. `{skill}` in `cmd` expands to the skill directory. A prompt that contains `keep_marker` passes, for work with secrets or work that needs the current session's context. No `jq` or a broken config means every call passes.

Install the hook in `~/.claude/settings.json`:

```json
{"hooks": {"PreToolUse": [{"matcher": "Agent|Task", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/ds-claude/scripts/subagent-redirect.sh"}]}]}}
```

## What the script changes on your machine

- It adds `task/` to `.git/info/exclude`, so logs stay out of your diffs.
- It writes `task/base`, `task/exec.log`, `task/verify.log`, `task/artifacts`, and `task/dispatch-log.tsv`.
- It runs `task/verify.sh` on your machine, up to twice per dispatch.
- It sets `PYTHONDONTWRITEBYTECODE=1` for the worker and `verify.sh`, so Python caches do not fail the scope check.
- It runs the worker with `opencode run --auto`, which approves tool calls without asking.
- It does not commit, push, or reset anything. The changes stay uncommitted for Claude to review.

## Warnings

- **The worker is not sandboxed.** The checks catch mistakes and shortcuts. They do not stop a worker that sets out to defeat them. In testing, `opencode run` wrote outside the repo with and without `--auto`, and `OPENCODE_PERMISSION={"external_directory":"deny"}` did not stop it. The scope check only sees changes inside the repo. Run it only where a wrong write is recoverable.
- **Your code goes to a third-party model.** Keep secrets and personal data out of dispatched work.
- **Files in `.gitignore` are invisible to the scope check.**

## Status

| Environment | State |
|---|---|
| Claude Code on macOS | Tested: a real dispatch to `opencode-go/deepseek-v4.1-flash` on opencode v2.2.5 passed |
| claude.ai / Cowork | Not tested. It needs the sandbox to install opencode with npm and to reach OpenCode |

## Works with Genie

[Genie Harness](https://github.com/royalskynet/genie-harness) was checked on a machine running both. Once ds-claude is installed, its dispatch rules win, and any Genie part that conflicts gets turned off.

- **Wheel gate: solved in Genie 0.5.8.** When ds-claude is installed, the gate skips `task/verify.sh`. Older Genie versions can refuse its first write once in a turn; writing it again works.
- **Guard: no conflict, stays on.** It also runs inside the worker when Genie's OpenCode plugin is installed. A worker's `git clean -fd` was blocked in testing, and the file stayed. It is the only safety check the worker has.
- **Rollback.** It uses `git stash` because Genie blocks `git clean -f`.
- **The word 派工.** ds-claude does not trigger on it, so it stays free for any local routing you already have.

## FAQ

**Why a script instead of a second model as reviewer?** A reviewer from the same model shares the worker's blind spots and costs a second run. A script gives the same answer every time.

**Why must `verify.sh` fail first?** A check that already passes proves nothing about the work.

**Does `opencode run` hang?** It does when stdin stays open, because it waits for end of input. `ds-run.sh` closes stdin for this reason. Use `</dev/null` if you call it yourself.

## Test

```bash
bash tests/test.sh
```

The tests run offline with a stub `opencode`. The switch and the hook have their own checks: `bash skills/ds-claude/scripts/ds-toggle-test.sh` and `bash skills/ds-claude/scripts/subagent-redirect-test.sh`.

## Related

[aashahin/claude-opencode-delegate](https://github.com/aashahin/claude-opencode-delegate) is an MCP server that gives Claude every OpenCode model as a delegate. It fits if you want many models and do not need an acceptance gate.

The routing table and the two guards in `SKILL.md` (do not switch the main model mid-task; a clear spec does not guarantee a small model is enough) are adapted from [Rajvardhman05/claude-model-router](https://github.com/Rajvardhman05/claude-model-router) (MIT).

## License

[MIT](LICENSE)
