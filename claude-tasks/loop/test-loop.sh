#!/usr/bin/env bash
# Smoke test for claude-tasks-loop.sh's run-note plumbing, using a stub
# `claude` CLI so no real API calls or TickTick/Obsidian access happen.
#
# The script itself can't write the run note (it lives in the vault, and only
# a firing's Obsidian MCP tools can reach it) -- this test only checks that
# the script computes a sane vault path and a real launch-start timestamp and
# hands both to the firing via the prompt, and that it no longer writes any
# local run-log file (that behavior moved into the vault note).
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

CAPTURED_PROMPT="$TMPROOT/captured-prompt.txt"
STUBDIR="$TMPROOT/bin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/claude" <<EOF
#!/usr/bin/env bash
# Stub for \`claude -p ...\`: just captures the prompt so the test can
# inspect what the script handed the firing, then reports success.
prompt=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -p) prompt="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "\$prompt" > "$CAPTURED_PROMPT"
echo "stub claude ran"
echo "CLAUDE_TASKS_RESULT: worked"
EOF
chmod +x "$STUBDIR/claude"
export PATH="$STUBDIR:$PATH"

BEFORE="$(date -Is)"
"$HERE/claude-tasks-loop.sh" "the test group" --once
AFTER="$(date -Is)"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$CAPTURED_PROMPT" ] || fail "stub claude never ran / prompt not captured"

RUN_NOTE="$(grep -oE 'claude-loops/[^ ]+\.md' "$CAPTURED_PROMPT" || true)"
[ -n "$RUN_NOTE" ] || fail "prompt has no claude-loops/*.md vault path"

LAUNCH_STARTED="$(grep -oE 'started at [^.]+' "$CAPTURED_PROMPT" | sed 's/started at //' || true)"
[ -n "$LAUNCH_STARTED" ] || fail "prompt has no launch-start timestamp"
# Sanity: it's a real ISO-8601 timestamp from `date`, not a placeholder, and
# falls within this test run's own wall-clock window.
[[ "$LAUNCH_STARTED" > "$BEFORE" || "$LAUNCH_STARTED" == "$BEFORE" ]] || fail "launch timestamp $LAUNCH_STARTED predates the test run"
[[ "$LAUNCH_STARTED" < "$AFTER" || "$LAUNCH_STARTED" == "$AFTER" ]] || fail "launch timestamp $LAUNCH_STARTED is after the test run"

LOGDIR="$XDG_STATE_HOME/claude-tasks-loop"
[ -n "$(ls "$LOGDIR"/*.log 2>/dev/null || true)" ] || fail "expected a session .log under $LOGDIR"
[ -z "$(ls "$LOGDIR"/run-*.md 2>/dev/null || true)" ] || fail "found a local run-*.md -- run notes now live in the vault, not $LOGDIR"

# The firing is what resolves the English scope to project ids, so the prompt
# has to tell it where to record them for the pre-check to read.
SCOPE_KEY="$(printf '%s' "the test group" | sha256sum | cut -c1-12)"
grep -q "$LOGDIR/scope-$SCOPE_KEY.ids" "$CAPTURED_PROMPT" || fail "prompt does not name the per-scope scope-ids file"
grep -q 'first line' "$CAPTURED_PROMPT" || fail "prompt does not say what to write into the scope-ids file"

# --- pre-check ------------------------------------------------------------
# A stub pre-check stands in for claude-tasks-check.sh so this test covers the
# loop's own branching (skip vs fire) rather than the checker's logic, which
# test-check.sh covers.
CHECKSTUB="$TMPROOT/check-stub.sh"
export CLAUDE_TASKS_CHECK="$CHECKSTUB"
stub_check() { printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$CHECKSTUB"; chmod +x "$CHECKSTUB"; }

# Runs the real loop (not --once) for a few ticks, then stops it. A firing
# leaves $CAPTURED_PROMPT behind; a skipped tick leaves nothing.
loop_briefly() {
  rm -f "$CAPTURED_PROMPT"
  "$HERE/claude-tasks-loop.sh" "the test group" 1s 1s >/dev/null 2>&1 &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

stub_check 10
loop_briefly
if [ -f "$CAPTURED_PROMPT" ]; then fail "pre-check said skip (exit 10) but a firing happened anyway"; fi

stub_check 0
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "pre-check said fire (exit 0) but no firing happened"

# Only exit 10 means skip: a broken checker must not silently stall the loop.
stub_check 3
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "a pre-check that failed (exit 3) should fire, not skip"

export CLAUDE_TASKS_CHECK="$TMPROOT/does-not-exist.sh"
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "a missing pre-check script should fire, not skip"

export CLAUDE_TASKS_CHECK="$CHECKSTUB"
stub_check 10
export CLAUDE_TASKS_PRECHECK=0
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "CLAUDE_TASKS_PRECHECK=0 should fire on every tick"
unset CLAUDE_TASKS_PRECHECK

# --once is an explicit "run now", so it never consults the pre-check.
rm -f "$CAPTURED_PROMPT"
"$HERE/claude-tasks-loop.sh" "the test group" --once >/dev/null 2>&1
[ -f "$CAPTURED_PROMPT" ] || fail "--once should fire regardless of the pre-check"

# --- overlap ---------------------------------------------------------------
# A firing turned away by the lock never happened, so anything the pre-check
# fingerprinted on its way in must not survive as "handled" -- otherwise a
# change swallowed by the lock is lost for good.
STATE_FILE="$LOGDIR/queue-$SCOPE_KEY.state"
echo "a-fingerprint-for-a-change-nobody-acted-on" > "$STATE_FILE"

exec 8>"$XDG_RUNTIME_DIR/claude-tasks-loop.lock"
flock -n 8 || fail "could not take the test lock"
stub_check 0
loop_briefly
exec 8>&-

if [ -f "$CAPTURED_PROMPT" ]; then fail "fired while another firing held the lock"; fi
if [ -f "$STATE_FILE" ]; then fail "kept the pre-check fingerprint after the lock turned the firing away"; fi

echo "PASS"
