---
name: claude-tasks
description: Pick up, work, and file delegated TickTick tasks using the claude-* status tags (claude / claude-ready / claude-inflight / claude-waiting / claude-plan-required), route decisions and reviews back to the user, and name tasks safely (the "#" tag hazard). Use when the user says "let's look at your tasks", "get started on whatever's next", "what's on your plate", "what needs me", "pick up the next task", "add a task for this", or otherwise asks Claude to work from or write to its TickTick queue.
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
| **Waiting** | `claude` + `claude-waiting` | Blocked on the user: a decision, a review, an answer, or an unblock. Always accompanied by a `NEEDS:` comment. A user comment here without a tag change is *conversation* — I reply on the task and stay Waiting; only `claude-ready` releases the work. | me |
| **Done** | *(task completed)* | Finished. Completion is the state; no tag needed. | me |

**Invariant:** never more than one of `claude-ready` / `claude-inflight` / `claude-waiting` on a task. Every status change is a single `update_task` that fetches the current tags first, removes the old status tag, adds the new one, and **preserves every other tag untouched** — other tags are the user's business. A task found carrying two status tags is corrupt: don't guess, report it and leave it alone until the user fixes it.

Fetch a list's queue with `mcp__ticktick__filter_tasks` `{"tag": ["claude"], "status": [0], "projectIds": ["<list-id>"]}` and bucket by status tag client-side (don't trust multi-tag filtering to mean AND). A cross-list "what needs me" is the same call with `{"tag": ["claude-waiting"], "status": [0]}` and no `projectIds`. The user may keep TickTick smart lists on these tags (e.g. "Needs me" on `claude-waiting`); nothing in the skill depends on them.

## Tag vocabulary

- **`claude`** — the user wants *me* to take this task on. The gate for everything in this skill.
- **`claude-ready`**, **`claude-inflight`**, **`claude-waiting`** — the status enum above. I set `claude-inflight` and `claude-waiting`; the user sets `claude-ready` (and I remove it when I pick the task up).
- **`claude-plan-required`** — orthogonal to status: don't do the thing; tell the user what I *would* do. I investigate, write the plan into the task note, and hand off with `NEEDS: decision`. Work starts only after the user releases the task (`claude-ready`) with the plan in hand. The tag is satisfied once that release has happened — it stays on the task as a record, but doesn't force a new plan every round. When absent, I have autonomy within the standing gates (see Autonomy and decision gates).

`claude`, `claude-ready`, and `claude-plan-required` are the user's control surface: I add `claude` only when capturing new tasks, and I never add `claude-ready` or `claude-plan-required`. Legacy tags are retired: treat `greenlit` as `claude-ready` and `discuss-first` as `claude-plan-required` if encountered, swap them during pickup, and mention it in the report; `claude-complete` is simply dropped.

## Finding and choosing the next task

Figuring out *which project we're in* is step one — sessions normally start opened to a particular repository, and that repo determines which slice of the queue is relevant.

1. **Identify the current project's TickTick list.** From the working directory: `git remote get-url origin`, normalize the URL (`git@github.com:owner/repo` ≡ `https://github.com/owner/repo`), find the vault note with that `url` frontmatter, and read its `ticktick-list` field — that's the list name. Resolve it to a list id via `mcp__ticktick__list_projects`. Keep this note handy: its folder is where task notes live (see Task notes in the vault), and its Development Logs hold project-level findings.
2. **Fetch and bucket** the list's open `claude` tasks by status tag.
3. **Report the plate by status, Waiting first.** When asked what's on my plate / what needs them, answer in this order — *Waiting (N)*, *Ready (N)*, *In progress (N)*, *Backlog (N)* — one line per task, and for Waiting and In progress tasks include the task's `Phase:` line (see Multi-phase tasks). Waiting is the user's inbox; leading with it is the point.
4. **Candidates are `claude-ready` tasks; replied-to Waiting tasks get a reply.** Fetch comments (`mcp__ticktick__get_comment`, project id + task id) for every `claude-ready` *and* every `claude-waiting` task. The tag says whether I may work; the comment is content — never infer one from the other:
   - `claude-ready` → a work candidate. Its comments (including any reply to a previous `NEEDS:`) are its instructions.
   - `claude-waiting` with a user comment newer than my last `NEEDS:` comment → the user is talking to me. Before picking up any work candidate, answer it: do whatever *investigation* the question needs (reading code, checking a capture) but produce no deliverable — no branch, no PR, no vault write-up beyond the task note — and post a fresh `NEEDS:` comment with the answer or refined options. The task stays `claude-waiting`.
   - `claude-waiting` whose newest comment is mine → untouched.
   Then read each candidate's `content` fully. Comments are where the user leaves guidance after queuing, and a later comment supersedes the body where they conflict. Treat comments as part of the task's instructions; a later comment supersedes the body where they conflict. A task whose body or comments say it is blocked on an incomplete task is not eligible.
5. **Choose**: default to the order tasks appear in the list (top first — `sortOrder`). A task returning from Waiting (a `NEEDS:` comment of mine followed by a user reply and `claude-ready`) generally goes first — the user has just spent attention on it and the context is warm. Otherwise take a task out of order only when it would genuinely be better done *after* work further down completes (it builds on, is blocked by, or would be reworked by that later task); a user-set priority (nonzero) also outranks position. Skipping ahead needs no confirmation, but the skip must be called out — in the chat report *and* the dev log — with the rationale.
6. **Stale check.** An In progress task with no comment, note edit, or commit from me in over a day is probably an abandoned session. Don't silently skip it: report it, and offer to resume it (read its task note/`Phase:` line and comments, then continue) before starting anything from Ready.
7. **Drift check — within a round, not across rounds.** Rounds are never capped: every trip through Waiting is the user choosing to continue, and more questions are better than fewer, bigger ones. The risk is the *autonomous stretch inside a round*, where nobody is in the loop. So at every natural checkpoint — updating the `Phase:` line, abandoning an approach, before opening a PR, writing a dev-log entry — compare where the work is against the plan in the task note, and hand off with `NEEDS: decision` when it has drifted: the approach has changed more than once, the change has grown past what the task described, or elapsed time (check `date` against the start time recorded in the `Phase:` line) is well beyond what the plan implied. Runaway effort is a decision the user gets to make, not something they discover in a bloated PR.
8. Work **one task at a time**. After finishing a round and reporting, offer to continue; don't chain through the whole queue unprompted unless the user asked for that.

If there's no repo context (or its list has no Ready tasks), say so and ask whether to look across all lists rather than silently going global. If no vault note matches the repo, ask where the project lives rather than guessing.

### Global mode: working across every project

When the session starts from a folder that contains the checkouts rather than from one of them — `~/Documents/Projects` is the intended root; `~/` also works but puts the whole home directory in scope and makes unanchored searches slow — or the user asks to look across all lists, work the whole queue rather than one list's slice:

1. **Fetch globally**: `filter_tasks` `{"tag": ["claude"], "status": [0]}` with no `projectIds`, plus the same for `claude-waiting`; bucket by status tag as usual, and group the report by list.
2. **Resolve each task's project**: list id → list name (`list_projects`) → the vault note whose `ticktick-list` frontmatter matches (`search_query` on `{"==": [{"var": "frontmatter.ticktick-list"}, "<name>"]}`) → that note's `url`. A task whose list has no project note is not workable in global mode: report it as "no project mapping" and skip it rather than guessing a repo.
3. **Resolve the checkout**: the note's `path` frontmatter if present; otherwise `~/Documents/Projects/<repo name from the url>`. Verify before touching anything: the directory exists and `git -C <path> remote get-url origin`, normalized, equals the note's `url`. A mismatch or missing checkout is a `NEEDS: unblock` (say which path was expected), not a reason to clone or pick a look-alike.
4. **Read the repo's own instructions first.** Claude Code only loads `CLAUDE.md` and `.claude/settings.json` from the session's cwd and its ancestors, so a repo entered from outside brings none of its own rules along. Before any work, read `<path>/AGENTS.md` and `<path>/CLAUDE.md` (whichever exist) and follow them as if the session had started there. Its permission allowlist still won't apply, so expect more prompts than an in-repo session; that's normal.
5. **Work in that checkout with absolute paths** — `git -C`, `npm --prefix`, absolute file paths, and every Glob/Grep anchored under `<path>` — rather than changing directory, so nothing depends on the session's cwd. Everything else in the lifecycle is unchanged: the project note is the one found in step 2, task notes are its peers, branches come off that repo's `main`.
6. Still **one task at a time**, and say which project each report is about — in global mode the user has no cwd to infer it from.

Global mode is only reliable when the checkouts are inside the session's working directory (or were added with `--add-dir`); from an unrelated folder every file access will prompt. If that happens, say so and suggest restarting from `~/Documents/Projects` instead of fighting through prompts.

## Autonomy and decision gates

**`claude-plan-required` present:** Investigate thoroughly (read code, reproduce, probe), form a recommended approach, write it into the task note's `# Outline and Plan` (options considered, recommendation, what would change, risks), and hand it back via Waiting with `NEEDS: decision` linking to the plan. Do not implement — no branch, no PR — until the user releases the task with `claude-ready`. If the investigation produced durable findings, log them before stopping.

**`claude-plan-required` absent (default):** Autonomy through to a pull request — implement, write or update tests (per global standards: solid types, test coverage), verify the suite passes, commit on a feature branch, push, open a PR. This standing grant covers pushing the branch and opening the PR; it does not cover merging, releases, or anything else outward-facing.

**Standing gates — these always go to Waiting first, in either mode.** Autonomy is bounded by a fixed list of things the user has said they want a say in, regardless of tags:

- changing public or documented behavior, an API surface, or a wire/file format;
- adding, removing, or upgrading a dependency;
- deleting, migrating, or rewriting persisted data, or changing a schema;
- choosing between materially different architectures or approaches when more than one is plausible and the task body doesn't pick;
- expanding scope beyond what the task describes, or dropping part of it;
- the task's premise turning out wrong (bug can't reproduce, the approach in the body won't work) — log the findings, then ask; never silently pivot to a different solution than the one described;
- anything touching an area the user has flagged (in the task, the project note, or CLAUDE.md) as sensitive.

Hitting a gate mid-task is not a failure; it's the loop working. Finish everything that doesn't depend on the answer, then hand off.

**Every decision I make on my own gets logged.** Any choice a reasonable reviewer might have wanted a say in — even if it didn't trip a gate — goes in the `# Decisions` table (see Task notes in the vault) marked *by: claude*, with the why. The user's review of a deliverable starts from that table, so it must be complete and honest, including decisions I'm not proud of.

**The PR must prove it isn't adding risk.** A PR is an argument to the reviewer, and its burden of proof is on me: demonstrate — with evidence, not assertion — that the work does not expose us to new risk of bugs. Ground the change in observed behavior (captures, live traffic, reference-client code) rather than assumption; enumerate the scenarios where the new behavior could plausibly be *worse* than the old and show what bounds each; state honest gaps (paths only unit-tested, scenarios never observed live) rather than leaving them for the reviewer to discover.

**Branching:** branch off up-to-date `main`, so each PR stands independent. When that doesn't make sense — the task builds on an unmerged branch, or main is broken — call it out: say what I branched from and why in both the report and the PR description. Branch names: short and descriptive (e.g. `fix/shared-zone-body-lookup`).

Scope is whatever the task says — tasks are not limited to coding. Research, writing, vault work, etc. are all fair game. If a task needs a capability I don't have, hand it back via Waiting with `NEEDS: unblock` rather than improvising around it.

## Handing off to the user: Waiting and the `NEEDS:` comment

Setting `claude-waiting` is the *only* way I ask the user for something, and it always comes with exactly one comment (`add_comment`, plain text, ≤1024 chars) in this shape:

```
NEEDS: decision | review | answer | unblock
Summary: one line on where the task stands
Options: A / B / C — my recommendation is B because … (decision only)
Look at: PR link / obsidian link to the task note (see Linking to vault notes) / file:line
To continue: comment to discuss; add claude-ready (with or without a comment) to release the work
```

- **decision** — a gate was hit or the approach needs choosing; options are enumerated with a recommendation.
- **review** — a deliverable without its own review loop (an investigation, research, vault work, a write-up) is done and wants eyes. A PR does *not* need this: its review happens on GitHub, and the task is completed directly.
- **answer** — a factual question only the user can answer.
- **unblock** — something I can't do (missing access, capability, or credential; failing infrastructure).

If the full detail won't fit in the comment, put it in the task note and keep the comment as the pointer — always with an `obsidian://` link, never a bare note title.

### Linking to vault notes

TickTick can't search the vault, so every pointer I leave in a task — the `Look at:` line of a `NEEDS:` comment, a review handoff, a task body that cites a dev-log entry — carries a clickable Obsidian URI:

```
obsidian://open?vault=Notes&file=<vault-relative path without .md, URL-encoded>
```

The vault is named `Notes`. Encode spaces as `%20` and keep folder separators as `/` (e.g. `obsidian://open?vault=Notes&file=projects/icloud-md/Shared%20note%20editing`). To land on a section, append the heading: `...&file=<path>%23Decisions`. Always link to the task note's `# Decisions` section in a `NEEDS: review` comment and in the finishing report, since that's where the user's review starts. Also include the link in the chat report so the user can open the note from either side. Then **stop**: report in chat what I handed off and why, and end the turn. The user's reply is one of four moves, and the tag and the comment carry independent meaning — the tag is "you may proceed," the comment is content: **accept** (`claude-ready`, no comment — take my recommendation and go), **respond-and-release** (comment + `claude-ready` — the comment is the new instruction; go), **discuss** (comment, no tag change — reply on the task in a fresh `NEEDS:` comment, stay Waiting, don't start the work), or **ignore** (nothing — silence means still thinking; it's not mine to touch). Discussion rounds are cheap and uncapped; they are the loop working.

## Multi-phase tasks: one task, many rounds

A task often goes through several rounds — check a PR, report; propose refactor options, get a choice; implement. That is **one task**, not a chain of tasks or subtasks. The rounds are In progress → Waiting → (user reply) → Ready → In progress, and the comment thread is the transcript.

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
  - `# Decisions` — a table: `date · decision · by (claude / user) · why`. Every choice of consequence, mine or theirs; the user's answers to `NEEDS:` requests are recorded here too so the note is self-contained.
  - `# Development Logs` — per the **dev-log** skill. With a task note in play, entries about *this task's* work go here; the project note's Development Logs remain for findings that outlive any single task.
- **`url` frontmatter — set when the PR is posted**: the PR's HTTPS URL, so the dev-log skill routes future sessions against that PR to this note. For non-PR deliverables, the deliverable's canonical URL if it has one; otherwise leave it unset.

All vault access goes through `mcp__obsidian__*` tools per the **dev-log** skill's cautions — never filesystem writes.

## Task lifecycle in TickTick

**On starting (from Ready):** read the repo's `AGENTS.md` if it has one — the user keeps project instructions there, and Claude Code does *not* load it automatically (only `CLAUDE.md`), so unless a `CLAUDE.md` imports it (`@AGENTS.md`) or symlinks to it, those instructions reach me only by reading the file deliberately. Then re-fetch comments — new guidance may have landed since the survey. Swap `claude-ready` for `claude-inflight` (fetch the task first; keep every other field and tag intact), set or update the `Phase:` line, and create the task note if warranted.

**On needing the user:** write the `NEEDS:` comment, update `Phase:`, swap `claude-inflight` for `claude-waiting`, report, stop.

**On finishing — once the deliverable exists (PR posted, or non-PR work done), in order:**

1. **Task note `url`**: set it to the PR's HTTPS URL (see Task notes in the vault).
2. **Integration-test evidence comment**: run the project's live/integration suite on the branch (for icloud-md: `ICLOUD_MD_ITEST=1 npm run test:integration`) and post a PR comment with the results. Concrete numbers from the run, corroborating evidence, an explicit accounting of any new risks and what bounds each, and the honest gaps. If the suite fails or can't run, say so in the comment and the report — never skip silently.
3. **Dev log**: add an entry (almost always warranted for code work) to the task note's `# Development Logs` (or the project note's, if no task note) — invoke the **dev-log** skill for the conventions. Cover what was done, key decisions/trade-offs, branch name, verification. Make sure `# Decisions` is complete.
4. **Close out or hand off**:
   - deliverable has its own review loop (a PR): update `Phase:` to `done — PR <url>`, remove `claude-inflight`, then `complete_task`. Closing my own tasks is in scope — the user reviews the deliverable, not the task.
   - anything else: `NEEDS: review` comment, swap to `claude-waiting`. The user completes it when satisfied (or responds and sends it back to Ready).
5. **Report, then pause**: summarize what was done, the PR link and the `obsidian://` link to the task note (see Linking to vault notes), what to look at (point at `# Decisions` first), anything surprising — then stop and invite review before continuing.

**When blocked or the premise fails:** `NEEDS: unblock` or `NEEDS: decision` as appropriate, swap to `claude-waiting`, report. Never leave a task `claude-inflight` at the end of a turn unless I'm genuinely mid-work and about to continue.

## Task titles: the `#` hazard

TickTick parses `#word` in a **task title** as a tag reference, and creates the tag if it doesn't already exist. So a title like `Fix flaky test from #482` or `#1 priority: rotate the API key` silently invents a `482` or `1` tag and pollutes the account's tag list — the stray `1` tag already in `list_tags` came from exactly this mistake.

**Rule: a title I write contains no `#` character unless it is a deliberate reference to a tag that already exists.** This applies everywhere a title is set — `create_task`, `batch_add_tasks`, `update_task`.

Before any call that sets a title, scan the string for `#` and resolve each occurrence:

- **Not meant as a tag** (the common case — PR/issue numbers, ordinals, ticket refs, channel names): rewrite it out. `#482` → `PR 482`; `#1 priority` → `top priority`; `owner/repo#5` → `owner/repo PR 5`. Don't reach for a near-miss like `PR #482` — the `#482` token still parses.
- **Meant as a tag**: don't spell it in the title. Put the bare name in the `tags` array, and only after confirming it exists via `mcp__ticktick__list_tags`. Inventing tags is the user's call, not mine.

The `#` is only special in titles. Task bodies (`content`) and comments are plain text, so `#482` there is safe and is the right place for the full reference.

If the user dictates a title containing a `#` token, apply the rewrite and mention it in the report; keep it verbatim only if they say the tag is what they want. If a stray tag does get created, say so — there's no tag-delete tool, so the user has to clean it up by hand.

## Adding tasks to the queue

The user will often ask me to capture work into TickTick (follow-ups discovered mid-task, findings from reviews, ideas from discussion).

- **Title**: short and recognizable — and free of `#` tokens.
- **List**: the current project's list; Inbox only if no list fits.
- **Priority**: none — leave it unset unless the user says otherwise.
- **Body**: detailed. Outline the work already performed: what was investigated, what was found (with file/function references), why it matters, and any recommended direction. Reference the relevant dev-log entry by note title and timestamp when one exists. A future reader (me, months later, with no context) should be able to start from the body alone.
- **Tags**: add `claude` when the task is clearly something I could take on; otherwise leave untagged (and then it's the user's task — see the hard boundary). Never add `claude-ready` or `claude-plan-required` — releasing a task, and requiring a plan, are the user's decisions.
- Use `batch_add_tasks` when capturing several at once.
