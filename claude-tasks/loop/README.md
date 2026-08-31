# claude-tasks loop

Runs the `claude-tasks` skill headlessly on a timer, as an ordinary foreground
command you can watch and stop. Each firing is a fresh Claude Code session
(`claude -p`), so no context accumulates — all state lives in Todoist and the
vault, and every run re-surveys the queue from scratch.

    ./claude-tasks-loop.sh                  # adaptive pacing, 5m..30m
    ./claude-tasks-loop.sh 2m 1h            # custom min / max wait
    ./claude-tasks-loop.sh --once

There is **no scope argument**: the queue is every project shared with
Claude's own Todoist account (Coddingtonbot, `me+claude@adamcoddington.net`),
and every task in them assigned to it. You scope the loop by sharing a
project with that account and by removing it — the skill accepts pending
invitations at the start of each survey and never leaves a project on its
own.

**Pre-check**: before each tick fires, `claude-tasks-check.sh` asks Todoist's
API directly — no model, no tokens — whether anything could possibly have
changed, and a tick with nothing to do is skipped outright. That is the whole
saving: an idle firing used to cost the full skill body (~10-15k input tokens)
just to conclude there was nothing to do.

It does *not* reimplement the skill's rules for what counts as a candidate. It
answers a deliberately coarser question and is wrong only in the safe
direction: saying "skip" when there is work would lose a task, so every
uncertainty — no token, an HTTP error, an unparseable response — fires anyway.
Saying "fire" when there is nothing costs exactly one ordinary firing, which
is what every tick cost before. It runs with Claude's own token, so the
projects are discovered from the account's membership — nothing is configured
and no state flows from the firings to the check.

It fires when any of these hold:

- it can't tell (see above);
- a **share invitation is pending** — a new project is you saying "work here
  too", and the firing accepts it;
- a **task assigned to Claude has no open ask subtask** — released work
  nobody picked up, or a firing that crashed mid-claim; either way the next
  firing should look at it. (This also covers an answered ask: completing the
  ask subtask removes it from the open set, leaving the work task
  assigned-with-no-ask.) A standing positive: it keeps firing until the
  state changes, and deliberately records no fingerprint, so a crashed
  firing can never be fingerprinted into silence;
- a task bearing the skill's `Phase:` line is **no longer assigned to
  Claude** and has no `## Handing over` section — you took it back and the
  close-out hasn't run (also standing);
- the **fingerprint** of Claude's assigned tasks and their ask subtasks
  differs from the previous check's — covering your comment on an ask
  (`note_count` is in the fingerprint, since a new comment isn't guaranteed
  to bump `updated_at`), a description edit, and a change of ask. Tasks not
  assigned to Claude (and not asks) are ignored, so your own tasks in a
  shared project never trigger a firing;
- a **pull request a Waiting task points at has changed** — a review (the
  skill lets you answer a `Needs review: PR <n>` ask by approving or merging
  on GitHub, which touches nothing in Todoist), a comment, a push, a merge or
  close. The PRs to watch come from the `github.com/…/pull/<n>` URLs in those
  tasks' descriptions — the `Phase: … delivered — PR <url>` line the skill
  writes — which the same Todoist response already carries, so discovery is
  free — which also means a stale pointer is a blind spot: if a PR is closed
  and re-opened under a new number, the skill must move the task's pointers
  to the new one (its *When a PR is superseded* section), or the pre-check
  keeps watching the dead PR and sleeps through everything on the live one.
  Each PR is one `gh api repos/<o>/<r>/pulls/<n>` call, and its `updated_at`
  goes into the same fingerprint. This is deliberately coarse: Claude's own
  pushes and replies bump it too, at the price of one idle firing, exactly
  as its own Todoist writes already do. It needs `gh` logged in with read
  access to the repos (your own login is fine — the pre-check only reads);
  `gh` missing or failing fires, like every other uncertainty, so a lapsed
  token shows up as extra firings rather than as approvals silently sitting
  unnoticed.

It needs `TODOIST_CLAUDE_API_TOKEN` — **Coddingtonbot's** API token, not
yours — read from the environment, sourced from `~/.secrets` (override with
`CLAUDE_TASKS_SECRETS`), or, at loop launch, pulled from the td credential
store (`td --user me+claude@… auth token view`). `CLAUDE_TASKS_PRECHECK=0`
disables the pre-check entirely; `--once` ignores it, since that's an
explicit "run now".

**The loop reads the secrets file once, at launch.** `claude-tasks-loop.sh`
sources it before the first tick and exports `TODOIST_CLAUDE_API_TOKEN`, so a
grant-gated secrets file (a pipe whose every open asks the user to approve)
costs exactly one grant per launch, answered while you're still at the
terminal — the per-tick pre-check finds the token already in its environment
and never opens the file itself. Only the token is exported, not the rest of
the file: the firings' `td` CLI carries its own credentials (the system
credential manager). The check's own sourcing branch remains as a fallback
for running it standalone.

**It says what changed.** A "changed" verdict is followed by the snapshot
lines that differ — `was:` for how a task or PR looked at the previous check,
`now:` for how it looks now; a line with only a `was:` vanished, one with
only a `now:` is new. The lines are the raw fingerprint rows:
`id|responsible|updated_at|note_count|,labels,` for a task,
`owner/repo/n|pr|updated_at|state|merged|head-sha` for a PR. Every decision,
with those lines, is also appended to `$LOGDIR/precheck.log` (next to the
`queue.state` hash and `queue.snap` snapshot it compares against), so a run
of unexpected firings can be read back after the terminal has scrolled.

**It cooperates with the overlap lock.** A tick whose firing the `flock` would
turn away is skipped at the pre-check instead, before any API call — otherwise
the check would fingerprint a change, the firing would be refused the lock, and
that change would be recorded as handled without anyone acting on it. Belt and
braces: a firing that *is* turned away deletes the fingerprint, so nothing the
lock swallowed can be written off. A lock-blocked tick also stays at `min`
rather than backing off, which is what you want while the other loop works.

Run it by hand to see what it would decide — it prints its reasoning to stderr
and exits `0` to fire, `10` to skip:

    ./claude-tasks-check.sh; echo $?

**Pacing** is adaptive: the skill ends each loop-mode report with
`CLAUDE_TASKS_RESULT: worked` or `idle`. After `worked` the next tick is `min`
later; after `idle` the wait doubles, capped at `max`. A run with no marker
(crash, denied tools) counts as idle and logs a warning, so a broken setup
backs off instead of hammering. A *skipped* tick costs nothing, so it earns no
backoff and the wait stays at `min` — backoff exists to stop idle **firings**
burning tokens, and still does whenever the pre-check is off or failing open.
The practical effect is that a queue nobody has touched is watched cheaply
every `min` instead of being fired at with a growing delay, so a completed ask
subtask gets picked up sooner *and* for less. One known pathology: a task the
firing *cannot* act on (say, in a project Todoist has made view-only for the
free account) is a standing positive that keeps firing; each firing reports
the problem and ends `idle`, so backoff caps the cost until you fix the
membership.

Run it in a terminal or a tmux window. Output streams to the terminal *and*
to `~/.local/state/claude-tasks-loop/<timestamp>.log` (last 200 kept).

**Overlap protection**: each firing takes a non-blocking `flock`; a firing
that finds the lock held (a long-running previous firing, or a second copy of
the script) is skipped and noted in `skipped.log` rather than run alongside.

**Permissions**: headless runs cannot answer prompts, so the script passes
`--permission-mode acceptEdits` plus an `--allowedTools` list (the `td` CLI,
Obsidian MCP tools, file tools, `curl` for the invitation-acceptance sync
calls, and `git`/`gh`/`npm`/`npx`). A denied tool should surface in the run
as a `NEEDS: unblock`; extend the list via `CLAUDE_TASKS_ALLOWED_TOOLS` if
that happens. `CLAUDE_TASKS_ROOT` overrides the projects root (default
`~/Documents/Projects`); `CLAUDE_TASKS_BOT_USER` overrides the bot account
ref used in the prompt and the td-credential-store fallback.

**Permissions in practice**: headless runs never prompt — a tool outside the
allowlist is denied outright and the model is told so, which the skill turns
into a `NEEDS: unblock` on the task. Watch the log for "denied" if a run
stalls, then extend the allowlist.

**Run log**: each launch of the script gets one Obsidian note, in the vault's
`claude-loops/` folder, shared across every firing of that launch (a `--once`
run gets its own too) — the script passes the note's vault path and the
launch's real start time (from `date`) to each firing. The skill has the
first firing create the note and every firing that works a task append a
brief, timestamped line — task title, Todoist link, one-sentence summary,
and any major decision — so a launch's activity reads as one skimmable list,
with dates as Obsidian links (`[[2026-08-26]]`). Full detail stays on the
task's own Obsidian note, per the skill's Loop mode section. The note lives
in the vault, not on disk, so it isn't part of the `$LOGDIR` log rotation.

**Watching progress**: plain runs print only the final message. Set
`CLAUDE_TASKS_VERBOSE=1` to stream a live feed — each assistant message and
tool call as it happens, plus the result line with cost and turn count — while
the raw `stream-json` still goes to the log. The other live view is Todoist
itself: assignments, ask subtasks, and the `Phase:` line move as the run does.

**Model**: `CLAUDE_TASKS_MODEL=opus ./claude-tasks-loop.sh` (an alias or a
full model id) passes `--model` to each firing. Unset, firings use your normal
default (`"model"` in `~/.claude/settings.json`, or `ANTHROPIC_MODEL`).
