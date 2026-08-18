---
name: claude-tasks
description: Pick up, work, and file delegated TickTick tasks, and name them safely (the "#" tag hazard). Use when the user says "let's look at your tasks", "get started on whatever's next", "what's on your plate", "pick up the next task", "add a task for this", or otherwise asks Claude to work from or write to its TickTick queue.
---

# Working my delegated TickTick task queue

The user delegates tasks to me through TickTick tags. This skill defines how to find those tasks, how much autonomy each one grants, how to record work back into TickTick, and how to add new tasks to the queue.

## Tag vocabulary

- **`claude`** — the user wants *me* to take this task on instead of them.
- **`greenlit`** — the user has thought about the task and decided it is something we actually want to do at all.
- **`discuss-first`** — I must investigate and discuss my proposed approach with the user *before* implementing. **When absent, I have full autonomy** (see Autonomy modes).
- **`claude-inflight`** — I am actively working this task. I add it when I start and remove it when I finish; a task already carrying it is claimed — don't start it again.
- **`claude-complete`** — I have completed my work on this task. I add it as part of close-out, just before completing the task, so work I finished stays filterable after the fact.

`claude`, `claude-inflight`, and `claude-complete` are tags I write; `greenlit` and `discuss-first` are the user's control surface and I never add or remove them.

A task is workable only when it is open (status 0), carries **both `claude` and `greenlit`**, and is not already `claude-inflight`. A `claude` task without `greenlit` is queued-but-not-released — never start it; if asked what's on my plate, list it as "awaiting greenlight."

## Finding and choosing the next task

Figuring out *which project we're in* is step one — sessions normally start opened to a particular repository, and that repo determines which slice of the queue is relevant.

1. **Identify the current project's TickTick list.** From the working directory: `git remote get-url origin`, normalize the URL (`git@github.com:owner/repo` ≡ `https://github.com/owner/repo`), find the vault note with that `url` frontmatter, and read its `ticktick-list` field — that's the list name. Resolve it to a list id via `mcp__ticktick__list_projects`. Keep this note handy: its folder is where task notes live (see Task notes), and its Development Logs hold project-level findings.
2. **Fetch candidates**: `mcp__ticktick__filter_tasks` with `{"tag": ["claude"], "status": [0], "projectIds": ["<list-id>"]}`, then keep only tasks whose `tags` also include `greenlit` and neither `claude-inflight` nor `claude-complete` (do not trust multi-tag filtering to mean AND — verify client-side).
3. **Read each candidate's `content` fully, and fetch its comments.** Task bodies often carry sequencing ("blocked on / sequenced after X"), references to dev-log entries in the vault, and fix direction. Comments are where the user leaves guidance *after* queuing a task (answers to open questions, direction changes, constraints) — they never come along with the task data, so call `mcp__ticktick__get_comment` (project id + task id) for each candidate. Treat comments as part of the task's instructions; a later comment supersedes the body where they conflict. A task whose body or comments say it is blocked on an incomplete task is not eligible.
4. **Choose**: default to the order tasks appear in the list (top first — TickTick's `sortOrder`). Take a task out of order only when it would genuinely be better done *after* work further down the list completes — it builds on, is blocked by, or would be reworked by that later task. Explicit sequencing in task bodies is the clearest such signal, and a user-set priority (nonzero) also outranks list position. Skipping ahead needs no confirmation from the user, but the skip must be called out — in the chat report *and* the dev log — along with the rationale for it.
5. Work **one task at a time**. After finishing and reporting, offer to continue to the next; don't chain through the whole queue unprompted unless the user asked for that.

If there's no repo context (or its list has no workable tasks), say so and ask whether to look across all lists rather than silently going global. If no vault note matches the repo, ask where the project lives rather than guessing.

## Autonomy modes

**`discuss-first` present:** Investigate thoroughly (read code, reproduce, probe), form a recommended approach, and present it to the user for discussion. Do not implement until they agree. If the investigation itself produced durable findings, log them in the Development Logs before stopping.

**`discuss-first` absent (default):** Full autonomy through to a pull request. Implement the fix/feature, write or update tests (per global standards: solid types, test coverage), verify the test suite passes, commit on a feature branch, push it, and open a PR. This standing grant covers pushing the branch and opening the PR; it does not cover merging, releases, or anything else outward-facing.

**The PR must prove it isn't adding risk.** A PR is an argument to the reviewer, and its burden of proof is on me: go to great lengths to demonstrate — with evidence, not assertion — that the work does not expose us to any new risk of bugs. That means grounding the change in observed behavior (captures, live traffic, reference-client code) rather than assumption; enumerating the scenarios where the new behavior could plausibly be *worse* than the old and showing what bounds each one; and stating honest gaps (paths only unit-tested, scenarios never observed live) rather than leaving them for the reviewer to discover.

**Branching:** branch off up-to-date `main`, so each PR stands independent. When that doesn't make sense — the task builds on an unmerged branch, or main is broken — that's worth a callout: say what I branched from and why in both the report and the PR description. Branch names: short and descriptive (e.g. `fix/shared-zone-body-lookup`).

Scope is whatever the tags say — tasks are not limited to coding. Research, writing, vault work, etc. are all fair game if tagged. If a task needs a capability I don't have, report that instead of improvising around it.

## Task notes in the vault

Every task I take on gets its own vault note, created **when I start the task** (at the same time as adding `claude-inflight`):

- **Location**: the same folder as the project note — a *peer* of it, not a child. Derive the folder from the project note's path.
- **Name**: the task's TickTick title, lightly normalized into a vault-safe filename if needed — keep it recognizable as the task. If a note by that name already exists, read it first and reuse it (a prior attempt at the same task) rather than clobbering it; never overwrite a note I didn't create.
- **Initial content**: an h1 section named `# Outline and Plan` containing a rough restatement of the ask in my own words (drawn from the task body) followed by the plan I intend to follow. For `discuss-first` tasks this doubles as the proposal I bring to the user. If discussion or investigation materially changes the plan before work starts, update this section; once work is underway, changes of direction are Development Log entries instead.
- **`url` frontmatter — set when the PR is posted**: set the note's frontmatter `url` field to the PR's HTTPS URL. This wires the note into the dev-log skill's routing: any future session working against that PR (review fixes, follow-ups) will resolve *this note* as its Development Log home. Leave `url` unset until a PR exists; for non-PR deliverables, set it to the deliverable's canonical URL if it has one, otherwise leave it unset.
- **Dev-log placement**: with a task note in play, Development Log entries about *this task's* work go in the task note. The project note's Development Logs remain for project-level findings that outlive any single task.

All vault access goes through `mcp__obsidian__*` tools per the **dev-log** skill's cautions — never filesystem writes.

## Task lifecycle in TickTick

**On starting:** re-fetch the task's comments (`mcp__ticktick__get_comment`) — new guidance may have landed since the task was surveyed, and it must shape the plan before work begins. Then add `claude-inflight` to the task's tags (keep its other tags intact — fetch current tags first), and create the task note with its `# Outline and Plan` section (see Task notes in the vault).

**On finishing — the default expected steps once the deliverable exists (PR posted, or non-PR work done), in order:**

1. **Task note `url`**: set the task note's frontmatter `url` field to the PR's HTTPS URL (see Task notes in the vault) so future dev-log routing lands there.
2. **Integration-test evidence comment**: run the project's live/integration suite on the branch (for icloud-md: `ICLOUD_MD_ITEST=1 npm run test:integration`) and post a PR comment with the results — hopefully: passing. The comment should prove, to the best of my ability, that the PR is going in the right direction: concrete numbers from the run (tests passed, relevant traffic observed in debug logs), corroborating evidence from captures or reference clients, an explicit accounting of any ways the PR might expose us to further risks and what bounds each, and the honest gaps (what the run did *not* exercise). If the suite fails or can't run, say so in the comment and in the report — don't skip silently.
3. **Dev log**: add an entry (if any is warranted — almost always yes for code work) to the **task note's** `# Development Logs` section — invoke the **dev-log** skill for the conventions (entry format, immutability, vault-safety cautions). Cover what was done, key decisions/trade-offs, branch name, and verification performed. Findings that outlive the task still go to the project note.
4. **Close out the task**: remove `claude-inflight`, add `claude-complete`, then **complete the task** (`complete_task`). Closing my own tasks is in scope — the user reviews the *deliverable*, not the task.
5. **Review handoff — only when the deliverable has no review cycle of its own.** A PR (or anything else with a well-defined outside review loop) needs nothing further: the review happens there. For everything else (investigations, research, vault work, write-ups), create a **new task** — not a subtask; the parent is now closed — in the same list, named **"Review: <original task title>"**, untagged and unprioritized — stripping any `#` token the original title carried (see Task titles: the `#` hazard). Its body should read like a PR description: what was asked, what was done and why, what changed (with links to the deliverable — the note, dev log entry, or write-up), the impacts and risks of the work, what specifically to look at, and any honest gaps. TickTick has no first-class task linking, so link the originating task by its web URL — `https://ticktick.com/webapp/#p/<projectId>/tasks/<taskId>` — near the top of the body.
6. **Report, then pause**: summarize what was done, the PR or review-task link, what to review, anything surprising — then **stop and invite the user to review before continuing**. Don't roll into the next task (or further changes on this one) until they've had their say.

**When blocked or the premise fails:** leave the task open, remove `claude-inflight`, add a TickTick comment (`add_comment`, plain text ≤1024 chars) stating what blocked it and what's needed, and report. If investigation reveals the task's premise is wrong (bug can't reproduce, approach in the body won't work), that's a `discuss-first`-style stop even in autonomous mode: log findings in the dev log, comment, and discuss — don't silently pivot to a different solution than the task describes.

## Task titles: the `#` hazard

TickTick parses `#word` in a **task title** as a tag reference, and creates the tag if it doesn't already exist. So a title like `Fix flaky test from #482` or `#1 priority: rotate the API key` silently invents a `482` or `1` label and pollutes the account's tag list — the stray `1` tag already in `list_tags` came from exactly this mistake.

**Rule: a title I write contains no `#` character unless it is a deliberate reference to a tag that already exists.** This applies everywhere a title is set — `create_task`, `batch_add_tasks`, `update_task`, and the derived `Review: <original task title>` task (which inherits the hazard from the title it copies; strip it there too).

Before any call that sets a title, scan the string for `#` and resolve each occurrence:

- **Not meant as a tag** (the common case — PR/issue numbers, ordinals, ticket refs, channel names): rewrite it out of the title. `#482` → `PR 482`; `#1 priority` → `top priority`; `owner/repo#5` → `owner/repo PR 5`. Don't reach for a near-miss like `PR #482` — the `#482` token is still there and still parses.
- **Meant as a tag**: don't spell it in the title at all. Put the bare name in the task's `tags` array, and only after confirming it exists via `mcp__ticktick__list_tags`. Inventing tags is the user's call, not mine — the same rule that governs `greenlit` and `discuss-first`.

The `#` is only special in titles. Task bodies (`content`) and comments are plain text, so `#482` there is safe and is the right place for the full reference — which is where the detail belongs anyway.

If the user dictates a title containing a `#` token, apply the rewrite and mention it in the report rather than passing it through; keep it verbatim only if they say the tag is what they want. And if a stray tag does get created, say so in the report — there's no tag-delete tool, so the user has to clean it up by hand.

## Adding tasks to the queue

The user will often ask me to capture work into TickTick (follow-ups discovered mid-task, findings from reviews, ideas from discussion).

- **Title**: short and recognizable — and free of `#` tokens (see Task titles: the `#` hazard).
- **List**: the current project's list (via the `ticktick-list` mapping above); Inbox only if no list fits.
- **Priority**: none — leave it unset unless the user says otherwise.
- **Body**: detailed, and this matters — outline in depth the work already performed: what was investigated, what was found (with file/function references), why it matters, and any recommended direction. Reference the relevant dev-log entry by note title and timestamp when one exists. A future reader (me, months later, with no context) should be able to start from the body alone.
- **Tags**: add `claude` when the task is clearly something I could take on; otherwise leave untagged. Never add `greenlit` or `discuss-first` — releasing a task is the user's decision.
- Use `batch_add_tasks` when capturing several at once.
