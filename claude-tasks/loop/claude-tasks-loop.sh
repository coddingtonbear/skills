#!/usr/bin/env bash
# The claude-tasks loop, run as a normal foreground command:
#
#   claude-tasks-loop.sh            # adaptive: 5m after a run that did work,
#                                   # doubling while idle, capped at 30m
#   claude-tasks-loop.sh 2m 1h      # custom min / max (sleep(1) syntax)
#   claude-tasks-loop.sh --once     # a single firing, then exit
#
# Pacing: each firing's report ends with "CLAUDE_TASKS_RESULT: worked|idle"
# (the claude-tasks skill emits it in loop mode). "worked" resets the wait to
# MIN; "idle" doubles it up to MAX; a missing marker counts as idle and warns.
#
# Every firing is a FRESH headless Claude Code session (`claude -p`), so no
# context accumulates across firings: all state lives in TickTick and the
# vault, and each run re-surveys the queue from scratch.
#
# Overlap protection: a non-blocking flock on a lockfile. If another firing
# is still running (this loop's, or a second copy of the script), the new
# firing is skipped and logged rather than run alongside it.
set -euo pipefail

ROOT="${CLAUDE_TASKS_ROOT:-$HOME/Documents/Projects}"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/claude-tasks-loop.lock"
LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tasks-loop"
PROMPT="Let's get started on your claude tasks."

# Tools a headless run may use without prompting. Anything else is denied and
# the run is expected to report it as a NEEDS: unblock. Extend as needed.
ALLOWED_TOOLS="${CLAUDE_TASKS_ALLOWED_TOOLS:-mcp__ticktick__*,mcp__obsidian__*,Read,Edit,Write,Glob,Grep,Bash(git:*),Bash(gh:*),Bash(npm:*),Bash(npx:*),Bash(date:*),Bash(ls:*)}"

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
MIN_WAIT=$(to_seconds "${1:-5m}")
MAX_WAIT=$(to_seconds "${2:-30m}")
[ "${1:-}" = "--once" ] && ONCE=1

mkdir -p "$LOGDIR"

fire() {
  local log="$LOGDIR/$(date +%Y-%m-%dT%H-%M-%S).log"
  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "$(date -Is) another firing is still running; skipped" | tee -a "$LOGDIR/skipped.log"
    exec 9>&-
    return 0
  fi
  echo "$(date -Is) firing from $ROOT -> $log"
  (
    cd "$ROOT"
    claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowedTools "$ALLOWED_TOOLS" \
      --add-dir "$ROOT" \
      "${MODEL_ARGS[@]}" \
      "${OUTPUT_ARGS[@]}" \
      2>&1 | tee -a "$log" | { if [ "$VERBOSE" = 1 ]; then feed; else cat; fi; }
  ) || echo "$(date -Is) claude exited non-zero" | tee -a "$log"
  echo "$(date -Is) done" | tee -a "$log"
  exec 9>&-   # release the lock between firings
  # keep the last 200 logs
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

trap 'echo; echo "loop stopped"; exit 0' INT TERM

if [ "$ONCE" = 1 ]; then
  fire
  exit 0
fi

WAIT=$MIN_WAIT
while true; do
  LAST_RESULT=unknown
  fire
  if [ "$LAST_RESULT" = worked ]; then
    WAIT=$MIN_WAIT
  else
    WAIT=$(( WAIT * 2 )); [ "$WAIT" -gt "$MAX_WAIT" ] && WAIT=$MAX_WAIT
  fi
  echo "$(date -Is) last run: $LAST_RESULT; next firing in $((WAIT/60))m$((WAIT%60))s (Ctrl-C to stop)"
  sleep "$WAIT"
done
