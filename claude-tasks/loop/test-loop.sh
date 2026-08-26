#!/usr/bin/env bash
# Smoke test for claude-tasks-loop.sh's run-log behavior, using a stub
# `claude` CLI so no real API calls or TickTick/Obsidian access happen.
#
#   ./test-loop.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export XDG_STATE_HOME="$TMPROOT/state"
export XDG_RUNTIME_DIR="$TMPROOT/run"
export CLAUDE_TASKS_ROOT="$TMPROOT/projects"
mkdir -p "$CLAUDE_TASKS_ROOT" "$XDG_RUNTIME_DIR"

STUBDIR="$TMPROOT/bin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/claude" <<'EOF'
#!/usr/bin/env bash
# Stub for `claude -p ...`: pulls the run-log path out of the prompt text,
# appends a fake worked entry (as a real firing would), and reports success.
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
run_log=$(printf '%s' "$prompt" | grep -oE '/[^ ]+\.md')
if [ -z "$run_log" ]; then
  echo "stub: no run-log path found in prompt" >&2
  exit 1
fi
printf -- '- 00:00 -- [stub task](https://ticktick.com/webapp/#p/x/tasks/y) -- did the thing. Decision: used a stub.\n' >> "$run_log"
echo "stub claude ran"
echo "CLAUDE_TASKS_RESULT: worked"
EOF
chmod +x "$STUBDIR/claude"
export PATH="$STUBDIR:$PATH"

"$HERE/claude-tasks-loop.sh" "the test group" --once

LOGDIR="$XDG_STATE_HOME/claude-tasks-loop"
RUN_LOG="$(ls "$LOGDIR"/run-*.md 2>/dev/null | head -n1 || true)"

fail() { echo "FAIL: $1"; exit 1; }

[ -n "$RUN_LOG" ] || fail "no run log created under $LOGDIR"
[ "$(ls "$LOGDIR"/run-*.md | wc -l)" = 1 ] || fail "expected exactly one run log for this launch"
grep -q '^# claude-tasks loop run' "$RUN_LOG" || fail "run log missing header"
grep -q '^Scope: the test group$' "$RUN_LOG" || fail "run log missing scope line"
grep -q 'did the thing' "$RUN_LOG" || fail "firing's appended entry missing from run log"

echo "PASS"
