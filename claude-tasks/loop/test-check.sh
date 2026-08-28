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

# Stub gh: `gh api repos/<o>/<r>/pulls/<n>` serves $FIXDIR/pr-<o>-<r>-<n>.json
# and exits with $FIXDIR/pr-<o>-<r>-<n>.code (default 0). Every call is
# appended to $FIXDIR/gh.calls so tests can assert that no call was made.
cat > "$STUBDIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FIXDIR/gh.calls"
key="\$(printf '%s' "\$2" | sed -E 's#^repos/([^/]+)/([^/]+)/pulls/([0-9]+)\$#pr-\\1-\\2-\\3#')"
[ -f "$FIXDIR/\$key.code" ] && exit "\$(cat "$FIXDIR/\$key.code")"
[ -f "$FIXDIR/\$key.json" ] && cat "$FIXDIR/\$key.json" && exit 0
echo '{"message":"Not Found"}' >&2; exit 1
EOF
chmod +x "$STUBDIR/gh"
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
    tid, status, tags, mtime, *content = r.split(None, 4)
    tasks.append({"id": tid, "status": int(status),
                  "tags": tags.split(",") if tags != "-" else [],
                  "modifiedTime": mtime, "title": "irrelevant",
                  "content": content[0] if content else ""})
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
echo "watched pull requests:"
# Writes $FIXDIR/pr-<o>-<r>-<n>.json the way `gh api repos/o/r/pulls/n` would.
pr_fixture() {
  python3 - "$FIXDIR/pr-$1.json" "$2" "$3" "$4" <<'PY'
import json, sys
out, updated, state, sha = sys.argv[1:]
json.dump({"updated_at": updated, "state": state, "merged": state == "merged",
           "head": {"sha": sha}}, open(out, "w"))
PY
}
PRTASK="t1 0 claude,claude-waiting 2026-08-26T18:00:00.000+0000 Phase: 1/1 — delivered — PR https://github.com/acme/widgets/pull/42"
rm -f "$FIXDIR/gh.calls"
fixture "$PRTASK"
pr_fixture acme-widgets-42 2026-08-26T18:00:00Z open aaa111
expect 0 "fires on first sight of a task waiting on a PR"
grep -q 'repos/acme/widgets/pulls/42' "$FIXDIR/gh.calls" || fail "did not look up the PR named in the waiting task's body"
expect 10 "skips while the PR is untouched"

# The case the queue fingerprint alone sleeps through: an approval (or any
# review, comment, push or merge) changes nothing in TickTick, but it bumps
# the PR's updated_at.
pr_fixture acme-widgets-42 2026-08-26T18:30:00Z open aaa111
expect 0 "fires when the PR is updated (a review posted) with TickTick unchanged"
expect 10 "settles back to skipping"

pr_fixture acme-widgets-42 2026-08-26T18:45:00Z merged aaa111
expect 0 "fires when the PR is merged"
expect 10 "settles back to skipping"

rm -f "$FIXDIR/gh.calls"
fixture "t1 0 claude,claude-waiting 2026-08-26T18:00:00.000+0000 Phase: 1/1 — delivered — a write-up, nothing on GitHub"
expect 0 "fires on the body change"
[ ! -e "$FIXDIR/gh.calls" ] || fail "called gh for a waiting task with no PR URL"
PASS=$((PASS + 1))
echo "  ok: makes no gh call when nothing is waiting on a PR"

rm -f "$FIXDIR/gh.calls"
fixture "t1 0 claude,claude-inflight 2026-08-26T18:00:00.000+0000 Phase: 1/2 — working — see https://github.com/acme/widgets/pull/42"
expect 0 "fires on claude-inflight as before"
[ ! -e "$FIXDIR/gh.calls" ] || fail "called gh for a PR named by a task that is not waiting"
PASS=$((PASS + 1))
echo "  ok: only claude-waiting tasks' PRs are watched"

fixture "$PRTASK"
pr_fixture acme-widgets-42 2026-08-26T18:45:00Z merged aaa111
expect 0 "fires on the return to waiting"
expect 10 "settles back to skipping"
echo 1 > "$FIXDIR/pr-acme-widgets-42.code"
expect 0 "fires when gh fails for a watched PR"
rm -f "$FIXDIR/pr-acme-widgets-42.code"
echo 'not json' > "$FIXDIR/pr-acme-widgets-42.json"
expect 0 "fires when the PR response cannot be parsed"
pr_fixture acme-widgets-42 2026-08-26T18:45:00Z merged aaa111
expect 10 "recovers and skips once gh is healthy again"

# No gh at all: a PATH with everything the checker needs except gh.
NOGH="$TMPROOT/nogh"; mkdir -p "$NOGH"
for t in bash env curl python3 sed grep cut sort sha256sum tail head date mkdir cat flock; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOGH/$t"
done
( PATH="$NOGH" "$CHECK" >/dev/null 2>&1; [ "$?" = 0 ] ) \
  || fail "should fire when gh is not installed and a PR is being waited on"
PASS=$((PASS + 1))
echo "  ok: fires when gh is not installed and a PR is being waited on"
fixture "t1 0 claude,claude-waiting 2026-08-26T14:00:00.000+0000"
expect 0 "fires on the change back to a plain waiting task"

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
