#!/usr/bin/env bash
# Tests for claude-tasks-check.sh, using a stub `curl` on PATH so no real
# Todoist API calls happen. Every case asserts the exit status: 0 = fire,
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

# Stub curl: routes by URL — the sync endpoint serves $FIXDIR/sync.json, the
# projects listing serves $FIXDIR/projects.json, and a tasks query serves
# $FIXDIR/<project-id>.json (id from the ?project_id= parameter). Each body
# file may have a sibling .code file for the HTTP status (default 200),
# matching the -w '\n%{http_code}' shape the checker asks for.
cat > "$STUBDIR/curl" <<EOF
#!/usr/bin/env bash
url="\${@: -1}"
case "\$url" in
  */sync)         key=sync ;;
  */projects*)    key=projects ;;
  *project_id=*)  key="\$(printf '%s' "\$url" | sed -E 's/.*project_id=([^&]+).*/\1/')" ;;
  *)              key=unknown ;;
esac
body="$FIXDIR/\$key.json"
code="200"
[ -f "$FIXDIR/\$key.code" ] && code="\$(cat "$FIXDIR/\$key.code")"
if [ -f "\$body" ]; then cat "\$body"; else echo '{"results":[]}'; fi
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

PID=6hPwTestProject1
BOT=botuid1
USER_=useruid1
export TODOIST_CLAUDE_API_TOKEN=stub-token
export CLAUDE_TASKS_SECRETS="$TMPROOT/no-such-secrets"
export CLAUDE_TASKS_STATE_FILE="$TMPROOT/queue.state"
export CLAUDE_TASKS_API_BASE="https://stub.invalid/api/v1"
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

# Like expect, but also asserts that the checker's stderr contains a pattern
# (what it said about the change), so the terminal line is testable.
expect_says() {
  local want="$1" pattern="$2" why="$3" got err
  err="$("$CHECK" 2>&1 >/dev/null)"; got=$?
  [ "$got" = "$want" ] || fail "$why (wanted exit $want, got $got)"
  printf '%s\n' "$err" | grep -qE -- "$pattern" \
    || fail "$why (stderr lacks '$pattern'; got: $(printf '%s' "$err" | tr '\n' ' '))"
  PASS=$((PASS + 1))
  echo "  ok: $why"
}

# Writes $FIXDIR/sync.json: the bot's uid plus N pending share invitations.
sync_fixture() {
  python3 - "$FIXDIR/sync.json" "$BOT" "${1:-0}" <<'PY'
import json, sys
out, uid, pending = sys.argv[1], sys.argv[2], int(sys.argv[3])
ns = [{"notification_type": "share_invitation_sent", "state": "invited",
       "id": "n%d" % i} for i in range(pending)]
ns.append({"notification_type": "karma_level", "state": None, "id": "nk"})
json.dump({"user": {"id": uid}, "live_notifications": ns}, open(out, "w"))
PY
}

# Writes $FIXDIR/projects.json listing the given project ids (plus an inbox
# project, which the checker must skip).
projects_fixture() {
  python3 - "$FIXDIR/projects.json" "$@" <<'PY'
import json, sys
out, ids = sys.argv[1], sys.argv[2:]
results = [{"id": "inboxproj1", "name": "Inbox", "inbox_project": True}]
results += [{"id": i, "name": "p-" + i} for i in ids]
json.dump({"results": results, "next_cursor": None}, open(out, "w"))
PY
}

# Writes $FIXDIR/<pid>.json from lines of
# "id parent resp updated_at note_count label[,label] [description]".
# Use "-" for no parent / unassigned / no labels.
fixture() {
  python3 - "$FIXDIR/$PID.json" "$@" <<'PY'
import json, sys
out, rows = sys.argv[1], sys.argv[2:]
tasks = []
for r in rows:
    tid, parent, resp, mtime, notes, labels, *desc = r.split(None, 6)
    tasks.append({"id": tid,
                  "parent_id": None if parent == "-" else parent,
                  "responsible_uid": None if resp == "-" else resp,
                  "updated_at": mtime, "note_count": int(notes),
                  "labels": labels.split(",") if labels != "-" else [],
                  "content": "irrelevant",
                  "description": desc[0].replace("\\n", "\n") if desc else ""})
json.dump({"results": tasks, "next_cursor": None}, open(out, "w"))
PY
}

sync_fixture 0
projects_fixture "$PID"

echo "fails open on auth and sync:"
( unset TODOIST_CLAUDE_API_TOKEN
  "$CHECK" >/dev/null 2>&1
  [ "$?" = 0 ] || exit 1 ) || fail "should fire when no TODOIST_CLAUDE_API_TOKEN is available"
PASS=$((PASS + 1))
echo "  ok: fires when no TODOIST_CLAUDE_API_TOKEN is available"

echo 500 > "$FIXDIR/sync.code"
expect 0 "fires when the sync endpoint returns a non-200"
rm -f "$FIXDIR/sync.code"
echo 'not json' > "$FIXDIR/sync.json"
expect 0 "fires when the sync response cannot be parsed"
sync_fixture 0

echo
echo "pending invitations:"
sync_fixture 2
expect_says 0 '2 pending share invitation' "fires while share invitations are pending"
expect 0 "keeps firing until the invitations are handled"
sync_fixture 0

echo
echo "membership:"
projects_fixture
expect 10 "skips when no projects are shared with the account"
projects_fixture "$PID"

echo
echo "standing positives:"
fixture "t1 - $BOT 2026-08-26T10:00:00Z 0 -"
expect_says 0 'assigned to Claude with no open ask' "fires on a queued task (assigned, no ask)"
expect 0 "keeps firing while it sits unclaimed (or a crashed firing left it mid-claim)"

fixture "t1 - $BOT 2026-08-26T10:00:00Z 0 - Phase: 1/2 — working (started 2026-08-26T09:00)"
expect 0 "a claimed task with no ask is the same standing positive (crash recovery)"

fixture "t9 - - 2026-08-26T10:00:00Z 0 - Phase: 2/3 — delivered\\n\\nold body"
expect_says 0 'looks handed back' "fires on a Phase-bearing task no longer assigned to Claude"
fixture "t9 - - 2026-08-26T10:00:00Z 0 - Phase: 2/3 — delivered\\n\\n## Handing over\\ndone"
rm -f "$CLAUDE_TASKS_STATE_FILE" "${CLAUDE_TASKS_STATE_FILE%.state}.snap"
expect 0 "records a first fingerprint after the close-out"
expect 10 "a closed-out handback (## Handing over present) is nobody's business"

echo
echo "waiting tasks and the fingerprint:"
# A waiting task: assigned to the bot, with an open ask subtask assigned to
# the user. The ask's own body starts with a Phase: line (the skill's ask
# template does) — it must not read as a handback.
WAIT_ROWS=("t1 - $BOT 2026-08-26T10:00:00Z 0 - Phase: 2/4 — awaiting decision (started 2026-08-26T09:00)"
           "a1 t1 $USER_ 2026-08-26T10:05:00Z 0 - Phase: 2/4 — awaiting decision\\n\\n## What I need\\n…")
rm -f "$CLAUDE_TASKS_STATE_FILE" "${CLAUDE_TASKS_STATE_FILE%.state}.snap"
fixture "${WAIT_ROWS[@]}"
expect 0 "fires the first time, with no recorded fingerprint"
expect 10 "skips while nothing changes (and the ask's Phase: line is not a handback)"

fixture "t1 - $BOT 2026-08-26T10:00:00Z 0 - Phase: 2/4 — awaiting decision (started 2026-08-26T09:00)" \
        "a1 t1 $USER_ 2026-08-26T10:05:00Z 1 - Phase: 2/4 — awaiting decision\\n\\n## What I need\\n…"
expect_says 0 'now: a1\|useruid1\|2026-08-26T10:05:00Z\|1' \
  "fires when the user comments on the ask (note_count moves), and says so"
grep -q 'now: a1|useruid1|2026-08-26T10:05:00Z|1' "$TMPROOT/precheck.log" \
  || fail "the change was not appended to precheck.log"
grep -q 'queue unchanged' "$TMPROOT/precheck.log" \
  || fail "skip decisions are not appended to precheck.log"
PASS=$((PASS + 1))
echo "  ok: decisions and changes land in precheck.log"
expect 10 "settles back to skipping"

# Completing the ask drops it from the open-task response, leaving the work
# task assigned-with-no-ask: the standing positive covers what the old
# fingerprint had to catch.
fixture "t1 - $BOT 2026-08-26T10:00:00Z 0 - Phase: 2/4 — awaiting decision (started 2026-08-26T09:00)"
expect_says 0 'assigned to Claude with no open ask' \
  "an answered ask (completed subtask) surfaces as the standing positive"

echo
echo "not my tasks:"
rm -f "$CLAUDE_TASKS_STATE_FILE" "${CLAUDE_TASKS_STATE_FILE%.state}.snap"
fixture "${WAIT_ROWS[@]}"
expect 0 "fires with no recorded fingerprint"
expect 10 "settles back to skipping"
fixture "${WAIT_ROWS[@]}" \
        "u1 - - 2026-08-26T15:00:00Z 0 errands"
expect 10 "ignores the user's own unassigned tasks in a shared project"
fixture "${WAIT_ROWS[@]}" \
        "u1 - $USER_ 2026-08-26T16:00:00Z 2 errands"
expect 10 "ignores edits to tasks assigned to the user (that aren't asks)"

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
PR_ROWS=("t1 - $BOT 2026-08-26T18:00:00Z 0 - Phase: 1/1 — delivered — PR https://github.com/acme/widgets/pull/42"
         "a1 t1 $USER_ 2026-08-26T18:01:00Z 0 - Phase: 1/1 — delivered\\n\\nPR: https://github.com/acme/widgets/pull/42")
rm -f "$FIXDIR/gh.calls" "$CLAUDE_TASKS_STATE_FILE" "${CLAUDE_TASKS_STATE_FILE%.state}.snap"
fixture "${PR_ROWS[@]}"
pr_fixture acme-widgets-42 2026-08-26T18:00:00Z open aaa111
expect 0 "fires on first sight of a waiting task pointing at a PR"
grep -q 'repos/acme/widgets/pulls/42' "$FIXDIR/gh.calls" || fail "did not look up the PR named in the waiting task's description"
expect 10 "skips while the PR is untouched"

# The case the queue fingerprint alone sleeps through: an approval (or any
# review, comment, push or merge) changes nothing in Todoist, but it bumps
# the PR's updated_at.
pr_fixture acme-widgets-42 2026-08-26T18:30:00Z open aaa111
expect 0 "fires when the PR is updated (a review posted) with Todoist unchanged"
expect 10 "settles back to skipping"

pr_fixture acme-widgets-42 2026-08-26T18:45:00Z merged aaa111
expect 0 "fires when the PR is merged"
expect 10 "settles back to skipping"

rm -f "$FIXDIR/gh.calls"
fixture "t1 - $BOT 2026-08-26T18:00:00Z 0 - Phase: 1/1 — delivered — a write-up, nothing on GitHub" \
        "a1 t1 $USER_ 2026-08-26T18:01:00Z 0 - Phase: 1/1 — delivered"
expect 0 "fires on the body change"
[ ! -e "$FIXDIR/gh.calls" ] || fail "called gh for a waiting task with no PR URL"
PASS=$((PASS + 1))
echo "  ok: makes no gh call when nothing is waiting on a PR"

fixture "${PR_ROWS[@]}"
pr_fixture acme-widgets-42 2026-08-26T18:45:00Z merged aaa111
expect 0 "fires on the return to the PR-waiting state"
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

echo
echo "pagination:"
fixture "${WAIT_ROWS[@]}"
rm -f "$CLAUDE_TASKS_STATE_FILE" "${CLAUDE_TASKS_STATE_FILE%.state}.snap"
expect 0 "baseline fires with no fingerprint"
expect 10 "baseline settles"
# An unusable cursor (would break the URL) must fail open.
python3 - "$FIXDIR/$PID.json" <<'PY'
import json, sys
json.dump({"results": [], "next_cursor": "bad cursor&x=1"}, open(sys.argv[1], "w"))
PY
expect 0 "fires (fails open) on an unusable tasks pagination cursor"
fixture "${WAIT_ROWS[@]}"
expect 10 "recovers once the response is single-page again"

echo
echo "fails open on the tasks endpoint:"
echo 500 > "$FIXDIR/$PID.code"
expect 0 "fires when the tasks endpoint returns a non-200"
rm -f "$FIXDIR/$PID.code"
echo 'not json at all' > "$FIXDIR/$PID.json"
expect 0 "fires when the tasks response cannot be parsed"
fixture "${WAIT_ROWS[@]}"
expect 10 "recovers and skips once the API is healthy again"

echo
echo "overlap with a running firing:"
: > "$CLAUDE_TASKS_LOCK"

# A change nobody has acted on yet.
fixture "t1 - $BOT 2026-08-26T17:00:00Z 0 - Phase: 2/4 — awaiting decision (started 2026-08-26T09:00)" \
        "a1 t1 $USER_ 2026-08-26T17:05:00Z 3 - Phase: 2/4 — awaiting decision"
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
echo "PASS ($PASS assertions)"
