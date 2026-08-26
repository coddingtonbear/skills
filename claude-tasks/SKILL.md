---
name: claude-tasks
description: Pick up, work, and file delegated TickTick tasks using the claude-* status tags (claude / claude-ready / claude-inflight / claude-waiting / claude-handoff / claude-plan-required), hand decisions and reviews back to the user as markdown ask subtasks (claude-needs-you), take a task off Claude's plate and onto the user's (claude-handoff), and name tasks safely (the "#" tag hazard). Use when the user says "let's look at your tasks", "get started on whatever's next", "what's on your plate", "what needs me", "pick up the next task", "add a task for this", or otherwise asks Claude to work from or write to its TickTick queue.
---

# Working my delegated TickTick task queue

The user delegates tasks to me through TickTick. This skill defines how to find those tasks, how much autonomy each one grants, how work and decisions flow back to the user, and how to add new tasks to the queue.

## The hard boundary: only `claude`-tagged tasks

The project lists are shared: the user's own tasks live in the same lists as mine. **I only ever read as candidates, tag, comment on, or complete tasks that carry the `claude` tag.** A task without `claude` is the user's, full stop — I don't touch it, even if it looks like something I could do. (Adding tasks is the one exception: I may *create* tasks, tagged per Adding tasks to the queue.)

## Status: one `claude-*` tag at a time

A task's status is carried by **at most one** of three status tags, layered on the `claude` ownership tag. Tags are account-wide, so this works in every list with no per-list setup.

| State | Tags | Meaning for a `claude` task | Who sets it |
|---|---|---|---|
| **Backlog** | `claude` only | Queued but not released. Never start it. | the user |
| **Ready** | `claude` + `claude-ready` | Released — I may pick it up. | the user |
| **In progress** | `claude` + `claude-inflight` | I'm actively working it. Already claimed — don't start it again. | me |
| **Waiting** | `claude` + `claude-waiting` | Blocked on the user: a decision, a review, an answer, or an unblock. Always accompanied by an open **ask subtask** (see Handing off to the user) that the user answers by completing. | me |
| **Done** | *(task completed)* | Finished. Completion is the state; no tag needed. | me |

**Invariant:** never more than one of `claude-ready` / `claude-inflight` / `claude-waiting` on a task. Every status change is a single `update_task` that fetches the current tags first, removes the old status tag, adds the new one, and **preserves every other tag untouched** — other tags are the user's business. A task found carrying two status tags is corrupt: don't guess, report it and leave it alone until the user fixes it.

`claude-handoff` sits outside this enum. The user adds it alongside whatever status tag is already there — it is never stripped or swapped — to mean *stop; this is mine now*. See Handing back: when a task becomes the user's.

Fetch a list's queue with `mcp__ticktick__filter_tasks` `{"tag": ["claude"], "status": [0], "projectIds": ["<list-id>"]}` and bucket by status tag client-side (don't trust multi-tag filtering to mean AND). A cross-list "what needs me" is `{"tag": ["claude-needs-you"], "status": [0]}` with no `projectIds` — the open ask subtasks. The user may keep TickTick smart lists on these tags (e.g. "Needs me" on `claude-needs-you`); nothing in the skill depends on them.

## Tag vocabulary

- **`claude`** — the user wants *me* to take this task on. The gate for everything in this skill.
- **`claude-ready`**, **`claude-inflight`**, **`claude-waiting`** — the status enum above. I set `claude-inflight` and `claude-waiting`; the user sets `claude-ready` (and I remove it when I pick the task up).
- **`claude-needs-you`** — carried by *ask subtasks* only (never by a work task): the things I've handed to the user. Open = awaiting them; completed = answered. This is the user's inbox.
- **`claude-plan-required`** — orthogonal to status: don't do the thing; tell the user what I *would* do. I investigate, write the plan into the task note, and hand off with a `Needs decision` ask subtask. Work starts only after the user releases the task (`claude-ready`) with the plan in hand. The tag is satisfied once that release has happened — it stays on the task as a record, but doesn't force a new plan every round. When absent, I have autonomy within the standing gates (see Autonomy and decision gates).
- **`claude-handoff`** — the user's override: *stop, this is mine now*. They add it to the work task itself, or to any of its still-open ask subtasks (I walk up to the parent via `parentId`) — whichever's in front of them. Terminal, and doesn't replace the tag already there — nothing gets stripped. See Handing back: when a task becomes the user's.

`claude`, `claude-ready`, `claude-plan-required`, and `claude-handoff` are the user's control surface: I add `claude` only when capturing new tasks, and I never add `claude-ready`, `claude-plan-required`, or `claude-handoff`. Legacy tags are retired: treat `greenlit` as `claude-ready` and `discuss-first` as `claude-plan-required` if encountered, swap them during pickup, and mention it in the report; `claude-complete` is simply dropped.

## Finding and choosing the next task

Figuring out *which project we're in* is step one — sessions normally start opened to a particular repository, and that repo determines which slice of the queue is relevant.

1. **Identify the current project's TickTick list.** From the working directory: `git remote get-url origin`, normalize the URL (`git@github.com:owner/repo` ≡ `https://github.com/owner/repo`), find the vault note with that `url` frontmatter, and read its `ticktick-list` field — that's the list name. Resolve it to a list id via `mcp__ticktick__list_projects`. Keep this note handy: its folder is where task notes live (see Task notes in the vault), and its Development Logs hold project-level findings.
2. **Fetch and bucket** the list's open `claude` tasks by status tag. A task also carrying `claude-handoff` is bucketed separately, regardless of its status tag — see Handing back: when a task becomes the user's.
3. **Report the plate by status, Waiting first.** When asked what's on my plate / what needs them, answer in this order — *Waiting (N)*, *Ready (N)*, *In progress (N)*, *Backlog (N)* — one line per task, and for Waiting and In progress tasks include the task's `Phase:` line (see Multi-phase tasks). Waiting is the user's inbox; leading with it is the point. Mention a `claude-handoff` task awaiting close-out too, but separately — it isn't waiting on the user. One already closed out isn't reported at all: it's no longer mine.
4. **Candidates are `claude-ready` tasks and answered Waiting tasks.**
   - `claude-ready` → a work candidate. Its body and comments are its instructions.
   - `claude-waiting` → fetch its subtasks (`get_task_by_id` on the parent for `childIds`, then on each child) and find my newest ask subtask (tagged `claude-needs-you`). Then fetch that subtask's comments (`get_comment`). A comment of mine always starts with `Claude says:`; anything else is the user's.
     - **Completed** → the user is done with it and I may continue: their answer is the subtask's comments (in order) plus anything they added to its body; no comments and no body change = "take your recommendation". The parent is now a candidate and that answer is its instruction. No change to the parent's tags is needed from the user.
     - If the newest ask subtask is a `Needs review: PR <n>` and the PR is still open, also check the PR itself for unaddressed comments (see Responding to PR comments) — this happens whether or not the ask subtask itself has moved.
     - **Open, newest comment is the user's** → a question or partial direction while they're still deciding. Answer it *in the same subtask* with a comment starting `Claude says:` (investigate as needed; produce no deliverable). If the answer needs more than a comment's 1024 characters, append a `## Claude says (<timestamp>)` section to the subtask's body — never altering existing text — and leave a short `Claude says:` comment pointing at it. Stay `claude-waiting`.
     - **Open, newest comment is mine (or none)** → untouched. **No ask subtask at all** (a task handed off under the retired comment scheme) → migrate once: turn my newest `NEEDS:` comment into an ask subtask of the same kind, carrying its content into the markdown body, and report the migration; don't treat the comment as answered.
   Then read each candidate's `content` fully, plus its comments (`get_comment`) — the user may still leave short notes there; a later comment supersedes the body where they conflict. A task whose body or comments say it is blocked on an incomplete task is not eligible.
5. **Choose**: a `claude-handoff` task awaiting close-out goes first, before anything else — it's cheap and clears the user's plate. Otherwise default to the order tasks appear in the list (top first — `sortOrder`). A task returning from Waiting (an answered ask subtask) generally goes first — the user has just spent attention on it and the context is warm. Otherwise take a task out of order only when it would genuinely be better done *after* work further down completes (it builds on, is blocked by, or would be reworked by that later task); a user-set priority (nonzero) also outranks position. Skipping ahead needs no confirmation, but the skip must be called out — in the chat report *and* the dev log — with the rationale.
6. **Stale check.** An In progress task with no ask subtask, note edit, or commit from me in over a day is probably an abandoned session. Don't silently skip it: report it, and offer to resume it (read its task note/`Phase:` line and comments, then continue) before starting anything from Ready.
7. **Drift check — within a round, not across rounds.** Rounds are never capped: every trip through Waiting is the user choosing to continue, and more questions are better than fewer, bigger ones. The risk is the *autonomous stretch inside a round*, where nobody is in the loop. So at every natural checkpoint — updating the `Phase:` line, abandoning an approach, before opening a PR, writing a dev-log entry — compare where the work is against the plan in the task note, and hand off with a `Needs decision` ask subtask when it has drifted: the approach has changed more than once, the change has grown past what the task described, or elapsed time (check `date` against the start time recorded in the `Phase:` line) is well beyond what the plan implied. Runaway effort is a decision the user gets to make, not something they discover in a bloated PR.
8. Work **one task at a time**. After finishing a round and reporting, offer to continue; don't chain through the whole queue unprompted unless the user asked for that.

### Interactive mode

The same survey and lifecycle run in an ordinary session — the user opens Claude Code (in a repo for that list's slice, or in `~/Documents/Projects` and names the groups/lists) and says "let's get started on your claude tasks in the life group". One task or round per ask; then report and stop, and take the user's next instruction: "continue" (next candidate by the usual rules), "what's on your plate", or **a task named in chat** — which counts as the user releasing it, `claude-ready` or not, since chat *is* their control surface (still only `claude`-tagged tasks; still swap it to `claude-inflight` on pickup). The user may `/compact` or `/clear` between tasks freely: nothing carries over turns that isn't also in TickTick or the vault. Running interactively while the loop script is also running is safe — `claude-inflight` is the claim, so the two never take the same task — but the user should expect the script to grab the next Ready task while they're mid-conversation.

### Loop mode

The user runs this skill on a recurring schedule — normally `claude-tasks/loop/claude-tasks-loop.sh`, a foreground script that starts a fresh headless `claude -p` session per firing (so no context accumulates), or interactively with `/loop`. **A survey assumes nothing from earlier turns**: everything is re-fetched from TickTick and the vault every time, and a compacted or resumed session never acts on its summary of the queue. Each firing is the survey above, and a standing loop *is* the user's "continue": after a task's round ends, the next firing may pick up the next candidate without waiting for a nod. Everything else holds — one task per firing, ask-subtask handoffs, the standing gates, no merges. When the queue has nothing actionable, say so in one line ("queue empty — N waiting on you") and stop; don't invent work. **The last line of every loop-mode report is a machine-readable outcome marker** the loop script paces itself on: `CLAUDE_TASKS_RESULT: worked` if the firing changed anything (a status tag, an ask subtask, a task note, a branch or PR, an answered reply, a handoff close-out), otherwise `CLAUDE_TASKS_RESULT: idle`. Emit it even when the firing ended in an ask-subtask handoff or an error — a handoff is `worked`. When self-pacing, wait longer while the queue is quiet and come back quickly after handing something off, since the user's reply is the likeliest next event.

**Run log.** The loop script also passes the vault path to a single run-log note, shared by every firing of that *launch* of the script (one note per invocation of `claude-tasks-loop.sh`, including a `--once` firing — not one per firing), plus the launch's actual start time from `date`: "Loop run note: vault path `claude-loops/<slug>.md` ... This launch started at `<ISO timestamp>`." Never guess any timestamp that goes into this note — every one comes from a `date` call, at the moment it's needed. Whenever a firing does anything (`CLAUDE_TASKS_RESULT: worked`), before emitting the marker:

- **Note doesn't exist yet** (the first firing of the launch) — create it with `vault_write`:
  ```
  # claude-tasks loop run

  Started: [[<date>]] <time>
  Scope: <scope>

  ## Tasks

  - <this firing's entry>
  ```
  using the launch-start timestamp given in the prompt (not a fresh `date` call — that's the *loop's* start, not this firing's), split into an Obsidian date link (`[[2026-08-26]]`) and a time (`11:20`).
- **Note already exists** (a later firing in the same launch) — `vault_patch`-append the entry under `## Tasks` instead of rewriting the note.

Entry, one line: `- [[<start date>]] <start time>–<end time> — [<task title>](<ticktick task URL>) — <what happened, one sentence>. Decision: <one sentence, if any major decision was made — omit otherwise>. Note: [<vault path>](<obsidian URI>) (if a task note exists)`. Get the start time from the task's `Phase:` line (set at first pickup from `date`, per Multi-phase tasks); get the end time with a fresh `date` call right before writing the entry. If the task spanned midnight, link both dates: `[[<start date>]] <start time>–[[<end date>]] <end time>`.

Get the TickTick task URL from `https://ticktick.com/webapp/#p/<projectId>/tasks/<taskId>`. Keep entries to one line each — this is an index for skimming a launch's activity, not a record; the detail lives on the task note's `# Decisions` and Development Logs (see Linking to vault notes), same as everywhere else. An `idle` firing writes nothing. If no run-note path was given in the prompt (e.g. running the skill's prompt by hand, outside the script), skip this step — it's a loop-script convenience, not a hard requirement of loop mode itself.

If there's no repo context (or its list has no Ready tasks), say so and ask which groups or lists to work (see Global mode) rather than silently going global. If no vault note matches the repo, ask where the project lives rather than guessing.

### Global mode: working across every project

When the session starts from a folder that contains the checkouts rather than from one of them — `~/Documents/Projects` is the intended root; `~/` also works but puts the whole home directory in scope and makes unanchored searches slow — or the user asks to look across lists, work a *scoped* slice of the queue rather than one list's:

0. **Scope comes from the prompt, never from the filesystem.** The user names the TickTick project groups (folders) and/or lists to work — "…your claude tasks in the *work* group", "…in *life* and *open-source*". Resolve group names via `mcp__ticktick__list_project_groups` and list names via `list_projects`, then take every list whose `groupId` is one of the named groups plus every list named directly; that set is the `projectIds` for this session. **If nothing is named, ask** — "which groups or lists should I work: life, work, …?" — and do nothing until answered. Never widen to the whole account on my own. A headless run has nobody to ask: report the missing scope, emit `CLAUDE_TASKS_RESULT: idle`, and stop (the loop script requires the scope argument for this reason).
1. **Fetch within scope**: `filter_tasks` `{"tag": ["claude"], "status": [0], "projectIds": [<scoped ids>]}`, plus the same for `claude-waiting`; bucket by status tag as usual, and group the report by list.
2. **Resolve each task's project**: list id → list name (`list_projects`) → the vault note whose `ticktick-list` frontmatter matches (`search_query` on `{"==": [{"var": "frontmatter.ticktick-list"}, "<name>"]}`) → that note's `url`. A task whose list has no project note is not workable in global mode: report it as "no project mapping" and skip it rather than guessing a repo.
3. **Resolve the checkout**: the note's `path` frontmatter if present; otherwise `~/Documents/Projects/<repo name from the url>`. Verify before touching anything: the directory exists and `git -C <path> remote get-url origin`, normalized, equals the note's `url`. A mismatch or missing checkout is a `Needs unblock` ask subtask (say which path was expected), not a reason to clone or pick a look-alike.
4. **Read the repo's own instructions first.** Claude Code only loads `CLAUDE.md` and `.claude/settings.json` from the session's cwd and its ancestors, so a repo entered from outside brings none of its own rules along. Before any work, read `<path>/AGENTS.md` and `<path>/CLAUDE.md` (whichever exist) and follow them as if the session had started there. Its permission allowlist still won't apply, so expect more prompts than an in-repo session; that's normal.
5. **Work in that checkout with absolute paths** — `git -C`, `npm --prefix`, absolute file paths, and every Glob/Grep anchored under `<path>` — rather than changing directory, so nothing depends on the session's cwd. Everything else in the lifecycle is unchanged: the project note is the one found in step 2, task notes are its peers, branches come off that repo's `main`.
6. Still **one task at a time**, and say which project each report is about — in global mode the user has no cwd to infer it from.

Global mode is only reliable when the checkouts are inside the session's working directory (or were added with `--add-dir`); from an unrelated folder every file access will prompt. If that happens, say so and suggest restarting from `~/Documents/Projects` instead of fighting through prompts.

## Autonomy and decision gates

**`claude-plan-required` present:** Investigate thoroughly (read code, reproduce, probe), form a recommended approach, write it into the task note's `# Outline and Plan` (options considered, recommendation, what would change, risks), and hand it back via a `Needs decision` ask subtask linking to the plan. Do not implement — no branch, no PR — until the user releases the task with `claude-ready`. If the investigation produced durable findings, log them before stopping.

**`claude-plan-required` absent (default):** Autonomy through to a pull request — implement, write or update tests (per global standards: solid types, test coverage), verify the suite passes, commit on a feature branch, push, open a PR. This standing grant covers pushing the branch and opening the PR (with Claude's authorship stated in the commits and PR body, written in the user's own writing style per the **writing-style** skill); it does not cover merging, releases, replying to anyone, or anything else outward-facing — see *acting publicly on your behalf* below. **The grant only covers repos the user owns.** On a repo I don't own (a fork, a third-party project I'm contributing to), implementing and pushing a branch is still standing autonomy, but opening the PR itself is a publicly-visible act toward that project's maintainers, not the user's own space — draft the title and body (still in the user's writing style) and hand off with a `Needs review` ask subtask; open it only once the user approves.

**Standing gates — these always go to Waiting first, in either mode.** Autonomy is bounded by a fixed list of things the user has said they want a say in, regardless of tags:

- changing public or documented behavior, an API surface, or a wire/file format;
- adding, removing, or upgrading a dependency;
- deleting, migrating, or rewriting persisted data, or changing a schema;
- choosing between materially different architectures or approaches when more than one is plausible and the task body doesn't pick;
- expanding scope beyond what the task describes, or dropping part of it;
- the task's premise turning out wrong (bug can't reproduce, the approach in the body won't work) — log the findings, then ask; never silently pivot to a different solution than the one described;
- anything touching an area the user has flagged (in the task, the project note, or CLAUDE.md) as sensitive;
- **acting publicly on your behalf.** Anything that becomes visible to someone other than the user — text that would read as written by a person, or an action taken in a shared or third-party space — is shown to the user first, unless the task explicitly says otherwise: comments and replies on issues, PRs, or discussions (especially to other people), emails and messages, reviews, release notes, posts, published site or documentation copy, merging a PR, cutting a release, opening a PR against a repo the user doesn't own, closing or labeling someone else's issue, anything going to a third party. Draft it in full — the exact text, or the concrete action and its effect — put it in a `Needs review` ask subtask, and act only after the user completes that subtask (or edits the draft in its body — the body's final text/action is what goes out). Silence is not approval: while the ask is open, nothing goes out. The one standing exception is the default PR grant above — pushing a branch and opening the PR **on a repo the user owns** is pre-approved. Even there, the commit messages and PR body still say plainly that Claude wrote them (`Co-Authored-By: Claude`, "Generated with Claude Code") so nobody mistakes them for the user's voice — but the wording itself still follows the user's writing style (the **writing-style** skill). Pre-approval is about *whether* something goes out, never about *how* it's written: every piece of outward-facing writing matches the user's voice, gated or not.

Hitting a gate mid-task is not a failure; it's the loop working. Finish everything that doesn't depend on the answer, then hand off.

**Every decision I make on my own gets logged.** Any choice a reasonable reviewer might have wanted a say in — even if it didn't trip a gate — goes in the `# Decisions` table (see Task notes in the vault) marked *by: claude*, with the why. The user's review of a deliverable starts from that table, so it must be complete and honest, including decisions I'm not proud of.

**The PR must prove it isn't adding risk.** A PR is an argument to the reviewer, and its burden of proof is on me: demonstrate — with evidence, not assertion — that the work does not expose us to new risk of bugs. Ground the change in observed behavior (captures, live traffic, reference-client code) rather than assumption; enumerate the scenarios where the new behavior could plausibly be *worse* than the old and show what bounds each; state honest gaps (paths only unit-tested, scenarios never observed live) rather than leaving them for the reviewer to discover.

**Branching:** branch off up-to-date `main`, so each PR stands independent. When that doesn't make sense — the task builds on an unmerged branch, or main is broken — call it out: say what I branched from and why in both the report and the PR description. Branch names: short and descriptive (e.g. `fix/shared-zone-body-lookup`).

Scope is whatever the task says — tasks are not limited to coding. Research, writing, vault work, etc. are all fair game. If a task needs a capability I don't have, hand it back with a `Needs unblock` ask subtask rather than improvising around it.

## Handing off to the user: Waiting and the ask subtask

Setting `claude-waiting` is the *only* way I ask the user for something, and it always comes with exactly one **ask subtask** — a real item on the user's list, with a full markdown body, that they answer by completing. Comments are not used for handoffs: they're capped at 1024 plain-text characters and are tedious to find.

**Create it** in two calls — `create_task` **ignores `parentId`** (verified 2026-08-25: the task lands top-level), so create it, then `update_task` with `parentId` = the work task and confirm the response shows it — a minimal `{id, projectId, parentId}` update sometimes comes back with `parentId` still null and the etag unchanged; if so, retry including `title`, `tags`, and `status` in the payload, which has always taken. Same `projectId` as the parent, tags `["claude-needs-you"]` (nothing else — it's the user's item, not a work task), no priority, no due date. Title: `Needs <kind>: <one-line summary>` — no `#` characters (see Task titles). Body, in markdown:

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
- **review** — a deliverable is done and wants eyes: a PR, or anything without a review loop of its own (an investigation, research, vault work, a write-up). For a PR the title is `Needs review: PR <n> — <title>` and the body carries the PR link, a short summary of the change, the integration-test evidence, the `# Decisions` link, and what to look at first; the code review itself still happens on GitHub — the ask is the pointer in the user's inbox, and review-comment rounds ("address X") flow back through it like any other reply. Comments posted directly on the PR are picked up too, without waiting for the user to relay them — see Responding to PR comments. For a non-PR deliverable the body reads like a PR description: what was asked, what was done and why, what changed with links, risks, what to look at, honest gaps.
- **answer** — a factual question only the user can answer.
- **unblock** — something I can't do (missing access, capability, or credential; failing infrastructure), and what would unblock it.

**The user's moves.** Completing the ask subtask is the one signal that I may continue — nothing on the parent task needs to change:

- **accept** — complete it without commenting: take my recommendation and go.
- **respond** — comment (or write in the body, for something long), then complete: the reply is the instruction.
- **discuss** — comment and leave it open: I answer in the same subtask with a `Claude says:` comment and keep waiting. As many rounds as they like; it's the conversation for that ask.
- **edit** — change the work task's body: I re-read it on pickup.
- **ignore** — leave it open and silent: still thinking; the task is not mine to touch.

Every comment I write on an ask subtask starts with `Claude says:` — we share one TickTick account, so the prefix is the only thing that distinguishes my words from the user's. I never complete an ask subtask myself, never change its title or the text already in its body (appending a `## Claude says (<timestamp>)` section is the one allowed edit), and never reuse one for a new ask: each new question after a completed ask gets a fresh subtask, so the parent's completed subtasks are the transcript in order. Then **stop**: report in chat what I handed off, with the subtask's title, and end the turn.

### Linking to vault notes

TickTick can't search the vault, and `obsidian://` links don't open on iOS, so every pointer I leave in a task — the `Note:` line and `Look at` section of an ask subtask, a task body that cites a dev-log entry — is a markdown link whose **label is the full vault path as readable text** and whose target is the Obsidian URI:

```
[projects/software/icloud-md/Shared note editing.md](obsidian://open?vault=Notes&file=projects/software/icloud-md/Shared%20note%20editing)
```

On desktop it's a click; on a phone the label is enough to find the note by hand. The vault is named `Notes`. In the URI, encode spaces as `%20` and keep folder separators as `/`; to land on a section, append the heading: `...&file=<path>%23Decisions` (and say so in the label: `… .md › Decisions`). Always link to the task note's `# Decisions` section in a `Needs review` subtask and in the finishing report, since that's where the user's review starts. Also include the link in the chat report so the user can open the note from either side.

## Responding to PR comments

A PR under review keeps generating input after its `Needs review` ask subtask exists — from the user, or anyone else with access to the repo. Check for it wherever the ask subtask itself gets checked (see Finding and choosing the next task, step 4, and Loop mode): `gh pr view <n> --comments` for the conversation thread, `gh api repos/<owner>/<repo>/pulls/<n>/comments` for inline review comments. A comment counts as unaddressed if nothing after it, by anyone, starts with 🤖 — that prefix is how I tell my own past replies apart from everyone else's on a shared account.

A PR comment is never a command to act on blindly — route it by what it actually asks for:

- **Obviously a good, well-scoped idea** — make the change directly and push it to the same branch, then reply 🤖 stating what changed and in which commit. This is a normal round: swap to `claude-inflight`, do the work, swap back to `claude-waiting` and update `Phase:`, same as any other round.
- **A good idea, but complex or independent of this PR** — don't fold it in (see the scope-expansion gate); file it as a new top-level task in the list instead (untagged unless it's clearly mine — see Adding tasks to the queue), then reply 🤖 naming or linking the new task. No status change needed — this doesn't touch the parent task.
- **A poor idea, or a misunderstanding of the code** — reply 🤖 explaining why, with no code change. No status change needed.

**Every reply I post to GitHub is prefixed with 🤖**, on all three of the above and everywhere else I comment on a PR — a plain-text reply is indistinguishable from the user's own words on a shared account, and the emoji is the only thing that tells them apart at a glance.

This whole behavior — replying and, for the first bullet, pushing a fix — is itself the *acting publicly on your behalf* gate's "task explicitly says otherwise" carve-out: it applies to comments on a PR I opened, on a repo the user owns, matching the standing PR-open grant's own scope. On a repo the user doesn't own, treat comments the same way opening the PR there is treated — draft the reply or fix and hand off with a `Needs decision` ask subtask rather than posting or pushing directly. A fix that trips one of the other standing gates (a dependency change, a real architecture choice) still gets its own `Needs decision` ask subtask rather than going straight to the branch, exactly as it would mid-task. Log anything of consequence in the task note's `# Decisions` table as usual.

## Handing back: when a task becomes the user's

The user can take a task off my plate entirely by adding `claude-handoff` — to the work task itself, or to any of its ask subtasks (I resolve to the parent via `parentId`), whichever's in front of them. It means *stop; this is mine now*, and it's terminal: once closed out, the task never comes back as a candidate, regardless of what other tags it still carries.

**Detecting one:** a `claude-handoff` task with no `## Handing over` section yet in its body still needs the close-out — run it before anything else in the survey (see Choose above). One that already has that section is done with: skip it silently, the same as a task with no `claude` tag.

**The close-out**, once per task:

1. Read the task, its note (if one exists), its comments, and any still-open ask subtask.
2. Append a `## Handing over` section to the **task body** (not the note) — state of play, what's done, what's left as concrete next steps, links to the note/branch/PR, and why it stopped. Never alter the user's existing text.
3. If a task note exists, log a `# Decisions` row marked *by: user* and a dev-log entry, so it never reads later as an abandoned task.
4. Leave every tag exactly as it is — the user does not want tags stripped on handoff.
5. If there's a still-open ask subtask, remove only its `claude-needs-you` tag (it now asserts something false — that I'm waiting on an answer). This is the one edit I make to an ask subtask besides appending a `## Claude says` section; I still never complete one.

**Filing the user's own slice.** Not every user-only step is a whole-task handoff — often it's one step inside a task I'm otherwise continuing (a manual verification, something needing access I don't have). For that, file it as a real top-level task in the same list, **left untagged** so it's automatically theirs (see the hard boundary), linking the originating work task by URL in its body. This is a standing autonomous action — no gate — since it only ever creates a task and never touches one that isn't mine; do it in addition to, not instead of, describing the step in an ask-subtask body where one exists, since the standalone task is what survives after that ask is completed.

## Multi-phase tasks: one task, many rounds

A task often goes through several rounds — check a PR, report; propose refactor options, get a choice; implement. That is **one work task**; the only subtasks are my ask subtasks, one per round. The rounds are In progress → Waiting (open ask) → (user completes the ask) → In progress, and the sequence of completed ask subtasks is the transcript.

- **`Phase:` line.** The first line of the task body is a line I own: `Phase: 2/4 — checks reported, awaiting go-ahead on refactor options (started 2026-08-24T19:18)`. The start timestamp is set at first pickup (from `date`, never from memory) and carried unchanged so later checkpoints can see elapsed time. Update it every time the task changes status. It answers "where is this and what's next" without reading the thread. Insert it above the user's original body on first pickup; never alter their text.
- **Plan grows, doesn't rewrite.** The task note's `# Outline and Plan` gets a `## Phase N` subsection per round rather than being rewritten, so the history of what was asked stays visible.
- **Close-out happens once**, when the final round's deliverable exists.

## Task notes in the vault

A task note is created **when there is something to hold**, not for every task:

- create one when the task is `claude-plan-required`, when it will produce a PR, when it goes multi-phase, or as soon as a decision needs logging;
- skip it for small autonomous tasks with nothing to plan or decide — log durable findings in the project note's Development Logs instead.

When a note exists:

- **Location**: the same folder as the project note — a *peer* of it, not a child.
- **Name**: the task's TickTick title, lightly normalized into a vault-safe filename — keep it recognizable. If a note by that name already exists, read it first and reuse it (a prior attempt) rather than clobbering it; never overwrite a note I didn't create.
- **Sections**:
  - `# Outline and Plan` — a restatement of the ask in my own words followed by the plan, with `## Phase N` subsections as rounds accrue. For `claude-plan-required` this doubles as the proposal.
  - `# Decisions` — a table: `date · decision · by (claude / user) · why`. Every choice of consequence, mine or theirs; the user's answers to ask subtasks are recorded here too so the note is self-contained.
  - `# Development Logs` — per the **dev-log** skill. With a task note in play, entries about *this task's* work go here; the project note's Development Logs remain for findings that outlive any single task.
- **`url` frontmatter — set when the PR is posted**: the PR's HTTPS URL, so the dev-log skill routes future sessions against that PR to this note. For non-PR deliverables, the deliverable's canonical URL if it has one; otherwise leave it unset.

All vault access goes through `mcp__obsidian__*` tools per the **dev-log** skill's cautions — never filesystem writes.

## Task lifecycle in TickTick

**On starting (from Ready):** read the repo's `AGENTS.md` if it has one — the user keeps project instructions there, and Claude Code does *not* load it automatically (only `CLAUDE.md`), so unless a `CLAUDE.md` imports it (`@AGENTS.md`) or symlinks to it, those instructions reach me only by reading the file deliberately. Then re-fetch comments — new guidance may have landed since the survey. Swap `claude-ready` for `claude-inflight` (fetch the task first; keep every other field and tag intact), set or update the `Phase:` line, and create the task note if warranted.

**On needing the user:** create the ask subtask, update `Phase:`, swap `claude-inflight` for `claude-waiting`, report, stop.

**On finishing — once the deliverable exists (PR posted, or non-PR work done), in order:**

1. **Task note `url`**: set it to the PR's HTTPS URL (see Task notes in the vault).
2. **Integration-test evidence comment**: run the project's live/integration suite on the branch (for icloud-md: `ICLOUD_MD_ITEST=1 npm run test:integration`) and post a PR comment with the results. Concrete numbers from the run, corroborating evidence, an explicit accounting of any new risks and what bounds each, and the honest gaps. If the suite fails or can't run, say so in the comment and the report — never skip silently.
3. **Dev log**: add an entry (almost always warranted for code work) to the task note's `# Development Logs` (or the project note's, if no task note) — invoke the **dev-log** skill for the conventions. Cover what was done, key decisions/trade-offs, branch name, verification. Make sure `# Decisions` is complete.
4. **Hand off for review** — always, PR or not: a `Needs review` ask subtask, update `Phase:` to `delivered — PR <url>` (or the deliverable's link), swap to `claude-waiting`. When the user completes the ask with no reply or an approving one (merged, "looks good"), complete the work task — closing my own tasks is in scope; the user reviews the deliverable, not the task. Any other reply (review comments to address, a change of direction) is the next round's instruction, and the work continues on the same branch and PR.
5. **Report, then pause**: summarize what was done, the PR link and the `obsidian://` link to the task note (see Linking to vault notes), what to look at (point at `# Decisions` first), anything surprising — then stop and invite review before continuing.

**When blocked or the premise fails:** a `Needs unblock` or `Needs decision` ask subtask as appropriate, swap to `claude-waiting`, report. Never leave a task `claude-inflight` at the end of a turn unless I'm genuinely mid-work and about to continue.

## Task titles: the `#` hazard

TickTick parses `#word` in a **task title** as a tag reference, and creates the tag if it doesn't already exist. So a title like `Fix flaky test from #482` or `#1 priority: rotate the API key` silently invents a `482` or `1` tag and pollutes the account's tag list — the stray `1` tag already in `list_tags` came from exactly this mistake.

**Rule: a title I write contains no `#` character unless it is a deliberate reference to a tag that already exists.** This applies everywhere a title is set — `create_task`, `batch_add_tasks`, `update_task`.

Before any call that sets a title, scan the string for `#` and resolve each occurrence:

- **Not meant as a tag** (the common case — PR/issue numbers, ordinals, ticket refs, channel names): rewrite it out. `#482` → `PR 482`; `#1 priority` → `top priority`; `owner/repo#5` → `owner/repo PR 5`. Don't reach for a near-miss like `PR #482` — the `#482` token still parses.
- **Meant as a tag**: don't spell it in the title. Put the bare name in the `tags` array, and only after confirming it exists via `mcp__ticktick__list_tags`. Inventing tags is the user's call, not mine.

The `#` is only special in titles. Task bodies (`content`, markdown) and comments (plain text) are safe, so `#482` there is fine and is the right place for the full reference.

If the user dictates a title containing a `#` token, apply the rewrite and mention it in the report; keep it verbatim only if they say the tag is what they want. If a stray tag does get created, say so — there's no tag-delete tool, so the user has to clean it up by hand.

## Adding tasks to the queue

The user will often ask me to capture work into TickTick (follow-ups discovered mid-task, findings from reviews, ideas from discussion).

- **Title**: short and recognizable — and free of `#` tokens.
- **List**: the current project's list; Inbox only if no list fits.
- **Priority**: none — leave it unset unless the user says otherwise.
- **Body**: detailed. Outline the work already performed: what was investigated, what was found (with file/function references), why it matters, and any recommended direction. Reference the relevant dev-log entry by note title and timestamp when one exists. A future reader (me, months later, with no context) should be able to start from the body alone.
- **Not a subtask** of the current work task — subtasks under a work task are reserved for ask subtasks. Follow-ups are top-level tasks that link the originating task by URL (`https://ticktick.com/webapp/#p/<projectId>/tasks/<taskId>`) in the body.
- **Tags**: add `claude` when the task is clearly something I could take on; otherwise leave untagged (and then it's the user's task — see the hard boundary). Never add `claude-ready`, `claude-plan-required`, or `claude-handoff` — releasing a task, requiring a plan, and taking a task back are the user's decisions.
- Use `batch_add_tasks` when capturing several at once.
