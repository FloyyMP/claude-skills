# claude-skills

Public agent skills repo: `FloyyMP/claude-skills` (renamed from `FloyyMP/skills` on 2026-10-08; GitHub redirects the old URL). Published via skills.sh.

## Layout
- `skills/<name>/SKILL.md` — one folder per skill (skills.sh / `npx skills` standard), plus optional `references/` and `scripts/`.
- Scripts ship in pairs: `.ps1` for Windows, `.sh`/`.py` for Linux.
- Line endings are LF (`.gitattributes`).

## Workflow
This repo is the source of truth. `~\.claude\skills\<name>\` holds installed copies (not symlinks), so never edit those directly.

1. Edit the skill here.
2. Commit and push to `master`.
3. Reinstall: `npx skills add FloyyMP/claude-skills --agent claude-code -g -y --skill '*'`
4. When adding a skill, add a row to the README table and the name to the GitHub repo description.

## skills.sh listing
- There's no submit step and no crawler. A repo or skill appears on skills.sh only after it's been installed through `npx skills add` (install telemetry). Step 3 above is what lists a new skill.
- Check the listing: `https://www.skills.sh/FloyyMP/claude-skills/<name>`. If the page says "isn't available in this repository", the skill hasn't been installed via the CLI yet.
- `npx skills add FloyyMP/claude-skills -l` lists the skills the CLI detects in the repo without installing them.
- The old `skills.sh/FloyyMP/skills` page is stale but still up.
