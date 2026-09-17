#!/usr/bin/env bash
# Smoke test for claude-tasks-loop.sh's run-note plumbing, using a stub
# `claude` CLI so no real API calls or Todoist/Obsidian access happen.
#
# The script itself can't write the run note (it lives in the vault, and only
# a firing's Obsidian MCP tools can reach it) -- this test only checks that
# the script computes a sane vault path and a real launch-start timestamp and
# hands both to the firing via the prompt, and that it no longer writes any
# local run-log file (that behavior moved into the vault note).
#
#   ./test-loop.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export XDG_STATE_HOME="$TMPROOT/state"
export XDG_RUNTIME_DIR="$TMPROOT/run"
export CLAUDE_TASKS_ROOT="$TMPROOT/projects"
# Never let the test open the real ~/.secrets: on machines where that's a
# grant-gated pipe, the loop's launch-time read would block on a prompt.
export CLAUDE_TASKS_SECRETS="$TMPROOT/no-such-secrets"
mkdir -p "$CLAUDE_TASKS_ROOT" "$XDG_RUNTIME_DIR"

CAPTURED_PROMPT="$TMPROOT/captured-prompt.txt"
STUBDIR="$TMPROOT/bin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/claude" <<EOF
#!/usr/bin/env bash
# Stub for \`claude -p ...\`: just captures the prompt so the test can
# inspect what the script handed the firing, then reports success.
# Every argument, one per line, for the --add-dir assertions (recorded
# before the loop below consumes them).
printf '%s\n' "\$@" > "$TMPROOT/captured-args.txt"
prompt=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -p) prompt="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "\$prompt" > "$CAPTURED_PROMPT"
printf '%s' "\${TODOIST_CLAUDE_API_TOKEN:-}" > "$TMPROOT/captured-token.txt"
# Every claude-tasks / Todoist variable the firing inherited, for the
# profile assertions.
env | grep -E '^(CLAUDE_TASKS_|TODOIST_)' | sort > "$TMPROOT/captured-env.txt"
echo "stub claude ran"
echo x >> "$TMPROOT/firings.txt"
echo "CLAUDE_TASKS_RESULT: \${STUB_RESULT:-worked}"
EOF
chmod +x "$STUBDIR/claude"
# Stub td: the loop falls back to the td credential store for the bot token
# when the secrets file doesn't carry it; the tests must never touch the real
# credential manager, so the stub just fails.
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBDIR/td"
chmod +x "$STUBDIR/td"
export PATH="$STUBDIR:$PATH"

fail() { echo "FAIL: $1"; exit 1; }

# No profile at all -- no --profile, no CLAUDE_TASKS_PROFILE -- refuses to
# launch. This is the work-machine failure of 2026-09-10: a launch that
# named nothing used to default to personal and fire as the wrong identity.
if env -u CLAUDE_TASKS_PROFILE "$HERE/claude-tasks-loop.sh" --once >"$TMPROOT/noprofile.out" 2>&1; then
  fail "a launch with no profile should refuse to start"
fi
[ -f "$CAPTURED_PROMPT" ] && fail "a launch with no profile fired anyway"
grep -q 'no profile' "$TMPROOT/noprofile.out" || fail "no-profile refusal did not say why: $(cat "$TMPROOT/noprofile.out")"
grep -q 'personal' "$TMPROOT/noprofile.out" || fail "no-profile refusal did not list the available profiles"

BEFORE="$(date -Is)"
"$HERE/claude-tasks-loop.sh" --profile personal --once
AFTER="$(date -Is)"

[ -f "$CAPTURED_PROMPT" ] || fail "stub claude never ran / prompt not captured"

RUN_NOTE="$(grep -oE 'claude-loops/[^ ]+\.md' "$CAPTURED_PROMPT" || true)"
[ -n "$RUN_NOTE" ] || fail "prompt has no claude-loops/*.md vault path"
case "$RUN_NOTE" in
  claude-loops/personal/*) ;;
  *) fail "run note $RUN_NOTE is not under the profile's own folder (claude-loops/personal/)" ;;
esac

# The firing is told which profile it is and where to read it.
grep -q 'Active claude-tasks profile: personal' "$CAPTURED_PROMPT" \
  || fail "prompt does not name the active profile"
grep -qE 'profiles/personal\.env' "$CAPTURED_PROMPT" \
  || fail "prompt does not point the firing at the profile file"
grep -q '^CLAUDE_TASKS_PROFILE=personal$' "$TMPROOT/captured-env.txt" \
  || fail "firing did not inherit CLAUDE_TASKS_PROFILE=personal"

LAUNCH_STARTED="$(grep -oE 'started at [^.]+' "$CAPTURED_PROMPT" | sed 's/started at //' || true)"
[ -n "$LAUNCH_STARTED" ] || fail "prompt has no launch-start timestamp"
# Sanity: it's a real ISO-8601 timestamp from `date`, not a placeholder, and
# falls within this test run's own wall-clock window.
[[ "$LAUNCH_STARTED" > "$BEFORE" || "$LAUNCH_STARTED" == "$BEFORE" ]] || fail "launch timestamp $LAUNCH_STARTED predates the test run"
[[ "$LAUNCH_STARTED" < "$AFTER" || "$LAUNCH_STARTED" == "$AFTER" ]] || fail "launch timestamp $LAUNCH_STARTED is after the test run"

# The queue is membership-scoped now: the prompt must say so and must not
# name any scope or scope-ids file.
grep -q 'every project shared with your Todoist account' "$CAPTURED_PROMPT" \
  || fail "prompt does not describe the membership-scoped queue"
grep -q 'accept pending invitations' "$CAPTURED_PROMPT" \
  || fail "prompt does not tell the firing to accept pending invitations"
if grep -q 'Scope-ids file' "$CAPTURED_PROMPT"; then
  fail "prompt still names a scope-ids file -- that plumbing was removed"
fi

LOGDIR="$XDG_STATE_HOME/claude-tasks-loop/personal"
[ -n "$(ls "$LOGDIR"/*.log 2>/dev/null || true)" ] || fail "expected a session .log under $LOGDIR"
[ -z "$(ls "$LOGDIR"/run-*.md 2>/dev/null || true)" ] || fail "found a local run-*.md -- run notes now live in the vault, not $LOGDIR"

# --- worktrees --------------------------------------------------------------
# The firing is handed a worktrees directory: created at launch, reachable
# without prompts (--add-dir), named in the prompt and the environment. With
# the root overridden from the environment (as this whole test does) and no
# CLAUDE_TASKS_WORKTREES override, it follows the root rather than the
# profile's spelling of it -- a scratch root must never send worktrees into
# the real ~/Documents/Projects.
add_dirs() { awk 'prev == "--add-dir" { print } { prev = $0 }' "$TMPROOT/captured-args.txt"; }
WT_EXPECTED="$CLAUDE_TASKS_ROOT/.claude-tasks-worktrees"
[ -d "$WT_EXPECTED" ] || fail "launch did not create the worktrees dir $WT_EXPECTED"
add_dirs | grep -qx "$WT_EXPECTED" || fail "firing was not given --add-dir $WT_EXPECTED (got: $(add_dirs | tr '\n' ' '))"
grep -q "Temporary worktrees .* go under $WT_EXPECTED" "$CAPTURED_PROMPT" \
  || fail "prompt does not name the worktrees dir"
grep -q "^CLAUDE_TASKS_WORKTREES=$WT_EXPECTED\$" "$TMPROOT/captured-env.txt" \
  || fail "firing did not inherit CLAUDE_TASKS_WORKTREES=$WT_EXPECTED"
# An explicit CLAUDE_TASKS_WORKTREES in the environment wins over both.
rm -f "$CAPTURED_PROMPT"
env CLAUDE_TASKS_WORKTREES="$TMPROOT/wt-override" "$HERE/claude-tasks-loop.sh" --profile personal --once >/dev/null 2>&1 \
  || fail "launch with CLAUDE_TASKS_WORKTREES override failed"
[ -d "$TMPROOT/wt-override" ] || fail "worktrees override dir was not created"
add_dirs | grep -qx "$TMPROOT/wt-override" || fail "worktrees override was not passed as --add-dir"
grep -q "^CLAUDE_TASKS_WORKTREES=$TMPROOT/wt-override\$" "$TMPROOT/captured-env.txt" \
  || fail "worktrees override was not exported to the firing"

# --- pre-check ------------------------------------------------------------
# A stub pre-check stands in for claude-tasks-check.sh so this test covers the
# loop's own branching (skip vs fire) rather than the checker's logic, which
# test-check.sh covers.
CHECKSTUB="$TMPROOT/check-stub.sh"
export CLAUDE_TASKS_CHECK="$CHECKSTUB"
stub_check() { printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$CHECKSTUB"; chmod +x "$CHECKSTUB"; }

# Runs the real loop (not --once) for a few ticks, then stops it. A firing
# leaves $CAPTURED_PROMPT behind; a skipped tick leaves nothing.
loop_briefly() {
  rm -f "$CAPTURED_PROMPT"
  "$HERE/claude-tasks-loop.sh" --profile personal 1s 1s >/dev/null 2>&1 &
  local pid=$!
  sleep 3
  kill -TERM "$pid" 2>/dev/null || true
  # bash runs its trap only once the foreground `sleep` returns, and a worked
  # firing sleeps longer than these ticks; end the sleep rather than wait it out.
  pkill -TERM -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

stub_check 10
loop_briefly
if [ -f "$CAPTURED_PROMPT" ]; then fail "pre-check said skip (exit 10) but a firing happened anyway"; fi

stub_check 0
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "pre-check said fire (exit 0) but no firing happened"

# Only exit 10 means skip: a broken checker must not silently stall the loop.
stub_check 3
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "a pre-check that failed (exit 3) should fire, not skip"

export CLAUDE_TASKS_CHECK="$TMPROOT/does-not-exist.sh"
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "a missing pre-check script should fire, not skip"

export CLAUDE_TASKS_CHECK="$CHECKSTUB"
stub_check 10
export CLAUDE_TASKS_PRECHECK=0
loop_briefly
[ -f "$CAPTURED_PROMPT" ] || fail "CLAUDE_TASKS_PRECHECK=0 should fire on every tick"
unset CLAUDE_TASKS_PRECHECK

# --- pacing -----------------------------------------------------------------
# After a firing that worked, the next tick comes after the short
# CLAUDE_TASKS_WORKED_WAIT, not MIN; after an idle one it's still MIN (or
# more). MIN is an hour here, so a second firing inside the window can only
# have come from the post-work wait.
count_firings() {
  rm -f "$TMPROOT/firings.txt"
  "$HERE/claude-tasks-loop.sh" --profile personal 1h 2h >"$TMPROOT/pacing.out" 2>&1 &
  local pid=$!
  sleep 4
  kill -TERM "$pid" 2>/dev/null || true
  # Same as loop_briefly: don't wait out the foreground `sleep`.
  pkill -TERM -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -f "$TMPROOT/firings.txt" ]; then wc -l < "$TMPROOT/firings.txt" | tr -d ' '; else echo 0; fi
}
stub_check 0
export CLAUDE_TASKS_WORKED_WAIT=1s
N="$(STUB_RESULT=worked count_firings)"
[ "$N" -ge 2 ] || fail "a worked firing should be followed within CLAUDE_TASKS_WORKED_WAIT, not MIN (fired $N times)"
grep -q 'last run: worked; next check in 0m1s' "$TMPROOT/pacing.out" \
  || fail "worked firing did not schedule the post-work wait: $(cat "$TMPROOT/pacing.out")"
N="$(STUB_RESULT=idle count_firings)"
[ "$N" -eq 1 ] || fail "an idle firing should wait MIN or longer, not the post-work wait (fired $N times)"
grep -q 'last run: idle; next check in 120m0s' "$TMPROOT/pacing.out" \
  || fail "idle firing did not back off from MIN: $(cat "$TMPROOT/pacing.out")"
unset CLAUDE_TASKS_WORKED_WAIT
# The default post-work wait is short -- well under a minute.
STUB_RESULT=worked count_firings >/dev/null
grep -q 'last run: worked; next check in 0m15s' "$TMPROOT/pacing.out" \
  || fail "default post-work wait is not 15s: $(cat "$TMPROOT/pacing.out")"

# --once is an explicit "run now", so it never consults the pre-check.
rm -f "$CAPTURED_PROMPT"
"$HERE/claude-tasks-loop.sh" --profile personal --once >/dev/null 2>&1
[ -f "$CAPTURED_PROMPT" ] || fail "--once should fire regardless of the pre-check"

# --- overlap ---------------------------------------------------------------
# A firing turned away by the lock never happened, so anything the pre-check
# fingerprinted on its way in must not survive as "handled" -- otherwise a
# change swallowed by the lock is lost for good.
STATE_FILE="$LOGDIR/queue.state"
SNAP_FILE="$LOGDIR/queue.snap"
echo "a-fingerprint-for-a-change-nobody-acted-on" > "$STATE_FILE"
echo "t1|botuid|2026-08-26T10:00:00Z|0|,," > "$SNAP_FILE"

exec 8>"$XDG_RUNTIME_DIR/claude-tasks-loop-personal.lock"
flock -n 8 || fail "could not take the test lock"
stub_check 0
loop_briefly
exec 8>&-

if [ -f "$CAPTURED_PROMPT" ]; then fail "fired while another firing held the lock"; fi
if [ -f "$STATE_FILE" ]; then fail "kept the pre-check fingerprint after the lock turned the firing away"; fi
if [ -f "$SNAP_FILE" ]; then fail "kept the pre-check snapshot after the lock turned the firing away"; fi

# --- secrets at launch ------------------------------------------------------
# The loop sources the secrets file ONCE at launch and exports the bot token,
# so a grant-gated file is opened exactly once per launch and the per-tick
# pre-check (and every firing) inherits it from the environment.
echo 'TODOIST_CLAUDE_API_TOKEN=tok-read-at-launch' > "$TMPROOT/secrets.env"
rm -f "$TMPROOT/captured-token.txt"
env -u TODOIST_CLAUDE_API_TOKEN CLAUDE_TASKS_SECRETS="$TMPROOT/secrets.env" \
  "$HERE/claude-tasks-loop.sh" --profile personal --once >/dev/null 2>&1
[ "$(cat "$TMPROOT/captured-token.txt" 2>/dev/null)" = "tok-read-at-launch" ] \
  || fail "launch-time secrets read did not export TODOIST_CLAUDE_API_TOKEN to the firing"

# A token already in the environment wins; the file is not even consulted.
rm -f "$TMPROOT/captured-token.txt"
env TODOIST_CLAUDE_API_TOKEN=tok-from-env CLAUDE_TASKS_SECRETS="$TMPROOT/secrets.env" \
  "$HERE/claude-tasks-loop.sh" --profile personal --once >/dev/null 2>&1
[ "$(cat "$TMPROOT/captured-token.txt" 2>/dev/null)" = "tok-from-env" ] \
  || fail "an environment-supplied TODOIST_CLAUDE_API_TOKEN should win over the secrets file"

# --- profiles ---------------------------------------------------------------
# A second profile (a different bot account, its own token variable, its own
# root) gets its own lock, log dir, run-note folder, and token -- and never
# the personal profile's token, even when that one is sitting in the
# environment under its generic name.
PROFDIR="$TMPROOT/profiles"
WORKROOT="$TMPROOT/work"
mkdir -p "$PROFDIR" "$WORKROOT"
cat > "$PROFDIR/work.env" <<EOF
CLAUDE_TASKS_PROFILE=work
CLAUDE_TASKS_BOT_USER=work-bot@example.com
CLAUDE_TASKS_TOKEN_VAR=TODOIST_WORK_TOKEN
CLAUDE_TASKS_GITHUB_MODE=shared
CLAUDE_TASKS_ROOT=$WORKROOT
CLAUDE_TASKS_WORKTREES=$TMPROOT/work-worktrees
EOF
printf 'TODOIST_CLAUDE_API_TOKEN=tok-personal\nTODOIST_WORK_TOKEN=tok-work\n' > "$TMPROOT/secrets.env"

work_once() {
  rm -f "$CAPTURED_PROMPT" "$TMPROOT/captured-env.txt"
  env -u CLAUDE_TASKS_ROOT "$@" CLAUDE_TASKS_PROFILE_DIR="$PROFDIR" CLAUDE_TASKS_SECRETS="$TMPROOT/secrets.env" \
    "$HERE/claude-tasks-loop.sh" --profile work --once >"$TMPROOT/work.out" 2>&1
}

work_once -u TODOIST_CLAUDE_API_TOKEN || fail "--profile work failed to launch: $(cat "$TMPROOT/work.out")"
[ -f "$CAPTURED_PROMPT" ] || fail "--profile work did not fire"
grep -q 'Active claude-tasks profile: work' "$CAPTURED_PROMPT" || fail "work prompt does not name the work profile"
grep -q 'work-bot@example.com' "$CAPTURED_PROMPT" || fail "work prompt does not carry the work bot user"
grep -q "$PROFDIR/work.env" "$CAPTURED_PROMPT" || fail "work prompt does not point at the work profile file"
grep -q 'claude-loops/work/' "$CAPTURED_PROMPT" || fail "work run note is not under claude-loops/work/"
grep -q '^CLAUDE_TASKS_PROFILE=work$' "$TMPROOT/captured-env.txt" || fail "work firing did not inherit CLAUDE_TASKS_PROFILE=work"
grep -q '^CLAUDE_TASKS_TOKEN_VAR=TODOIST_WORK_TOKEN$' "$TMPROOT/captured-env.txt" || fail "work firing did not inherit the token variable name"
grep -q '^TODOIST_WORK_TOKEN=tok-work$' "$TMPROOT/captured-env.txt" || fail "work token was not read from the secrets file under the profile's variable"
if grep -q '^TODOIST_CLAUDE_API_TOKEN=' "$TMPROOT/captured-env.txt"; then
  fail "the work firing was handed the personal token"
fi
[ -n "$(ls "$XDG_STATE_HOME/claude-tasks-loop/work"/*.log 2>/dev/null || true)" ] \
  || fail "work profile did not log under its own state directory"
grep -q "firing from $WORKROOT" "$TMPROOT/work.out" || fail "work profile did not fire from its own root"
# With no root override, the profile's own worktrees path is honored as is.
[ -d "$TMPROOT/work-worktrees" ] || fail "work profile's worktrees dir was not created"
add_dirs | grep -qx "$TMPROOT/work-worktrees" || fail "work profile's worktrees dir was not passed as --add-dir"
grep -q "^CLAUDE_TASKS_WORKTREES=$TMPROOT/work-worktrees\$" "$TMPROOT/captured-env.txt" \
  || fail "work firing did not inherit the profile's worktrees path"

# The personal token in the environment, under its generic name, must not be
# taken for the work profile: the pre-check would watch the wrong queue.
work_once TODOIST_CLAUDE_API_TOKEN=tok-personal-env || fail "--profile work with a personal token in the env failed to launch"
grep -q '^TODOIST_WORK_TOKEN=tok-work$' "$TMPROOT/captured-env.txt" \
  || fail "work profile did not read its own token when a personal one was in the environment"

# Half-configured or unknown profiles refuse to launch rather than fire
# against nobody.
rm -f "$CAPTURED_PROMPT"
if env CLAUDE_TASKS_PROFILE_DIR="$PROFDIR" "$HERE/claude-tasks-loop.sh" --profile nope --once >/dev/null 2>&1; then
  fail "an unknown profile should refuse to launch"
fi
[ -f "$CAPTURED_PROMPT" ] && fail "an unknown profile fired anyway"
printf 'CLAUDE_TASKS_PROFILE=blank\nCLAUDE_TASKS_BOT_USER=\nCLAUDE_TASKS_ROOT=%s\n' "$WORKROOT" > "$PROFDIR/blank.env"
if env -u CLAUDE_TASKS_BOT_USER CLAUDE_TASKS_PROFILE_DIR="$PROFDIR" "$HERE/claude-tasks-loop.sh" --profile blank --once >/dev/null 2>&1; then
  fail "a profile with an empty bot user should refuse to launch"
fi
[ -f "$CAPTURED_PROMPT" ] && fail "a profile with an empty bot user fired anyway"

# CLAUDE_TASKS_PROFILE in the launching shell's environment selects a
# profile too, and --profile beats it.
rm -f "$CAPTURED_PROMPT"
env -u CLAUDE_TASKS_ROOT -u TODOIST_CLAUDE_API_TOKEN CLAUDE_TASKS_PROFILE=work CLAUDE_TASKS_PROFILE_DIR="$PROFDIR" \
  CLAUDE_TASKS_SECRETS="$TMPROOT/secrets.env" "$HERE/claude-tasks-loop.sh" --once >/dev/null 2>&1 \
  || fail "CLAUDE_TASKS_PROFILE=work failed to launch"
grep -q 'Active claude-tasks profile: work' "$CAPTURED_PROMPT" || fail "CLAUDE_TASKS_PROFILE did not select the work profile"

echo "PASS"
