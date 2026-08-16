# Edge Cases — unusual repo states at close-out

Read this only when Step 5's reads detect one of the states below. Each has a specific safe path; none should be improvised.

## Unborn HEAD (fresh `git init`, no commits yet)

`git log`, `@{u}`, and the default-branch derivation all error — that's expected, not a failure. Skip those reads, stage your paths (5b–5c), and make the first commit (5d). There's nothing to push unless a remote + upstream already exist.

## Detached HEAD

If `git symbolic-ref -q HEAD` shows no branch, a commit here gets orphaned on push. Create a branch (`git switch -c <name>`) or surface to the user.

## In-progress merge / rebase

If `git status` shows an unfinished merge/rebase (or `git rev-parse --git-path MERGE_HEAD` / `rebase-merge` / `rebase-apply` resolves to an existing path), the repo is mid-operation. **Do not auto-commit** — that bakes a half-resolved state. Surface it, summarise the conflict, hand back. This is a "Session has open items" outcome.

## Submodules

If `.gitmodules` exists and this session changed files inside a submodule: commit + push the **submodule** first (run it through 5a–5f), *then* the parent commit bumps the submodule pointer. A parent commit alone leaves the submodule at its old SHA — the change won't reach a fresh clone.
