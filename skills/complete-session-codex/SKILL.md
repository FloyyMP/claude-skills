---
name: complete-session-codex
description: Close out a Codex work session by verifying changed files, resolving unfinished work, committing and pushing touched repositories, and proving the workspace is clean. Use when the user asks to complete, wrap up, or close out the session; do not use for a single task's normal finish.
license: MIT
metadata:
  short-description: Close out a Codex session safely
---

# Complete Session (Codex)

Finish the session so the user can close the window without losing work. Inspect the live workspace and conversation, resolve requested unfinished work, land every touched repository, and report machine-backed proof of the final state.

Run the workflow in order. Never claim clean without running the command that proves it. If a step does not apply, record the evidence and why.

## 1. Establish scope and live state

Use the current conversation and workspace to identify every repository edited this session. For each repository, run `git status --short`, `git diff --stat`, and `git log --oneline -5`. Include repositories changed by shell commands even when no file edit was made. Record pre-existing dirty paths before staging anything.

Check live work before committing:

- use `collaboration.list_agents` and stop or finish session-created agents before landing their edits;
- inspect any background command output and wait for a task that is about to finish;
- identify session-created servers, watchers, or other processes and stop only throwaway development processes;
- inspect worktrees and schedulers when the session used them.

Do not commit while another live task can still mutate a touched repository.

Evidence line: `repos: N · edited paths: N · agents: N · background tasks: N · worktrees: N`.

## 2. Resolve unfinished work

Make a punch list from the conversation, current todos, errors, and changed files. Verify edited source with the repository's documented gate. If no project gate exists, run the strongest proportionate offline check. The bundled `scripts/run-gates.ps1` can run bounded Python, Go, and Node checks:

```powershell
pwsh -NoProfile -File <skill-dir>\scripts\run-gates.ps1 -Repo <repo> -TimeoutSec 300
```

A failing gate blocks pushing that repository unless it is demonstrated to be pre-existing. Do not install toolchains or hide failures just to make a gate runnable. Resolve requested follow-ups; list user-deferred or genuinely blocked items as open.

Evidence line: `open todos: N · unverified paths: N · unresolved errors: N`.

## 3. Remove session cruft

Inspect untracked files in each touched repository. Delete only throwaway files created by this session (temporary scripts, captured output, backups). Preserve uncertain or user-owned files and report them. Do not use `git clean`.

Evidence line: `untracked paths: N · throwaway paths removed: N`.

## 4. Review project instructions

Read the touched repository's `AGENTS.md`, `CLAUDE.md`, or equivalent before committing. Follow its branch, test, and commit rules. Add a one-line durable gotcha only when the session exposed a non-obvious failure that will matter later; do not manufacture documentation changes.

## 5. Commit and push every touched repository

The user's standing project rule is to commit and push directly to the current branch. Do not create branches. Repository instructions override this when they explicitly require another branch or prohibit pushing.

For each repository:

1. Re-check status after fixes.
2. Stage only paths changed by this session. Never use `git add -A` when pre-existing dirty paths exist.
3. Inspect the staged diff and scan added lines for likely secrets. Never commit credentials, `.env` files, or private keys.
4. Commit using the repository's existing message style.
5. Push the current branch. Never force-push. If push is rejected, stop and report the exact reason; keep the local commit.
6. Check stashes, worktrees, and session-created unmerged branches. Remove only resources created by this session and already merged.

Derive the default branch when a repository instruction requires landing there; never assume `main`. Read [references/edge-cases.md](references/edge-cases.md) if the repository is unborn, detached, mid-merge/rebase, a linked worktree, or contains submodules. Do not auto-commit an in-progress merge or rebase.

If the user invoked this skill implicitly (for example, “that’s it”), ask once before the first push. Explicit requests such as “complete session” authorize the push.

## 6. Prove the final state

Run the bundled read-only checker for every touched repository:

```powershell
pwsh -NoProfile -File <skill-dir>\scripts\prove-clean.ps1 -Repo <repo1>,<repo2>
```

Also verify active agents/background tasks, processes started this session, and any requested output files. Run `git status --porcelain` again. Report a table whose rows include the actual command and result:

- working tree clean;
- no unpushed commits (or no remote);
- no operation in progress;
- current branch is allowed by repository instructions;
- no session-created stashes, worktrees, or unmerged branches;
- verification gate result;
- agents, background tasks, and processes stopped or none;
- documentation and user-requested artifacts present.

Separate machine-checked results from behavior that still needs a human (for example, a UI flow or credentialed production call). End with the literal verdict `Session is clean.` only when every required row passes. Otherwise end with `Session has open items:` followed by one numbered blocker per line.

## Boundaries

Never run `git reset --hard`, `git push --force`, or `git clean -f`. Never delete a branch, worktree, or stash you did not create this session without the user's instruction. Never skip hooks with `--no-verify`. Do not invoke this skill recursively.
