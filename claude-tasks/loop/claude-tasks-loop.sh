#!/usr/bin/env bash
# The claude-tasks loop, run as a normal foreground command:
#
#   claude-tasks-loop.sh --profile personal # adaptive: 15s after a run that did
#                                           # work, 5m after an idle one, doubling
#                                           # while idle, cap 30m
#   claude-tasks-loop.sh --profile work 2m 1h   # custom min / max (sleep(1) syntax)
#   claude-tasks-loop.sh --profile work --once  # a single firing, then exit
#
# A profile is REQUIRED: `--profile <name>`, or CLAUDE_TASKS_PROFILE in the
# environment. There is no default -- a launch that names no profile refuses
# to start rather than quietly acting as one identity on a machine meant for
# the other.
#
# The queue is every project shared with Claude's own Todoist account and
# every task in them assigned to it; the user scopes the loop by sharing and
# unsharing projects. WHICH account -- and which GitHub identity, and where
# the checkouts live -- comes from the profile (../profiles/<name>.env, see
# the skill's Profiles section). Everything the loop keeps on disk or in the
# vault is per profile, so a personal and a work loop run side by side
# without sharing a lock, a fingerprint, or a run note.
#
# Pacing: each firing's report ends with "CLAUDE_TASKS_RESULT: worked|idle"
# (the claude-tasks skill emits it in loop mode). "worked" checks again after
# only CLAUDE_TASKS_WORKED_WAIT (default 15s) -- a queue with more tasks left
# shouldn't sit for MIN between them, and the pre-check keeps a quick recheck
# of an emptied queue cheap -- and resets the backoff to MIN; "idle" doubles
# the backoff up to MAX; a missing marker counts as idle and warns.
#
# Every firing is a FRESH headless Claude Code session (`claude -p`), so no
# context accumulates across firings: all state lives in Todoist and the
# vault, and each run re-surveys the queue from scratch.
#
# Run log: one Obsidian note per LAUNCH of this script (not per firing), in
# the vault's claude-loops/ folder. Its path and this launch's actual start
# time (from `date`) are passed to every firing in the prompt; the skill's
# Loop mode section has the first firing create it and each firing that
# works a task append a brief, timestamped line, so the whole launch's
# activity reads as one list. The note lives in the vault, not on disk here
# — only the firing (via its Obsidian MCP tools) can write it.
#
# Overlap protection: a non-blocking flock on a lockfile. If another firing
# is still running (this loop's, or a second copy of the script), the new
# firing is skipped and logged rather than run alongside it.
#
# Pre-check: before each firing, claude-tasks-check.sh asks Todoist's API
# directly -- no model, no tokens -- whether anything could possibly have
# changed, and a tick with nothing to do is skipped outright. It fails open
# (no token, any API trouble => fire anyway), so it can only remove firings
# from the schedule, never add them. Set CLAUDE_TASKS_PRECHECK=0 to fire on
# every tick as before.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- profile ---------------------------------------------------------------
# `--profile <name>` (anywhere on the command line) or CLAUDE_TASKS_PROFILE
# picks ../profiles/<name>.env; neither means refuse (exit 2). A variable
# already in the environment beats the profile's value for the four the
# loop itself uses (ROOT, BOT_USER, TOKEN_VAR, WORKTREES), so a one-off
# override -- or a test pointing at a scratch root -- needs no edit to the
# file.
PROFILE_ARG=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   PROFILE_ARG="${2:?--profile needs a name}"; shift 2 ;;
    --profile=*) PROFILE_ARG="${1#--profile=}"; shift ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

PROFILE="${PROFILE_ARG:-${CLAUDE_TASKS_PROFILE:-}}"
[ -n "$PROFILE" ] || { echo "no profile: pass --profile <name> or set CLAUDE_TASKS_PROFILE (profiles: $(ls "${CLAUDE_TASKS_PROFILE_DIR:-$HERE/../profiles}" 2>/dev/null | sed -n 's/\.env$//p' | tr '\n' ' '))" >&2; exit 2; }
case "$PROFILE" in
  *[!A-Za-z0-9_-]*) echo "bad profile name: '$PROFILE'" >&2; exit 2 ;;
esac
PROFILE_DIR="${CLAUDE_TASKS_PROFILE_DIR:-$HERE/../profiles}"
PROFILE_FILE="$PROFILE_DIR/$PROFILE.env"
[ -r "$PROFILE_FILE" ] || { echo "no such profile: $PROFILE ($PROFILE_FILE)" >&2; exit 2; }
ENV_ROOT="${CLAUDE_TASKS_ROOT:-}"
ENV_BOT_USER="${CLAUDE_TASKS_BOT_USER:-}"
ENV_TOKEN_VAR="${CLAUDE_TASKS_TOKEN_VAR:-}"
ENV_WORKTREES="${CLAUDE_TASKS_WORKTREES:-}"
# shellcheck disable=SC1090
. "$PROFILE_FILE"
ROOT="${ENV_ROOT:-${CLAUDE_TASKS_ROOT:-}}"
# Where a firing puts temporary worktrees (the skill's Workspaces section).
# The profile's value is spelled in terms of its own root, so a root
# override from the environment moves the worktrees along with it unless
# the environment names them too.
if [ -n "$ENV_WORKTREES" ]; then
  WORKTREES="$ENV_WORKTREES"
elif [ -n "$ENV_ROOT" ]; then
  WORKTREES="$ROOT/.claude-tasks-worktrees"
else
  WORKTREES="${CLAUDE_TASKS_WORKTREES:-$ROOT/.claude-tasks-worktrees}"
fi
BOT_USER="${ENV_BOT_USER:-${CLAUDE_TASKS_BOT_USER:-}}"
TOKEN_VAR="${ENV_TOKEN_VAR:-${CLAUDE_TASKS_TOKEN_VAR:-TODOIST_CLAUDE_API_TOKEN}}"
[ -n "$BOT_USER" ] || { echo "profile $PROFILE: CLAUDE_TASKS_BOT_USER is empty; fill it in $PROFILE_FILE" >&2; exit 2; }
[ -n "$ROOT" ]     || { echo "profile $PROFILE: CLAUDE_TASKS_ROOT is empty; fill it in $PROFILE_FILE" >&2; exit 2; }
[ -d "$ROOT" ]     || { echo "profile $PROFILE: root $ROOT is not a directory" >&2; exit 2; }
mkdir -p "$WORKTREES" || { echo "profile $PROFILE: cannot create worktrees dir $WORKTREES" >&2; exit 2; }
WORKTREES="$(cd "$WORKTREES" && pwd)"   # absolute: the firing gets it via --add-dir
case "$TOKEN_VAR" in
  ""|*[!A-Za-z0-9_]*) echo "profile $PROFILE: bad CLAUDE_TASKS_TOKEN_VAR '$TOKEN_VAR'" >&2; exit 2 ;;
esac
PROFILE_DIR="$(cd "$PROFILE_DIR" && pwd)"   # absolute: the firing gets it via --add-dir
PROFILE_FILE="$PROFILE_DIR/$PROFILE.env"
# The firing reads the profile file itself; these two tell it (and the
# pre-check) which one. This export, plus the profile named in the prompt
# below, is the whole hand-off: a firing needs nothing from a settings.json
# env block to know who it is.
export CLAUDE_TASKS_PROFILE="$PROFILE" CLAUDE_TASKS_TOKEN_VAR="$TOKEN_VAR"
# The resolved worktrees path too: the skill treats the environment's value
# as authoritative over the profile text, exactly as it does for the root.
export CLAUDE_TASKS_WORKTREES="$WORKTREES"

LOCK="${XDG_RUNTIME_DIR:-/tmp}/claude-tasks-loop-$PROFILE.lock"
LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tasks-loop/$PROFILE"
mkdir -p "$LOGDIR"
LAUNCH_STARTED="$(date -Is)"
RUN_NOTE="claude-loops/$PROFILE/$(date +%Y-%m-%dT%H-%M-%S).md"

STATE_FILE="${CLAUDE_TASKS_STATE_FILE:-$LOGDIR/queue.state}"
export CLAUDE_TASKS_STATE_FILE="$STATE_FILE" CLAUDE_TASKS_LOCK="$LOCK"

# Secrets: read ONCE at launch, not once per tick. ~/.secrets can be
# grant-gated (a pipe whose every open asks the user to approve), and the
# pre-check would otherwise source it itself on every tick — a grant prompt
# every few minutes. Reading here costs one grant per launch, while the
# operator is still at the terminal; exporting the token means
# claude-tasks-check.sh's own sourcing branch (guarded on the variable being
# unset) never opens the file again. Only the profile's token variable
# ($TOKEN_VAR — the bot account's token, which the pre-check queries with) is
# taken: the firings' `td` CLI carries its own credentials (the system
# credential manager), and exporting the whole file would put every secret
# into each headless session's environment. If the secrets file doesn't
# carry it, fall back to the td credential store itself.
#
# The token is looked up under the PROFILE's variable name only, in the
# environment first and then the file. A generically named token already in
# the environment is never taken for another profile: the pre-check would
# then watch the wrong account's queue and skip firings the right one needed.
SECRETS="${CLAUDE_TASKS_SECRETS:-$HOME/.secrets}"
TOKEN="${!TOKEN_VAR:-}"
if [ -z "$TOKEN" ] && [ -r "$SECRETS" ]; then
  echo "$(date -Is) reading $TOKEN_VAR from $SECRETS (a grant prompt may appear; granting now covers the whole launch)"
  TOKEN="$(set +eu; . "$SECRETS" >/dev/null 2>&1; printf '%s' "${!TOKEN_VAR:-}")"
fi
if [ -z "$TOKEN" ] && command -v td >/dev/null 2>&1; then
  TOKEN="$(td --user "$BOT_USER" auth token view 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1 || true)"
fi
if [ -n "$TOKEN" ]; then
  export "$TOKEN_VAR=$TOKEN"
else
  echo "$(date -Is) no $TOKEN_VAR available; the pre-check will fail open and fire every tick" >&2
fi
unset TOKEN

PROMPT="Let's get started on your claude tasks (loop mode, headless firing). Active claude-tasks profile: $PROFILE — read $PROFILE_FILE first; it names the accounts you are (Todoist $BOT_USER, and the GitHub identity mode). Your queue is every project shared with your Todoist account ($BOT_USER) and every task in them assigned to you — accept pending invitations first, then survey and work one task; end with the CLAUDE_TASKS_RESULT marker. Temporary worktrees (per the skill's Workspaces section) go under $WORKTREES. Loop run note (per the skill's Loop mode Run log section — create it if missing, append a brief timestamped line when you work a task, get every timestamp from \`date\`): vault path $RUN_NOTE. This launch started at $LAUNCH_STARTED."

# Tools a headless run may use without prompting. Anything else is denied and
# the run is expected to report it as a NEEDS: unblock. Extend as needed.
ALLOWED_TOOLS="${CLAUDE_TASKS_ALLOWED_TOOLS:-mcp__obsidian__*,Read,Edit,Write,Glob,Grep,Bash(td:*),Bash(git:*),Bash(gh:*),Bash(npm:*),Bash(npx:*),Bash(date:*),Bash(ls:*),Bash(curl:*),Bash(printenv:*)}"

# Model for headless firings: an alias (opus, sonnet, haiku) or a full model id.
# Unset = the session default from ~/.claude/settings.json / ANTHROPIC_MODEL.
MODEL_ARGS=()
if [ -n "${CLAUDE_TASKS_MODEL:-}" ]; then
  MODEL_ARGS=(--model "$CLAUDE_TASKS_MODEL")
fi

# CLAUDE_TASKS_VERBOSE=1 streams every assistant message and tool call live
# (stream-json, filtered to a readable feed); the raw JSON goes to the log.
VERBOSE="${CLAUDE_TASKS_VERBOSE:-0}"
OUTPUT_ARGS=()
if [ "$VERBOSE" = 1 ]; then
  OUTPUT_ARGS=(--output-format stream-json --verbose)
fi

# Turns stream-json lines into a one-line-per-event feed for the terminal.
feed() {
  python3 -u -c '
import json, sys
for line in sys.stdin:
    try:
        ev = json.loads(line)
    except ValueError:
        print(line.rstrip()); continue
    t = ev.get("type")
    if t == "assistant":
        for c in ev.get("message", {}).get("content", []):
            if c.get("type") == "text" and c.get("text", "").strip():
                print("assistant:", c["text"].strip().replace("\n", " ")[:300])
            elif c.get("type") == "tool_use":
                inp = c.get("input", {})
                hint = inp.get("command") or inp.get("file_path") or inp.get("path") or inp.get("task_id") or ""
                print("  tool:", c.get("name"), str(hint)[:120])
    elif t == "result":
        print("result:", ev.get("subtype"), "| cost $%.2f" % ev.get("total_cost_usd", 0), "|", ev.get("num_turns"), "turns")
        r = ev.get("result")
        if r: print(r.strip()[:2000])
'
}

# The outcome marker from a firing's log: "worked", "idle", or empty when the
# firing emitted none. Only the firing's OWN report counts -- assistant text
# and the final `result` -- and the LAST marker in it wins. A stream-json log
# replays the whole conversation, including the skill instructions that quote
# `CLAUDE_TASKS_RESULT: worked` in prose, so a grep over the raw log said
# "worked" for every firing and the idle backoff never engaged. Thinking
# blocks, tool results and user/system messages are ignored for the same
# reason; plain (non-JSON) logs are the report as printed, so they count.
read_marker() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, re, sys

marker = re.compile(r"^[ \t]*`?CLAUDE_TASKS_RESULT:[ \t]*(worked|idle)\b", re.M)

def reported(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                yield line
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") == "result":
                if isinstance(ev.get("result"), str):
                    yield ev["result"]
            elif ev.get("type") == "assistant":
                for block in ev.get("message", {}).get("content", []):
                    if block.get("type") == "text":
                        yield block.get("text", "")

found = ""
for chunk in reported(sys.argv[1]):
    for m in marker.finditer(chunk):
        found = m.group(1)
print(found)
' "$1"
  else
    # No python3 (the verbose feed needs it too, so this is a bare-bones
    # machine): drop the replayed conversation turns and take the last
    # marker that is still at the start of a line -- cruder, but it can't
    # read the skill text in the user message as this firing's outcome.
    grep -v '"type":"user"' "$1" 2>/dev/null \
      | grep -oE '(^|\\n)`?CLAUDE_TASKS_RESULT: *(worked|idle)' \
      | grep -oE '(worked|idle)' | tail -n 1
  fi
}

# sleep(1)-style duration -> seconds (e.g. 90, 5m, 2h)
to_seconds() {
  local d="$1" n="${1%[smhd]}"
  case "$d" in
    *s) echo "$n" ;; *m) echo $((n*60)) ;; *h) echo $((n*3600)) ;; *d) echo $((n*86400)) ;;
    *) echo "$d" ;;
  esac
}

ONCE=0
if [ "${1:-}" = "--once" ]; then ONCE=1; shift; fi
MIN_WAIT=$(to_seconds "${1:-5m}")
MAX_WAIT=$(to_seconds "${2:-30m}")
# The wait after a firing that did work. Short rather than zero: it leaves a
# moment to Ctrl-C between firings, and bounds how fast a firing that keeps
# reporting "worked" without making progress can repeat.
WORKED_WAIT=$(to_seconds "${CLAUDE_TASKS_WORKED_WAIT:-15s}")

fire() {
  local log="$LOGDIR/$(date +%Y-%m-%dT%H-%M-%S).log"
  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "$(date -Is) another firing is still running; skipped" | tee -a "$LOGDIR/skipped.log"
    exec 9>&-
    # This firing never happened, so whatever the pre-check fingerprinted on
    # its way here was never acted on. Drop the fingerprint rather than let a
    # change the lock swallowed get recorded as handled.
    rm -f "$STATE_FILE" "${STATE_FILE%.state}.snap"
    return 0
  fi
  echo "$(date -Is) firing from $ROOT -> $log"
  (
    cd "$ROOT"
    claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowedTools "$ALLOWED_TOOLS" \
      --add-dir "$ROOT" \
      --add-dir "$WORKTREES" \
      --add-dir "$LOGDIR" \
      --add-dir "$PROFILE_DIR" \
      "${MODEL_ARGS[@]}" \
      "${OUTPUT_ARGS[@]}" \
      2>&1 | tee -a "$log" | { if [ "$VERBOSE" = 1 ]; then feed; else cat; fi; }
  ) || echo "$(date -Is) claude exited non-zero" | tee -a "$log"
  echo "$(date -Is) done" | tee -a "$log"
  exec 9>&-   # release the lock between firings
  # keep the last 200 session logs
  ls -1t "$LOGDIR"/*.log 2>/dev/null | tail -n +201 | xargs -r rm -f

  # Outcome marker, read back from the log -- from the firing's OWN report
  # only (see read_marker). A plain grep over the whole log used to match
  # "worked" on every stream-json firing, because the log replays the skill's
  # instructions, which quote the marker: the loop then never backed off.
  LAST_RESULT="$(read_marker "$log")"
  if [ -z "$LAST_RESULT" ]; then
    LAST_RESULT=unknown
    echo "$(date -Is) warning: no CLAUDE_TASKS_RESULT marker in output; treating as idle" | tee -a "$log"
  fi
}

echo "$(date -Is) profile: $PROFILE ($BOT_USER, root $ROOT, worktrees $WORKTREES); run note: $RUN_NOTE (vault, started $LAUNCH_STARTED)"

trap 'echo; echo "loop stopped"; exit 0' INT TERM

if [ "$ONCE" = 1 ]; then
  fire
  exit 0
fi

CHECK="${CLAUDE_TASKS_CHECK:-$HERE/claude-tasks-check.sh}"
PRECHECK="${CLAUDE_TASKS_PRECHECK:-1}"

# Exit 10 -- and only exit 10 -- means "nothing could have changed, skip".
# Every other status, including a crash in the checker itself, fires.
should_skip() {
  [ "$PRECHECK" = 1 ] || return 1
  [ -x "$CHECK" ] || return 1
  "$CHECK"; [ "$?" -eq 10 ]
}

# BACKOFF is the idle wait, kept apart from the WAIT actually slept so the
# short post-work wait never becomes the base the idle doubling starts from.
BACKOFF=$MIN_WAIT
while true; do
  LAST_RESULT=unknown
  if should_skip; then
    LAST_RESULT=skipped
  else
    fire
  fi
  case "$LAST_RESULT" in
    # Work done means there may well be more queued: look again almost at
    # once. If there isn't, the pre-check skips that tick for free.
    worked) BACKOFF=$MIN_WAIT; WAIT=$WORKED_WAIT ;;
    # A skipped tick costs nothing, so it earns no backoff: stay at MIN and
    # keep watching cheaply. Backoff exists to stop idle *firings* burning
    # tokens, and still does whenever the pre-check is off or failing open.
    skipped) BACKOFF=$MIN_WAIT; WAIT=$MIN_WAIT ;;
    *) BACKOFF=$(( BACKOFF * 2 )); [ "$BACKOFF" -gt "$MAX_WAIT" ] && BACKOFF=$MAX_WAIT; WAIT=$BACKOFF ;;
  esac
  echo "$(date -Is) last run: $LAST_RESULT; next check in $((WAIT/60))m$((WAIT%60))s (Ctrl-C to stop)"
  sleep "$WAIT"
done
