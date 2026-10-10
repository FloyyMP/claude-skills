---
name: find-tooling
version: 1.0.2
description: Find and install the best plugins, MCP servers, skills and CLI tools for the current project or task. Use when starting work on a project, when a task would benefit from tooling not yet installed, or when asked to find plugins/skills/tools. Installs directly; for a rated recommendations report without installing, use automation-advisor.
---

# find-tooling

Steps 2, 5 and 7 are Claude Code only. Under Codex use only steps 3 and 4, with `--agent codex`.

Skill dir (default): `C:\Users\Alfie\.claude\skills\find-tooling\`. On other machines it is `~/.claude/skills/find-tooling/`.

## 1. Identify needs

Read the project's manifests (package.json, pyproject.toml / requirements.txt, go.mod, Cargo.toml, etc.) and the task. List 1-4 distinct needs, each as stack + job (for example "Next.js + Prisma database migrations"). Drop needs already covered by installed plugins, skills or MCP servers in your context.

## 2. Plugins

Per need, ONE call with 3-5 terms: the stack, the task, a specific tool name, a synonym.

```
python -I "<skill dir>/scripts/search.py" nextjs prisma postgres database migration
```

- Run the calls for different needs in parallel.
- It searches every locally cached marketplace and prints one ranked line per plugin. Never Read marketplace.json files (up to 1.5 MB each).
- Terms match word prefixes (`next` hits `nextjs`); 1-2 character terms match whole words only. Use specific terms: `cli` also hits `client`.
- Line format: `3+2/5 name@marketplace  [INSTALLED] [reviewed:anthropic] [12.3k installs] [~850 tok always-on] [S5 A2 C0 H1 M1]  +2 copies — description`
  - `3+2/5`: 3 of 5 terms hit the plugin's name/keywords/description, 2 more only via inner skills/agents/commands (typical of giant bundles). Without `+`, all hits are direct.
  - `~` marks an estimate; no `~` means the official catalog's exact value. S/A/C/H/M = skills, agents, commands, hooks, MCP servers.
  - `+2 copies`: same plugin name in lower-priority marketplaces. The shown entry is the original-author or highest-priority one.
- `--top N` changes the default 15 lines. The last line reports catalog age; if it says to update, run `claude plugin marketplace update`, then search again.
- MCP servers usually ship inside plugins (M > 0). Search the service name.

## 3. Skills

Per need, in parallel: `npx -y skills find <2-3 terms>`. Non-interactive; results ranked by installs, format `owner/repo@skill`. Install:

```
npx skills add <owner/repo> --skill <skill> --agent claude-code -g -y
```

## 4. CLI tools

Only tools Claude itself will run. Try `winget search <name>` first; otherwise `npm i -g`, `uv tool install`, `go install` or `cargo install`.

## 5. Choosing and installing

Prefer, in order: full coverage of the need, the original author over aggregator copies, reviewed or high-install entries, low always-on tokens. Cap at about 3 plugins and 3 skills per project unless clearly needed. Hooks are fine.

- Stack- or project-specific plugin: `claude plugin install <name>@<marketplace> --scope project`
- General-purpose plugin: `claude plugin install <name>@<marketplace>` (user scope)

## 6. Report

Install without asking. Then tell Floyy what was added, one line each (name, why), and ask them to run `/reload-plugins` (Claude cannot run slash commands).

## 7. Setup on a new machine

Run `claude plugin marketplace list`. For each repo below that is missing, run `claude plugin marketplace add <repo>`:

- anthropics/claude-plugins-community
- jeremylongshore/tons-of-skills-marketplace
- anthropics/skills
- sickn33/agentic-awesome-skills
- alirezarezvani/claude-skills
- davepoon/buildwithclaude
- trailofbits/skills
- VoltAgent/awesome-claude-code-subagents
- obra/superpowers-marketplace
- ccplugins/awesome-claude-code-plugins
- TheBushidoCollective/han
- fcakyon/claude-codex-settings

Usually already present: anthropics/claude-plugins-official, Leonxlnx/taste-skill, wshobson/agents, parallel-web/parallel-agent-skills, rehan-remade/universal-modder, affaan-m/everything-claude-code, and DietrichGebert/ponytail (add as git: `claude plugin marketplace add https://github.com/DietrichGebert/ponytail.git`).
