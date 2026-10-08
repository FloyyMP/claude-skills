# claude-skills

Public agent skills repo: `FloyyMP/claude-skills`. Published via skills.sh.

## Layout
- `<name>/SKILL.md` — one folder per skill at repo root, plus optional `references/` and `scripts/`.
- Scripts ship in pairs: `.ps1` for Windows, `.sh`/`.py` for Linux.
- Line endings are LF (`.gitattributes`).

## Workflow
`~\.claude\skills\` IS this repo (git-tracked directly). Edit skills in place, commit, push to `main`.

1. Edit the skill here (`~\.claude\skills\<name>\SKILL.md`).
2. `git add`, `git commit`, `git push`.
3. To install on a fresh machine: `npx skills add FloyyMP/claude-skills --agent claude-code -g -y`
4. When adding a skill, add a row to the README table and update the GitHub repo description.

## skills.sh listing
- A skill appears on skills.sh only after it's been installed through `npx skills add` (install telemetry).
- Check listing: `https://www.skills.sh/FloyyMP/claude-skills/<name>`.
- `npx skills add FloyyMP/claude-skills -l` lists skills the CLI detects without installing.
