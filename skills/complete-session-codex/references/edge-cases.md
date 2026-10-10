# Edge Cases — unusual repo states at close-out (Codex)

Read this only when Step 6's checks detect one of the states below. Each has a specific safe path; none should be improvised.

## Unborn HEAD (fresh `git init`, no commits yet)

`git log` and `@{u}` error — expected, not a failure. Skip those reads, stage your paths (6b–6c), make the first commit (6d). With a remote, push with `git push -u origin <branch>` (6e). With no remote, check Precedence first: a global rule such as "every `git init` is followed by `gh repo create` + push" means create the remote and push now; otherwise there's nothing to push.

## Detached HEAD

`git symbolic-ref -q HEAD` prints nothing: a commit here is orphaned on push. Don't create a branch: stop and surface it to the user.

## In-progress merge / rebase

`git status` shows an unfinished merge/rebase (or `git rev-parse --git-path MERGE_HEAD` / `rebase-merge` / `rebase-apply` exists). **Do not commit** — that bakes in a half-resolved state. Summarise the conflict and hand back. Skip 6f for this repo. This is a "Session has open items" outcome.

## Linked worktree

The session worked in a `git worktree add` checkout, so `git switch <default>` fails (the main tree holds it). Verify `git merge-base --is-ancestor origin/<default> HEAD`, then `git push origin HEAD:<default>`. Tell the user the main tree needs `git pull`. Remove the worktree (`git worktree remove <path>`) only if this session created it, its branch is landed, and you are not running inside it. A worktree that predates the session is listed as a note (prove-clean prints `note`), never removed and never an open item.

## Submodules

`.gitmodules` exists and the session changed files inside a submodule: land and push the **submodule** first (6a–6g), *then* commit the parent's pointer bump. A parent commit alone leaves the submodule at its old SHA on a fresh clone.
