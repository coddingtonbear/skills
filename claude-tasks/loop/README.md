# claude-tasks loop

Runs the `claude-tasks` skill headlessly on a timer, as an ordinary foreground
command you can watch and stop. Each firing is a fresh Claude Code session
(`claude -p`), so no context accumulates — all state lives in TickTick and the
vault, and every run re-surveys the queue from scratch.

    ./claude-tasks-loop.sh            # every 30 minutes until Ctrl-C
    ./claude-tasks-loop.sh 10m        # custom interval
    ./claude-tasks-loop.sh --once     # one firing

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
