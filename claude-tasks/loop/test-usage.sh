#!/usr/bin/env bash
# Tests for claude-tasks-usage.sh, against a credentials file and a usage
# response of the test's own making (the endpoint is a file:// URL), so no
# real credentials are read and nothing is sent anywhere.
#
#   ./test-usage.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

CREDS="$TMPROOT/credentials.json"
RESP="$TMPROOT/usage.json"
export CLAUDE_TASKS_CREDENTIALS="$CREDS"
export CLAUDE_TASKS_USAGE_URL="file://$RESP"
export CLAUDE_TASKS_USAGE_LOG="$TMPROOT/usage.log"
unset CLAUDE_TASKS_USAGE_CAP CLAUDE_TASKS_STATE_FILE

fail() { echo "FAIL: $1"; exit 1; }

printf '{"claudeAiOauth":{"accessToken":"tok-test","refreshToken":"r","expiresAt":0}}' > "$CREDS"
RESET_EPOCH=1792424400
RESET_ISO="2026-10-19T15:40:00.485134+00:00"
response() {  # <utilization json value>
  printf '{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":0.0}}' "$1" "$RESET_ISO" > "$RESP"
}

# Runs the gate; sets STATUS, OUT (stdout) and ERR (stderr).
run() {
  set +e
  OUT="$(env "$@" "$HERE/claude-tasks-usage.sh" 2>"$TMPROOT/err")"; STATUS=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
}

# --- below the cap: fire ------------------------------------------------------
response 51.0
run
[ "$STATUS" -eq 0 ] || fail "51% under the default cap should fire (exit $STATUS: $ERR)"
grep -q '51% (cap 90%)' <<<"$ERR" || fail "firing line does not report the percentage and cap: $ERR"
grep -q 'firing' "$CLAUDE_TASKS_USAGE_LOG" || fail "decision was not appended to the usage log"

# --- at or above the cap: hold, with the reset time on stdout -----------------
response 90.0
run
[ "$STATUS" -eq 10 ] || fail "90% at the default cap should hold (exit $STATUS: $ERR)"
[ "$OUT" = "$RESET_EPOCH" ] || fail "hold should print the reset epoch $RESET_EPOCH, printed '$OUT'"
grep -q "resets $RESET_ISO" <<<"$ERR" || fail "hold line does not name the reset time: $ERR"

response 97.3
run
[ "$STATUS" -eq 10 ] || fail "97.3% should hold (exit $STATUS: $ERR)"

# The compare is on whole percent, floored: 89.9% is still under 90.
response 89.9
run
[ "$STATUS" -eq 0 ] || fail "89.9% should still fire under a cap of 90 (exit $STATUS: $ERR)"

# --- the cap is configurable, and 0 or empty disables the gate ---------------
response 51.0
run CLAUDE_TASKS_USAGE_CAP=50
[ "$STATUS" -eq 10 ] || fail "51% should hold under a cap of 50 (exit $STATUS: $ERR)"
run CLAUDE_TASKS_USAGE_CAP=0
[ "$STATUS" -eq 0 ] || fail "CLAUDE_TASKS_USAGE_CAP=0 should disable the gate (exit $STATUS: $ERR)"
grep -q 'disabled' <<<"$ERR" || fail "disabled gate did not say so: $ERR"
run CLAUDE_TASKS_USAGE_CAP=
[ "$STATUS" -eq 0 ] || fail "an empty CLAUDE_TASKS_USAGE_CAP should disable the gate (exit $STATUS: $ERR)"
# A disabled gate never reads the credentials or calls out.
response 99.0
run CLAUDE_TASKS_USAGE_CAP=0 CLAUDE_TASKS_CREDENTIALS="$TMPROOT/nope"
[ "$STATUS" -eq 0 ] || fail "a disabled gate should not depend on the credentials (exit $STATUS)"
run CLAUDE_TASKS_USAGE_CAP=ninety
[ "$STATUS" -eq 0 ] || fail "a malformed cap should fail open (exit $STATUS: $ERR)"
grep -q 'bad CLAUDE_TASKS_USAGE_CAP' <<<"$ERR" || fail "malformed cap did not say why: $ERR"

# --- every uncertainty fails open ---------------------------------------------
# The gate can only remove firings from the schedule; when it cannot tell, the
# tick goes on as if the gate weren't there.
response 99.0
run CLAUDE_TASKS_CREDENTIALS="$TMPROOT/does-not-exist.json"
[ "$STATUS" -eq 0 ] || fail "missing credentials should fire (exit $STATUS: $ERR)"
grep -q 'no readable credentials' <<<"$ERR" || fail "missing credentials did not say why: $ERR"

printf '{"claudeAiOauth":{"refreshToken":"r"}}' > "$TMPROOT/no-token.json"
run CLAUDE_TASKS_CREDENTIALS="$TMPROOT/no-token.json"
[ "$STATUS" -eq 0 ] || fail "credentials without an access token should fire (exit $STATUS: $ERR)"

printf 'not json' > "$TMPROOT/bad-creds.json"
run CLAUDE_TASKS_CREDENTIALS="$TMPROOT/bad-creds.json"
[ "$STATUS" -eq 0 ] || fail "unparseable credentials should fire (exit $STATUS: $ERR)"

run CLAUDE_TASKS_USAGE_URL="file://$TMPROOT/no-such-response.json"
[ "$STATUS" -eq 0 ] || fail "a failed request should fire (exit $STATUS: $ERR)"
grep -q 'request failed' <<<"$ERR" || fail "failed request did not say why: $ERR"

printf 'not json' > "$RESP"
run
[ "$STATUS" -eq 0 ] || fail "an unparseable response should fire (exit $STATUS: $ERR)"

printf '{"seven_day":{"utilization":99.0}}' > "$RESP"
run
[ "$STATUS" -eq 0 ] || fail "a response without five_hour should fire (exit $STATUS: $ERR)"

printf '{"five_hour":{"utilization":null,"resets_at":null}}' > "$RESP"
run
[ "$STATUS" -eq 0 ] || fail "a null utilization should fire (exit $STATUS: $ERR)"

printf '{"five_hour":{"utilization":99.0,"resets_at":"soon"}}' > "$RESP"
run
[ "$STATUS" -eq 0 ] || fail "an unparseable reset time should fire rather than hold blind (exit $STATUS: $ERR)"

# --- the token never reaches the command line --------------------------------
# curl gets the Authorization header from a config on stdin, so a process
# listing during the call never shows the token. Checked by substituting a
# curl that records its arguments.
STUBDIR="$TMPROOT/bin"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMPROOT/curl-args.txt"
cat > "$TMPROOT/curl-stdin.txt"
exec /usr/bin/curl "\$@" < "$TMPROOT/curl-stdin.txt"
EOF
chmod +x "$STUBDIR/curl"
response 51.0
run PATH="$STUBDIR:$PATH"
[ "$STATUS" -eq 0 ] || fail "run through the recording curl failed (exit $STATUS: $ERR)"
if grep -q 'tok-test' "$TMPROOT/curl-args.txt"; then fail "the access token was passed on curl's command line"; fi
grep -q 'Authorization: Bearer tok-test' "$TMPROOT/curl-stdin.txt" || fail "the Authorization header did not reach curl via stdin"

echo "PASS"
