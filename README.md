# claude-skills

Agent skills by FloyyMP. Install with [skills.sh](https://skills.sh):

```bash
npx skills add FloyyMP/claude-skills --agent claude-code -g -y --skill '*'
```

| Skill | What it does |
|---|---|
| [audit-setup](skills/audit-setup) | Fully analyses a Claude Code setup — plugins, skills, MCP servers, subagents, slash commands, hooks, settings, CLAUDE.md and permissions. |
| [automation-advisor](skills/automation-advisor) | Analyses a codebase and recommends Claude Code automations — MCP servers, skills, plugins, hooks, subagents, CLAUDE.md/config — each rated and verified against live sources. |
| [complete-session](skills/complete-session) | Closes out a Claude Code session so the window can be shut with nothing lost — verifies edited files, lands and pushes every touched repo, updates CLAUDE.md and memory, then proves the state is clean. |
| [find-tooling](skills/find-tooling) | Finds the best plugins, skills, MCP servers and CLI tools for the current project or task — searches every cached Claude Code marketplace in one ranked, compact call, then installs the picks. |
| [isolate-core](skills/isolate-core) | Strips a project to its core source and zips it. Manual-only — invoke explicitly with /isolate-core. |
| [sync-skills](skills/sync-skills) | Pulls, pushes and reinstalls every skill from this repo, from any directory. Manual-only — invoke with /sync-skills. |
