---
name: complete-session-codex
version: 1.1.0
description: Close out a Codex work session by verifying changed files, resolving unfinished work, committing and pushing touched repositories, and proving the workspace is clean. Use when the user asks to complete, wrap up, or close out the session; do not use for a single task's normal finish.
license: MIT
metadata:
  short-description: Close out a Codex session safely
---

# Complete Session (Codex)

Kept in sync with complete-session 2.0.0.

Finish the session so the user can close the window without losing work: nothing pending, everything landed, pushed and documented, with machine-backed proof. Run the steps in order. If a step does not apply, record the evidence and why.

## Rules for every step

**Evidence first.** Each step prints its evidence line (source + counts), then its verdict. "None" / "clean" only after an evidence line showing zero. Never claim clean without the command that proves it.

**Act, don't ask.** Working-tree items get the sensible default without a question (Steps 3, 6b). Pause only for an action that is destructive and irreversible with no clear intent signal.

**Ordering:** every repo-bound write (Steps 2, 4, 5) happens before Step 6 so it rides one commit per repo. Memory and global config are never committed.

**Trigger:** explicit requests ("complete session", "wrap up", "close out") authorize commit + push. Anything implicit ("that's it") gets one combined confirmation before the first push.

**Precedence:** branch, push and deploy rules in the repo's `AGENTS.md` / `CLAUDE.md` or the global `~/AGENTS.md` override 6a/6e — follow them and say so. Their **documented post-change steps** are part of landing (e.g. claude-skills: version bump, README row, repo description, reinstall, `npx skills remove` for deleted skills) — do them. Never widen scope.

**Scripts.** `<C>` = `~/.agents/skills/complete-session-codex/scripts` (Windows `C:\Users\<user>\.agents\skills\complete-session-codex\scripts`); `<S>` = `~/.agents/skills/complete-session/scripts` (the `.sh` / `.py` twins and `memory-index-check`). Windows: call the `.ps1` directly from PowerShell — `& '<C>\x.ps1' -Repo a,b` — never through `pwsh -File` / `-Command` (passes `a,b` as one string, loses exit codes). Linux/macOS: `bash <S>/x.sh`, `python3 <S>/x.py` (`python` on Windows). Read each script's verdict line, not just `$?`.

## 1. Establish scope and live state

**Record the session start** now as unix seconds: the timestamp of the first command run this session, or the rollout file name (`~/.codex/sessions/YYYY/MM/DD/rollout-<start>-<id>.jsonl`) when you know it is this session's; fallback `git -C <repo> reflog -1 --date=unix` taken before any close-out change. Step 8 needs it.

From the conversation and workspace, list every repository changed this session — including ones changed only by shell commands. Per repo: `git status --short`, `git diff --stat`, `git log --oneline -5`. Dirty paths the session didn't touch are the user's pre-existing edits (6b). Note changes outside any repo (Step 5).

Live work, before committing anything:
- `collaboration.list_agents` — stop or finish session-created agents first;
- background command output — wait for a task about to finish;
- session-created servers / watchers: Windows `Get-Process | ? StartTime -gt ([datetime]'<start>')`, `Get-NetTCPConnection -State Listen`; Linux `ps -o pid,etimes,args`, `ss -ltnp`. Stop only throwaway dev processes; note live dev servers per repo;
- worktrees and schedulers the session used.

Do not commit while a live task can still mutate a touched repository.

Evidence line: `start: <unix> · repos: N · edited paths: N · outside-repo changes: N · agents: N · background tasks: N · worktrees: N`.

## 2. Resolve unfinished work

Punch list from the conversation, todos, errors and changed files. Per item:
- **Asked for and still undone / unresolved error** — finish it if it fits in a few minutes; bigger → open item.
- **Edited source** — run the repo's documented gate; else the bundled runner:
  ```
  & '<C>\run-gates.ps1' -Repo <repo> -TimeoutSec 300 [-TotalTimeoutSec 540] [-NoBuild]
  bash <S>/run-gates.sh --repo <repo> [--timeout 300] [--total-timeout 540] [--no-build]
  ```
  Exit 0 pass · 1 fail · 2 timed out / unverified · 3 not runnable (then run the strongest offline check and report it as that). Size it to the change; pass `-NoBuild` when that repo's dev server is live (`next build` clobbers `next dev`). Bounded, self-terminating smoke runs are fine; never start long-lived processes or install toolchains to make a gate runnable. A gitignored build product (`dist/`, `*.exe`) whose source changed → rebuild and smoke-test.
- **A failing gate blocks the push** for that repo (commit locally, open item) unless it already fails on `HEAD` without your changes — prove it on a clean export (`git archive HEAD`), then report it as pre-existing.
- **Not done** (above the verdict, never blocking, never applied): deferred by the user in any wording; suggested by you with no reply; needs live credentials or production; a decision only the user can make.

Evidence line: `open todos: N · unverified paths: N · unresolved errors: N`.

## 3. Remove session cruft

Untracked files per touched repo, no questions: delete throwaway files this session created (temp scripts, captured output, `.bak`); add credential/output files that clearly shouldn't be tracked to `.gitignore`; leave untracked files of unclear origin untracked and list them in Step 8. Never `git clean`.

Evidence line: `untracked paths: N · removed: N · gitignored: N · left untracked: N`.

## 4. Project instructions and config

Read each touched repo's `AGENTS.md` / `CLAUDE.md` before committing and follow its branch, test and commit rules.

Add a gotcha only if it passes all four: **durable** (matters in a future session), **non-obvious** (not derivable from code, layout or git), **actionable** ("without this, a future session will ___" — can't finish the sentence, cut it), **not covered** in any tier (repo, parent, global). Default skew is omit; most sessions add nothing. Repo gotchas go in the repo's file and ride Step 6's commit. A global rule goes in `~/AGENTS.md` only when the user asked for it this session — that request is the yes; show the diff. When a rule lands in instructions, archive any memory duplicating it (Step 7). Config past ~150 lines or contradicting itself → reconcile; verify against live state before deleting, when unsure scope it.

## 5. Outside-repo changes

- **Installed skill edited** (`~/.agents/skills/<name>/` or `~/.claude/skills/<name>/`) — the next `npx skills add` overwrites it: port the edit to the source clone (claude-skills) so it lands in Step 6 with its post-change steps.
- **Global instructions edited** — update the mirror (`~/AGENTS.md` ↔ `~/.claude/CLAUDE.md`, per memory).
- **Installs, plugins, MCP servers, skills, schedules, registry, env vars, GitHub settings** — list under "Environment changes" in Step 8; say when they must be repeated on the user's other machines (laptop, VPS).

Evidence line: `outside-repo edits: N · environment changes: N`.

## 6. Commit and push every touched repository

Per repo, re-check `git status --short`. **Idempotency gate:** clean, nothing unpushed, no leftovers → "nothing to land"; never an empty commit. Unborn, detached, mid-merge/rebase, linked worktree or submodules → read [references/edge-cases.md](references/edge-cases.md) and follow it.

**Default branch, fail-closed:** `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`); else `origin/main` / `origin/master` if present; no remote → `init.defaultBranch`, else `main`/`master`. Unknown → say so; never assume the current branch.

**6a Branch.** Unless Precedence applies: commit on the default branch; never create a branch. On a branch this session created → commit, then `git switch <default>; git merge --ff-only <branch>`, push, delete the branch (and its remote copy if pushed). A branch that predates the session → commit and push it; landing or deleting it needs the user's yes. State the decision in one line.

**6b Stage** by explicit path, never `git add -A` / `.`: paths this session changed; the user's pre-existing tracked edits and deletions (commit them together and list them in Step 8) — only in a repo the session itself changed; a repo whose sole dirt is the user's WIP gets nothing staged; session-created untracked files that belong in the repo. Skip unintended mode-only changes.

**6c Secrets scan** — its own command; read it before committing:
```powershell
$a = git -C <repo> diff --cached -U0 -- ':/' ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*.sum' | ? { $_ -like '+*' -and $_ -notlike '+++ *' }
$block = 'BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|bearer [a-z0-9._-]{20,}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_\w{20,}|sk-(proj|ant)-[A-Za-z0-9_-]{20,}|[sr]k_live_[A-Za-z0-9]{16,}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.eyJ|://[^/:@ ]+:[^@ ]+@|(api_?key|secret|token|password|passwd|private_?key)[a-z_]*["'']?\s*[:=]\s*["''][^"'' ]{8,}["'']'
'== BLOCK'; $a | Select-String $block
'== REVIEW'; $a | Select-String 'password|passwd|secret|api_?key|token' | select -First 20
git -C <repo> diff --cached --name-only | Select-String '(^|/)\.env(\.local|\.prod[a-z]*|\.dev[a-z]*|\.staging)?$|(^|[/_.-])(cred|creds|secret|secrets|token|tokens|key|keys)([_.-]|$)'
```
Linux: same patterns with `grep -inE`. **BLOCK hit or staged `.env` (not `.env.example`), with a remote:** a file that clearly shouldn't be tracked → unstage + gitignore it; a secret in source → stop, list `file:line`, ask. No remote → note and proceed (local tools may hardcode secrets). REVIEW and filename hits are reported, never blocking.

**6d Commit** in the repo's message style, one commit per repo. Hook failure → exact error, fix if obvious.

**6e Push** the default branch (`-u origin <default>` if no upstream). Rejected → report, keep the local commit, offer pull/rebase-then-push. Auth/network → exact error, committed-but-unpushed. No remote → landed locally (unless a global rule requires a remote — edge-cases). Then run the repo's documented post-change steps.

**6f Prior unpushed commits** not made this session: if the branch deploys (instructions or memory call it production / auto-deploy, or `railway.json`, `railway.toml`, `vercel.json`, `netlify.toml`, `fly.toml`, or a GitHub workflow on push to it exists) → list them and ask before pushing. Otherwise secrets-scan the range (`git log -p '@{u}..'` through the BLOCK pattern) and push.

**6g Leftovers:** `git stash list`, `git worktree list`, `git branch --no-merged <default>`. Remove only stashes, worktrees and branches this session created and already merged. Older ones are listed; a worktree that predates the session is a note, not an open item.

## 7. Memory

Codex shares Claude Code's memory store (`C:\Users\Alfie\.claude\memory`, as named in global `~/AGENTS.md`). Run the check first and confirm the dir it prints is that one (else pass `--memory-dir`):
```
python <S>/memory-index-check.py [--memory-dir <dir>]
```
Save only durable, non-obvious facts not already in memory, the repo, git history, or global `~/AGENTS.md` / `~/.claude/CLAUDE.md` (covered there → don't save; archive any memory copy). Fails: "fixed X this session", a rule already global, a one-off answer to a close-out question (never save "don't ask again" from one), a path derivable from the repo. Default skew is omit.

Format: one fact per file, update an existing file rather than duplicating, absolute dates, `name` == filename:
```markdown
---
name: <short-kebab-case-slug>
description: <one-line summary used for recall>
metadata:
  type: user | feedback | project | reference
---

<the fact. Feedback/project: add **Why:** and **How to apply:** lines.>
```
Index it with one line in `MEMORY.md` under the right `##` section: `- [Title](file.md) — hook`, one link, ≤ 150 chars. Re-run the check: fix every structural finding (exit 1). Every `warn:` line (index > 150 lines / 20 KB, long or multi-link lines, duplicate descriptions, staleness markers) is a reconcile signal: merge duplicates, shorten index lines, fix or archive stale entries. **Never hard-delete:** move the file to `unused/` and drop its index line. Verify against live state before archiving. Memory is never committed.

Evidence line: `candidates: N — saved: N, updated: N, archived: N, rejected: N`.

## 8. Prove the final state

Read-only checker for every touched repo, with the Step 1 start time:
```
& '<C>\prove-clean.ps1' -Repo <repo1>,<repo2> -Since <start>
SINCE=<start> bash <S>/prove-clean.sh <repo1> <repo2>
```
Rows are `ok`, `OPEN` or `note` (pre-existing worktrees, behind upstream — never blocking); it ends with `checks ok: N, open: M, notes: K` and `ALL CLEAN` / `OPEN ITEMS`. Also verify agents and background tasks are stopped and requested output files exist.

Output, in order:
1. Non-ok rows only, then `N checks OK` and the notes in one line; the full table (command + result per row) only when something is open. Durations like `1m 52s`; Windows paths with backslashes.
2. Machine-checked vs needs a human (a UI flow, a credentialed production call).
3. Committed pre-existing user edits and files left untracked, if any.
4. Environment changes (Step 5).
5. **Not done** — one line each (Step 2).
6. **The verdict, the literal last line(s):**
   - `Session is clean.` — every required row ok.
   - `Session has open items:` — numbered blockers: uncommitted edited files, unpushed commits, a gate failing on this session's changes, an unresolved error the user asked to fix, unpushed commits on a deploying branch awaiting a yes. Pre-existing stashes, branches or worktrees, a project-approved working branch, and "Not done" items are not open items.

## Boundaries

Never force-push. No `git reset --hard` or `git clean -f` unless the user asks. Never skip hooks with `--no-verify`. Never merge-commit onto the default branch — `--ff-only` or stop and ask. Never delete a branch, worktree or stash you did not create this session without the user's instruction. Do not invoke this skill recursively.
