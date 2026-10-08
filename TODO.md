# TODO

Temporary list from the 2026-10-08 session. Delete this file once every item is done.

- [ ] **README:** add an `audit-setup` row to the skill table (only `complete-session` is listed).
- [ ] **session-facts.py Windows crash:** `skills/complete-session/scripts/session-facts.py:201` and `:208` pass `HOME` (`C:\Users\...`) as the `re.sub` replacement, which raises `re.PatternError: bad escape \U`. Fix: `lambda _: HOME`. Check for other `re.sub` calls with path replacements.
- [ ] **session-facts.ps1 wrong branch:** it reported `(detached/unborn)` for `claude-skills` while `git symbolic-ref --short HEAD` returned `master`. The suspect is `$LASTEXITCODE` at `skills/complete-session/scripts/session-facts.ps1:226` after the `| Select-Object -First 1` pipeline (unverified). Reproduce first, then fix.
- [ ] **memory-index-check.py inline links:** it only counts the first `.md` link per `MEMORY.md` line (`skills/complete-session/scripts/memory-index-check.py:71`), so files linked mid-line show as "not in index" (e.g. `debian-sshd-hardening-conf.md`, `nordvpn-killswitch-new-exe.md`). Decide whether to count every link or keep the one-entry-per-line rule and restructure `MEMORY.md`.
- [ ] **memory-index-check.py archive:** it reports 35 files under `memory\unused\` as unindexed. Consider skipping an archive folder.
- [ ] **Smoke-test `audit-setup`:** installed from the repo but never run.
- [ ] After script fixes: push, reinstall (`npx skills add FloyyMP/claude-skills --agent claude-code -g -y --skill '*'`), rerun `/complete-session` to confirm.
