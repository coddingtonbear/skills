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
#     uncertainty -- no token, no scope, an HTTP error, an unparseable
#     response -- exits 0 and fires;
#   * saying "fire" when there is nothing costs exactly one ordinary firing,
#     which is what happened on every tick before this script existed.
#
# The skill text stays the only place the real candidate rules live -- there
# is nothing here to drift out of sync with it. The pre-check watches two
# things the firings treat as answers from the user: the TickTick queue, and
# the GitHub pull requests that queue is waiting on (the skill lets the user
# answer a `Needs review: PR <n>` ask by approving or merging on GitHub, which
# touches nothing in TickTick, so the queue fingerprint alone would sleep
# through it).
#
# Fires when any of these hold:
#   1. it cannot tell (see above)
#   2. an open task in scope carries `claude-ready` (released work nobody has
#      picked up) or `claude-inflight` (a firing that did not finish cleanly;
#      normal firings leave neither tag behind)
#   3. the fingerprint of the claude-tagged open tasks in scope differs from
#      the one recorded at the previous check -- which covers a completed ask
#      subtask (completed tasks drop out of the API response entirely), a new
#      comment, a body edit, a retag, and a newly added task
#   4. a pull request a `claude-waiting` task points at has changed since the
#      previous check -- a review, a comment, a push, a merge or close. The PRs
#      come from the `github.com/<owner>/<repo>/pull/<n>` URLs in those tasks'
#      bodies (the skill's `Phase: ... delivered -- PR <url>` line), which the
#      same TickTick response already carries, so discovery costs nothing; each
#      PR is then one `gh api` call, and its `updated_at` is folded into the
#      same fingerprint. Deliberately coarse: my own pushes and replies bump
#      it too, costing one idle firing, the same price my TickTick writes
#      already pay.
#
# Scope comes from the file the firings write (see CLAUDE_TASKS_SCOPE_FILE);
# until one exists, every tick fires, exactly as it did before.
#
# Environment:
#   TICKTICK_API_TOKEN        TickTick Open API token; sourced from
#                             CLAUDE_TASKS_SECRETS when not already set
#   gh                        the GitHub CLI, logged in with read access to
#                             the watched repos (the user's own login is fine:
#                             the pre-check only reads); missing or failing
#                             => fire, like every other uncertainty
#   CLAUDE_TASKS_SECRETS      shell-sourceable secrets file (default ~/.secrets)
#   CLAUDE_TASKS_SCOPE        the scope string this loop was launched with
#   CLAUDE_TASKS_SCOPE_FILE   resolved project ids (line 1: the scope string
#                             they were resolved from; then one id per line);
#                             defaults to a per-scope path under $LOGDIR
#   CLAUDE_TASKS_STATE_FILE   where the queue fingerprint is kept; likewise
#                             per-scope, so two loops don't share one
#   CLAUDE_TASKS_LOCK         the loop's lockfile; a tick is skipped outright
#                             while another firing holds it
#   CLAUDE_TASKS_API_BASE     API base (default TickTick's; overridden by tests)
set -uo pipefail

LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tasks-loop"
API="${CLAUDE_TASKS_API_BASE:-https://api.ticktick.com/open/v1}"
SECRETS="${CLAUDE_TASKS_SECRETS:-$HOME/.secrets}"
SCOPE="${CLAUDE_TASKS_SCOPE:-}"
LOCK="${CLAUDE_TASKS_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/claude-tasks-loop.lock}"
# Keyed by scope, so two loops over different scopes keep separate files --
# claude-tasks-loop.sh derives the same key and normally passes both paths.
SCOPE_KEY="$(printf '%s' "$SCOPE" | sha256sum | cut -c1-12)"
SCOPE_FILE="${CLAUDE_TASKS_SCOPE_FILE:-$LOGDIR/scope-$SCOPE_KEY.ids}"
STATE_FILE="${CLAUDE_TASKS_STATE_FILE:-$LOGDIR/queue-$SCOPE_KEY.state}"

say()  { echo "$(date -Is) precheck: $1" >&2; }
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

if [ -z "${TICKTICK_API_TOKEN:-}" ] && [ -r "$SECRETS" ]; then
  set -a; . "$SECRETS" >/dev/null 2>&1 || true; set +a
fi
[ -n "${TICKTICK_API_TOKEN:-}" ] || fire "no TICKTICK_API_TOKEN"

[ -r "$SCOPE_FILE" ] || fire "no resolved scope yet ($SCOPE_FILE)"
[ "$(head -n1 "$SCOPE_FILE")" = "$SCOPE" ] || fire "scope file was resolved from a different scope"
IDS="$(tail -n +2 "$SCOPE_FILE" | grep -E '^[0-9a-fA-F]{16,32}$' || true)"
[ -n "$IDS" ] || fire "scope file lists no project ids"

# One line per claude-tagged OPEN task: id|status|,tag,tag,|modifiedTime.
# Tags are comma-wrapped so a whole-tag match is a plain fixed-string grep.
# Plus one `pr|<owner>/<repo>/<n>` line per pull request URL found in the
# body of a `claude-waiting` task -- the PRs the queue is waiting on.
EXTRACT='
import json, re, sys
d = json.load(sys.stdin)
PR = re.compile(r"https?://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
for t in d.get("tasks") or []:
    tags = sorted(str(x) for x in (t.get("tags") or []))
    if not any(x.startswith("claude") for x in tags):
        continue
    print("%s|%s|,%s,|%s" % (t.get("id"), t.get("status"), ",".join(tags), t.get("modifiedTime")))
    if "claude-waiting" in tags:
        for o, r, n in sorted(set(PR.findall(t.get("content") or ""))):
            print("pr|%s/%s/%s" % (o, r, n))
'

SNAP=""
PRS=""
for pid in $IDS; do
  RESP="$(curl -sS -m 30 -w $'\n%{http_code}' \
            -H "Authorization: Bearer $TICKTICK_API_TOKEN" \
            "$API/project/$pid/data" 2>/dev/null)" || fire "request failed for project $pid"
  CODE="$(printf '%s' "$RESP" | tail -n1)"
  [ "$CODE" = 200 ] || fire "HTTP $CODE for project $pid"
  LINES="$(printf '%s' "$RESP" | sed '$d' | python3 -c "$EXTRACT")" || fire "unparseable response for project $pid"
  TASKS="$(printf '%s' "$LINES" | grep -v '^pr|' || true)"
  FOUND="$(printf '%s' "$LINES" | grep '^pr|' | cut -d'|' -f2 || true)"
  [ -n "$TASKS" ] && SNAP="$SNAP$TASKS"$'\n'
  [ -n "$FOUND" ] && PRS="$PRS$FOUND"$'\n'
done

# A released or stuck task is a standing positive: no stored state involved,
# so a crashed firing that left `claude-inflight` behind gets retried instead
# of being fingerprinted into silence.
if printf '%s' "$SNAP" | grep -q ',claude-ready,'; then
  fire "a claude-ready task is waiting"
fi
if printf '%s' "$SNAP" | grep -q ',claude-inflight,'; then
  fire "a claude-inflight task is unfinished"
fi

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
for ref in $(printf '%s' "$PRS" | LC_ALL=C sort -u); do
  command -v gh >/dev/null 2>&1 || fire "gh not found, and the queue is waiting on PR $ref"
  o="${ref%%/*}"; rest="${ref#*/}"; r="${rest%%/*}"; n="${rest#*/}"
  BODY="$(gh api "repos/$o/$r/pulls/$n" 2>/dev/null)" || fire "gh api failed for PR $ref"
  LINE="$(printf '%s' "$BODY" | python3 -c "$PR_LINE" 2>/dev/null)" || fire "unparseable response for PR $ref"
  SNAP="$SNAP$ref|$LINE"$'\n'
done

NOW="$(printf '%s' "$SNAP" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"
WAS="$(cat "$STATE_FILE" 2>/dev/null || true)"

if [ "$NOW" = "$WAS" ]; then
  skip "queue unchanged"
fi

# Record at check time, not after the firing: a change the user makes *during*
# a firing must still be visible to the next check. The cost is that my own
# writes during a firing show up as a change too, so a working round is
# normally followed by one idle firing before things go quiet.
mkdir -p "$(dirname "$STATE_FILE")"
printf '%s\n' "$NOW" > "$STATE_FILE"
fire "queue or a watched PR changed since the last check"
