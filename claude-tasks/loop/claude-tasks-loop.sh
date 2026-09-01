#!/usr/bin/env bash
# The claude-tasks loop, run as a normal foreground command:
#
#   claude-tasks-loop.sh                    # adaptive: 5m after a run that did
#                                           # work, doubling while idle, cap 30m
#   claude-tasks-loop.sh 2m 1h              # custom min / max (sleep(1) syntax)
#   claude-tasks-loop.sh --once             # a single firing, then exit
#
# The queue is every project shared with Claude's own Todoist account
# (Coddingtonbot) and every task in them assigned to it; the user scopes the
# loop by sharing and unsharing projects.
#
# Pacing: each firing's report ends with "CLAUDE_TASKS_RESULT: worked|idle"
# (the claude-tasks skill emits it in loop mode). "worked" resets the wait to
# MIN; "idle" doubles it up to MAX; a missing marker counts as idle and warns.
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
ROOT="${CLAUDE_TASKS_ROOT:-$HOME/Documents/Projects}"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/claude-tasks-loop.lock"
LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tasks-loop"
BOT_USER="${CLAUDE_TASKS_BOT_USER:-me+claude@adamcoddington.net}"
mkdir -p "$LOGDIR"
LAUNCH_STARTED="$(date -Is)"
RUN_NOTE="claude-loops/$(date +%Y-%m-%dT%H-%M-%S).md"

STATE_FILE="${CLAUDE_TASKS_STATE_FILE:-$LOGDIR/queue.state}"
export CLAUDE_TASKS_STATE_FILE="$STATE_FILE" CLAUDE_TASKS_LOCK="$LOCK"

# Secrets: read ONCE at launch, not once per tick. ~/.secrets can be
# grant-gated (a pipe whose every open asks the user to approve), and the
# pre-check would otherwise source it itself on every tick — a grant prompt
# every few minutes. Reading here costs one grant per launch, while the
# operator is still at the terminal; exporting the token means
# claude-tasks-check.sh's own sourcing branch (guarded on the variable being
# unset) never opens the file again. Only TODOIST_CLAUDE_API_TOKEN — the
# Coddingtonbot account's token, which the pre-check queries with — is taken:
# the firings' `td` CLI carries its own credentials (the system credential
# manager), and exporting the whole file would put every secret into each
# headless session's environment. If the secrets file doesn't carry it, fall
# back to the td credential store itself.
SECRETS="${CLAUDE_TASKS_SECRETS:-$HOME/.secrets}"
if [ -z "${TODOIST_CLAUDE_API_TOKEN:-}" ] && [ -r "$SECRETS" ]; then
  echo "$(date -Is) reading TODOIST_CLAUDE_API_TOKEN from $SECRETS (a grant prompt may appear; granting now covers the whole launch)"
  TODOIST_CLAUDE_API_TOKEN="$(set +eu; . "$SECRETS" >/dev/null 2>&1; printf '%s' "${TODOIST_CLAUDE_API_TOKEN:-}")"
fi
if [ -z "${TODOIST_CLAUDE_API_TOKEN:-}" ] && command -v td >/dev/null 2>&1; then
  TODOIST_CLAUDE_API_TOKEN="$(td --user "$BOT_USER" auth token view 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1 || true)"
fi
if [ -n "${TODOIST_CLAUDE_API_TOKEN:-}" ]; then
  export TODOIST_CLAUDE_API_TOKEN
else
  echo "$(date -Is) no TODOIST_CLAUDE_API_TOKEN available; the pre-check will fail open and fire every tick" >&2
fi

PROMPT="Let's get started on your claude tasks (loop mode, headless firing). Your queue is every project shared with your Todoist account ($BOT_USER) and every task in them assigned to you — accept pending invitations first, then survey and work one task; end with the CLAUDE_TASKS_RESULT marker. Loop run note (per the skill's Loop mode Run log section — create it if missing, append a brief timestamped line when you work a task, get every timestamp from \`date\`): vault path $RUN_NOTE. This launch started at $LAUNCH_STARTED."

# Tools a headless run may use without prompting. Anything else is denied and
# the run is expected to report it as a NEEDS: unblock. Extend as needed.
ALLOWED_TOOLS="${CLAUDE_TASKS_ALLOWED_TOOLS:-mcp__obsidian__*,Read,Edit,Write,Glob,Grep,Bash(td:*),Bash(git:*),Bash(gh:*),Bash(npm:*),Bash(npx:*),Bash(date:*),Bash(ls:*),Bash(curl:*)}"

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
      --add-dir "$LOGDIR" \
      "${MODEL_ARGS[@]}" \
      "${OUTPUT_ARGS[@]}" \
      2>&1 | tee -a "$log" | { if [ "$VERBOSE" = 1 ]; then feed; else cat; fi; }
  ) || echo "$(date -Is) claude exited non-zero" | tee -a "$log"
  echo "$(date -Is) done" | tee -a "$log"
  exec 9>&-   # release the lock between firings
  # keep the last 200 session logs
  ls -1t "$LOGDIR"/*.log 2>/dev/null | tail -n +201 | xargs -r rm -f

  # Outcome marker, read back from the log (works for plain and stream-json output).
  if grep -q 'CLAUDE_TASKS_RESULT: *worked' "$log"; then
    LAST_RESULT=worked
  elif grep -q 'CLAUDE_TASKS_RESULT: *idle' "$log"; then
    LAST_RESULT=idle
  else
    LAST_RESULT=unknown
    echo "$(date -Is) warning: no CLAUDE_TASKS_RESULT marker in output; treating as idle" | tee -a "$log"
  fi
}

echo "$(date -Is) run note: $RUN_NOTE (vault, started $LAUNCH_STARTED)"

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

WAIT=$MIN_WAIT
while true; do
  LAST_RESULT=unknown
  if should_skip; then
    LAST_RESULT=skipped
  else
    fire
  fi
  case "$LAST_RESULT" in
    # A skipped tick costs nothing, so it earns no backoff: stay at MIN and
    # keep watching cheaply. Backoff exists to stop idle *firings* burning
    # tokens, and still does whenever the pre-check is off or failing open.
    worked|skipped) WAIT=$MIN_WAIT ;;
    *) WAIT=$(( WAIT * 2 )); [ "$WAIT" -gt "$MAX_WAIT" ] && WAIT=$MAX_WAIT ;;
  esac
  echo "$(date -Is) last run: $LAST_RESULT; next check in $((WAIT/60))m$((WAIT%60))s (Ctrl-C to stop)"
  sleep "$WAIT"
done
