#!/usr/bin/env bash
# Cheap pre-check for claude-tasks-loop.sh: decide whether a firing could
# possibly have anything to do, without spending a single token.
#
#   claude-tasks-check.sh          # exit 0 = fire, exit 10 = skip this firing
#
# It does NOT reimplement the skill's rules for what counts as a candidate.
# It answers a deliberately coarser question -- "could anything possibly have
# changed?" -- and is wrong only in the safe direction. The asymmetry is the
# whole design:
#
#   * saying "skip" when there IS work loses a task (real harm), so every
#     uncertainty -- no token, an HTTP error, an unparseable response --
#     exits 0 and fires;
#   * saying "fire" when there is nothing costs exactly one ordinary firing,
#     which is what happened on every tick before this script existed.
#
# It runs with CLAUDE'S OWN Todoist token (the Coddingtonbot account), so the
# queue is discovered rather than configured: the projects are whatever is
# shared with that account, and the tasks that matter are the ones assigned
# to it. No scope argument, no state flowing from the firings to the check.
#
# Fires when any of these hold:
#   1. it cannot tell (see above)
#   2. a share invitation is pending (a new project is the user saying
#      "work here too")
#   3. a task assigned to Claude has no open ask subtask -- released work
#      nobody picked up, or a firing that crashed mid-claim; either way the
#      skill should look at it (standing positive: keeps firing until the
#      state changes)
#   4. a task bearing the skill's `Phase:` line is no longer assigned to
#      Claude and has no `## Handing over` section -- the user took it back
#      and the close-out hasn't run (standing positive)
#   5. the fingerprint of Claude's assigned tasks and their ask subtasks
#      differs from the previous check's -- covering a user comment on an ask
#      (note_count), a description edit (updated_at), and a change of ask
#   6. a pull request a Waiting task points at has changed since the previous
#      check -- a review, a comment, a push, a merge or close. The PRs come
#      from the `github.com/<owner>/<repo>/pull/<n>` URLs in those tasks'
#      descriptions (the skill's `Phase: ... delivered -- PR <url>` line);
#      each is one `gh api` call, its `updated_at` folded into the same
#      fingerprint. Deliberately coarse: Claude's own pushes and replies bump
#      it too, costing one idle firing, the same price its Todoist writes
#      already pay.
#
# A completed ask subtask needs no special case any more: completing it
# leaves the work task assigned-with-no-open-ask, which is standing
# positive 3.
#
# Environment:
#   TODOIST_CLAUDE_API_TOKEN  Coddingtonbot's Todoist API token; sourced from
#                             CLAUDE_TASKS_SECRETS when not already set
#   gh                        the GitHub CLI, logged in with read access to
#                             the watched repos (the user's own login is fine:
#                             the pre-check only reads); missing or failing
#                             => fire, like every other uncertainty
#   CLAUDE_TASKS_SECRETS      shell-sourceable secrets file (default ~/.secrets)
#   CLAUDE_TASKS_STATE_FILE   where the queue fingerprint is kept. The
#                             snapshot the fingerprint was taken of lives
#                             beside it (`.snap` for `.state`), and every
#                             decision is appended to precheck.log in the
#                             same directory
#   CLAUDE_TASKS_LOCK         the loop's lockfile; a tick is skipped outright
#                             while another firing holds it
#   CLAUDE_TASKS_API_BASE     API base (default Todoist's unified v1;
#                             overridden by tests)
set -uo pipefail

LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tasks-loop"
API="${CLAUDE_TASKS_API_BASE:-https://api.todoist.com/api/v1}"
SECRETS="${CLAUDE_TASKS_SECRETS:-$HOME/.secrets}"
LOCK="${CLAUDE_TASKS_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/claude-tasks-loop.lock}"
STATE_FILE="${CLAUDE_TASKS_STATE_FILE:-$LOGDIR/queue.state}"
# The sorted snapshot behind the fingerprint, kept so a "changed" verdict can
# say *what* changed instead of only that the hash moved.
SNAP_FILE="${STATE_FILE%.state}.snap"
# Every decision, and the change it saw, also lands here: the loop only shows
# this script's stderr on the terminal, which scrolls away.
PRECHECK_LOG="$(dirname "$STATE_FILE")/precheck.log"

say()  {
  echo "$(date -Is) precheck: $1" >&2
  { mkdir -p "$(dirname "$PRECHECK_LOG")" && echo "$(date -Is) $1" >> "$PRECHECK_LOG"; } 2>/dev/null || true
}
fire() { say "$1 -> firing"; exit 0; }
skip() { say "$1 -> skipping (no tokens spent)"; exit 10; }

command -v curl    >/dev/null 2>&1 || fire "curl not found"
command -v python3 >/dev/null 2>&1 || fire "python3 not found"

# If a firing already holds the loop's lock there is nothing this tick can do
# but wait -- and firing anyway would be worse than useless: the loop's own
# flock would turn it away *after* this script had already recorded a
# fingerprint, marking as handled a change nobody acted on. Bail out before
# touching the API or the state file. The lock is released again immediately
# so a real firing is never held up by a pre-check.
if [ -e "$LOCK" ] && command -v flock >/dev/null 2>&1; then
  flock -n "$LOCK" true || skip "a firing is already running"
fi

if [ -z "${TODOIST_CLAUDE_API_TOKEN:-}" ] && [ -r "$SECRETS" ]; then
  set -a; . "$SECRETS" >/dev/null 2>&1 || true; set +a
fi
[ -n "${TODOIST_CLAUDE_API_TOKEN:-}" ] || fire "no TODOIST_CLAUDE_API_TOKEN"

AUTH="Authorization: Bearer $TODOIST_CLAUDE_API_TOKEN"

# --- who am I, and is anything pending? ------------------------------------
# One sync call yields both the account's own uid (so nothing is hardcoded)
# and the live notifications, where pending share invitations appear.
SYNC_PARSE='
import json, sys
d = json.load(sys.stdin)
print("uid|%s" % d["user"]["id"])
pending = [n for n in d.get("live_notifications") or []
           if n.get("notification_type") == "share_invitation_sent"
           and n.get("state") == "invited"]
print("pending|%d" % len(pending))
'
RESP="$(curl -sS -m 30 -w $'\n%{http_code}' -X POST -H "$AUTH" \
          -H 'Content-Type: application/json' \
          -d '{"sync_token":"*","resource_types":["user","live_notifications"]}' \
          "$API/sync" 2>/dev/null)" || fire "sync request failed"
CODE="$(printf '%s' "$RESP" | tail -n1)"
[ "$CODE" = 200 ] || fire "HTTP $CODE from sync"
SYNC_OUT="$(printf '%s' "$RESP" | sed '$d' | python3 -c "$SYNC_PARSE")" || fire "unparseable sync response"
UID_="$(printf '%s\n' "$SYNC_OUT" | sed -n 's/^uid|//p')"
PENDING="$(printf '%s\n' "$SYNC_OUT" | sed -n 's/^pending|//p')"
[ -n "$UID_" ] || fire "sync response carried no user id"
[ "${PENDING:-0}" = 0 ] || fire "$PENDING pending share invitation(s)"

# --- the projects shared with this account ---------------------------------
PROJ_PARSE='
import json, sys
d = json.load(sys.stdin)
for p in d.get("results") or []:
    if p.get("inbox_project"):
        continue
    print("proj|%s" % p.get("id"))
print("next|%s" % (d.get("next_cursor") or ""))
'
IDS=""
CURSOR=""
while :; do
  URL="$API/projects?limit=200${CURSOR:+&cursor=$CURSOR}"
  RESP="$(curl -sS -m 30 -w $'\n%{http_code}' -H "$AUTH" "$URL" 2>/dev/null)" || fire "projects request failed"
  CODE="$(printf '%s' "$RESP" | tail -n1)"
  [ "$CODE" = 200 ] || fire "HTTP $CODE listing projects"
  LINES="$(printf '%s' "$RESP" | sed '$d' | python3 -c "$PROJ_PARSE")" || fire "unparseable projects response"
  IDS="$IDS$(printf '%s\n' "$LINES" | sed -n 's/^proj|//p')"$'\n'
  CURSOR="$(printf '%s\n' "$LINES" | sed -n 's/^next|//p' | tail -n1)"
  case "$CURSOR" in
    "") break ;;
    *[!A-Za-z0-9=_-]*) fire "unusable projects pagination cursor" ;;
  esac
done
IDS="$(printf '%s' "$IDS" | grep -E '^[A-Za-z0-9]{8,64}$' || true)"
[ -n "$IDS" ] || skip "no projects are shared with this account"

# --- every open task in those projects, as raw rows ------------------------
# t|<id>|<parent or ->|<responsible uid or ->|<updated_at>|<note_count>|,labels,|<flags>
#   flags: P = description carries a "Phase:" line, H = a "## Handing over"
#   section; both are the skill's own markers.
# r|<task id>|<owner>/<repo>/<n> per PR URL found in a description.
EXTRACT='
import json, re, sys
d = json.load(sys.stdin)
PR = re.compile(r"https?://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
for t in d.get("results") or []:
    desc = t.get("description") or ""
    labels = sorted(str(x) for x in (t.get("labels") or []))
    flags = ""
    if re.search(r"^Phase:", desc, re.M): flags += "P"
    if re.search(r"^## Handing over", desc, re.M): flags += "H"
    print("t|%s|%s|%s|%s|%s|,%s,|%s" % (
        t.get("id"), t.get("parent_id") or "-", t.get("responsible_uid") or "-",
        t.get("updated_at"), t.get("note_count"), ",".join(labels), flags or "-"))
    for o, r, n in sorted(set(PR.findall(desc))):
        print("r|%s|%s/%s/%s" % (t.get("id"), o, r, n))
print("next|%s" % (d.get("next_cursor") or ""))
'
ROWS=""
for pid in $IDS; do
  CURSOR=""
  while :; do
    URL="$API/tasks?project_id=$pid&limit=200${CURSOR:+&cursor=$CURSOR}"
    RESP="$(curl -sS -m 30 -w $'\n%{http_code}' -H "$AUTH" "$URL" 2>/dev/null)" || fire "request failed for project $pid"
    CODE="$(printf '%s' "$RESP" | tail -n1)"
    [ "$CODE" = 200 ] || fire "HTTP $CODE for project $pid"
    LINES="$(printf '%s' "$RESP" | sed '$d' | python3 -c "$EXTRACT")" || fire "unparseable response for project $pid"
    ROWS="$ROWS$(printf '%s\n' "$LINES" | grep -v '^next|' || true)"$'\n'
    CURSOR="$(printf '%s\n' "$LINES" | sed -n 's/^next|//p' | tail -n1)"
    case "$CURSOR" in
      "") break ;;
      *[!A-Za-z0-9=_-]*) fire "unusable pagination cursor for project $pid" ;;
    esac
  done
done

# --- classify against the skill's states -----------------------------------
# Standing positives come out as fire| lines; the fingerprint of the tasks
# worth watching (Claude's tasks and their asks) as snap| lines; the PRs the
# Waiting tasks point at as pr| lines.
CLASSIFY='
import sys
uid = sys.argv[1]
tasks, prs = {}, {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("t|"):
        _, tid, parent, resp, updated, notes, labels, flags = line.split("|")
        tasks[tid] = dict(parent=parent, resp=resp, updated=updated,
                          notes=notes, labels=labels, flags=flags)
    elif line.startswith("r|"):
        _, tid, ref = line.split("|")
        prs.setdefault(tid, set()).add(ref)
mine = {tid for tid, t in tasks.items() if t["resp"] == uid}
asks = {}  # work task id -> open ask subtask ids
for tid, t in tasks.items():
    if t["parent"] in mine and t["resp"] != uid:
        asks.setdefault(t["parent"], []).append(tid)
for tid in sorted(mine):
    if tid not in asks:
        print("fire|task %s is assigned to Claude with no open ask" % tid)
for tid, t in sorted(tasks.items()):
    if (t["resp"] != uid and "P" in t["flags"] and "H" not in t["flags"]
            and t["parent"] not in mine and tid not in mine):
        print("fire|task %s looks handed back and not closed out" % tid)
watched = sorted(mine) + sorted(x for xs in asks.values() for x in xs)
for tid in watched:
    t = tasks[tid]
    print("snap|%s|%s|%s|%s|%s" % (tid, t["resp"], t["updated"], t["notes"], t["labels"]))
for tid in sorted(mine):
    if tid in asks:
        for ref in sorted(prs.get(tid, ())):
            print("pr|%s" % ref)
'
CLASSIFIED="$(printf '%s' "$ROWS" | python3 -c "$CLASSIFY" "$UID_")" || fire "classification failed"

# A standing positive fires without recording a fingerprint, so a queue that
# stays in a state already fired on keeps firing until a firing changes it --
# a crashed firing can never be fingerprinted into silence.
FIRST_FIRE="$(printf '%s\n' "$CLASSIFIED" | sed -n 's/^fire|//p' | head -n1)"
[ -z "$FIRST_FIRE" ] || fire "$FIRST_FIRE"

SNAP="$(printf '%s\n' "$CLASSIFIED" | sed -n 's/^snap|//p')"
PRS="$(printf '%s\n' "$CLASSIFIED" | sed -n 's/^pr|//p')"

# The pull requests the queue is waiting on. One `gh api` call each; what
# matters is that *anything* about the PR moved since the last check, and
# `updated_at` covers reviews, comments, pushes, merges and closes alike.
# Read straight from the JSON rather than via --jq so an unexpected shape
# fails loudly (and fires) instead of hashing an empty string.
PR_LINE='
import json, sys
p = json.load(sys.stdin)
print("pr|%s|%s|%s|%s" % (p["updated_at"], p["state"], p.get("merged"), p["head"]["sha"]))
'
for ref in $(printf '%s\n' "$PRS" | LC_ALL=C sort -u); do
  command -v gh >/dev/null 2>&1 || fire "gh not found, and the queue is waiting on PR $ref"
  o="${ref%%/*}"; rest="${ref#*/}"; r="${rest%%/*}"; n="${rest#*/}"
  BODY="$(gh api "repos/$o/$r/pulls/$n" 2>/dev/null)" || fire "gh api failed for PR $ref"
  LINE="$(printf '%s' "$BODY" | python3 -c "$PR_LINE" 2>/dev/null)" || fire "unparseable response for PR $ref"
  SNAP="$SNAP"$'\n'"$ref|$LINE"
done

SORTED="$(printf '%s\n' "$SNAP" | grep -v '^$' | LC_ALL=C sort)"
NOW="$(printf '%s' "$SORTED" | sha256sum | cut -d' ' -f1)"
WAS="$(cat "$STATE_FILE" 2>/dev/null || true)"

if [ "$NOW" = "$WAS" ]; then
  skip "queue unchanged"
fi

# Say what moved, line by line, before firing. Task lines read
# id|responsible|updated_at|note_count|,labels,; PR lines read
# owner/repo/n|pr|updated_at|state|merged|head sha. A line only under "was"
# vanished; only under "now" is new; a pair is an edit, a comment, or PR
# activity.
if [ -r "$SNAP_FILE" ]; then
  say "changed since the last check:"
  diff <(cat "$SNAP_FILE") <(printf '%s\n' "$SORTED") \
    | sed -n 's/^< /  was: /p; s/^> /  now: /p' >&2
  diff <(cat "$SNAP_FILE") <(printf '%s\n' "$SORTED") \
    | sed -n 's/^< /  was: /p; s/^> /  now: /p' >> "$PRECHECK_LOG" 2>/dev/null || true
else
  say "no snapshot from a previous check to compare against"
fi

# Record at check time, not after the firing: a change the user makes *during*
# a firing must still be visible to the next check. The cost is that Claude's
# own writes during a firing show up as a change too, so a working round is
# normally followed by one idle firing before things go quiet.
mkdir -p "$(dirname "$STATE_FILE")"
printf '%s\n' "$NOW" > "$STATE_FILE"
printf '%s\n' "$SORTED" > "$SNAP_FILE"
fire "queue or a watched PR changed since the last check"
