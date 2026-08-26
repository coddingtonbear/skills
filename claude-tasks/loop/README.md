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

**Pacing** is adaptive: the skill ends each loop-mode report with
`CLAUDE_TASKS_RESULT: worked` or `idle`. After `worked` the next firing is
`min` later; after `idle` the wait doubles, capped at `max`. A run with no
marker (crash, denied tools) counts as idle and logs a warning, so a broken
setup backs off instead of hammering.

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
