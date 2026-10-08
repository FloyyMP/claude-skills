---
description: Pull, push, and reinstall every skill from FloyyMP/claude-skills
---

Run in order from this repo; stop and report on the first failure:

1. `git pull --rebase`
2. If there are uncommitted changes, stop and ask: they must be committed (with `version:` bumped) first.
3. `git push`
4. `npx skills add FloyyMP/claude-skills --agent claude-code -g -y --skill '*'`

Report: commits pushed, skills installed.
