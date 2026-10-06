# Edge Cases — unusual repo states at close-out

Read this only when Step 5's reads detect one of the states below. Each has a specific safe path; none should be improvised.

## Unborn HEAD (fresh `git init`, no commits yet)

`git log`, `@{u}`, and the default-branch derivation all error — that's expected, not a failure. Skip those reads, stage your paths (5b–5c), and make the first commit (5d). There's nothing to push unless a remote + upstream already exist.

## Detached HEAD

If `git symbolic-ref -q HEAD` shows no branch, a commit here gets orphaned on push. Create a branch (`git switch -c <name>`) or surface to the user.

## In-progress merge / rebase

If `git status` shows an unfinished merge/rebase (or `git rev-parse --git-path MERGE_HEAD` / `rebase-merge` / `rebase-apply` resolves to an existing path), the repo is mid-operation. **Do not auto-commit** — that bakes a half-resolved state. Surface it, summarise the conflict, hand back. This is a "Session has open items" outcome.

## Harness worktree (`EnterWorktree` / `Agent isolation:worktree`)

If the facts show a worktree was entered, the session did its work in a linked worktree under `<repo>/.claude/worktrees/<name>` on a branch like `worktree-<name>`, not the main working tree. `git worktree list` shows it even though no `git worktree add` ran. Two things follow:

- **Edits look "MISSING NOW"** in the facts because the worktree dir was already removed on `ExitWorktree` — that is expected, not lost work, *provided* the branch was landed. Confirm the commits reached `DEFAULT_BRANCH` (`git log --oneline` on the main tree), don't try to re-verify files at the vanished worktree path.
- **A worktree still present at close** (ExitWorktree never ran) is session-created and yours to resolve: land its branch through 5a–5h, then `git worktree remove <path>`. Step 5h treats it exactly like a `git worktree add` you made.

## Submodules

If `.gitmodules` exists and this session changed files inside a submodule: land + push the **submodule** first (run it through 5a–5h), *then* the parent commit bumps the submodule pointer. A parent commit alone leaves the submodule at its old SHA — the change won't reach a fresh clone.
