# claude-skills

Public agent skills repo: `FloyyMP/claude-skills`, published via skills.sh. **The only home for every custom skill Floyy creates**, on every machine and VPS. One branch: `main`. The same skills install for Claude Code and Codex.

## Layout
- `skills/<name>/SKILL.md` — one folder per skill (skills.sh / `npx skills` standard), plus optional `references/` and `scripts/`.
- Scripts ship in pairs where it matters: `.ps1` for Windows, `.sh`/`.py` for Linux. The `.sh`/`.py` is the source of truth; any change to it updates the `.ps1` twin in the same commit.
- Line endings are LF (`.gitattributes`).
- Project-specific skills stay in their own project repo; everything general-purpose lives here.

## Versioning
Each `SKILL.md` carries a `version:` field (semver). Bump it on every edit: patch for fixes/wording, minor for new behaviour, major for breaking changes.

## Workflow (same on every machine)
Each machine has one clone of this repo. `~/.agents/skills/<name>/` (Codex) and `~/.claude/skills/<name>/` (Claude Code) hold **installed copies** made by `npx skills add`, so they are never git repos and never edited by hand.

1. `git pull` first. Skills are edited from several machines; skipping the pull is how history diverged on 2026-10-08.
2. Edit the skill here. A new skill starts here too, never directly in an installed-copies folder.
3. Commit and push to `main` straight away.
4. Reinstall: `npx skills add FloyyMP/claude-skills --agent codex -g -y --skill '*'` (and `--agent claude-code` for Claude Code).
5. When adding a skill, add a row to the README table and the name to the GitHub repo description: `gh repo edit FloyyMP/claude-skills --description "Floyy's Claude Code skills: <comma-separated names>"`.
6. When removing a skill, also remove its installed copies: `npx skills remove <name> -g -y` (cleans every agent's copy).

## skills.sh listing
- There's no submit step and no crawler. A skill appears on skills.sh only after it's been installed through `npx skills add` (install telemetry). Step 4 above is what lists a new skill.
- Check the listing: `https://www.skills.sh/FloyyMP/claude-skills/<name>`. "isn't available in this repository" means it hasn't been installed via the CLI yet.
- `npx skills add FloyyMP/claude-skills -l` lists the skills the CLI detects without installing them.
