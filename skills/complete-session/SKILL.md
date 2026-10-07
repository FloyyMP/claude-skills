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

**Modes:** default is **execute**. If the user asked to *preview* / *dry-run*, run every read-only check (Step 0's facts, `prove-clean.sh`, the memory check) but make **no writes** — no edits, commits, pushes, stashes, memory saves. Don't run `run-gates.sh` in preview: test runners write caches, lockfiles and venvs; name the gate command in the manifest instead. Instead of narrating step by step, end with **one consolidated manifest** of what execute *would* do: repos to stage+commit+push (with the branch decision per repo), files to be staged, CLAUDE.md / settings edits with their diffs, memories to add or update. One block the user can approve at a glance, then stop.

**Trigger type:** **Explicit** = `/complete-session`, or the user used one of the description's phrases ("complete session", "wrap up", "done for today", "close out"). **Everything else is implicit** ("that's it", "we're done", "call it a day", "heading out") — it can be a false positive, so it gets one confirmation before the first push (5e). Explicit needs no gate. Invoking this skill **is** the user's "commit and push" ask — the standing "don't commit unless I ask" rule is satisfied.

**Precedence:** branch, push and deploy rules in the repo's `CLAUDE.md` / `AGENTS.md` or the global `~/.claude/CLAUDE.md` (a working branch such as `dev`, PR-only, "never push to main", "ask before shipping UI") **override Step 5a/5e**. Follow them and say so in one line. The close-out finishes what the user asked for; it never widens scope.

**Never invoke recursively.** If this skill is already running this turn, exit immediately.

---

## Step 0: Session Facts + Live State

### 0a: Pull the facts from the transcript

Run the parser via the **Bash tool**. The session id defaults to `$CLAUDE_CODE_SESSION_ID`, which the harness sets for every Bash command:

```
~/.claude/skills/complete-session/scripts/session-facts.py [--session-id <id>] [--json]
```

It reads `~/.claude/projects/<slug>/<session-id>.jsonl` (plus subagent transcripts) and prints: files edited grouped by git repo, repos touched **with a live git-state snapshot** (branch, default, dirty count, ahead count, stashes, worktrees), shell commands that wrote files / changed git state / launched processes, `run_in_background` jobs, subagents (with `isolation`), **worktrees entered** (`EnterWorktree` / `Agent isolation:worktree`), **files handed to the user** (`SendUserFile`), **questions asked** (`AskUserQuestion`), **skills invoked**, schedulers, the last todo list, compaction count **and tokens dropped**, idle time since last activity, and the session temp dir (`/tmp/claude-<uid>/<slug>/<session-id>`). **These facts drive Steps 1, 2, 5 and 7** — repos come from *files touched*, never from cwd. If cwd is not a repo but the facts show edits inside one, that repo is in scope. Repos changed only through shell commands (`sed -i`, heredoc, `git commit`) are added when dirty or ahead and tagged `<via shell>`; their files aren't in FILES EDITED, so take their paths from `git status` in 0c.

The repo snapshot means Steps 0c, 4, 5 and 7 start from machine truth, not a separate hand-run of `git status`. For the machine parts of Steps 5 and 7, iterate `--json` output (`ReposTouched`, `RepoState`) rather than eyeballing the human report.

If the script errors, show the error and fall back to conversation recall for this run — and say so in Step 7 (it downgrades "proved" to "recalled").

Note the compaction count. ≥1 means recall of the early session is unreliable: lean harder on the facts — the report prints the dropped-token total so you can see *how much* is gone.

### 0b: Live work the window close would kill

Cross-check the facts against live state:
- **Background commands / workflows** (`run_in_background`, `Workflow`) — still running? Their output is in the session tmp dir's `tasks/*.output`. Wait if about to finish, else ask whether to stop (`TaskStop`).
- **Subagents** — `ListAgents` / `TaskStop`.
- **Schedulers / watches** — `/loop` wakeups, `CronList` for crons created this session, `RemoteTrigger` for cloud routines.
- **Detached processes** — only if the facts flag any `process` launches (dev servers, `nohup`, `&`, `docker run`): check what's still alive since session start (`Started` is in `--json`):
  ```
  age=$(( $(date +%s) - $(date -d '<Started from 0a>' +%s) ))
  ps -u "$(id -u)" -o pid,etimes,args --sort=etimes | awk -v a="$age" 'NR==1 || $2 < a'
  ss -ltnp
  ```
  (`etimes` = seconds since the process started, so `< age` means started during this session — but so did every other process on the machine in that window: match candidates against the commands the facts list before touching one.)
  Report anything the session started that is still listening. Stop it only if it was clearly a throwaway dev server; otherwise ask. Never start new processes during the close-out.

**Do not pass Step 0 until every live task is resolved** — a running task can mutate files that Step 5 then commits.

### 0c: Starting tree snapshot per touched repo

For **each repo in the facts**, run `git -C <repo> status --short` and note what was **already dirty**: the facts count dirty paths untouched since the session started as the user's own (`PreExistingDirty`). This bounds Step 5b and is the rollback reference if a Step 1 autofix clobbers pre-existing edits.

**The facts under-report shell work.** Most edits go through Bash (heredocs, `sed`, scripts), which the parser can only partly see; a repo you changed through a relative path or a script can be missing entirely. Add every repo the conversation shows you changed, and say it was added from the conversation.

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
  ~/.claude/skills/complete-session/scripts/run-gates.sh --repo <repo-root> [--timeout 300]
  ```
  It gates every language it finds (`pyproject.toml` / each `go.mod` / `package.json`) and exits 0 pass / 1 fail / 2 timed-out-unverified / 3 not runnable (no recognized gate, toolchain or deps missing). Read its `RESULT:` line — don't pipe it into `tail` and trust `$?`. **The repo's own gate wins:** if its `CLAUDE.md` / README names a test command or environment (`TZ=UTC`, "we don't use uv", a Makefile target), run that. On exit 3, run the strongest offline check (compile, `py_compile`, `bash -n`, a smoke run) and report it as that — never install toolchains or pull images to make a gate runnable.
  **Every check is timeout-bounded** (the runner enforces it; do the same by hand). A hung test must not stall the close — kill it, report the path as unverified (exit 2), move on. Delete throwaway verification scripts after. Report pass/fail counts.
  - **A failing gate blocks the push for that repo** — commit locally, list it as open. Exception: a failure that already fails on `HEAD` without your changes (prove it on a clean copy: `d=$(mktemp -d); git archive HEAD | tar -x -C "$d"`, gate there) — report it as pre-existing, don't fix it, don't block on it.
  - **Build outputs:** if the repo has a gitignored build product (`dist/`, `build/`, `*.exe`) and source changed, rebuild it and smoke-test — `git status` never shows a stale binary.
  - **Green tooling is not a working feature.** A typecheck passing says nothing about a UI interaction or a network path you didn't exercise. In Step 7, name what was *machine-checked* and what remains *untested by a human*.
- **You suggested or noticed it, user didn't reply** (an offer, an unrelated typo, a bug you pointed out) — **don't apply it**. The user didn't ask for it; list it in Step 7 under "offered, not done" in one line. This covers changes to code, tests, dependencies, the environment (installs, image pulls, servers) and global config (`~/.claude/settings.json`, global `CLAUDE.md`, hooks) — including anything a plugin or hook told you to offer. It does **not** cover the repo-`CLAUDE.md` learnings and memories Steps 3 and 6 exist for: those follow their own test, offered or not.
- **User deferred it, in any wording** ("leave it", "later", "next week", "don't bother yet") — respect it; list as deferred in Step 7.
- **Genuinely blocked** (live credentials, a production run, a decision only the user can make) — list as deferred in Step 7, name the blocker.

Default is resolve what the user asked for, not ask. Pause only when the path forward is genuinely ambiguous. If there's a tool to ask (AskUserQuestion), use it; without one (headless), take the non-destructive option — skip, don't push, keep — and list it as open.

**TODO.md sweep:** if the repo has a `TODO.md`, strike through (`~~…~~`) items done this session. Rides Step 5's commit.

---

## Step 2: Cruft + Session Temp Sweep

Evidence line: `untracked in touched repos: N · session tmp files: N`.

**Working trees:** for each touched repo, look at untracked files (`git status --short | grep '^??'`). Throwaway scratch **you** created (verification scripts, temp output, `.bak`) — delete. Anything uncertain (user's own files, real output) — ask once, keep or delete, act same turn.

**Session temp dir:** the facts print `SESSION TMP` (`/tmp/claude-<uid>/<slug>/<session-id>`, holding `tasks/*.output` from background jobs and anything else the harness wrote). It is not durable. Glance at it — don't delete it (the harness is writing your live command output there): anything the user asked for (a report, exported data, a generated file) gets moved somewhere durable and its path printed, or handed over via `SendUserFile` where that tool exists — reports go to the user as `.md` files, never as artifacts. Throwaway files **you** created elsewhere in `/tmp` (probe scripts, captured output) — delete. Everything else can die with the window; say so in one line. The facts' **files-handed-to-user** list shows what you already sent, so you don't re-hand or miss one.

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
- Cross-project preferences the user **asked to make a global rule** → **global `~/.claude/CLAUDE.md`**. Every other preference or feedback goes to memory (Step 6) — one home, never both.
- **Harness behaviour** ("from now on, when X happens, do Y") is a **hook**, not prose → `.claude/settings.json` via the `update-config` skill. Same for permission allowlists and env vars. Only when the user asked for it this session.

### Flow
1. Reflect for gotchas; run each through the four-point test.
2. Read the target file, confirm no overlap. Repo `CLAUDE.md` survivors: apply directly — no y/n gate (standing user preference); the diff rides the commit. Global `CLAUDE.md` / settings: show the exact diff and apply only on a yes — they reach every project and aren't version-controlled. Never `cat` `~/.claude/settings.json` (it can hold tokens): `jq 'del(.env)' ~/.claude/settings.json`.
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
Fallback: `<remote>/main` or `<remote>/master` if one exists (the facts' `Default` does this offline). No remote → `init.defaultBranch`, else `main`/`master`. Unknown → say so; don't assume the current branch.

### 5a: Branch decision
Unless a CLAUDE.md branch rule applies (see **Precedence**), the user's rule: **commit directly on `DEFAULT_BRANCH`, never create a branch.** Work lands on `DEFAULT_BRANCH` before the session ends.
- On `DEFAULT_BRANCH` with changes → commit there, push (5e).
- On a branch **this session created** → commit there, then fast-forward it into default, push, delete it (5e).
- On a branch that **existed before the session** (a feature branch, a long-lived `dev`) → commit and push that branch; landing it on default or deleting it needs the user's yes.
State the decision in one line.

### 5b: Stage — bounded scope
Stage **only the paths this session edited** (from the facts, plus Step 1/3 edits): `git add <path> <path>`. **Never** `git add -A` / `.` unless the tree was clean at 0c.

**Pre-existing-dirty guard:** a file dirty at 0c *and* edited by you bundles the user's earlier hunks. Don't use `git add -p` (interactive, hangs). Surface it — name the file, ask commit-together / skip / user-splits — act same turn.

**Mode noise:** if `git diff <path>` shows only a mode change (`old mode 100644 / new mode 100755`) you didn't intend, skip it — phantom-dirty.

### 5c: Secrets scan
Run via the **bash tool**, as **its own command** — read the result before committing; never chain it with `commit`/`push`. From the repo root, added lines only; the scan covers token *formats*, not just key-ish variable names:
```
git -C <repo> diff --cached -U0 -- ':/' ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*.sum' | grep '^+' \
  | grep -inE "(api_?key|secret|access_?token|auth_?token|client_?secret|password|passwd|private_?key|BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|bearer [a-z0-9._-]{20,}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_\w{20,}|sk-(proj|ant)-[A-Za-z0-9_-]{20,}|[sr]k_live_[A-Za-z0-9]{16,}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.eyJ|://[^/:@ ]+:[^@ ]+@)"
```
`gitleaks protect --staged` is better where installed. Also flag staged `.env` files and filenames containing `cred`, `secret`, `token`, `key`. Hardcoded secrets are fine in **local** tools but must not reach a remote. **Hits + remote exists:** stop, list `file:line — pattern` (the file's line, not the diff's), ask. **No remote:** note, proceed.

### 5d: Commit
Nothing staged → one line why, go to 5f. Otherwise a concise message in the repo's style — one commit per repo unless the user prefers small commits; commit. Pre-commit hook fails → report exact error, fix if obvious (never invent an issue number or a ticket the hook demands — ask), never `--no-verify`.

### 5e: Land on default and push
**Implicit-trigger gate:** if this skill fired implicitly, pause once before the first push: state what's committed and where it's going; push only on go-ahead. One combined confirmation for all repos.

If committed on a branch this session created (see 5a):
```
git switch DEFAULT_BRANCH
git merge --ff-only <branch>
```
Inside a linked worktree (`claude -w`, `EnterWorktree`) `git switch DEFAULT_BRANCH` fails because the main tree has it checked out: verify `git merge-base --is-ancestor origin/DEFAULT_BRANCH HEAD`, then `git push origin HEAD:DEFAULT_BRANCH`, and tell the user the main tree needs `git pull` and the worktree can be removed after exit — you can't remove the worktree you're running in.
- **ff-only fails** (default moved underneath you) → stop, report, ask: rebase-then-land or hand back. Never merge-commit or force.
- Success → `git push` default (`-u origin DEFAULT_BRANCH` if no upstream), then `git branch -d <branch>`; if the branch was ever pushed, `git push origin --delete <branch>`.

If committed straight to default → `git push` (`-u` if no upstream).

**No remote** → landed locally; say "no remote, nothing to push".

### 5f: Prior unpushed commits
`git log @{u}.. --oneline 2>/dev/null` (fallback `git log <branch> --not --remotes`). Ahead → secrets-scan the range (`git log -p @{u}.. | grep '^+' | grep -inE …` as in 5c), then push. "No changes this session" + 3 unpushed commits is not clean. Not while a merge/rebase is in progress (edge-cases): hand back instead.

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

**Auto-save** without asking. Memory lives in the **auto-memory dir named in the system prompt** — on Linux that's per project: `~/.claude/projects/<slug>/memory/`, flat, one fact per file:

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

After writing the file, add one pointer line to that dir's `MEMORY.md`: `- [Title](file.md) — hook`. The file name must match `name:`.

Convert relative dates to absolute. Check for an existing file covering the same ground and update it rather than near-duplicating. Memory is **never committed, never pushed**. An answer the user gave to one close-out question is a decision for this session, not a standing rule — don't save "don't ask again" memories from it.

**Mechanical index check — every session:**
```
~/.claude/skills/complete-session/scripts/memory-index-check.py [--stats] [--memory-dir <dir>]
```
It finds the memory dir from the session's git root (the one the system prompt names), and "no memory files yet" passes — never create an empty `MEMORY.md` to satisfy it. Fix every **finding** (unindexed file, dangling `MEMORY.md` link, indexed-twice, bad frontmatter, name/file mismatch) before moving on — those are structural and fail the exit code. **Dead `[[wikilinks]]`** are reported too but are *informational*: a forward reference to a memory you haven't written yet is allowed by the format, so only fix one that's an actual typo or points at a renamed file. Cheap, and it catches the "claimed to save, never wrote the file" failure.

**Deep reconcile — only on signal:** you hit a stale, duplicate or contradictory memory this session, or a memory names a file/flag/path you found no longer exists. Then merge, fix, or delete — **verifying against live state first**. Not every session, and never because of a raw entry count. When a signal does trip, `--stats` gives the by-type counts and the **orphan list** (memories nothing links to) to focus the reconcile.

---

## Step 7: Prove Clean

Not a paragraph — a table, every row backed by a command you ran **now** (not earlier in the skill). A row you can't back with output is an open item.

**Generate the per-repo rows mechanically** — this is the proof step, so don't hand-run and hand-transcribe six git commands per repo:
```
SINCE=$(date -d '<Started from 0a>' +%s) ~/.claude/skills/complete-session/scripts/prove-clean.sh <repo1> <repo2>
```
It emits the working-tree / unpushed / **push-landed (local HEAD == upstream)** / op-in-progress / on-default / stashes / worktree / unmerged rows per repo and exits 0 only when every repo is clean. `SINCE` limits the stash and branch rows to ones created this session — the user's own older stashes and branches are theirs, not open items. Read its `ALL CLEAN` / `OPEN ITEMS` line; don't pipe it. A repo whose documented working branch isn't the default (see **Precedence**) will show `on default branch OPEN` by design — mark that row "working branch per CLAUDE.md", not ✓. Paste the non-repo rows (gate, background, session tmp, memory index, config, memory) around it. Open the session with a one-line **summary** from the facts: `<duration, copied from the facts' span> · <N> repos landed · <N> files changed · <N> memories saved · <N> tokens dropped`.

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
background / agents            tasks/*.output · ListAgents · CronList    none ✓
processes started by session   ps etimes < session age                   none ✓ | not checked (none launched)
session tmp                    <path>                                    N files, handed over / left to expire ✓
memory index                   memory-index-check.py                     0 findings ✓
config changed                 —                                         repo CLAUDE.md / global / settings / none
memory                         —                                         N added, N updated
```

Then **machine-checked vs untested:** one line each — what the gates covered, and what only a human can confirm (a UI flow, a prod path, a credentialed call).

End with one of:
- **Session is clean.** — every row ✓. The normal ending.
- **Session has open items:** — followed by a numbered list, one per line, each naming the blocker.
  - **Acceptable blockers:** user deferred it (any wording); needs live credentials/production; a decision only the user can make and you already asked; a push rejected / gate-declined / failed on auth — committed locally, say so; a gate that fails on this session's changes — committed locally, not pushed; staged secrets awaiting a decision; `ff-only` refused because default moved; pre-existing user WIP left uncommitted on purpose.
  - **Not acceptable:** "didn't have time to verify", or any row you simply didn't run.
  - Suggestions the user never answered and things you noticed in passing are **not** open items: list them after the ending under "Offered, not done" (one line each), so they neither block "clean" nor get applied.

If Step 0a's script failed and you ran on recall, say so here: the table is then "recalled", not "proved".

---

## Boundaries

- Never run destructive git operations (`reset --hard`, `push --force`, `clean -f`) unless the user explicitly asks. (`git reset --soft` for commit-folding is fine — it loses no work.)
- Never skip pre-commit / pre-push hooks with `--no-verify`.
- Never merge-commit onto the default branch — `--ff-only`, or stop and ask.
- Never delete a branch, worktree or stash you didn't create this session without asking.
- Never change global config (`~/.claude/settings.json`, global `CLAUDE.md`, hooks) without the user's yes, and never print `settings.json` whole.
- Never hardcode a default branch name — derive it per repo.
- If any step fails, surface the failure and ask before proceeding — never silently swallow errors.
- Never invoke this skill recursively.
