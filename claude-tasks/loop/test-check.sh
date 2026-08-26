#!/usr/bin/env bash
# Tests for claude-tasks-check.sh, using a stub `curl` on PATH so no real
# TickTick API calls happen. Every case asserts the exit status: 0 = fire,
# 10 = skip.
#
#   ./test-check.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/claude-tasks-check.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

FIXDIR="$TMPROOT/fixtures"
STUBDIR="$TMPROOT/bin"
mkdir -p "$FIXDIR" "$STUBDIR"

# Stub curl: serves $FIXDIR/<project-id>.json, with the HTTP code taken from
# $FIXDIR/<project-id>.code (default 200), in the -w '\n%{http_code}' shape
# the checker asks for.
cat > "$STUBDIR/curl" <<EOF
#!/usr/bin/env bash
url="\${@: -1}"
pid="\$(basename "\$(dirname "\$url")")"
body="$FIXDIR/\$pid.json"
code="200"
[ -f "$FIXDIR/\$pid.code" ] && code="\$(cat "$FIXDIR/\$pid.code")"
if [ -f "\$body" ]; then cat "\$body"; else echo '{"tasks":[]}'; fi
printf '\n%s' "\$code"
EOF
chmod +x "$STUBDIR/curl"
export PATH="$STUBDIR:$PATH"

PID=6a8f04098f086ae6e27e1e74
export TICKTICK_API_TOKEN=stub-token
export CLAUDE_TASKS_SECRETS="$TMPROOT/no-such-secrets"
export CLAUDE_TASKS_SCOPE="the test group"
export CLAUDE_TASKS_SCOPE_FILE="$TMPROOT/scope.ids"
export CLAUDE_TASKS_STATE_FILE="$TMPROOT/queue.state"
export CLAUDE_TASKS_API_BASE="https://stub.invalid/open/v1"
# Never let the tests touch (or be blocked by) a real loop's lockfile.
export CLAUDE_TASKS_LOCK="$TMPROOT/loop.lock"

PASS=0
fail() { echo "FAIL: $1"; exit 1; }

# Runs the checker and asserts its exit status. 0 = fire, 10 = skip.
expect() {
  local want="$1" why="$2" got
  "$CHECK" >/dev/null 2>&1; got=$?
  [ "$got" = "$want" ] || fail "$why (wanted exit $want, got $got)"
  PASS=$((PASS + 1))
  echo "  ok: $why"
}

# Writes $FIXDIR/<pid>.json from lines of "id status tag[,tag] modifiedTime".
fixture() {
  python3 - "$FIXDIR/$PID.json" "$@" <<'PY'
import json, sys
out, rows = sys.argv[1], sys.argv[2:]
tasks = []
for r in rows:
    tid, status, tags, mtime = r.split()
    tasks.append({"id": tid, "status": int(status),
                  "tags": tags.split(",") if tags != "-" else [],
                  "modifiedTime": mtime, "title": "irrelevant"})
json.dump({"project": {"id": "p"}, "tasks": tasks, "columns": []}, open(out, "w"))
PY
}

echo "no resolved scope yet:"
expect 0 "fires when the scope file does not exist"

printf '%s\n%s\n' "a different scope" "$PID" > "$CLAUDE_TASKS_SCOPE_FILE"
expect 0 "fires when the scope file was resolved from a different scope"

printf '%s\n%s\n' "$CLAUDE_TASKS_SCOPE" "not-a-project-id" > "$CLAUDE_TASKS_SCOPE_FILE"
expect 0 "fires when the scope file lists no usable project ids"

printf '%s\n%s\n' "$CLAUDE_TASKS_SCOPE" "$PID" > "$CLAUDE_TASKS_SCOPE_FILE"

echo
echo "fingerprint:"
fixture "t1 0 claude,claude-waiting 2026-08-26T10:00:00.000+0000"
expect 0 "fires the first time, with no recorded fingerprint"
expect 10 "skips when nothing has changed since the last check"

fixture "t1 0 claude,claude-waiting 2026-08-26T11:00:00.000+0000"
expect 0 "fires when a task's modifiedTime moves (a comment or body edit)"
expect 10 "settles back to skipping"

fixture "t1 0 claude,claude-waiting 2026-08-26T11:00:00.000+0000" \
        "t2 0 claude-needs-you 2026-08-26T11:05:00.000+0000"
expect 0 "fires when a task appears (a new ask subtask or task)"
expect 10 "settles back to skipping"

# The case a modifiedTime watermark would have missed: completing an ask
# subtask drops it from the API response entirely, and does NOT bump its
# parent's modifiedTime. A set fingerprint catches the disappearance.
fixture "t1 0 claude,claude-waiting 2026-08-26T11:00:00.000+0000"
expect 0 "fires when a task disappears (an ask subtask the user completed)"
expect 10 "settles back to skipping"

echo
echo "standing positives:"
fixture "t1 0 claude,claude-ready 2026-08-26T12:00:00.000+0000"
expect 0 "fires on the change to claude-ready"
expect 0 "keeps firing while a claude-ready task sits unclaimed"

fixture "t1 0 claude,claude-inflight 2026-08-26T12:00:00.000+0000"
expect 0 "fires on the change to claude-inflight"
expect 0 "keeps firing while a claude-inflight task is unfinished"

# Firing on a standing positive deliberately does not record a fingerprint,
# so a queue that returns to a state already fired on stays quiet rather than
# firing a second time for the same state.
fixture "t1 0 claude,claude-waiting 2026-08-26T11:00:00.000+0000"
expect 10 "does not re-fire on a state it has already fired on"

echo
echo "not my tasks:"
rm -f "$CLAUDE_TASKS_STATE_FILE"
fixture "t1 0 claude,claude-waiting 2026-08-26T14:00:00.000+0000"
expect 0 "fires with no recorded fingerprint"
expect 10 "settles back to skipping"
fixture "t1 0 claude,claude-waiting 2026-08-26T14:00:00.000+0000" \
        "u1 0 errands 2026-08-26T15:00:00.000+0000"
expect 10 "ignores the user's own untagged tasks in a shared list"
fixture "t1 0 claude,claude-waiting 2026-08-26T14:00:00.000+0000" \
        "u1 0 errands 2026-08-26T16:00:00.000+0000"
expect 10 "ignores edits to the user's own tasks in a shared list"

echo
echo "fails open:"
echo 500 > "$FIXDIR/$PID.code"
expect 0 "fires when the API returns a non-200"
rm -f "$FIXDIR/$PID.code"

echo 'not json at all' > "$FIXDIR/$PID.json"
expect 0 "fires when the response cannot be parsed"

fixture "t1 0 claude,claude-waiting 2026-08-26T14:00:00.000+0000"
expect 10 "recovers and skips once the API is healthy again"

( unset TICKTICK_API_TOKEN
  "$CHECK" >/dev/null 2>&1
  [ "$?" = 0 ] || exit 1 ) || fail "should fire when no TICKTICK_API_TOKEN is available"
PASS=$((PASS + 1))
echo "  ok: fires when no TICKTICK_API_TOKEN is available"

echo
echo "overlap with a running firing:"
: > "$CLAUDE_TASKS_LOCK"

# A change nobody has acted on yet.
fixture "t1 0 claude,claude-waiting 2026-08-26T17:00:00.000+0000"
BEFORE_STATE="$(cat "$CLAUDE_TASKS_STATE_FILE" 2>/dev/null || true)"

# Hold the lock the way a firing does, and check from "another loop".
exec 7>"$CLAUDE_TASKS_LOCK"
flock -n 7 || fail "could not take the test lock"
expect 10 "skips while another firing holds the lock"
# The important half: it must not have fingerprinted the change as handled,
# or the firing that never ran would be silently written off.
[ "$(cat "$CLAUDE_TASKS_STATE_FILE" 2>/dev/null || true)" = "$BEFORE_STATE" ] \
  || fail "recorded a fingerprint for a change it skipped over -- that change would be lost"
PASS=$((PASS + 1))
echo "  ok: records nothing while the lock is held"
exec 7>&-

expect 0 "fires once the lock is free again"

rm -f "$CLAUDE_TASKS_LOCK"
expect 10 "treats a missing lockfile as nobody firing"

echo
echo "per-scope state:"
# Two loops over different scopes must not share files, or each sees the
# other's scope, fails open, and quietly loses the pre-check for good.
unset CLAUDE_TASKS_SCOPE_FILE CLAUDE_TASKS_STATE_FILE
KEY_OF() { CLAUDE_TASKS_SCOPE="$1" bash -c 'printf "%s" "$CLAUDE_TASKS_SCOPE" | sha256sum | cut -c1-12'; }
[ "$(KEY_OF "the work group")" != "$(KEY_OF "the life group")" ] \
  || fail "two different scopes derive the same state-file key"
[ "$(KEY_OF "the work group")" = "$(KEY_OF "the work group")" ] \
  || fail "the same scope derives an unstable state-file key"
PASS=$((PASS + 1))
echo "  ok: state paths are keyed by scope"

echo
echo "PASS ($PASS assertions)"
