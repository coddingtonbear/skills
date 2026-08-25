#!/usr/bin/env bash
# The claude-tasks loop, run as a normal foreground command:
#
#   claude-tasks-loop.sh            # fire every 30 minutes until Ctrl-C
#   claude-tasks-loop.sh 10m        # different interval (sleep(1) syntax)
#   claude-tasks-loop.sh --once     # a single firing, then exit
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

INTERVAL="30m"
ONCE=0
case "${1:-}" in
  --once) ONCE=1 ;;
  "") ;;
  *) INTERVAL="$1" ;;
esac

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
      2>&1 | tee -a "$log"
  ) || echo "$(date -Is) claude exited non-zero" | tee -a "$log"
  echo "$(date -Is) done" | tee -a "$log"
  exec 9>&-   # release the lock between firings
  # keep the last 200 logs
  ls -1t "$LOGDIR"/*.log 2>/dev/null | tail -n +201 | xargs -r rm -f
}

trap 'echo; echo "loop stopped"; exit 0' INT TERM

if [ "$ONCE" = 1 ]; then
  fire
  exit 0
fi

while true; do
  fire
  echo "$(date -Is) next firing in $INTERVAL (Ctrl-C to stop)"
  sleep "$INTERVAL"
done
