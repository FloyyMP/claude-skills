---
name: sync-skills
version: 1.0.1
description: Pull, push, and reinstall every skill from FloyyMP/claude-skills. Manual-only — run when the user invokes /sync-skills.
disable-model-invocation: true
---

# sync-skills

Works from any directory. First find this machine's clone of `FloyyMP/claude-skills` (a repo whose `git remote get-url origin` contains `FloyyMP/claude-skills`), checking in order:

1. The current repo.
2. Known clone paths, relative to the home directory:
   - `projects/claude-skills` (Ubuntu VPS)
   - `Documents/Floyy/Projects/Others/claude-skills` (main desktop PC)
   - `Documents/Projects/claude-skills`, `Documents/Projects/Others/claude-skills` (Windows RDP)
3. Any `claude-skills` folder up to 6 levels under the home directory.

None found → stop and ask for the path.

Then run in order against that clone (`git -C <clone>`); stop and report on the first failure:

1. `git pull --rebase`
2. If there are uncommitted changes, stop and ask: they must be committed (with `version:` bumped) first.
3. `git push`
4. `npx skills add FloyyMP/claude-skills --agent claude-code -g -y --skill '*'`

Report: clone path, commits pushed, skills installed.
