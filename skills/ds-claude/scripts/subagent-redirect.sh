#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook: while ds-claude is on, deny Claude subagents that a config maps to another executor.
# Config: $DS_REDIRECT_CONFIG, else ~/.config/ds-claude/redirect.json, else redirect.default.json next to this script.
# Off switch: ~/.claude/ds-claude.off (`/ds-claude off`). No jq or bad config -> allow (fail open, never blocks by accident).
in="$(cat)"
[ -f "${DS_CLAUDE_OFF_FLAG:-$HOME/.claude/ds-claude.off}" ] && exit 0
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v jq >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
cfg="${DS_REDIRECT_CONFIG:-$HOME/.config/ds-claude/redirect.json}"
[ -f "$cfg" ] || cfg="$here/redirect.default.json"
printf '%s' "$in" | jq -c --slurpfile c "$cfg" --arg skill "$(dirname "$here")" '
  $c[0] as $c | (.tool_input // {}) as $t
  | ($t.model // "" | if . == "" then "default" else . end) as $m
  | $c.rules[$m] as $r
  | if (($c.exempt_types // []) | index($t.subagent_type // "")) != null then empty
    elif (($t.prompt // "") | contains($c.keep_marker // "ds-keep")) then empty
    elif $r == null then empty
    else {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
      permissionDecisionReason: ("ds-claude: subagent model=" + $m + " -> " + $r.to + ". Run: "
        + ($r.cmd | gsub("\\{skill\\}"; $skill)) + ". " + ($c.hint // ""))}}
    end' 2>/dev/null
exit 0
