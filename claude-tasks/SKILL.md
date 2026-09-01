---
name: claude-tasks
description: Pick up, work, and file delegated Todoist tasks from Claude's own Todoist account (Coddingtonbot) — the queue is every task assigned to that account in the projects shared with it, in-progress work wears the claude-inflight label, plans are gated with the claude-plan-required label, decisions and reviews go back to the user as ask subtasks assigned to them, and the user takes work back by reassigning. Use when the user says "let's look at your tasks", "get started on whatever's next", "what's on your plate", "what needs me", "pick up the next task", "add a task for this", or otherwise asks Claude to work from or write to its Todoist queue.
---

# Working my delegated Todoist task queue

The user delegates tasks to me through Todoist, using **assignment between two accounts**: theirs (`me@adamcoddington.net`, uid 60535251) and mine (**Coddingtonbot**, `me+claude@adamcoddington.net`, uid 60537043). This skill defines how to find my tasks, how much autonomy each one grants, how work and decisions flow back to the user, and how to add new tasks to the queue.

All Todoist access goes through the official `td` CLI (`@doist/todoist-cli`), and **every queue operation runs as my account**: `td --user me+claude@adamcoddington.net …`. The user's account is td's default, so a `td` call without `--user` acts as *them* — never do that for queue work. Always pass `--json` (or `--ndjson`) when reading, and always reference tasks, projects, and comments as `id:<id>` — a bare ref is a fuzzy title search and can silently act on the wrong task.

## The hard boundary: only tasks assigned to me

The shared projects hold the user's own tasks alongside mine. **A task is mine if and only if it is assigned to Coddingtonbot.** Anything else — unassigned, or assigned to the user — I don't work, edit, complete, or comment on, even if it looks like something I could do. The full list of things I touch:

1. tasks assigned to me (the work);
2. ask subtasks I created (assigned to the user — see Handing off to the user);
3. a task bearing my `Phase:` line that is no longer assigned to me — the one-time handoff close-out (see Handing back);
4. *creating* new tasks (see Adding tasks to the queue) and accepting share invitations (below).

**Assignment moves in one direction: the user's.** They assign a task to me to release it; they reassign it away to take it back. I never assign, unassign, or reassign a work task — with one exception: a task the user names *in chat* counts as released (chat is their control surface), and I self-assign it on pickup so Todoist reflects what they said. Completing my own finished tasks is in scope, as ever.

## Scope is membership: the shared projects

My queue spans exactly the projects shared with my account — there is no scope argument, no group/area resolution. The user controls scope by sharing a project with `me+claude@adamcoddington.net` (instantly adds me — no acceptance step between accounts that already share something) and by removing my account from a project.

- **Accept pending invitations first.** Every survey starts by checking for pending share invitations and accepting them — a new project is the user saying "work here too." `td notification list`/`accept` are broken in td 2.1.0 (schema bug, confirmed 2026-08-31), so use the sync API with my token:

  ```
  POST https://api.todoist.com/api/v1/sync
    {"sync_token": "*", "resource_types": ["live_notifications"]}
    → notifications with notification_type "share_invitation_sent" and state "invited"
  POST … /sync  {"commands": [{"type": "accept_invitation", "uuid": "<uuid>",
                 "args": {"invitation_id": "…", "invitation_secret": "…"}}]}
  ```

  A newly visible project gets resolved to its vault note per Project resolution. (Pending invitations are rare in practice — they only occur before two accounts share anything — but checking is cheap.)
- **Never leave a project.** Both directions of membership are the user's: I accept, I never leave or remove myself, no matter how empty a project's queue is (user decision, 2026-08-31). Instead, mention drained projects in the survey report ("`markdown-patch` has nothing assigned to me") so the user can prune membership when they care to.
- **The free plan caps my account at 5 usable projects.** Todoist marks projects beyond the first 5 **View Only** in its UI for my account (the user manages this by keeping my membership at 5 or fewer). The API has been observed to accept writes in an over-limit project anyway (2026-08-31), so there's no reliable flag to check — instead, whenever my membership exceeds 5, say so prominently in the survey report, and treat any permission-style write failure as this limit biting: report which project, and hand the affected task's round back in chat (an ask subtask may not be creatable there).
- **Removal is the emergency stop.** If the user removes my account from a project, my assignments there are cleared and my access ends instantly — any in-flight state freezes where it was (the vault note keeps the durable record). The graceful way to take a task back is reassignment, which leaves me able to close out (see Handing back).

## Task states

A task's state is carried by its assignment plus the markers I own — the `Phase:` line in its description, the `claude-inflight` label, and its open ask subtask.

| State | Signal | Who sets it |
|---|---|---|
| **Queued** | Assigned to me, no `Phase:` line yet | the user (assigning is the release) |
| **In progress** | Assigned to me, `claude-inflight` + `Phase:` line present, no open ask subtask | me (the `Phase:` line is my claim — a concurrent session skips a claimed task) |
| **Waiting** | Assigned to me, with an open **ask subtask** assigned to the user | me |
| **Done** | Task completed | me |
| **Handed back** | `Phase:` line present but no longer assigned to me | the user (reassigning away = *stop, this is mine now*) |

- **`claude-inflight`** — the one label I manage, so the user can see at a glance what I'm actively working on (e.g. via a saved filter on `@claude-inflight`). Added when I claim a task, removed when it goes to Waiting (the ask on the user's plate is the signal then), re-added when an answered ask resumes work, and removed during a handback close-out. The `Phase:` line stays the authoritative claim; the label is the display. Every label change fetches the task first — `td task update --labels` **replaces the whole set**, so write back every other label untouched.
- **`claude-plan-required`** — a label, orthogonal to state: don't do the thing; tell the user what I *would* do. I investigate, write the plan into the task note, and hand off with a `Needs decision` ask subtask. Implementation starts only after the user answers that ask approving a plan. The label stays on the task as a record and doesn't force a new plan every round. It's the user's label: I never add it, and I leave it in place.

## Finding and choosing the next task

Figuring out *which project we're in* is step one — sessions normally start opened to a particular repository, and that repo determines which slice of the queue is relevant.

1. **Accept pending invitations** (see Scope is membership).
2. **Fetch my plate.** In-repo: normalize `git remote get-url origin`, enter Project resolution by `url`, resolve the note's `todoist-project` to a project id via `td --user me+claude@adamcoddington.net project list --json`, then `td --user … task list --project id:<id> --assignee me --json --all`. Across every project (global mode): `td --user … task list --filter "assigned to: me" --json --all`, grouped by project in the report.
3. **Classify each task**: fetch its open subtasks (`td --user … task list --parent id:<task> --json`) — an open subtask assigned to the user is its ask, and the task is Waiting; otherwise a `Phase:` line means In progress, none means Queued. Also scan the fetched projects for **handed-back tasks** — a `Phase:`-bearing task no longer assigned to me with no `## Handing over` section (see Handing back).
4. **Report the plate by state, Waiting first** — *Waiting (N)*, *Queued (N)*, *In progress (N)* — one line per task, and for Waiting and In progress tasks include the task's `Phase:` line (see Multi-phase tasks). Waiting is the user's inbox; leading with it is the point. Mention a handed-back task awaiting close-out too, but separately — it isn't waiting on the user. One already closed out isn't reported at all: it's no longer mine. Note drained projects here as well.
5. **Candidates are Queued tasks and answered Waiting tasks.**
   - Queued → a work candidate. Its description and comments are its instructions.
   - Waiting → if the ask subtask is gone from the open list, it was completed: fetch it by id — the `Ask:` link in the work task's `Phase:` block carries the id (see Multi-phase tasks) — with `td --user … task view id:<sub> --json`, then its comments with `td --user … comment list id:<sub> --json`; both work on completed tasks (verified 2026-08-31). Comment authorship is visible (separate accounts), so the user's words and mine are never confused.
     - **Completed** → the user is done with it and I may continue: their answer is the subtask's comments (in order) plus anything they added to its description; no comments and no description change = "take your recommendation". The parent is now a candidate and that answer is its instruction.
     - If the newest ask subtask is a `Needs review: PR <n>`, also check the PR itself — its review state and its unaddressed comments (see Responding to PR comments) — whether or not the ask subtask itself has moved. The user's GitHub approval or merge of the PR answers the ask just as completing the subtask does (see Approval on GitHub); a `Request changes` review is a non-approving reply.
     - **Open, newest comment is the user's** → a question or partial direction while they're still deciding. Answer it *in the same subtask* with a comment (investigate as needed; produce no deliverable). Todoist comments hold long markdown, so the answer normally fits in the comment; for something durable or heavily structured, append a `## Claude says (<timestamp>)` section to the subtask's description instead — never altering existing text — and leave a short comment pointing at it. Stay Waiting.
     - **Open, newest comment is mine (or none)** → untouched; skip.
   Then read each candidate's description fully, plus its comments (`td --user … comment list id:<task> --json`) — the user may still leave short notes there; a later comment supersedes the description where they conflict. A task whose description or comments say it is blocked on an incomplete task is not eligible.
6. **Choose**: a handed-back task awaiting close-out goes first, before anything else — it's cheap and clears the user's plate. Otherwise default to the order tasks appear in the project (top first — the order `td task list` returns). A task returning from Waiting (an answered ask subtask) generally goes first — the user has just spent attention on it and the context is warm. Otherwise take a task out of order only when it would genuinely be better done *after* work further down completes (it builds on, is blocked by, or would be reworked by that later task); a user-set priority (p1–p3) also outranks position. Skipping ahead needs no confirmation, but the skip must be called out — in the chat report *and* the dev log — with the rationale.
7. **Stale check.** An In progress task with no ask subtask, note edit, or commit from me in over a day is probably an abandoned session. Don't silently skip it: report it, and offer to resume it (read its task note/`Phase:` line and comments, then continue) before starting anything Queued.
8. **Drift check — within a round, not across rounds.** Rounds are never capped: every trip through Waiting is the user choosing to continue, and more questions are better than fewer, bigger ones. The risk is the *autonomous stretch inside a round*, where nobody is in the loop. So at every natural checkpoint — updating the `Phase:` line, abandoning an approach, before opening a PR, writing a dev-log entry — compare where the work is against the plan in the task note, and hand off with a `Needs decision` ask subtask when it has drifted: the approach has changed more than once, the change has grown past what the task described, or elapsed time (check `date` against the start time recorded in the `Phase:` line) is well beyond what the plan implied. Runaway effort is a decision the user gets to make, not something they discover in a bloated PR.
9. Work **one task at a time**. After finishing a round and reporting, offer to continue; don't chain through the whole queue unprompted unless the user asked for that.

### Interactive mode

The same survey and lifecycle run in an ordinary session — the user opens Claude Code (in a repo, or in `~/Documents/Projects` for the whole plate) and says "let's get started on your claude tasks". One task or round per ask; then report and stop, and take the user's next instruction: "continue" (next candidate by the usual rules), "what's on your plate", or **a task named in chat** — which counts as the user releasing it whether or not it's assigned yet (chat *is* their control surface): self-assign it on pickup so Todoist reflects the release, and say so in the report. The user may `/compact` or `/clear` between tasks freely: nothing carries over turns that isn't also in Todoist or the vault. Running interactively while the loop script is also running is safe — the `Phase:` line is the claim, so the two never take the same task — but the user should expect the script to grab the next Queued task while they're mid-conversation.

### Global mode: working across every project

When the session starts from a folder that contains the checkouts rather than from one of them — `~/Documents/Projects` is the intended root; `~/` also works but puts the whole home directory in scope and makes unanchored searches slow — or the user asks to look across projects:

1. **Fetch the whole plate**: `td --user … task list --filter "assigned to: me" --json --all`; group the report by project. The user may narrow it in chat ("just the obsidian projects") — that's a filter on the report and candidate order, not a change to what's mine.
2. **Resolve each task's project**: enter Project resolution (below) by `todoist-project`, then on to the verified checkout via `url` when the project has one.
3. **Read the repo's own instructions first.** Claude Code only loads `CLAUDE.md` and `.claude/settings.json` from the session's cwd and its ancestors, so a repo entered from outside brings none of its own rules along. Before any work, read `<path>/AGENTS.md` and `<path>/CLAUDE.md` (whichever exist) and follow them as if the session had started there. Its permission allowlist still won't apply, so expect more prompts than an in-repo session; that's normal.
4. **Work in that checkout with absolute paths** — `git -C`, `npm --prefix`, absolute file paths, and every Glob/Grep anchored under `<path>` — rather than changing directory, so nothing depends on the session's cwd. Everything else in the lifecycle is unchanged: the project note is the one found in step 2, task notes are its peers, branches come off that repo's `main`.
5. Still **one task at a time**, and say which project each report is about — in global mode the user has no cwd to infer it from.

Global mode is only reliable when the checkouts are inside the session's working directory (or were added with `--add-dir`); from an unrelated folder every file access will prompt. If that happens, say so and suggest restarting from `~/Documents/Projects` instead of fighting through prompts.

### Loop mode

The user runs this skill on a recurring schedule — normally `claude-tasks/loop/claude-tasks-loop.sh`, a foreground script that starts a fresh headless `claude -p` session per firing (so no context accumulates), or interactively with `/loop`. **A survey assumes nothing from earlier turns**: everything is re-fetched from Todoist and the vault every time, and a compacted or resumed session never acts on its summary of the queue. Each firing is the survey above over the whole plate (global mode), and a standing loop *is* the user's "continue": after a task's round ends, the next firing may pick up the next candidate without waiting for a nod. Everything else holds — one task per firing, ask-subtask handoffs, the standing gates, no merges. When the queue has nothing actionable, say so in one line ("queue empty — N waiting on you") and stop; don't invent work. **The last line of every loop-mode report is a machine-readable outcome marker** the loop script paces itself on: `CLAUDE_TASKS_RESULT: worked` if the firing changed anything (an accepted invitation, an ask subtask, a task note, a branch or PR, an answered reply, a handoff close-out), otherwise `CLAUDE_TASKS_RESULT: idle`. Emit it even when the firing ended in an ask-subtask handoff or an error — a handoff is `worked`. When self-pacing, wait longer while the queue is quiet and come back quickly after handing something off, since the user's reply is the likeliest next event.

Before each firing, the loop's pre-check (`loop/claude-tasks-check.sh`) asks Todoist directly — with my token, no model — whether anything could possibly have changed, and skips the firing outright when nothing has. It discovers the projects from my own membership, so no state flows from the firings to the pre-check.

**Run log.** The loop script also passes the vault path to a single run-log note, shared by every firing of that *launch* of the script (one note per invocation of `claude-tasks-loop.sh`, including a `--once` firing — not one per firing), plus the launch's actual start time from `date`: "Loop run note: vault path `claude-loops/<slug>.md` ... This launch started at `<ISO timestamp>`." Never guess any timestamp that goes into this note — every one comes from a `date` call, at the moment it's needed. Whenever a firing does anything (`CLAUDE_TASKS_RESULT: worked`), before emitting the marker:

- **Note doesn't exist yet** (the first firing of the launch) — create it with `vault_write`:
  ```
  # claude-tasks loop run

  Started: [[<date>]] <time>

  ## Tasks

  - <this firing's entry>
  ```
  using the launch-start timestamp given in the prompt (not a fresh `date` call — that's the *loop's* start, not this firing's), split into an Obsidian date link (`[[2026-08-26]]`) and a time (`11:20`).
- **Note already exists** (a later firing in the same launch) — `vault_patch`-append the entry under `## Tasks` instead of rewriting the note.

Entry, one line: `- [[<start date>]] <start time>–<end time> — [<task title>](<Todoist task URL>) — <what happened, one sentence>. Decision: <one sentence, if any major decision was made — omit otherwise>. Note: [<vault path>](<obsidian URI>) (if a task note exists)`. Get the start time from the task's `Phase:` line (set at first pickup from `date`, per Multi-phase tasks); get the end time with a fresh `date` call right before writing the entry. If the task spanned midnight, link both dates: `[[<start date>]] <start time>–[[<end date>]] <end time>`.

Build the Todoist task URL per Linking to Todoist tasks. Keep entries to one line each — this is an index for skimming a launch's activity, not a record; the detail lives on the task note's `# Decisions` and Development Logs (see Linking to vault notes), same as everywhere else. An `idle` firing writes nothing. If no run-note path was given in the prompt (e.g. running the skill's prompt by hand, outside the script), skip this step — it's a loop-script convenience, not a hard requirement of loop mode itself.

### Project resolution

Every project has **one vault note** tying its pieces together, and resolution — from either direction — is one move: look the note up by whichever frontmatter field is already known, then read everything else off it.

- **`todoist-project`** — the Todoist project holding this project's tasks. One Todoist project per note and one note per Todoist project: the pairing is the project's identity. Enter here when starting from the queue — project id → name via `td --user … project list --json`, then `search_query` on `{"==": [{"var": "frontmatter.todoist-project"}, "<name>"]}`. Matching is by this field only, never by the note's path or title, so a moved note keeps resolving. A Todoist project with no matching note gets one created on the spot — best guess, no waiting on the user: pick the folder by analogy with the existing project notes (a sibling of the most similar projects), write the note with `todoist-project` plus `url` only when a repository is evident from the project or its tasks, re-running the search first so an earlier firing's note isn't duplicated. Then flag the guess: one **top-level task in that same Todoist project, assigned to the user**, titled `Needs review: project note placement for <project>`, its description linking the new note (per Linking to vault notes) and stating what was guessed (folder; repo or none). It's fire-and-forget — nothing goes to Waiting over it and nothing resumes when it's completed; a wrong guess is fixed by moving the note.
- **`url`** — the repository behind the project, when one exists, in normalized HTTPS form (`git@github.com:owner/repo` ≡ `https://github.com/owner/repo`; no trailing `.git`). Enter here when starting from a checkout: normalize `git remote get-url origin` and match. The field also implies where the checkout lives — `~/Documents/Projects/<repo name from the url>` — verified before touching anything: the directory exists and `git -C <path> remote get-url origin`, normalized, equals `url`; a mismatch or missing checkout is a `Needs unblock` ask subtask (say which path was expected), never a reason to clone or pick a look-alike. A note without `url` is a repo-less project (next section). A *repo* without a matching note is the one lookup that asks instead of guessing: the unknown is which Todoist project the repo maps to, and guessing that wrong misroutes tasks rather than just misplacing a file.

Whichever field it was found by, keep the note in hand: its folder is where task notes live (see Task notes in the vault), and its Development Logs hold project-level findings.

### Repo-less projects

A project note may carry `todoist-project` and no `url` — a project with no repository behind it (career management, planning, pure research). These resolve normally per Project resolution; only the repo mechanics fall away:

- The checkout mechanics fall away: nothing to verify, no repo instructions to read (global mode's steps 3–4 don't apply). In-repo mode can never surface such a project — there's no repo to start a session from — so its tasks are reached in global mode or by the user naming them in chat.
- The vault side is unchanged: task notes are peers of the project note, `# Decisions` and Development Logs work as usual. Dev-log entries route to the project note already in hand from resolution — don't hunt for it by `url`.
- Deliverables are whatever the task defines — vault notes, documents, research write-ups (scope was never limited to coding). "Autonomy through to a PR" translates to autonomy through to the deliverable, and the round still ends the same way: a `Needs review` ask subtask linking to it. The standing gates apply untouched — in particular, anything outward-facing (sending, posting, publishing beyond the vault and Todoist) goes to Waiting first, exactly as ever.
- A task that turns out to need a repository after all — "put this in git", "set up a site for it" — is a `Needs unblock` ask subtask, not a cue to create or pick a repo.

## Autonomy and decision gates

**`claude-plan-required` present:** Investigate thoroughly (read code, reproduce, probe), form a recommended approach, write it into the task note's `# Outline and Plan` (options considered, recommendation, what would change, risks), and hand it back via a `Needs decision` ask subtask linking to the plan. Do not implement — no branch, no PR — until the user answers that ask approving a plan (completing it takes the recommended one). If the investigation produced durable findings, log them before stopping.

**`claude-plan-required` absent (default):** Autonomy through to a pull request — implement, write or update tests (per global standards: solid types, test coverage), verify the suite passes, commit on a feature branch, push, open a PR. This standing grant covers pushing the branch and opening the PR (with Claude's authorship stated in the commits and PR body, written in the user's own writing style per the **writing-style** skill); it does not cover merging, releases, replying to anyone, or anything else outward-facing — see *acting publicly on your behalf* below. **The grant only covers repos the user owns.** On a repo I don't own (a fork, a third-party project I'm contributing to), implementing and pushing a branch is still standing autonomy, but opening the PR itself is a publicly-visible act toward that project's maintainers, not the user's own space — draft the title and body (still in the user's writing style) and hand off with a `Needs review` ask subtask; open it only once the user approves.

**Standing gates — these always go to Waiting first, in either mode.** Autonomy is bounded by a fixed list of things the user has said they want a say in:

- changing public or documented behavior, an API surface, or a wire/file format;
- adding, removing, or upgrading a dependency;
- deleting, migrating, or rewriting persisted data, or changing a schema;
- choosing between materially different architectures or approaches when more than one is plausible and the task description doesn't pick;
- expanding scope beyond what the task describes, or dropping part of it;
- the task's premise turning out wrong (bug can't reproduce, the approach in the description won't work) — log the findings, then ask; never silently pivot to a different solution than the one described;
- anything touching an area the user has flagged (in the task, the project note, or CLAUDE.md) as sensitive;
- **acting publicly on your behalf.** Anything that becomes visible to someone other than the user — text that would read as written by a person, or an action taken in a shared or third-party space — is shown to the user first, unless the task explicitly says otherwise: comments and replies on issues, PRs, or discussions (especially to other people), emails and messages, reviews, release notes, posts, published site or documentation copy, merging a PR, cutting a release, opening a PR against a repo the user doesn't own, closing or labeling someone else's issue, anything going to a third party. Draft it in full — the exact text, or the concrete action and its effect — put it in a `Needs review` ask subtask, and act only after the user completes that subtask (or edits the draft in its description — the description's final text/action is what goes out). Silence is not approval: while the ask is open, nothing goes out. The one standing exception is the default PR grant above — pushing a branch and opening the PR **on a repo the user owns** is pre-approved, and so is merging that PR once the user has approved it on GitHub (see Approval on GitHub). Even there, commits and the PR go out under my own GitHub identity (`coddingtonbot`, author `me+claude@adamcoddington.net`), so nobody mistakes them for the user's — no extra "written by Claude" markers are needed — but the wording itself still follows the user's writing style (the **writing-style** skill). Pre-approval is about *whether* something goes out, never about *how* it's written: every piece of outward-facing writing matches the user's voice, gated or not.

Hitting a gate mid-task is not a failure; it's the loop working. Finish everything that doesn't depend on the answer, then hand off.

**Every decision I make on my own gets logged.** Any choice a reasonable reviewer might have wanted a say in — even if it didn't trip a gate — goes in the `# Decisions` table (see Task notes in the vault) marked *by: claude*, with the why. The user's review of a deliverable starts from that table, so it must be complete and honest, including decisions I'm not proud of.

**The PR must prove it isn't adding risk.** A PR is an argument to the reviewer, and its burden of proof is on me: demonstrate — with evidence, not assertion — that the work does not expose us to new risk of bugs. Ground the change in observed behavior (captures, live traffic, reference-client code) rather than assumption; enumerate the scenarios where the new behavior could plausibly be *worse* than the old and show what bounds each; state honest gaps (paths only unit-tested, scenarios never observed live) rather than leaving them for the reviewer to discover.

**Branching:** branch off up-to-date `main`, so each PR stands independent. When that doesn't make sense — the task builds on an unmerged branch, or main is broken — call it out: say what I branched from and why in both the report and the PR description. Branch names: short and descriptive (e.g. `fix/shared-zone-body-lookup`).

Scope is whatever the task says — tasks are not limited to coding. Research, writing, vault work, etc. are all fair game. If a task needs a capability I don't have, hand it back with a `Needs unblock` ask subtask rather than improvising around it.

## Handing off to the user: Waiting and the ask subtask

An **ask subtask** is the *only* way I ask the user for something — a real item assigned to them, with a full markdown description, that they answer by completing. Creating one puts the task in Waiting; assignment notifies them through Todoist itself.

**Create it** in one call — `--project` is required whenever `--assignee` is used, even with `--parent` (verified 2026-08-31):

```
td --user me+claude@adamcoddington.net task add "Needs <kind>: <one-line summary>" \
  --parent id:<work-task-id> --project id:<project-id> \
  --assignee me@adamcoddington.net --stdin --json < body.md
```

No labels, no priority, no due date. Title: `Needs <kind>: <one-line summary>` — no `@` tokens (see Task titles). Then record the created subtask's URL as the `Ask:` line in the work task's `Phase:` block (see Multi-phase tasks) — that id is how a later round finds the ask once it's completed. Description, in markdown:

```
Phase: 2/4 — checks reported, awaiting go-ahead on refactor options
Note: [projects/software/foo/Task title.md](obsidian://open?vault=Notes&file=…)   (if a task note exists)
PR: <link>                                                                          (if one exists)

## What I need
One paragraph: where the task stands and exactly what I'm asking for.

## Options            (decision only)
- **A** — …
- **B** — … *(recommended, because …)*
- **C** — …

## Look at
- links: PR, task note `#Decisions`, file:line …

## To answer
Reply in a comment on this subtask, then complete it — or just complete it to take the recommendation. Questions first? Comment and leave it open; I'll answer here.
```

Kinds:

- **decision** — a gate was hit or the approach needs choosing; options enumerated with a recommendation.
- **review** — a deliverable is done and wants eyes: a PR, or anything without a review loop of its own (an investigation, research, vault work, a write-up). For a PR the title is `Needs review: PR <n> — <title>` and the description carries the PR link, a short summary of the change, the integration-test evidence, the `# Decisions` link, and what to look at first; the code review itself still happens on GitHub — the ask is the pointer on the user's plate, and review-comment rounds ("address X") flow back through it like any other reply. Comments posted directly on the PR are picked up too, without waiting for the user to relay them — see Responding to PR comments. For a non-PR deliverable the description reads like a PR description: what was asked, what was done and why, what changed with links, risks, what to look at, honest gaps.
- **answer** — a factual question only the user can answer.
- **unblock** — something I can't do (missing access, capability, or credential; failing infrastructure), and what would unblock it.

**The user's moves.** Completing the ask subtask is the one signal that I may continue — nothing on the work task needs to change:

- **accept** — complete it without commenting: take my recommendation and go.
- **respond** — comment (or write in the description, for something long), then complete: the reply is the instruction.
- **discuss** — comment and leave it open: I answer in the same subtask with a comment and keep waiting. As many rounds as they like; it's the conversation for that ask. Authorship distinguishes us — no prefixes needed.
- **edit** — change the work task's description: I re-read it on pickup.
- **ignore** — leave it open and silent: still thinking; the task is not mine to touch.

I never complete an ask subtask myself — with one exception: when the user answers a `Needs review: PR <n>` ask on GitHub instead (see Approval on GitHub), I complete it, after leaving a comment linking the approval or merge, so the transcript still records how the round ended. I never change its title or the text already in its description (appending a `## Claude says (<timestamp>)` section is the one allowed edit), and never reuse one for a new ask: each new question after a completed ask gets a fresh subtask, so the work task's completed subtasks are the transcript in order. Then **stop**: report in chat what I handed off, with the subtask's title, and end the turn.

### Linking to vault notes

Todoist can't search the vault, and `obsidian://` links don't open on iOS, so every pointer I leave in a task — the `Note:` line and `Look at` section of an ask subtask, a task description that cites a dev-log entry — is a markdown link whose **label is the full vault path as readable text** and whose target is the Obsidian URI:

```
[projects/software/icloud-md/Shared note editing.md](obsidian://open?vault=Notes&file=projects/software/icloud-md/Shared%20note%20editing)
```

On desktop it's a click; on a phone the label is enough to find the note by hand. The vault is named `Notes`. In the URI, encode spaces as `%20` and keep folder separators as `/`; to land on a section, append the heading: `...&file=<path>%23Decisions` (and say so in the label: `… .md › Decisions`). Always link to the task note's `# Decisions` section in a `Needs review` subtask and in the finishing report, since that's where the user's review starts. Also include the link in the chat report so the user can open the note from either side.

### Linking to Todoist tasks

Any link to a Todoist task, anywhere — PR descriptions, vault notes and dev-log entries, ask-subtask descriptions, follow-up tasks, loop run notes, chat reports — uses the task's `url` field, returned verbatim by `td task view id:<id> --json` and `td task add --json` (shape: `https://app.todoist.com/app/task/<slug>-<id>`). Don't hand-build task URLs from ids alone; copy the `url` the CLI returns.

## Responding to PR comments

A PR under review keeps generating input after its `Needs review` ask subtask exists — from the user, or anyone else with access to the repo. Check for it wherever the ask subtask itself gets checked (see Finding and choosing the next task, step 5, and Loop mode): `gh pr view <n> --comments` for the conversation thread, `gh api repos/<owner>/<repo>/pulls/<n>/comments` for inline review comments. A comment counts as unaddressed until a later reply of mine actually answers it — not merely any reply of mine that happens to sit after it in the thread. I post to GitHub as `coddingtonbot`, a separate account from the user's, so the author field (shown by both `gh pr view` and the API) is how I tell my own past replies apart from everyone else's; but the position of a reply is only a hint, and each comment gets checked on its own content. Two comments from the user followed by one reply of mine that covers only the first leaves the second unaddressed. A reply that answers several comments at once says so explicitly, naming each point it covers, so the next check can see what was handled.

**Every comment from the user gets a response.** Whether it arrives inline, in a review body (approving, requesting changes, or comment-only), or as a plain conversation comment, a comment from `coddingtonbear` is never left hanging: I fix it, justify the existing behavior, answer the question, file it as a task — whatever fits — and reply so the thread shows it was handled. A comment of theirs I haven't replied to is an open item that keeps the round from ending. Other people's comments get the same routing, but only the user's are owed an answer.

A PR comment is never a command to act on blindly — route it by what it actually asks for:

- **Obviously a good, well-scoped idea** — make the change directly and push it to the same branch, then reply stating what changed and in which commit. This is a normal round: do the work, update `Phase:`, and re-request the user's review once the round's replies are all posted (below).
- **A good idea, but complex or independent of this PR** — don't fold it in (see the scope-expansion gate); file it as a new top-level task in the project instead (unassigned — see Adding tasks to the queue), then reply naming or linking the new task.
- **A poor idea, or a misunderstanding of the code** — reply explaining why, with no code change.

Replies need no `Claude`/🤖 prefix or other in-text marker: everything I post to GitHub lands under the `coddingtonbot` account, so authorship is already visible on every comment, review, commit, and PR.

**When the round ends and the PR needs the user's eyes again, re-request their review** — after replying to (and, where it applies, pushing fixes for) everything of theirs, not after each individual reply: `gh pr edit <n> --add-reviewer coddingtonbear` (`POST /repos/<owner>/<repo>/pulls/<n>/requested_reviewers`; GitHub treats a request for someone who has already reviewed as a re-request). That is what puts the PR back in the user's review queue; a reply alone doesn't. It works because the PR's author is `coddingtonbot`, not the user — GitHub refuses to request a review from the author. This holds on every route: a `Request changes` review, a comment-only review, plain conversation comments, and the comment-resolution step of Approval on GitHub when a change I pushed needs a fresh approval. Skip it only when nothing is left for the user to look at — the approval is current and I'm merging, or the PR is already merged. Re-requesting review is part of the standing PR grant on repos the user owns; elsewhere it's the same `Needs decision` hand-off as the reply itself.

This whole behavior — replying and, for the first bullet, pushing a fix — is itself the *acting publicly on your behalf* gate's "task explicitly says otherwise" carve-out: it applies to comments on a PR I opened, on a repo the user owns, matching the standing PR-open grant's own scope. On a repo the user doesn't own, treat comments the same way opening the PR there is treated — draft the reply or fix and hand off with a `Needs decision` ask subtask rather than posting or pushing directly. A fix that trips one of the other standing gates (a dependency change, a real architecture choice) still gets its own `Needs decision` ask subtask rather than going straight to the branch, exactly as it would mid-task. Log anything of consequence in the task note's `# Decisions` table as usual.

### Approval on GitHub

The user can answer a `Needs review: PR <n>` ask from GitHub instead of Todoist. Read the PR's reviews wherever the ask gets checked (`gh pr view <n> --json reviews,mergedAt,headRefOid`, or `gh api repos/<owner>/<repo>/pulls/<n>/reviews`). Two signals count, and only from the user's own account (`coddingtonbear` — another collaborator's approval is welcome but doesn't close the user's review):

- **Merged** — the strongest answer. Nothing left to do on the PR: complete the ask subtask (with a comment linking the merge), complete the work task, finish as usual.
- **Approved** — a review with state `APPROVED` on the PR's *current* head commit. An approval GitHub has marked stale (I pushed after it) doesn't count; wait for a fresh one. A `Request changes` review is the opposite: it's the next round's instruction, handled through the comment routing above, and nothing closes.

An approval means "merge it, once the comments are handled", so, in order:

1. **Resolve every unaddressed comment on the PR first** — inline review comments, the review body, and the conversation thread — using the routing above. Comments whose resolution is obvious and well-scoped: make the change, push, reply. A comment that is unclear, controversial, or would need one of the other standing gates: reply asking or explaining, **stop here** — don't merge, stay Waiting, and say so in the report. The approval is still on file; once the user answers and the comment is resolved, continue from here (a reply from them that changes the code invalidates the approval anyway, so a fresh one will be needed — re-request their review after pushing it, per Responding to PR comments).
2. **Merge** — only on a repo the user owns; elsewhere an approval is a `Needs decision` ask to merge, like anything else public there. Match the repo's existing merge convention (look at how recent PRs were merged: merge commits vs squash vs rebase; `AGENTS.md` wins if it says), delete the remote branch, and confirm the merge landed.
3. **Close out** — comment on the ask subtask linking the approval and the merge, complete the ask subtask, then complete the work task and finish as usual (dev log, report). This is the one case where I complete an ask subtask myself.

### When a PR is superseded

Whenever a delivered PR stops being *the* PR — it was closed and re-opened under a new number (same branch or a fresh one), split, or replaced — every pointer to it in Todoist moves in the same round, before I finish: the work task's `Phase: … delivered — PR <url>` line, the `Needs review: PR <n>` ask subtask's title and its `PR:` line, and a one-line `Superseded: PR <old> was closed and re-opened as PR <new> (<why>, <date>)` note at the top of each description so the history stays legible. Then a comment on the ask subtask naming the new PR. These pointers are what everything downstream keys on — the approval check above reads the number from the ask's title, and the loop's pre-check ([loop/README.md](loop/README.md)) watches only the PR URLs found in Waiting tasks' descriptions — so a stale one means a review, a comment, or a merge on the *real* PR goes unnoticed for as long as the old number stands. A closed PR that a Waiting task still points at is a bug in the queue, not a state to leave it in.

## Handing back: when a task becomes the user's

The user takes a task off my plate by **reassigning it** — to themselves, or to nobody. It means *stop; this is mine now*, and it's terminal: once closed out, the task never comes back as a candidate unless they assign it to me again (which is a fresh release).

**Detecting one:** a task bearing my `Phase:` line that is no longer assigned to me, with no `## Handing over` section yet in its description, still needs the close-out — run it before anything else in the survey (see Choose above). One that already has that section is done with: skip it silently, like any other task that isn't mine. (An ask subtask is never a handoff candidate — its parent is the work task, and its `Phase:` line belongs to the ask body's template.)

**The close-out**, once per task:

1. Read the task, its note (if one exists), its comments, and any still-open ask subtask.
2. Append a `## Handing over` section to the **task description** (not the note) — state of play, what's done, what's left as concrete next steps, links to the note/branch/PR, and why it stopped. Never alter the user's existing text.
3. If a task note exists, log a `# Decisions` row marked *by: user* and a dev-log entry, so it never reads later as an abandoned task.
4. Remove `claude-inflight` if the task still wears it — it's my label, and it now asserts something false. Every other label stays exactly as it is.
5. If there's a still-open ask subtask, unassign it (`td --user … task update id:<ask> --unassign`) — it now asserts something false, that I'm waiting on an answer. This is the one edit I make to an ask subtask besides appending a `## Claude says` section; I still never complete one.

If the user removes my account from the project instead of reassigning, none of this is possible — access is gone and assignments were cleared (verified 2026-08-31). That's the emergency stop: the vault note keeps the durable state, and nothing more is owed.

**Filing the user's own slice.** Not every user-only step is a whole-task handoff — often it's one step inside a task I'm otherwise continuing (a manual verification, something needing access I don't have). For that, file it as a real top-level task in the same project, **assigned to the user**, linking the originating work task by URL in its description. This is a standing autonomous action — no gate — since it only ever creates a task; do it in addition to, not instead of, describing the step in an ask-subtask description where one exists, since the standalone task is what survives after that ask is completed.

## Multi-phase tasks: one task, many rounds

A task often goes through several rounds — check a PR, report; propose refactor options, get a choice; implement. That is **one work task**; the only subtasks are my ask subtasks, one per round. The rounds are In progress → Waiting (open ask) → (user completes the ask) → In progress, and the sequence of completed ask subtasks is the transcript.

- **`Phase:` block.** The first lines of the task description are lines I own: `Phase: 2/4 — checks reported, awaiting go-ahead on refactor options (started 2026-08-24T19:18)`, and — whenever the task is Waiting — an `Ask: [<subtask title>](<subtask url>)` line naming the current ask subtask, so a later round can fetch it by id even after it's completed (completed tasks vanish from listings but stay fetchable by id — verified 2026-08-31). The start timestamp is set at first pickup (from `date`, never from memory) and carried unchanged so later checkpoints can see elapsed time. Setting the `Phase:` line at pickup is also the **claim**: a concurrent session treats any `Phase:`-bearing assigned task as taken. Update the block every time the task changes state. It answers "where is this and what's next" without reading the thread. Insert it above the user's original description on first pickup; never alter their text. When the task is waiting on a PR, the `Phase:` line's `delivered — PR <url>` must carry the PR's full `https://github.com/<owner>/<repo>/pull/<n>` URL: the loop's pre-check (`claude-tasks/loop/claude-tasks-check.sh`) reads it from Waiting tasks to know which PRs to watch for the user's review, so a missing or shortened URL means a GitHub approval goes unnoticed until something else changes in the queue.
- **Plan grows, doesn't rewrite.** The task note's `# Outline and Plan` gets a `## Phase N` subsection per round rather than being rewritten, so the history of what was asked stays visible.
- **Close-out happens once**, when the final round's deliverable exists.

## Task notes in the vault

A task note is created **when there is something to hold**, not for every task:

- create one when the task is `claude-plan-required`, when it will produce a PR, when it goes multi-phase, or as soon as a decision needs logging;
- skip it for small autonomous tasks with nothing to plan or decide — log durable findings in the project note's Development Logs instead.

When a note exists:

- **Location**: the same folder as the project note — a *peer* of it, not a child.
- **Name**: the task's Todoist title, lightly normalized into a vault-safe filename — keep it recognizable. If a note by that name already exists, read it first and reuse it (a prior attempt) rather than clobbering it; never overwrite a note I didn't create.
- **Sections**:
  - `# Outline and Plan` — a restatement of the ask in my own words followed by the plan, with `## Phase N` subsections as rounds accrue. For `claude-plan-required` this doubles as the proposal.
  - `# Decisions` — a table: `date · decision · by (claude / user) · why`. Every choice of consequence, mine or theirs; the user's answers to ask subtasks are recorded here too so the note is self-contained.
  - `# Development Logs` — per the **dev-log** skill. With a task note in play, entries about *this task's* work go here; the project note's Development Logs remain for findings that outlive any single task.
- **`url` frontmatter — set when the PR is posted**: the PR's HTTPS URL, so the dev-log skill routes future sessions against that PR to this note. For non-PR deliverables, the deliverable's canonical URL if it has one; otherwise leave it unset.

All vault access goes through `mcp__obsidian__*` tools per the **dev-log** skill's cautions — never filesystem writes.

## Task lifecycle in Todoist

**On starting (from Queued):** read the repo's `AGENTS.md` if it has one — the user keeps project instructions there, and Claude Code does *not* load it automatically (only `CLAUDE.md`), so unless a `CLAUDE.md` imports it (`@AGENTS.md`) or symlinks to it, those instructions reach me only by reading the file deliberately. Then re-fetch comments — new guidance may have landed since the survey. Set the `Phase:` line (the claim), add `claude-inflight` (fetch first; preserve every other label), and create the task note if warranted.

**On needing the user:** create the ask subtask (assigned to them), update `Phase:` (including the `Ask:` line), remove `claude-inflight`, report, stop.

**On finishing — once the deliverable exists (PR posted, or non-PR work done), in order:**

1. **Task note `url`**: set it to the PR's HTTPS URL (see Task notes in the vault).
2. **Integration-test evidence comment**: run the project's live/integration suite on the branch (for icloud-md: `ICLOUD_MD_ITEST=1 npm run test:integration`) and post a PR comment with the results. Concrete numbers from the run, corroborating evidence, an explicit accounting of any new risks and what bounds each, and the honest gaps. If the suite fails or can't run, say so in the comment and the report — never skip silently.
3. **Dev log**: add an entry (almost always warranted for code work) to the task note's `# Development Logs` (or the project note's, if no task note) — invoke the **dev-log** skill for the conventions. Cover what was done, key decisions/trade-offs, branch name, verification. Make sure `# Decisions` is complete.
4. **Hand off for review** — always, PR or not: a `Needs review` ask subtask, update `Phase:` to `delivered — PR <url>` (or the deliverable's link). When the user completes the ask with no reply or an approving one ("looks good"), or approves or merges the PR on GitHub (see Approval on GitHub), complete the work task — closing my own tasks is in scope; the user reviews the deliverable, not the task. Any other reply (review comments to address, a change of direction) is the next round's instruction, and the work continues on the same branch and PR.
5. **Report, then pause**: summarize what was done, the PR link and the `obsidian://` link to the task note (see Linking to vault notes), what to look at (point at `# Decisions` first), anything surprising — then stop and invite review before continuing.

**When blocked or the premise fails:** a `Needs unblock` or `Needs decision` ask subtask as appropriate, report. Never leave a task claimed-but-askless at the end of a turn unless I'm genuinely mid-work and about to continue.

## Task titles: the `@` hazard

Todoist parses `@word` in a **task title on creation** — quick-add style — even through `td task add`'s structured flags and the API (verified live 2026-08-31): the token is silently stripped from the title and attached as a label, and **a label that doesn't exist yet is invented on the spot**. A title like `Follow up with @sean on the review`, or `Email @john about the launch`, silently becomes a mislabeled task plus, possibly, a brand-new label polluting the account.

The verified edges (2026-08-31): `#word` in a title is *not* parsed (PR/issue references like `PR #482` are safe); `+name` is *not* parsed (assignee syntax is a quick-add-UI behavior only); descriptions are not parsed at all; and `td task update --content` does not re-parse. The hazard is `@` in a title at creation, only.

**Rule: no `@` token in a title passed to `td task add` (or `td task quickadd`, which parses everything by design), unless it is a deliberate reference to a label.** Before any create call, scan the title for `@` and resolve each occurrence:

- **Not meant as a label** (the common case — handles, mentions, email addresses): rewrite it out. `@john` → `John`; `reply to @coddingtonbear` → `reply to coddingtonbear`. An email address in the middle of a title is safest spelled without the `@` (`me at example.com`) or moved to the description, which isn't parsed.
- **Meant as a label**: don't spell it in the title. Put the bare name in `--labels` instead, and only after confirming it exists via `td --user … label list --json`. Inventing labels is the user's call, not mine.

Comments and descriptions are safe — neither has been observed to parse tokens.

If a create call's `--json` response comes back with labels beyond what was passed in `--labels`, that's this hazard firing: fix the task immediately (`td task update` with the corrected title and label set) rather than leaving the stray label in place, and if a stray label was invented, delete it with `td label delete` and say so in the report.

If the user dictates a title containing an `@` token, apply the rewrite and mention it in the report; keep it verbatim only if they say the label is what they want.

## Adding tasks to the queue

The user will often ask me to capture work into Todoist (follow-ups discovered mid-task, findings from reviews, ideas from discussion).

- **Title**: short and recognizable — and free of `@` tokens.
- **Project**: the current project's Todoist project (it must be one shared with me — if none fits, say so and ask rather than reaching for a project I can't see).
- **Assignment**: **unassigned** — releasing work to me is the user's gesture, so I never assign a captured task to myself, even one that's obviously for me; say in the report that it's ready to assign. A task that is *the user's* step (see Filing the user's own slice) is assigned to them.
- **Priority**: none — leave it unset (p4) unless the user says otherwise.
- **Description**: detailed. Outline the work already performed: what was investigated, what was found (with file/function references), why it matters, and any recommended direction. Reference the relevant dev-log entry by note title and timestamp when one exists. A future reader (me, months later, with no context) should be able to start from the description alone.
- **Not a subtask** of the current work task — subtasks under a work task are reserved for ask subtasks. Follow-ups are top-level tasks that link the originating task by URL (see Linking to Todoist tasks) in the description.
- **Labels**: none. Never add `claude-plan-required` — requiring a plan is the user's decision.
- Capturing several at once is just several `td task add` calls.
