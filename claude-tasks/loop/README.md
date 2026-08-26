# claude-tasks loop

Runs the `claude-tasks` skill headlessly on a timer, as an ordinary foreground
command you can watch and stop. Each firing is a fresh Claude Code session
(`claude -p`), so no context accumulates — all state lives in TickTick and the
vault, and every run re-surveys the queue from scratch.

    ./claude-tasks-loop.sh "the life group"            # adaptive pacing, 5m..30m
    ./claude-tasks-loop.sh "the work group" 2m 1h      # custom min / max wait
    ./claude-tasks-loop.sh "life and open-source" --once

The first argument is the **scope** — the TickTick project groups and/or lists
to work, phrased as the skill's prompt expects ("the work group", "life and
open-source", "the icloud-md list"). It is required: scope always comes from
the prompt, never from the filesystem, and a headless run can't ask.
`CLAUDE_TASKS_SCOPE` can supply it instead.

**Pre-check**: before each tick fires, `claude-tasks-check.sh` asks TickTick's
API directly — no model, no tokens — whether anything could possibly have
changed, and a tick with nothing to do is skipped outright. That is the whole
saving: an idle firing used to cost the full skill body (~10-15k input tokens)
just to conclude there was nothing to do.

It does *not* reimplement the skill's rules for what counts as a candidate. It
answers a deliberately coarser question and is wrong only in the safe
direction: saying "skip" when there is work would lose a task, so every
uncertainty — no token, no resolved scope, an HTTP error, an unparseable
response — fires anyway. Saying "fire" when there is nothing costs exactly one
ordinary firing, which is what every tick cost before. **The pre-check can only
remove firings from the schedule, never add them**, and there is nothing in it
to drift out of sync with the skill text.

It fires when any of these hold:

- it can't tell (see above);
- an open task in scope carries `claude-ready` (released work nobody picked up)
  or `claude-inflight` (a firing that didn't finish cleanly — normal firings
  leave neither tag behind);
- the fingerprint of the `claude`-tagged open tasks in scope differs from the
  previous check's. This covers a completed ask subtask (completed tasks drop
  out of the API response entirely, and completing a subtask does *not* bump
  its parent's `modifiedTime` — so a timestamp watermark alone would miss the
  single most important event), a new comment, a body edit, a retag, and a
  newly added task. Tasks without a `claude*` tag are ignored, so the user's
  own tasks in a shared list never trigger a firing.

It needs `TICKTICK_API_TOKEN` (read from the environment, or sourced from
`~/.secrets` — override with `CLAUDE_TASKS_SECRETS`) and the **scope-ids file**
`$LOGDIR/scope.ids`, which each firing writes: the scope string on line 1, one
project id per line after it. Until a firing has written one, every tick fires
exactly as before. `CLAUDE_TASKS_PRECHECK=0` disables the pre-check entirely;
`--once` ignores it, since that's an explicit "run now".

**It cooperates with the overlap lock.** A tick whose firing the `flock` would
turn away is skipped at the pre-check instead, before any API call — otherwise
the check would fingerprint a change, the firing would be refused the lock, and
that change would be recorded as handled without anyone acting on it. Belt and
braces: a firing that *is* turned away deletes the fingerprint, so nothing the
lock swallowed can be written off. A lock-blocked tick now also stays at `min`
rather than backing off, which is what you want while the other loop works.

Both the scope-ids file and the fingerprint are **keyed by scope**
(`scope-<hash>.ids`, `queue-<hash>.state`), so running one loop over the work
group and another over life doesn't have them overwriting each other's state —
which would leave both permanently failing open and silently doing no good.

Run it by hand to see what it would decide — it prints its reasoning to stderr
and exits `0` to fire, `10` to skip:

    CLAUDE_TASKS_SCOPE="the work group" ./claude-tasks-check.sh; echo $?

**Pacing** is adaptive: the skill ends each loop-mode report with
`CLAUDE_TASKS_RESULT: worked` or `idle`. After `worked` the next tick is `min`
later; after `idle` the wait doubles, capped at `max`. A run with no marker
(crash, denied tools) counts as idle and logs a warning, so a broken setup
backs off instead of hammering. A *skipped* tick costs nothing, so it earns no
backoff and the wait stays at `min` — backoff exists to stop idle **firings**
burning tokens, and still does whenever the pre-check is off or failing open.
The practical effect is that a queue nobody has touched is watched cheaply
every `min` instead of being fired at with a growing delay, so a completed ask
subtask gets picked up sooner *and* for less.

Run it in a terminal or a tmux window. Output streams to the terminal *and*
to `~/.local/state/claude-tasks-loop/<timestamp>.log` (last 200 kept).

**Overlap protection**: each firing takes a non-blocking `flock`; a firing
that finds the lock held (a long-running previous firing, or a second copy of
the script) is skipped and noted in `skipped.log` rather than run alongside.

**Permissions**: headless runs cannot answer prompts, so the script passes
`--permission-mode acceptEdits` plus an `--allowedTools` list (TickTick and
Obsidian MCP tools, file tools, and `git`/`gh`/`npm`/`npx`). A denied tool
should surface in the run as a `NEEDS: unblock`; extend the list via
`CLAUDE_TASKS_ALLOWED_TOOLS` if that happens. `CLAUDE_TASKS_ROOT` overrides the
projects root (default `~/Documents/Projects`).

**Permissions in practice**: headless runs never prompt — a tool outside the
allowlist is denied outright and the model is told so, which the skill turns
into a `NEEDS: unblock` on the task. Watch the log for "denied" if a run
stalls, then extend the allowlist.

**Run log**: each launch of the script gets one Obsidian note, in the vault's
`claude-loops/` folder, shared across every firing of that launch (a `--once`
run gets its own too) — the script passes the note's vault path and the
launch's real start time (from `date`) to each firing. The skill has the
first firing create the note and every firing that works a task append a
brief, timestamped line — task title, TickTick link, one-sentence summary,
and any major decision — so a launch's activity reads as one skimmable list,
with dates as Obsidian links (`[[2026-08-26]]`). Full detail stays on the
task's own Obsidian note, per the skill's Loop mode section. The note lives
in the vault, not on disk, so it isn't part of the `$LOGDIR` log rotation.

**Watching progress**: plain runs print only the final message. Set
`CLAUDE_TASKS_VERBOSE=1` to stream a live feed — each assistant message and
tool call as it happens, plus the result line with cost and turn count — while
the raw `stream-json` still goes to the log. The other live view is TickTick
itself: the `Phase:` line and the `claude-*` tag move as the run does.

**Model**: `CLAUDE_TASKS_MODEL=opus ./claude-tasks-loop.sh` (an alias or a
full model id) passes `--model` to each firing. Unset, firings use your normal
default (`"model"` in `~/.claude/settings.json`, or `ANTHROPIC_MODEL`).
