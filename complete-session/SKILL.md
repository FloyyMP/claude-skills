---
name: complete-session
description: End-of-session cleanup. Surfaces unfinished work, commits and pushes pending changes, revises CLAUDE.md, updates memory, confirms session is clean.
license: MIT
---

# Complete Session

Goal: the user can close the window with zero doubt — nothing pending, nothing lost, everything documented and pushed.

Run the steps in order. Report each step's result in **one line** before moving on. Never skip a step silently — if it doesn't apply, say so and move on.

**Ordering:** every repo-bound write (Step 1 code fixes, Step 3 repo config edits) happens **before** the single commit in Step 5, so it all rides one commit. Memory (Step 6) and the global config (Step 3) live outside the repo and are written separately, never committed.

**Modes:** default is **execute**. If the user asked to *preview* / *dry-run* the close, run every read-only check below but make **no writes** — no file edits, commits, pushes, stashes, soft-resets, or memory saves. Print the planned action per step and stop. Resume real execution only on explicit go-ahead.

**Trigger type:** note how this skill fired. **Explicit** = the user ran `/complete-session`, or the agent loaded it because the user clearly said "complete session", "wrap up", "done for today". **Implicit** = a fuzzy signal inferred from chat ("that's it", "we're done", "finish session"). An implicit trigger can be a false positive (the user meant "wrap up *this one task*", not close the session), so it gets a confirmation before the first irreversible outward action — the Step 5 push (see 5e). Explicit needs no such gate.

**Never invoke recursively.** If this skill is already running this turn, exit immediately.

---

## Step 0: Background Tasks + Starting State

Two checks before anything else.

**Live background work that the window close would kill:**
- Bash/PowerShell commands started with `run_in_background` — they survive the turn and re-invoke on exit.
- Subagents launched via the `Agent` tool still running — inspect with `TaskOutput`, stop with `TaskStop`.
- `Monitor` watches, a `/loop` dynamic wakeup (`ScheduleWakeup`), or scheduled cloud agents (`CronList`) created this session.

If found: surface each. Wait if it's about to finish; otherwise ask whether to stop it. **Do not pass Step 0 until every live task is resolved** — a running task can mutate files that Steps 1–5 then commit, mixing in-progress work into a "finished" commit.

If none: one line saying so.

**Record the starting tree state** (git repos only): run `git status --short` once and note which files were **already dirty before** this session's work. This snapshot does two jobs: it's the rollback reference (`git diff` / `git stash`) if a Step 1 autofix (lint `--fix`, formatter) clobbers pre-existing edits, and it bounds what Step 5 may stage (Step 5b).

---

## Step 1: Surface And Resolve Unfinished Work

Re-read the conversation for:
- Open `TodoWrite` tasks not marked complete
- Errors raised but never resolved
- Half-implemented features ("I'll do the X part later")
- Things the user deferred ("come back to that", "leave it for now")
- Files edited but never tested / verified
- Promised follow-ups never executed

Nothing found: one line, move on.

**Found something: resolve it now.** This is a punch list to clear, not a status report. Default action is to do the work, not report it as pending.

Per item:
- **Unfinished implementation / unresolved error / promised follow-up** — finish it (edit, bash, etc.). One line on what you did.
- **Edited but unverified** — run the strongest check possible without credentials/network the user hasn't authorised: type-check, lint, `py_compile`, a targeted harness over the changed paths, a dev-server smoke test for UI. **Bound every check with a timeout** — a hung test must not stall the close; kill it, report the path as unverified, move on (don't let it block the session). Delete throwaway verification scripts after. Report pass/fail counts.
- **You suggested it, user didn't reply** — silence doesn't mean deferral. Apply now if reversible and low-risk. If destructive or opinionated, ask once here, then act on the answer **same turn** — never carry it forward as deferred.
- **User said "leave it" / "ignore for now" verbatim** — respect it, list as deferred in Step 7. This is the *only* thing that counts as user-deferred.
- **Genuinely blocked** (needs live credentials, a real production run, or a decision only the user can make) — list as deferred in Step 7, name the blocker.

Default is resolve, not ask. Pause only when the path forward is genuinely ambiguous — "user never replied" does not qualify.

**TODO.md sweep:** if the repo has a `TODO.md` (or similar), strike through (`~~...~~`) items done this session with a one-line note. Rides Step 5's commit — no separate commit.

---

## Step 2: Untracked Cruft Sweep

Scan the working tree for junk that shouldn't be committed or left behind:
- Throwaway verification / scratch scripts from this session (Step 1 should have removed these; this is the backstop).
- Stray temp files, `.bak` files, editor swap files.
- A timestamped `results/` run dir or other tool output not meant to be tracked.

One line per candidate with what it is. Delete obvious throwaway scratch **you** created. For anything uncertain (user's own files, real output), ask once — keep or delete — then act same turn.

Clean tree: one line, move on.

---

## Step 3: Config Revision (CLAUDE.md)

Run every session, even with no code changes — **unless** the session produced nothing worth documenting (pure Q&A, trivial one-liner). Then note "nothing worth adding" and move on. Never manufacture edits to justify the step.

### Inclusion test — a candidate is added only if it passes ALL four:
1. **Durable** — matters in a *future* session, not just this one. Session narrative ("fixed the X bug today") fails; the underlying gotcha ("Y silently truncates on Z") passes.
2. **Non-obvious** — not derivable from the code, repo layout, or `git log`. If a new dev would learn it in five minutes of reading, drop it.
3. **Actionable — name the failure it prevents.** State, in one sentence, the concrete mistake a future session makes *without* this entry: "without this, a future session will ___." If you can't write that sentence, the entry isn't actionable — cut it. This is the primary filter; it's harder to rationalise past than "is this useful?", which a session that just did the work always answers yes to.
4. **Not already covered — across ALL tiers, not just this file.** Read the target file first; if a line already says it (even loosely), don't restate. Then check the *other* tiers — any parent-directory `CLAUDE.md` and the global `~/.claude/CLAUDE.md`. A gotcha may already live one tier up. If it does, leave it there; never duplicate downward. If it's misfiled, route it (see Routing) rather than copy it.

**Default skew is omit.** A near-empty revision is the normal, healthy outcome — most sessions add nothing. Adding a marginal entry "to be safe" *is* the failure mode. When unsure, drop it.

**Calibration — entries that LOOK worth adding but FAIL (reject these):**
- "Uses Tailwind v4 / Next 16 / Prisma 6" → fails #2, derivable from `package.json`.
- "Fixed the nav-underline bug this session" → fails #1, session narrative, not a durable rule.
- "Prefer async for network calls" → fails #4, already a standing rule in the global `CLAUDE.md`.
- "The `add` route validates input" → fails #2 + #3, derivable from code, changes no future behaviour.
- "Be careful with migrations" → fails #3, names no concrete failure (contrast: "`prisma migrate dev` refuses destructive drops non-interactively — `UPDATE … SET col=NULL` first" passes — names the exact failure + fix).
If a candidate resembles the left-hand pattern, drop it without further debate.

### Routing
- Project-specific gotchas (build commands, repo layout, local quirks) → the **repo's own `CLAUDE.md`**. Staged into Step 5's commit.
- Cross-project preferences and behavioral rules → the **global `~/.claude/CLAUDE.md`** (outside any repo, never committed).
- **Harness behaviour, not knowledge** — anything phrased as "from now on, when X happens, do Y" is a **hook**, not a `CLAUDE.md` line. Claude executes prose; only the harness executes hooks. Route these to `.claude/settings.json` via the `update-config` skill. Same for permission allowlists and env vars.
- **`AGENTS.md`-only repos:** if the repo has an `AGENTS.md` but no `CLAUDE.md`, edit the existing file rather than introducing a second convention.

If more than one exists, route each addition to the correct one. Never dump project trivia into the global file, or personal prefs into a shared repo file.

**Layered config files (global `~/.claude/CLAUDE.md` + any parent-dir `CLAUDE.md` + the repo's own):** all of them load into context together. Before adding to the repo file, grep the parent and global files for the same rule — if it's there, it already applies, so don't restate it one tier down. Put each rule at the *broadest* tier it's true for and nowhere else.

**Global file caution:** `~/.claude/CLAUDE.md` is outside any repo and **not version-controlled** — an edit there can't be reverted with git. Show the exact diff.

### Flow
1. Reflect for gotchas, patterns, commands. Run each through the four-point test; keep only what passes all four.
2. **Read the target file**, confirm no overlap, apply surviving additions directly — no y/n gate. Standing user preference is auto-approve. Show the diff. (If a future user overrides this, fall back to propose-and-wait.)
3. **Do not commit here** — the repo config edit rides Step 5; the global edit is never committed.
4. Nothing survived: note "nothing worth adding", move on. Expected most sessions — not a failure.

### Consolidation gate — counters unbounded growth

The add-flow above can only **grow** the file; nothing in it prunes. That is the real rot vector — not low-quality additions (the four-point test guards those), but a file that accumulates stale and contradictory entries as the project moves, while still loading into every session's context. Counter it here:

- After applying additions, check the target file's size/shape. **Overdue signal:** a single config file past ~150 lines, or one whose gotchas/rules list dominates it, or you noticed a contradiction while reading it this session.
- **When overdue:** if a dedicated consolidation skill is listed in the available-skills block this session, invoke it on that file — don't guess at a skill name that isn't listed. Otherwise do a manual reconcile pass: read the file end to end; merge duplicates, scope environment-specific claims (e.g. local vs prod), delete entries now false or obvious, fix contradictions.
- **Unlike the add-flow, this pass MAY delete and rewrite.** But **verify a claim against live state before deleting it** — a "stale-looking" line may still be true for one environment (e.g. a DB-URL rule that still holds locally but not in prod). When unsure, scope it, don't cut it.
- Don't force it every session — only when the signal trips. A reconcile edit rides Step 5's commit. Note the outcome in one line.

---

## Step 4: Re-check Working Tree State

Steps 1–3 may have edited files. Re-run `git status` so Step 5 commits the true final state, not the Step 0 snapshot.

---

## Step 5: Git Commit + Push

**Not a git repo:** one line, skip to Step 6.

**Idempotency gate:** `git status --short` plus unpushed-commit check (below). If the tree is clean **and** nothing is unpushed: one line "Nothing to commit or push", skip to Step 6. Never create an empty commit.

Read repo state and commit style: `git status` and `git log --oneline -5`.

**Unusual repo states.** If these reads show an unborn HEAD (fresh `git init`), a detached HEAD, an in-progress merge/rebase, or a `.gitmodules` with changes inside a submodule, read `references/edge-cases.md` in this skill's directory and follow the path for that state. Don't improvise one. In the ordinary case, skip the file entirely.

**Derive the default branch per repo** (used in 5a and 5e — never hardcode `master`/`main`):
```
git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null   # -> origin/main ; strip "origin/"
```
If unset, fall back to `git remote show origin` — the `HEAD branch:` line; with no remote at all, use that repo's current branch. Call the result `DEFAULT_BRANCH`. **Re-derive it for every repo** in a multi-repo session — a worktree or submodule has its own default branch.

**Multi-repo session:** if work touched more than one repo (main + submodule), run 5a–5g for *each* touched repo, not just cwd. List each repo and its result.

### 5a: Branch check
If the current branch **is** `DEFAULT_BRANCH` **and** the changes are feature/WIP (not a trivial doc/config tweak), prefer a branch first (`git switch -c <descriptive-name>`), unless the user explicitly committed to default this session.

State the branch decision in one line.

### 5b: Stage — bounded scope
Stage **only the paths this session created or edited** (Step 1 code, Step 3 repo config, TODO.md). Name them explicitly: `git add <path> <path>`. **Never** `git add -A` / `git add .` unless the tree was already clean at Step 0 — blanket staging swallows pre-existing user WIP, stray configs, and unrelated files.

**Pre-existing-dirty guard:** for each path you're about to stage, check the Step 0 snapshot. If a file was **already dirty before this session** *and* you also edited it, `git add <path>` bundles the user's earlier hunks into this commit. Do **not** reach for `git add -p` to split them — it's interactive and hangs the agent. Instead surface it: name the file, say it held uncommitted work before this session, and ask how to handle it (commit both together / skip the file / user splits it first), then act on the answer same turn. Files clean at Step 0 stage whole; new untracked files have no pre-existing hunks, so they stage whole too.

**CRLF / mode noise (Windows):** a file can show as modified in `git status` from pure line-ending (`core.autocrlf`) or file-mode changes with no real content delta. Before staging, if `git diff <path>` shows no substantive change, skip it — it's phantom-dirty, not your work.

### 5c: Secrets scan before commit
Inspect the staged diff for things that must not reach a remote. Run via the **bash tool**:
```
git diff --cached -- . ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*.sum' \
  | grep -inE "(api_?key|secret_?key|access_?token|auth_?token|client_?secret|password|passwd|private_?key|BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|bearer [a-z0-9._-]{20,})"
```
PowerShell-only fallback: `git diff --cached | Select-String -Pattern '(api_?key|secret|token|password|private_?key|BEGIN .*PRIVATE KEY|AKIA[0-9A-Z]{16})'`.

Lockfiles, `*.sum`, and checksum files are excluded — their long hex strings aren't secrets. For a deeper sweep, treat long quoted strings as *candidates to eyeball*, not auto-blockers.

Also flag: staged `.env` files, and filenames containing `cred`, `secret`, `token`, `key`.

Hardcoded secrets are fine in **local** tools (user preference) but must not reach a remote. **Scan hits + repo has a remote:** stop, list each as `file:line — matched pattern`, ask before continuing. **Purely local repo (no remote):** note the hit in one line, proceed.

### 5d: Commit
1. **Nothing staged?** If 5b left the index empty (all changes were pre-existing/unrelated), do not force an empty commit. One line on what was left unstaged and why, then go to 5f (prior unpushed commits may still exist).
2. Auto-generate a concise message matching the project's existing style (from the `git log` above). Don't ask for approval.
3. Commit. Pre-commit hook fails — report the exact error, fix if obvious, else surface. Never `--no-verify`.

### 5e: Push
**Implicit-trigger gate:** if this skill fired implicitly (see *Trigger type* above), pause once before the first push: state what's committed and the target `<remote>/<branch>`, and push only on go-ahead. The commit is already local and reversible; the push is outward and the point of no easy return. The explicit trigger skips this gate. In a multi-repo session, one combined confirmation listing every repo/branch is enough — don't prompt per repo.

1. Push to the tracking branch.
2. **No upstream:** push with `-u` to set it. State the branch.

### 5f: Unpushed prior commits
Even with no new changes this session, check for local commits never pushed: `git log @{u}.. --oneline 2>/dev/null` (fallback `git log <branch> --not --remotes`). If the branch is ahead of upstream, push them. "No changes this session" + 3 unpushed commits doesn't equal clean.

### 5g: Push failure handling
- **No upstream:** push with `-u` to set it. State the branch.
- **Rejected (non-fast-forward):** remote moved. Report it. **Do not auto-force.** Offer to pull/rebase then push, or hand back.
- **Auth / network failure:** report the exact error. The commit is safe locally — say it's committed but unpushed.
- **Pre-push hook fail:** report the exact error, fix if obvious, never `--no-verify`.

Report what was committed and the push result per repo.

---

## Step 6: Memory Update

Persist anything from this session worth keeping that isn't already in memory:
- New user preferences / feedback given this session
- Project decisions or context the user expressed
- Corrections to stale memory entries
- New external references mentioned

**Same bar as Step 3's inclusion test:** durable, non-obvious, not already stored. Don't persist session narrative or anything the repo/code/git already records. Default skew omit.

**Auto-save** without asking. If you correct or delete a stale entry, name which one.

Memory lives outside the repo — **never part of Step 5's commit, never pushed**. Write directly to `~/.claude/memory/`; the directory already exists, so don't `mkdir` or test for it. One fact per file:

```markdown
---
name: <short-kebab-case-slug>
description: <one-line summary, used to decide relevance during recall>
metadata:
  type: user | feedback | project | reference
---

<the fact. For feedback/project, follow with **Why:** and **How to apply:** lines.
Link related memories with [[their-name]].>
```

Then add one pointer line to `~/.claude/memory/MEMORY.md` — `- [Title](file.md) — hook`. `MEMORY.md` is the index loaded every session: one line per memory, never memory content itself.

Convert relative dates to absolute before writing ("today" → the actual date). Check for an existing file covering the same ground and update it rather than creating a near-duplicate.

**Consolidation gate (memory is add-only too):** if the memory dir has grown large (≳20 entries) or you hit a stale/duplicate/contradictory entry this session, run a reconcile pass — merge duplicates, fix stale facts, delete memories that turned out wrong, prune the `MEMORY.md` index. Same rule as Step 3: verify a claim against live state before deleting it. Memory stays uncommitted. Only when the signal trips — not every session.

Nothing new: one line.

---

## Step 7: Confirm Clean

**Dangling stash check:** if you ran `git stash` anywhere this session (e.g. the Step 0 fallback before a risky autofix), it must not be left dangling. `git stash pop` it if the work belongs in the tree, or report the exact stash ref and why it's parked. Never end with a silent unrestored stash.

One short summary paragraph:
- Background tasks: all finished/stopped, or none
- Committed + pushed per repo (or that nothing needed it), including any prior unpushed commits flushed
- Whether config changed (repo `CLAUDE.md`, global `CLAUDE.md`, and/or `.claude/settings.json`)
- Memory entries added / updated
- Any stash created this session: restored or reported
- Any items the user explicitly deferred

End with one of:
- **Session is clean.** — default. All steps green; Step 1 items resolved in place. This should be the ending almost every time.
- **Session has open items — see below.** — only for genuinely blocked items. Follow with a blank line, `Open items:`, then a numbered list, one per line, each naming the blocker.
  - **Acceptable blockers:** user said "leave it" / "ignore for now" verbatim; needs live credentials or production data you don't have; a decision only the user can make and you already asked; a push was rejected, gate-declined (5e implicit-trigger gate not approved), or failed on auth/network — the commit is safe locally, say it's committed but unpushed; staged secrets need a push decision.
  - **Not acceptable:** "user didn't reply to my suggestion", "noticed something tangential", "didn't have time to verify" (run the strongest offline check now — Step 1). Only verification that genuinely requires a live run you cannot perform counts as blocked — name that blocker explicitly.

---

## Boundaries

- Never run destructive git operations (`reset --hard`, `push --force`, `clean -f`) unless the user explicitly asks. (`git reset --soft` for commit-folding is fine — it loses no work.)
- Never skip pre-commit / pre-push hooks with `--no-verify`.
- Never hardcode a default branch name — derive it (Step 5).
- If any step fails, surface the failure and ask before proceeding — never silently swallow errors.
- Never invoke this skill recursively.
