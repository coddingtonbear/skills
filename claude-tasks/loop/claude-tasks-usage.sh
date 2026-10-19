#!/usr/bin/env bash
# Usage gate for claude-tasks-loop.sh: hold a tick when the Claude
# subscription's 5-hour window is nearly spent, so a headless firing never
# eats the last of the window the user may want for themselves.
#
#   claude-tasks-usage.sh     # exit 0 = fire, exit 10 = hold; on 10, stdout is
#                             # the window's reset time as epoch seconds
#
# It asks the same endpoint Claude Code's own /usage does, with the OAuth
# access token Claude Code keeps in ~/.claude/.credentials.json, and compares
# `five_hour.utilization` (a percentage) against the cap. The endpoint is not
# documented, so like the Todoist pre-check this script is wrong only in the
# safe direction for the queue: any uncertainty -- no credentials, an expired
# token, an HTTP error, a response without the field -- exits 0 and fires. A
# firing refreshes the token on its way, so an expired one heals itself by
# the next tick; the price of each uncertainty is one ordinary firing, which
# is what every tick cost before this gate existed.
#
# Environment:
#   CLAUDE_TASKS_USAGE_CAP          hold at or above this percentage of the
#                                   5-hour window (default 90). 0 or empty
#                                   disables the gate: exit 0 without a call
#   CLAUDE_TASKS_CREDENTIALS        Claude Code's credentials file (default
#                                   ~/.claude/.credentials.json)
#   CLAUDE_TASKS_USAGE_URL          the usage endpoint (default Anthropic's;
#                                   the tests point it at a file:// JSON)
#   CLAUDE_TASKS_USAGE_LOG          where decisions are appended (default
#                                   usage.log beside CLAUDE_TASKS_STATE_FILE
#                                   when that is set; none otherwise)
set -uo pipefail

CAP="${CLAUDE_TASKS_USAGE_CAP-90}"
CREDENTIALS="${CLAUDE_TASKS_CREDENTIALS:-$HOME/.claude/.credentials.json}"
URL="${CLAUDE_TASKS_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
LOG="${CLAUDE_TASKS_USAGE_LOG:-}"
if [ -z "$LOG" ] && [ -n "${CLAUDE_TASKS_STATE_FILE:-}" ]; then
  LOG="$(dirname "$CLAUDE_TASKS_STATE_FILE")/usage.log"
fi

say() {
  echo "$(date -Is) usage: $1" >&2
  if [ -n "$LOG" ]; then
    { mkdir -p "$(dirname "$LOG")" && echo "$(date -Is) $1" >> "$LOG"; } 2>/dev/null || true
  fi
}
fire() { say "$1 -> firing"; exit 0; }
hold() { say "$1 -> holding"; printf '%s\n' "$2"; exit 10; }

case "$CAP" in
  ""|0) fire "gate disabled (CLAUDE_TASKS_USAGE_CAP=${CAP:-unset})" ;;
  *[!0-9]*) fire "bad CLAUDE_TASKS_USAGE_CAP '$CAP' (whole percent expected)" ;;
esac

command -v curl    >/dev/null 2>&1 || fire "curl not found"
command -v python3 >/dev/null 2>&1 || fire "python3 not found"
[ -r "$CREDENTIALS" ] || fire "no readable credentials file at $CREDENTIALS"

# Only the access token leaves the file, and it reaches curl through a config
# on stdin rather than the command line, so it never shows in `ps`.
TOKEN="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d["claudeAiOauth"]["accessToken"])
except Exception:
    pass
' "$CREDENTIALS" 2>/dev/null)" || true
[ -n "$TOKEN" ] || fire "no claudeAiOauth.accessToken in $CREDENTIALS"

RESP="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$TOKEN" \
        | curl -sS -m 20 -K - -w $'\n%{http_code}' "$URL" 2>/dev/null)" || fire "usage request failed"
unset TOKEN
STATUS="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"
# file:// responses carry no status; anything else must be a 2xx.
case "$STATUS" in
  000|2[0-9][0-9]) ;;
  *) fire "usage endpoint returned HTTP $STATUS" ;;
esac

# used|<percent>|<reset epoch>|<reset iso>, or an error line.
PARSE='
import json, sys
from datetime import datetime, timezone
try:
    d = json.loads(sys.stdin.read())
    fh = d["five_hour"]
    used = float(fh["utilization"])
    resets = fh.get("resets_at")
    when = datetime.fromisoformat(str(resets).replace("Z", "+00:00"))
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    print("used|%d|%d|%s" % (int(used), int(when.timestamp()), when.isoformat()))
except Exception as e:
    print("error|%s: %s" % (type(e).__name__, e))
'
LINE="$(printf '%s' "$BODY" | python3 -c "$PARSE" 2>/dev/null)" || fire "could not parse the usage response"
case "$LINE" in
  used\|*) ;;
  *) fire "usage response unusable (${LINE#error|})" ;;
esac
IFS='|' read -r _ USED RESET_EPOCH RESET_ISO <<<"$LINE"

if [ "$USED" -ge "$CAP" ]; then
  hold "5-hour window at ${USED}% (cap ${CAP}%), resets $RESET_ISO" "$RESET_EPOCH"
fi
fire "5-hour window at ${USED}% (cap ${CAP}%)"
