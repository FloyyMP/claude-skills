---
name: complete-session
description: Closes out a Claude Code session so the window can be shut with nothing lost — verifies edited files, lands and pushes every touched repo, updates CLAUDE.md and memory, then proves the state is clean with command output. Use when the user runs /complete-session or says "complete session", "wrap up", "done for today", "close out". Not for wrapping up a single task mid-session.
license: MIT
---

# Complete Session

Goal: the user can close the window with zero doubt — nothing pending, nothing lost, everything documented, landed and pushed.

Run the steps in order. **Never skip a step silently** — if it doesn't apply, show why and move on.

## The evidence-first rule (applies to every step)

Every step prints its **evidence line first, verdict second**. The evidence line names the source and a count: "files edited this session: 3 (transcript)", "candidates considered: 2 — rejected: …", "repos touched: 0 (transcript)". A verdict of "nothing" / "clean" / "none" is **only allowed after an evidence line that shows zero**. A step that prints a conclusion with no evidence has not run.

Why: a close-out that reads `No unfinished work. Nothing worth adding. No new learnings. Session is clean.` is indistinguishable from one that never looked. This rule is what separates them.

**Recall is not evidence.** After context compaction, "re-read the conversation" is lossy. The facts come from the transcript on disk (Step 0's script); the conversation only supplements them.

**Ordering:** every repo-bound write (Step 1 fixes, Step 3 repo config edits) happens **before** Step 5 so it all rides one commit per repo. Memory (Step 6) and the global config live outside any repo and are never committed.

**Modes:** default is **execute**. If the user asked to *preview* / *dry-run*, run every read-only check (Step 0's facts, `prove-clean.ps1`, `run-gates.ps1`, the memory check all stay safe) but make **no writes** — no edits, commits, pushes, stashes, memory saves. Instead of narrating step by step, end with **one consolidated manifest** of what execute *would* do: repos to stage+commit+push (with the branch decision per repo), files to be staged, CLAUDE.md / settings edits with their diffs, memories to add or update. One block the user can approve at a glance, then stop.

**Trigger type:** **Explicit** = `/complete-session` or the user clearly said "complete session" / "wrap up" / "done for today". **Implicit** = a fuzzy signal ("that's it", "we're done"). Implicit can be a false positive, so it gets one confirmation before the first push (5e). Explicit needs no gate. Invoking this skill **is** the user's "commit and push" ask — the standing "don't commit unless I ask" rule is satisfied.

**Never invoke recursively.** If this skill is already running this turn, exit immediately.

---

## Step 0: Session Facts + Live State

### 0a: Pull the facts from the transcript

Run the parser via the **PowerShell tool**. The session id is the UUID in the scratchpad path shown in the system prompt (`…\claude\<slug>\<session-id>\scratchpad`):

```
& "$HOME\.claude\skills\complete-session\scripts\session-facts.ps1" -SessionId <session-id>
```

It reads `~/.claude/projects/<slug>/<session-id>.jsonl` (plus subagent transcripts) and prints: files edited grouped by git repo, repos touched **with a live git-state snapshot** (branch, default, dirty count, ahead count, stashes, worktrees), shell commands that wrote files / changed git state / launched processes, `run_in_background` jobs, subagents (with `isolation`), **worktrees entered** (`EnterWorktree` / `Agent isolation:worktree`), **files handed to the user** (`SendUserFile`), **questions asked** (`AskUserQuestion`), **skills invoked**, schedulers, the last todo list, compaction count **and tokens dropped**, idle time since last activity, and the scratchpad path. **These facts drive Steps 1, 2, 5 and 7** — repos come from *files touched*, never from cwd. If cwd is not a repo but the facts show edits inside one, that repo is in scope.

The repo snapshot means Steps 0c, 4, 5 and 7 start from machine truth, not a separate hand-run of `git status`. For the machine parts of Steps 5 and 7, iterate `-Json` output (`ReposTouched`, `RepoState`) rather than eyeballing the human report.

If the script errors, show the error and fall back to conversation recall for this run — and say so in Step 7 (it downgrades "proved" to "recalled").

Note the compaction count. ≥1 means recall of the early session is unreliable: lean harder on the facts — the report prints the dropped-token total so you can see *how much* is gone.

### 0b: Live work the window close would kill

Cross-check the facts against live state:
- **Background commands** (`run_in_background`) — still running? Wait if about to finish, else ask whether to stop.
- **Subagents** — `TaskOutput` / `TaskStop`.
- **Schedulers / watches** — `Monitor`, `/loop` wakeups, `CronList` for cloud agents created this session.
- **Detached processes** — only if the facts flag any `process` launches (dev servers, `Start-Process`, `&`): check what's still alive since session start:
  ```
  $t=[datetime]'<Started from 0a>'; Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt $t } 2>$null | Select-Object Name,Id,StartTime
  Get-NetTCPConnection -State Listen | Select-Object LocalPort,OwningProcess
  ```
  (`StartTime` throws AccessDenied on protected processes — the `SilentlyContinue` keeps the list flowing past them.)
  Report anything the session started that is still listening. Stop it only if it was clearly a throwaway dev server; otherwise ask.

**Do not pass Step 0 until every live task is resolved** — a running task can mutate files that Step 5 then commits.

### 0c: Starting tree snapshot per touched repo

For **each repo in the facts**, run `git -C <repo> status --short` and note what was **already dirty** (paths not in the facts' edited list). This bounds Step 5b and is the rollback reference if a Step 1 autofix clobbers pre-existing edits.

Evidence line: `repos: N (transcript) · files edited: N · bg: N · agents: N · worktrees: N · processes flagged: N · compactions: N (~N tokens dropped)`.

---

## Step 1: Surface And Resolve Unfinished Work

Sources, in order of trust:
1. **Facts:** open todos, files edited (each needs a verification result), files marked `MISSING NOW` (edited then deleted — intended?), subagent edits.
2. **Conversation:** errors raised but never resolved, "I'll do X later", promised follow-ups, things you suggested and the user never answered.

Evidence line: `open todos: N · files edited: N · unverified: N · promised follow-ups: N`.

**Found something: resolve it now.** This is a punch list to clear, not a status report.

Per item:
- **Unfinished implementation / unresolved error / promised follow-up** — finish it. One line on what you did.
- **Non-repo doc edits** (memory files, `~/.claude/CLAUDE.md`, `.claude/settings.json`) have **no language gate** — they are handled by Steps 3 and 6, not here. Don't try to "verify" them with a build.
- **Edited but unverified** (source in a repo) — run the **named gate** for that repo, from its root (a build from a subdirectory can silently target the wrong module). The gate runner does the language detection, timeout-bounding and pass/fail rules for you:
  ```
  & "$HOME\.claude\skills\complete-session\scripts\run-gates.ps1" -Repo <repo-root> [-TimeoutSec 300]
  ```
  It matches `go.mod` / `pyproject.toml` / `package.json`, runs the gate below, and exits 0 pass / 1 fail / 2 timed-out-unverified. Fall back to running the steps by hand only when the repo fits none of them:
  - Python (`pyproject.toml`): `uvx ruff check . && uvx ruff format --check . && uv run pytest` (pytest exit 5 = no tests = skip, not fail).
  - Go (`go.mod`): `gofmt -l .` (must print nothing), `go vet ./...`, `go test -race ./...`.
  - Node/TS (`package.json`): the project's own `typecheck` / `lint` / `test` / `build` scripts, whichever exist.
  - Anything else: the gate the repo's own `CLAUDE.md` names; failing that, the strongest offline check (compile, `py_compile`, a dev-server smoke test for UI).
  **Every check is timeout-bounded** (the runner enforces it; do the same by hand). A hung test must not stall the close — kill it, report the path as unverified (exit 2), move on. Delete throwaway verification scripts after. Report pass/fail counts.
  - **Build outputs:** if the repo has a gitignored build product (`dist/`, `build/`, `*.exe`) and source changed, rebuild it and smoke-test — `git status` never shows a stale binary.
  - **Green tooling is not a working feature.** A typecheck passing says nothing about a UI interaction or a network path you didn't exercise. In Step 7, name what was *machine-checked* and what remains *untested by a human*.
- **You suggested it, user didn't reply** — silence isn't deferral. Apply now if reversible and low-risk. If destructive or opinionated, ask once, act on the answer **same turn**.
- **User said "leave it" / "ignore for now" verbatim** — respect it; list as deferred in Step 7. This is the *only* thing that counts as user-deferred.
- **Genuinely blocked** (live credentials, a production run, a decision only the user can make) — list as deferred in Step 7, name the blocker.

Default is resolve, not ask. Pause only when the path forward is genuinely ambiguous — "user never replied" does not qualify.

**TODO.md sweep:** if the repo has a `TODO.md`, strike through (`~~…~~`) items done this session. Rides Step 5's commit.

---

## Step 2: Cruft + Scratchpad Sweep

Evidence line: `untracked in touched repos: N · jobs/tmp files: N · scratchpad files: N`.

**Working trees:** for each touched repo, look at untracked files (`git status --short | grep '^??'`). Throwaway scratch **you** created (verification scripts, temp output, `.bak`) — delete. Anything uncertain (user's own files, real output) — ask once, keep or delete, act same turn.

**Bash-tool job temp:** files written by the Bash tool land in `~/.claude/jobs/<id>/tmp`, not the scratchpad and not a repo — the facts list them under `(not in a git repo)`. Glance at that bucket for anything you created this session and left behind (probe scripts, captured output). Harness may GC the jobs dir, but don't rely on it; delete your own throwaways, hand over anything the user wanted.

**Scratchpad:** the session scratchpad dir (path in the facts) is deleted with the session. Glance at it: anything the user asked for (a report, exported data, a generated file) gets moved somewhere durable or handed over via `SendUserFile` — reports go to the user as `.md` files, never as artifacts. Everything else can die with the window; say so in one line. The facts' **files-handed-to-user** list shows what you already sent, so you don't re-hand or miss one.

---

## Step 3: Config Revision (CLAUDE.md)

Evidence line: `candidates: N — kept: N, rejected: N (reasons)`. If the session was pure Q&A or a trivial one-liner, `candidates: 0` is the honest line — never manufacture edits to justify the step.

### Inclusion test — a candidate is added only if it passes ALL four:
1. **Durable** — matters in a *future* session. Session narrative fails; the underlying gotcha passes.
2. **Non-obvious** — not derivable from the code, repo layout, or `git log`.
3. **Actionable — name the failure it prevents.** Write the sentence: "without this, a future session will ___." Can't write it → cut it. This is the primary filter.
4. **Not already covered — across ALL tiers.** Read the target file; then grep any parent-directory `CLAUDE.md` and the global `~/.claude/CLAUDE.md`. If it lives one tier up, leave it there — never duplicate downward.

**Default skew is omit.** Most sessions add nothing. Adding a marginal entry "to be safe" *is* the failure mode.

**Calibration — these LOOK worth adding but FAIL:**
- "Uses Tailwind v4 / Next 16" → derivable from `package.json`.
- "Fixed the nav bug this session" → session narrative.
- "Prefer async for network calls" → already a global rule.
- "Be careful with migrations" → names no concrete failure. (Contrast: "`prisma migrate dev` refuses destructive drops non-interactively — `UPDATE … SET col=NULL` first" passes.)

### Routing
- Project gotchas (build commands, layout, local quirks) → the **repo's own `CLAUDE.md`** (rides Step 5's commit). `AGENTS.md`-only repo → edit that file, don't introduce a second convention.
- Cross-project preferences and behavioral rules → **global `~/.claude/CLAUDE.md`** (never committed; not version-controlled — show the exact diff).
- **Harness behaviour** ("from now on, when X happens, do Y") is a **hook**, not prose → `.claude/settings.json` via the `update-config` skill. Same for permission allowlists and env vars.

### Flow
1. Reflect for gotchas; run each through the four-point test.
2. Read the target file, confirm no overlap, apply survivors directly — no y/n gate (standing user preference). Show the diff.
3. Don't commit here — the repo edit rides Step 5.

### Consolidation gate
The add-flow only grows the file. **Overdue signal:** a config file past ~150 lines, or a contradiction noticed while reading it. When overdue: reconcile — merge duplicates, scope environment-specific claims, delete entries now false or obvious. **Verify a claim against live state before deleting it**; when unsure, scope it, don't cut it. Only when the signal trips.

---

## Step 4: Re-check Working Tree State

Steps 1–3 may have edited files. Re-run `git -C <repo> status --short` for each touched repo so Step 5 commits the true final state.

---

## Step 5: Land + Push — Every Touched Repo

Evidence line: `repos touched: N (transcript)`. **Iterate over the repos from the facts**, not cwd. No repos → one line, skip to Step 6.

Per repo, run 5a–5h. Report each repo's result on its own line.

**Idempotency gate:** tree clean **and** nothing unpushed **and** no leftovers (5h) → "nothing to land", next repo. Never create an empty commit.

Read `git status` and `git log --oneline -5` (commit style). **Unusual states** — unborn HEAD, detached HEAD, in-progress merge/rebase, submodules — read `references/edge-cases.md` and follow that path; don't improvise.

**Derive `DEFAULT_BRANCH` per repo** (never hardcode):
```
git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null   # -> origin/main ; strip "origin/"
```
Fallback: `git remote show origin` → `HEAD branch:`. No remote → the repo's current branch (`git symbolic-ref --short HEAD`).

### 5a: Branch decision
The user's rule: **never create a branch.** Commit directly on `DEFAULT_BRANCH` and push.
- On `DEFAULT_BRANCH` with changes → commit there.
- Already on a feature branch (someone else made it) → commit there, then land it (5e) and delete it — unless the user explicitly said this session to keep the branch separate. If unsure, ask once, act same turn.
State the decision in one line.

### 5b: Stage — bounded scope
Stage **only the paths this session edited** (from the facts, plus Step 1/3 edits): `git add <path> <path>`. **Never** `git add -A` / `.` unless the tree was clean at 0c.

**Pre-existing-dirty guard:** a file dirty at 0c *and* edited by you bundles the user's earlier hunks. Don't use `git add -p` (interactive, hangs). Surface it — name the file, ask commit-together / skip / user-splits — act same turn.

**CRLF / mode noise (Windows):** if `git diff <path>` shows no substantive change, skip it — phantom-dirty.

### 5c: Secrets scan
Run via the **bash tool**:
```
git diff --cached -- . ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*.sum' \
  | grep -inE "(api_?key|secret_?key|access_?token|auth_?token|client_?secret|password|passwd|private_?key|BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|bearer [a-z0-9._-]{20,})"
```
Also flag staged `.env` files and filenames containing `cred`, `secret`, `token`, `key`. Hardcoded secrets are fine in **local** tools but must not reach a remote. **Hits + remote exists:** stop, list `file:line — pattern`, ask. **No remote:** note, proceed.

### 5d: Commit
Nothing staged → one line why, go to 5f. Otherwise a concise message in the repo's style; commit. Pre-commit hook fails → report exact error, fix if obvious, never `--no-verify`.

### 5e: Land on default and push
**Implicit-trigger gate:** if this skill fired implicitly, pause once before the first push: state what's committed and where it's going; push only on go-ahead. One combined confirmation for all repos.

If committed on a branch:
```
git switch DEFAULT_BRANCH
git merge --ff-only <branch>
```
- **ff-only fails** (default moved underneath you) → stop, report, ask: rebase-then-land or hand back. Never merge-commit or force.
- Success → `git push` default (`-u origin DEFAULT_BRANCH` if no upstream), then `git branch -d <branch>`; if the branch was ever pushed, `git push origin --delete <branch>`.

If committed straight to default → `git push` (`-u` if no upstream).

**No remote** → landed locally; say "no remote, nothing to push".

### 5f: Prior unpushed commits
`git log @{u}.. --oneline 2>/dev/null` (fallback `git log <branch> --not --remotes`). Ahead → push. "No changes this session" + 3 unpushed commits is not clean.

### 5g: Push failures
- **Rejected (non-fast-forward)** → remote moved. Report. **Never auto-force.** Offer pull/rebase-then-push or hand back.
- **Auth / network** → exact error; the commit is safe locally — say committed-but-unpushed.
- **Pre-push hook fail** → exact error, fix if obvious, never `--no-verify`.

### 5h: Leftover sweep
Things that outlive a session unnoticed:
```
git stash list
git worktree list
git branch --no-merged DEFAULT_BRANCH
```
- **Stashes:** any you created this session → `pop` if the work belongs in the tree, else report the ref and why. Pre-existing stashes → list them; don't touch.
- **Worktrees** beyond the main one → list; remove only if you created it this session and it's merged. Session-created means the facts show `git worktree add` **or** a harness `EnterWorktree` / `Agent isolation:worktree` entry — the harness path lands under `<repo>/.claude/worktrees/<name>`, and `git worktree list` will show it even though no `git worktree add` ran. Cross-reference both. Remove a harness worktree with `git worktree remove` after its branch is landed.
- **Unmerged branches:** created this session (facts show `switch -c` / `checkout -b`) → land or, if abandoned, ask once then delete. Older ones → list only.

Report: `<repo>: committed <sha> on <branch> → landed on <default> → pushed <remote> · leftovers: none`.

---

## Step 6: Memory Update

Evidence line: `candidates: N — saved: N, updated: N, rejected: N`.

Persist what this session produced that isn't already in memory: new user preferences/feedback, project decisions or context the user expressed, corrections to stale entries, new external references. **Same bar as Step 3:** durable, non-obvious, not already stored, not something the repo/git already records. Default skew omit.

**Auto-save** without asking. Write directly to `~/.claude/memory/` (exists; don't `mkdir`). One fact per file:

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

Then one pointer line in `MEMORY.md` — `- [Title](file.md) — hook`. Convert relative dates to absolute. Check for an existing file covering the same ground and update it rather than near-duplicating. Memory is **never committed, never pushed**.

**Mechanical index check — every session:**
```
& "$HOME\.claude\skills\complete-session\scripts\memory-index-check.ps1" [-Stats]
```
Fix every **finding** (unindexed file, dangling `MEMORY.md` link, indexed-twice, bad frontmatter, name/file mismatch) before moving on — those are structural and fail the exit code. **Dead `[[wikilinks]]`** are reported too but are *informational*: a forward reference to a memory you haven't written yet is allowed by the format, so only fix one that's an actual typo or points at a renamed file. Cheap, and it catches the "claimed to save, never wrote the file" failure.

**Deep reconcile — only on signal:** you hit a stale, duplicate or contradictory memory this session, or a memory names a file/flag/path you found no longer exists. Then merge, fix, or delete — **verifying against live state first**. Not every session, and never because of a raw entry count. When a signal does trip, `-Stats` gives the by-type counts and the **orphan list** (memories nothing links to) to focus the reconcile.

---

## Step 7: Prove Clean

Not a paragraph — a table, every row backed by a command you ran **now** (not earlier in the skill). A row you can't back with output is an open item.

**Generate the per-repo rows mechanically** — this is the proof step, so don't hand-run and hand-transcribe six git commands per repo:
```
& "$HOME\.claude\skills\complete-session\scripts\prove-clean.ps1" -Repo <repo1>,<repo2>
```
It emits the working-tree / unpushed / **push-landed (local HEAD == upstream)** / on-default / stashes / worktree / unmerged rows per repo and exits 0 only when every repo is clean. Paste the non-repo rows (gate, background, scratchpad, memory index, config, memory) around it. Open the session with a one-line **summary** from the facts: `<duration> · <N> repos landed · <N> files changed · <N> memories saved · <N> tokens dropped`.

```
CHECK                          COMMAND                                   RESULT
per repo <path>:
  working tree clean           git status --porcelain                    (empty) ✓
  nothing unpushed             git rev-list --count @{u}..HEAD           0 ✓   | no remote
  on default branch            git symbolic-ref --short HEAD             main ✓
  no stashes                   git stash list                            (empty) ✓
  single worktree              git worktree list                         1 ✓
  no session branches left     git branch --no-merged <default>          (empty) ✓
  verification gate            <gate command>                            pass N / fail 0 ✓  | not run: <why>
background / agents            TaskOutput · CronList                     none ✓
processes started by session   Get-Process since <start>                 none ✓ | not checked (none launched)
scratchpad                     <path>                                    N files, handed over / discarded ✓
memory index                   memory-index-check.ps1                    0 findings ✓
config changed                 —                                         repo CLAUDE.md / global / settings / none
memory                         —                                         N added, N updated
```

Then **machine-checked vs untested:** one line each — what the gates covered, and what only a human can confirm (a UI flow, a prod path, a credentialed call).

End with one of:
- **Session is clean.** — every row ✓. The normal ending.
- **Session has open items:** — followed by a numbered list, one per line, each naming the blocker.
  - **Acceptable blockers:** user said "leave it" verbatim; needs live credentials/production; a decision only the user can make and you already asked; a push rejected / gate-declined / failed on auth — committed locally, say so; staged secrets awaiting a decision; `ff-only` refused because default moved.
  - **Not acceptable:** "user didn't reply to my suggestion", "noticed something tangential", "didn't have time to verify", or any row you simply didn't run.

If Step 0a's script failed and you ran on recall, say so here: the table is then "recalled", not "proved".

---

## Boundaries

- Never run destructive git operations (`reset --hard`, `push --force`, `clean -f`) unless the user explicitly asks. (`git reset --soft` for commit-folding is fine — it loses no work.)
- Never skip pre-commit / pre-push hooks with `--no-verify`.
- Never merge-commit onto the default branch — `--ff-only`, or stop and ask.
- Never delete a branch, worktree or stash you didn't create this session without asking.
- Never hardcode a default branch name — derive it per repo.
- If any step fails, surface the failure and ask before proceeding — never silently swallow errors.
- Never invoke this skill recursively.
