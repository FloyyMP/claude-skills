---
name: complete-session
version: 2.0.0
description: Closes out a Claude Code session so the window can be shut with nothing lost — verifies edited files, lands and pushes every touched repo, updates CLAUDE.md and memory, then proves the state is clean with command output. Use when the user runs /complete-session or says "complete session", "wrap up", "done for today", "close out". Not for wrapping up a single task mid-session.
license: MIT
---

# Complete Session

Goal: the user can close the window with zero doubt — nothing pending, nothing lost, everything documented, landed and pushed. Run the steps in order. **Never skip a step silently** — if it doesn't apply, show why and move on.

## Rules for every step

**Evidence first.** Every step prints its **evidence line first, verdict second**: source + count ("files edited this session: 3 (transcript)", "candidates considered: 2 — rejected: …"). "Nothing" / "clean" / "none" is **only allowed after an evidence line that shows zero**. A step with a conclusion and no evidence has not run. **Recall is not evidence.** Facts come from the transcript on disk (Step 0a); the conversation only supplements them.

**Act, don't ask.** Working-tree items get the sensible default without a question (Steps 2, 5b). Pause only for an action that is destructive and irreversible with no clear intent signal. With no ask tool (headless), take the non-destructive option — skip, don't push, keep — and list it as open.

**Ordering:** every repo-bound write (Steps 1, 3, 4) happens **before** Step 5 so it rides one commit per repo. Memory and global config live outside repos and are never committed.

**Modes:** default is **execute**. On *preview* / *dry-run*: run every read-only check (facts, `prove-clean`, `memory-index-check`), make **no writes** (edits, commits, pushes, stashes, memory saves), don't run `run-gates` (test runners write caches, lockfiles, venvs — name the gate command instead). End with **one consolidated manifest**: per repo the branch decision, paths to stage, commit + push; CLAUDE.md / settings diffs; outside-repo actions; memories to add, update or archive. Then stop.

**Trigger type:** **Explicit** = `/complete-session` or a description phrase ("complete session", "wrap up", "done for today", "close out"). **Everything else is implicit** ("that's it", "call it a day") — it gets one confirmation before the first push (5e). Invoking this skill **is** the user's "commit and push" ask. **Never invoke recursively** — already running this turn → exit.

**Precedence:** rules in the repo's `CLAUDE.md` / `AGENTS.md` or the global `~/.claude/CLAUDE.md` override Step 5a/5e (a working branch such as `dev`, PR-only, "ask before shipping UI") — follow them and say so in one line. The same files' **documented post-change steps** are part of landing (e.g. claude-skills: version bump, README row, repo description, reinstall, `npx skills remove` for deleted skills) — do them. The close-out finishes what the user asked for; it never widens scope.

**Running the scripts.** `<S>` = `~/.claude/skills/complete-session/scripts` (Windows: `C:\Users\<user>\.claude\skills\complete-session\scripts`). Run through the **Bash tool** (Git Bash on Windows works for all four): `.py` as `python <S>/x.py` on Windows, `python3 <S>/x.py` on Linux/macOS; `.sh` as `bash <S>/x.sh`. Never execute them directly (the `python3` shebang doesn't exist on Windows). **No bash at all:** call the `.ps1` twin from the PowerShell tool as `& '<S>\x.ps1' -Flag value -Repo a,b` — never wrap it in `pwsh -Command` / `-File` (both lose exit codes or split arrays). Read each script's verdict line; never pipe it into `tail` and trust `$?`.

## Step 0: Session Facts + Live State

### 0a: Pull the facts from the transcript

Run **once** — `--brief` by default, `--json` only if you must iterate programmatically, never both:
```
python <S>/session-facts.py --brief [--session-id <id>]     # ps1: -Brief / -Json / -SessionId
```
Exit 0 = report produced (it may carry `WARNING:` lines / JSON `Warnings`), 1 = transcript missing. It prints: files edited grouped by repo, repos touched with live git state and per-repo dirty paths the session didn't edit (tagged `pre-existing` or `via shell`), `OutsideRepoEdits` (`memory` / `global-config` / `installed-skill` / `session-tmp` / `other`), `ExternalEffects` (`git-write` / `install` / `plugin` / `mcp` / `skill` / `github` / `schedule` / `registry` / `env` / `process` / `delete`), background jobs, subagents, worktrees, files handed to the user, questions asked, the last todo list, compactions, `Started`, duration and the session temp dir. Failed or refused tool calls are excluded. **These facts drive Steps 1, 2, 4, 5 and 7.**

- **Warning that the session id was missing / the newest transcript was used:** confirm it is this session (match a recent user message) before trusting its repos.
- **Warning that a repo's state is unknown:** treat that repo as unknown and check it by hand — never as clean.
- **Exit 1 / script error:** show it, fall back to conversation recall, and say so in Step 7 ("recalled", not "proved"). Compactions ≥ 1 → recall of the early session is unreliable; lean on the facts.

### 0b: Live work the window close would kill

- **Background commands / workflows** — still running? Output is in the session temp dir's `tasks/*.output`. Wait if about to finish, else ask whether to stop (`TaskStop`).
- **Subagents** — `ListAgents` / `TaskStop`. **Schedulers** — `/loop` wakeups, `CronList`, `RemoteTrigger` for anything created this session.
- **Detached processes** — only if `ExternalEffects` has `process` entries (dev servers, `nohup`, `&`, `docker run`). Find what's still alive since `Started`:
  - Windows (PowerShell tool): `Get-Process | ? StartTime -gt ([datetime]'<Started>')` and `Get-NetTCPConnection -State Listen | select LocalPort,OwningProcess`
  - Linux/macOS: `ps -u "$(id -u)" -o pid,etimes,args --sort=etimes` (keep `etimes` < session age) and `ss -ltnp`

  Other processes start in that window too — match against the facts' commands before touching one. Stop it only if it was clearly a throwaway dev server; otherwise ask. Note live dev servers per repo (Step 1 gates need it).

**Do not pass Step 0 until every live task is resolved** — a running task can mutate files Step 5 then commits.

### 0c: Close-time snapshot per touched repo

For each repo in the facts, `git -C <repo> status --short`. This is a **close-time** snapshot: which dirt predates the session comes from the facts' `pre-existing` tags. The parser also adds session cwds as candidates but reports only dirty/ahead ones, and it under-reports shell work (heredocs, `sed`, relative paths, scripts) — add every repo the conversation shows you changed and say it was added from the conversation.

Evidence line: `repos: N (transcript) · files edited: N · outside-repo edits: N · external effects: N · bg: N · agents: N · worktrees: N · compactions: N (~N tokens dropped)`.

## Step 1: Surface And Resolve Unfinished Work

Sources, in order of trust:
1. **Facts:** open todos, files edited (each needs a verification result), files marked `MISSING NOW` (edited then deleted — intended?), `delete` effects, subagent edits.
2. **Conversation:** errors raised but never resolved, "I'll do X later", promised follow-ups, suggestions the user never answered.

Evidence line: `open todos: N · files edited: N · unverified: N · promised follow-ups: N`.

This is a punch list to clear, not a status report. Per item:
- **Unfinished work the user asked for / unresolved error / promised follow-up** — finish it **only if it fits in a few minutes**; one line on what you did. Bigger → open item in Step 7.
- **Non-repo doc edits** (memory, global `CLAUDE.md`, settings) have no gate — Steps 3, 4 and 6 handle them.
- **Edited but unverified source** — run the gate from the **repo root** (a build from a subdirectory can target the wrong module):
  ```
  bash <S>/run-gates.sh --repo <root> [--timeout 300] [--total-timeout 540] [--no-build]
  ```
  It gates `pyproject.toml` and `requirements.txt` + `tests/` Python, each `go.mod`, `package.json`, Cargo, `.csproj` / `.sln`, and subprojects one level down (`SKIP <path>: <reason>` lines say what it passed over). Exit 0 pass · 1 fail · 2 timed out / unverified (incl. the 540 s total budget) · 3 not runnable (no gate steps; no test, typecheck or build step ran; toolchain/deps missing).
  - **Size it to the change.** Pass `--no-build` when a dev server for that repo is live (0b) — `next build` clobbers a running `next dev`.
  - **The repo's own gate wins:** a test command or environment its `CLAUDE.md` / README names (`TZ=UTC`, a Makefile target) runs instead.
  - **Exit 3:** run the strongest offline check (compile, `py_compile`, `bash -n`) and report it as that. Never install toolchains or pull images to make a gate runnable.
  - **Hand checks are timeout-bounded too.** A hung test is killed and reported unverified. Bounded, self-terminating smoke runs are allowed; long-lived processes are not started. Delete throwaway verification scripts after.
  - **A failing gate blocks the push for that repo** — commit locally, list as open. Exception: it **already fails on `HEAD`** without your changes (prove it: `d=$(mktemp -d); git archive HEAD | tar -x -C "$d"`, gate there) → report as pre-existing, don't fix, don't block.
  - **Build outputs:** a gitignored build product (`dist/`, `build/`, `*.exe`) whose source changed → rebuild and smoke-test; `git status` never shows a stale binary.
  - **Green tooling is not a working feature** — Step 7 separates machine-checked from untested-by-a-human.
- **You suggested or noticed it, the user didn't reply** (an offer, an unrelated typo, a plugin/hook nudge) — **don't apply it**; list under "Offered, not done". Covers code, deps, environment and global config. Not the repo-`CLAUDE.md` learnings and memories of Steps 3 and 6 — those follow their own test.
- **User deferred it, in any wording** ("leave it", "later") — list as deferred.
- **Genuinely blocked** (live credentials, production, a decision only the user can make) — list as deferred, name the blocker.

**TODO.md sweep:** strike through (`~~…~~`) items done this session; rides Step 5's commit.

## Step 2: Cruft + Session Temp Sweep

Evidence line: `untracked in touched repos: N · scratch deleted: N · gitignored: N · left untracked: N · session tmp files: N`.

**Working trees** (`git status --short | grep '^??'` per touched repo), no questions:
- Scratch **you** created (verification scripts, temp output, `.bak`) → delete.
- Credential or output files that clearly shouldn't be tracked → add to `.gitignore` (rides the commit).
- Untracked files of unclear origin → leave untracked, list them in Step 7.

**Session temp dir** (`SESSION TMP` in the facts — Linux `/tmp/claude-<uid>/<slug>/<session-id>`, Windows `%TEMP%\claude\<slug>\<session-id>`): not durable. Don't delete it (the harness writes live output there). Anything the user asked for (a report, exported data) → move somewhere durable and print the path, or `SendUserFile` — reports as `.md` files, never artifacts. Throwaway files you created elsewhere in temp → delete. The rest dies with the window; say so. The facts' files-handed-to-user list stops you re-handing or missing one.

## Step 3: Config Revision (CLAUDE.md)

Evidence line: `candidates: N — kept: N, rejected: N (reasons)`. Pure Q&A or a trivial one-liner → `candidates: 0` is the honest line; never manufacture edits.

**Inclusion test — ALL four:**
1. **Durable** — matters in a *future* session. Session narrative fails; the underlying gotcha passes.
2. **Non-obvious** — not derivable from the code, repo layout or `git log`.
3. **Actionable** — write "without this, a future session will ___." Can't → cut. This is the primary filter.
4. **Not already covered across ALL tiers** — read the target file, grep parent `CLAUDE.md` files and the global one. Lives one tier up → leave it there.

**Default skew is omit.** Adding a marginal entry "to be safe" *is* the failure mode.

**Calibration — these LOOK worth adding but FAIL:**
- "Uses Tailwind v4 / Next 16" → derivable from `package.json`.
- "Fixed the nav bug this session" → narrative.
- "Prefer async for network calls" → already a global rule.
- "Be careful with migrations" → names no failure. (Passes: "`prisma migrate dev` refuses destructive drops non-interactively — `UPDATE … SET col=NULL` first".)

**Routing:**
- Project gotchas → the **repo's own `CLAUDE.md`** (`AGENTS.md`-only repo → that file). Apply directly, no gate; rides the commit.
- A cross-project rule the user **asked to make global this session** → global `~/.claude/CLAUDE.md`. That request is the yes: show the diff and apply, don't ask again. Every other preference → memory (Step 6); one home, never both. When a rule moves into a `CLAUDE.md`, archive any memory duplicating it (Step 6).
- **Harness behaviour** ("from now on, when X, do Y"), permissions, env vars → `.claude/settings.json` via the `update-config` skill, only when asked this session.

**Consolidation gate:** a config file past ~150 lines, or a contradiction noticed while reading it → reconcile: merge duplicates, scope environment-specific claims, delete entries now false or obvious. **Verify against live state before deleting; when unsure, scope it.** Only when the signal trips.

## Step 4: Outside-Repo Changes

Evidence line: `outside-repo edits: N (memory N · global-config N · installed-skill N · other N) · external effects: N`. Driven by `OutsideRepoEdits` + `ExternalEffects`.

- **`installed-skill`** — `~/.claude/skills/<name>/` is overwritten by the next `npx skills add`. Port the edit to the source clone (claude-skills), which then lands in Step 5 with its post-change steps (Precedence) including the reinstall.
- **`global-config`** — if a mirror exists (memory or the file says so, e.g. `~/AGENTS.md` mirrors `~/.claude/CLAUDE.md`), apply the same change there.
- **`install` / `plugin` / `mcp` / `skill` / `github` / `schedule` / `registry` / `env`** — list under "Environment changes" in Step 7, one line each. If it must be repeated on the user's other machines (laptop, VPS), say so.
- **`memory`** — feeds Step 6's `already saved this session` count.

## Step 5: Land + Push — Every Touched Repo

Evidence line: `repos touched: N (transcript)`. Iterate the facts' repos (plus 0c additions), not cwd. No repos → one line, Step 6. Per repo, re-run `git status --short` (Steps 1–4 edited files), read `git log --oneline -5` for commit style, then 5a–5h.

**Idempotency gate:** tree clean **and** nothing unpushed **and** no leftovers (5h) → "nothing to land", next repo. Never create an empty commit.

**Unusual states** — unborn HEAD, detached HEAD, merge/rebase in progress, harness worktree, submodules → read `references/edge-cases.md` and follow it; don't improvise.

**`DEFAULT_BRANCH`, per repo, fail-closed:** `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`); else `<remote>/main` or `<remote>/master` if one exists (the facts' `Default`); no remote → `init.defaultBranch`, else `main`/`master`. Unknown → say so; never assume the current branch.

### 5a: Branch decision
Unless Precedence applies: **commit on `DEFAULT_BRANCH`, never create a branch.** State the decision in one line.
- On `DEFAULT_BRANCH` → commit, push (5e).
- On a branch **this session created** → commit, fast-forward into default, push, delete it (5e).
- On a branch that **existed before the session** → commit and push that branch; landing or deleting it needs the user's yes.

### 5b: Stage — bounded scope
`git add <path> …` by explicit path, never `-A` / `.`:
- paths this session edited (facts + Steps 1–4) and `via shell` paths;
- the user's own **pre-existing** tracked edits and deletions in this repo — committed together with the session's; Step 7 lists those paths. **Only in a repo the session itself changed** (edits, `via shell` paths, or session commits): a repo listed only because a command mentioned its path, whose sole dirt is `pre-existing`, gets nothing staged — list it as "user WIP left as-is";
- session-created untracked files that belong in the repo. Untracked files of unclear origin stay out (Step 2).
- Skip a mode-only change (`old mode 100644 / new mode 100755`) you didn't intend.

### 5c: Secrets scan
Its **own Bash command** — read the result before committing:
```
cd <repo> && a() { git diff --cached -U0 -- ':/' ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*.sum' | grep '^+' | grep -v '^+++ '; }
echo '== BLOCK'; a | grep -inE "BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|bearer [a-z0-9._-]{20,}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_\w{20,}|sk-(proj|ant)-[A-Za-z0-9_-]{20,}|[sr]k_live_[A-Za-z0-9]{16,}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.eyJ|://[^/:@ ]+:[^@ ]+@|(api_?key|secret|token|password|passwd|private_?key)[a-z_]*[\"']?\s*[:=]\s*[\"'][^\"' ]{8,}[\"']"
echo '== REVIEW'; a | grep -inE 'password|passwd|secret|api_?key|token' | head -20
git diff --cached --name-only | grep -iE '(^|/)\.env(\.local|\.prod[a-z]*|\.dev[a-z]*|\.staging)?$|(^|[/_.-])(cred|creds|secret|secrets|token|tokens|key|keys)([_.-]|$)'
```
`gitleaks protect --staged` is better where installed. **BLOCK hits or a staged `.env` (not `.env.example`), and a remote exists:** a file that clearly shouldn't be tracked → unstage + `.gitignore` it (act); a secret in source → stop, list `file:line — pattern` (the file's line, not the diff's), ask. **No remote** → note, proceed (hardcoded secrets are fine in local tools; they must not reach a remote). REVIEW counts and filename hits are reported in one line, never blocking.

### 5d: Commit
Nothing staged → one line why, go to 5f. Else one commit per repo (unless the user prefers small commits) in the repo's style. A hook failure → exact error, fix if obvious; never invent an issue number or ticket the hook demands — ask.

### 5e: Land on default and push
**Implicit-trigger gate:** fired implicitly → pause once before the first push: what's committed and where it goes, one combined confirmation for all repos.

Branch this session created → `git switch DEFAULT_BRANCH && git merge --ff-only <branch>`:
- In a linked worktree (`claude -w`, `EnterWorktree`) `git switch` fails (the main tree holds the branch): verify `git merge-base --is-ancestor origin/DEFAULT_BRANCH HEAD`, then `git push origin HEAD:DEFAULT_BRANCH`; tell the user the main tree needs `git pull` and the worktree can be removed after exit.
- `--ff-only` fails (default moved) → stop, report, ask: rebase-then-land or hand back.
- Success → `git push` (`-u origin DEFAULT_BRANCH` if no upstream), `git branch -d <branch>`, and `git push origin --delete <branch>` if it was ever pushed.

Straight on default → `git push` (`-u` if no upstream). **No remote** → "landed locally, no remote" (unless a global rule requires one — edge-cases). Then run the repo's documented post-change steps (Precedence).

### 5f: Prior unpushed commits
`git log @{u}.. --oneline` (fallback `git log <branch> --not --remotes`). "No changes this session" + 3 unpushed commits is not clean. Mid merge/rebase → hand back (edge-cases). Commits not made this session:
- **Branch deploys** — repo `CLAUDE.md` / `AGENTS.md` or memory calls it production / auto-deploy, or deploy config exists (`railway.json`, `railway.toml`, `vercel.json`, `netlify.toml`, `fly.toml`, a GitHub workflow on push to that branch) → list them and ask before pushing.
- Otherwise → secrets-scan the range (`git log -p @{u}.. | grep '^+' | grep -v '^+++ '` through the BLOCK pattern), then push.

### 5g: Push failures
**Rejected (non-fast-forward)** → remote moved; report, offer pull/rebase-then-push or hand back. **Auth / network** → exact error; committed-but-unpushed. **Pre-push hook** → exact error, fix if obvious.

### 5h: Leftover sweep
`git stash list` · `git worktree list` · `git branch --no-merged DEFAULT_BRANCH`
- **Stashes** you created → `pop` if the work belongs in the tree, else report ref + why. Older ones → list.
- **Worktrees** you created (facts show `git worktree add` or a harness worktree — edge-cases) and merged → remove. A worktree that predates the session → note, not an open item.
- **Branches** created this session (`switch -c` / `checkout -b`) → land, or if abandoned ask once then delete. Older → list.

One line per repo: `<repo>: committed <sha> on <branch> → landed on <default> → pushed <remote> · leftovers: none`.

## Step 6: Memory Update

Run the index check first — it names the memory dir (`memory dir: <path> (source: …)`, from `autoMemoryDirectory`; not necessarily `~/.claude/projects/<slug>/memory`):
```
python <S>/memory-index-check.py [--memory-dir <dir>]
```
Evidence line: `candidates: N — saved: N, updated: N, archived: N, rejected: N · already saved this session: N` (the last from `OutsideRepoEdits` kind `memory` — don't re-save after a compaction).

**What to save:** new preferences/feedback, project decisions, corrections to stale entries, new external references. **Same bar as Step 3**, default skew omit. Read the global `~/.claude/CLAUDE.md` and `~/AGENTS.md` first: covered there → don't save, and archive any memory copy.

**Calibration — these LOOK worth saving but FAIL:**
- "Fixed the login redirect this session" → narrative; the commit records it.
- "Floyy wants `pathlib` not `os.path`" → already in global `CLAUDE.md`.
- "Floyy said skip the README this time" → a one-off answer to a close-out question, not a standing rule. Never save "don't ask again" memories from close-out answers.
- "r6-checker source lives in `src/`" → derivable from the repo.

**Format** — auto-save, one fact per file, `name` == filename (without `.md`); update an existing file rather than near-duplicating; absolute dates:
```markdown
---
name: <short-kebab-case-slug>
description: <one-line summary, used to decide relevance during recall>
metadata:
  type: user | feedback | project | reference
---

<the fact. For feedback/project, follow with **Why:** and **How to apply:** lines. Link related memories with [[their-name]].>
```
Then one index line in `MEMORY.md` under the right `##` section: `- [Title](file.md) — hook`, one link, ≤ 150 chars; facts go in the file, not the index. Memory is never committed or pushed. **Re-run the check after writing.** Exit 1 = structural findings (unindexed file, dangling link, indexed twice, bad frontmatter, name/file mismatch) — fix them all. "No memory files yet" passes; never create an empty `MEMORY.md`.

**Reconcile signals — act on them:** any `warn:` line (index > 150 lines / 20 KB — Claude Code loads only the first 200 lines / 25 KB; long or multi-link lines; duplicate descriptions; self-declared status like "(some stale)", "(verify …)", "on hold", "unregistered", "deprecated", "outdated"), a stale or contradictory memory hit this session, a memory naming a path/flag that no longer exists, or a memory about this skill's behaviour that the skill contradicts (memory is newer → follow it and list "update complete-session" under Offered; else fix the memory). Merge duplicates, shorten index lines, fix or archive stale entries. **Never hard-delete:** move the file to `unused/` in the memory dir and drop its index line. **Verify against live state before archiving; when unsure, scope it.**

## Step 7: Prove Clean

Every row is backed by a command run **now**. A row you can't back is an open item. Per-repo rows, mechanically:
```
SINCE=$(date -d '<Started>' +%s) bash <S>/prove-clean.sh <repo1> <repo2>
# ps1: & '<S>\prove-clean.ps1' -Repo a,b -Since ([DateTimeOffset]'<Started>').ToUnixTimeSeconds()
```
Rows are `ok`, `OPEN`, or `note` (pre-existing worktrees, behind upstream — notes never block). It ends with `checks ok: N, open: M, notes: K` then `ALL CLEAN` / `OPEN ITEMS`; invalid `SINCE` exits 2. A repo on its documented working branch (Precedence) shows `on default branch OPEN` by design — mark it "working branch per CLAUDE.md".

**Output, in order:**
1. Summary from the facts: `<duration, e.g. 45m 41s> · N repos landed · N files changed · N memories saved · N tokens dropped`. Durations as `1m 52s`, never bare seconds; Windows paths with backslashes on Windows.
2. Non-ok rows only, then `N checks OK` and prove-clean's notes in one line. The full table only when something is open. Non-repo rows count the same way: gate, background/agents/schedulers, processes, session tmp, memory index, config changed, memories.
3. **Machine-checked vs untested:** one line each — what the gates covered; what only a human can confirm (a UI flow, a prod path, a credentialed call).
4. **Committed user edits** (5b pre-existing paths) and **left untracked** (Step 2), if any.
5. **Environment changes** (Step 4), with "repeat on laptop/VPS" where it applies.
6. **Offered, not done** — suggestions never answered, things noticed in passing. Not open items; never applied. Plus the "recalled" note if 0a fell back.
7. **The verdict — the literal last line(s); nothing after it:**
   - **Session is clean.** — every row ok.
   - **Session has open items:** — a numbered list, one blocker per line.
     - **Acceptable blockers:** deferred by the user; needs live credentials/production; a decision only the user can make and you asked; push rejected / declined / auth failure (committed locally); a gate failing on this session's changes (committed, not pushed); staged secrets awaiting a decision; `ff-only` refused; unpushed commits on a deploying branch awaiting a yes.
     - **Not acceptable:** "didn't have time to verify", or any row you didn't run.

## Boundaries

- Never force-push. No `reset --hard` / `clean -f` unless the user explicitly asks; `reset --soft` for folding commits is fine.
- Never skip hooks with `--no-verify`.
- Never merge-commit onto the default branch — `--ff-only`, or stop and ask.
- Never delete a branch, worktree or stash you didn't create this session without asking.
- Global config (`~/.claude/settings.json`, global `CLAUDE.md`, hooks) changes only on the user's yes — a request made this session counts. Never print `settings.json` whole (it can hold tokens): `jq 'del(.env)' ~/.claude/settings.json`.
- Never hardcode a default branch — derive it per repo.
- A failing step is surfaced, never silently swallowed.
