# claude-skills

Agent skills by FloyyMP. Install with [skills.sh](https://skills.sh):

```powershell
npx skills add FloyyMP/claude-skills --agent claude-code -g -y
```

| Skill | What it does |
|---|---|
| [claude-automation-recommender](claude-automation-recommender) | Analyses a codebase and recommends Claude Code automations — hooks, subagents, skills, plugins, MCP servers. |
| [audit-setup](audit-setup) | Fully analyses a Claude Code setup — plugins, skills, MCP servers, subagents, slash commands, hooks, settings, CLAUDE.md and permissions. |
| [complete-session](complete-session) | Closes out a Claude Code session so the window can be shut with nothing lost — verifies edited files, lands and pushes every touched repo, updates CLAUDE.md and memory, then proves the state is clean. |
| [exe-api-extractor](exe-api-extractor) | Analyses Windows PE executables (.exe, .dll) to extract backend API info: endpoints, credentials, auth tokens, headers, TLS fingerprints, internal function names. |
| [isolate-core](isolate-core) | Strips a project to its core source and zips it. Manual-only — invoke explicitly with /isolate-core. |
| [r6-appid-perf](r6-appid-perf) | Extracts and ranks AppID performance from run_summary.log files; supports time-based and count-based filters. |
| [xml-prompt](xml-prompt) | Turns a plain-English request into a tight, well-structured XML prompt optimised for LLM output. |
