#!/usr/bin/env bash
# subagent-redirect.sh check: default config, custom executor config, exemptions, keep marker, off switch.
set -euo pipefail
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude"
H="$(cd "$(dirname "$0")" && pwd)/subagent-redirect.sh"
run() { printf '%s' "$1" | HOME="$T" bash "$H"; }
fail() { echo "FAIL: $*"; exit 1; }
run '{"tool_input":{"model":"sonnet","prompt":"x"}}' | grep -q '"deny".*ds-run.sh <workdir>' || fail "sonnet not redirected to ds-run"
run '{"tool_input":{"model":"haiku","prompt":"x"}}' | grep -q -- '--ask' || fail "haiku not redirected to --ask"
run '{"tool_input":{"model":"haiku"}}' | grep -q '{skill}' && fail "{skill} not expanded"
[ -z "$(run '{"tool_input":{"prompt":"x"}}')" ] || fail "no-model should pass with default config"
[ -z "$(run '{"tool_input":{"subagent_type":"Explore","model":"haiku"}}')" ] || fail "Explore should pass"
[ -z "$(run '{"tool_input":{"model":"sonnet","prompt":"has secrets ds-keep"}}')" ] || fail "keep marker should pass"
mkdir -p "$T/.config/ds-claude"
cat > "$T/.config/ds-claude/redirect.json" <<'J'
{"exempt_types":["o-worker"],"keep_marker":"KEEP","rules":{"default":{"to":"my-runner","cmd":"myq add <task>"},"sonnet":{"to":"my-runner","cmd":"myq add <task>"}}}
J
run '{"tool_input":{"prompt":"x"}}' | grep -q 'myq add' || fail "custom config: no-model not redirected"
run '{"tool_input":{"subagent_type":"Explore","prompt":"x"}}' | grep -q 'myq add' || fail "custom exempt list not used"
[ -z "$(run '{"tool_input":{"model":"haiku","prompt":"x"}}')" ] || fail "unmapped model should pass"
[ -z "$(run '{"tool_input":{"model":"sonnet","prompt":"KEEP"}}')" ] || fail "custom keep marker ignored"
echo '{broken' > "$T/.config/ds-claude/redirect.json"
[ -z "$(run '{"tool_input":{"model":"sonnet","prompt":"x"}}')" ] || fail "bad config should fail open"
rm "$T/.config/ds-claude/redirect.json"
: > "$T/.claude/ds-claude.off"
[ -z "$(run '{"tool_input":{"model":"sonnet","prompt":"x"}}')" ] || fail "off flag should pass"
echo "PASS subagent-redirect"
