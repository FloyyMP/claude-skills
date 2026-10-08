---
name: audit-setup
description: Fully analyse a Claude Code setup — plugins, skills, MCP servers, subagents, slash commands, hooks, settings, CLAUDE.md, permissions. Use when the user asks to audit, review, analyse or clean up their Claude Code setup/config.
---

# Audit Setup

Read-only audit of a Claude Code setup. Never modify anything unless the user asks afterwards.

## 1. Collect (user + project scope)

Check both `~/.claude/` and the project's `.claude/` (plus `.mcp.json`, `CLAUDE.md`). Use PowerShell on Windows, bash elsewhere.

| Area | Where to look |
|---|---|
| CLAUDE.md | `~/.claude/CLAUDE.md`, `./CLAUDE.md`, `./.claude/CLAUDE.md`, any nested ones |
| Settings | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json` |
| Skills | `~/.claude/skills/*/SKILL.md`, `.claude/skills/*/SKILL.md` |
| Subagents | `~/.claude/agents/*.md`, `.claude/agents/*.md` |
| Slash commands | `~/.claude/commands/**`, `.claude/commands/**` |
| Plugins | `~/.claude/plugins/` (installed list, marketplaces) + `enabledPlugins` in settings |
| MCP servers | `.mcp.json`, `~/.claude.json` (user + per-project `mcpServers`), plugin-provided ones; `claude mcp list` if available |
| Hooks | `hooks` in all settings files + plugin hooks |
| Permissions | `permissions` (allow/deny/ask), `defaultMode`, `additionalDirectories` in settings |
| Other | `env`, `model`, `statusLine`, `outputStyle` in settings |

For each skill/agent/command, read the frontmatter (name, description, tools, model). Skip unreadable files and say so.

## 2. Analyse

Check for:

- **Duplicates / overlap** — skills, commands or agents that do the same thing; same MCP server in several scopes.
- **Conflicts** — contradictions between CLAUDE.md files, or between allow and deny rules.
- **Weak descriptions** — vague skill/agent descriptions that won't trigger reliably, or are so broad they trigger constantly.
- **Context bloat** — huge CLAUDE.md, many MCP servers (each adds tool definitions), long skill descriptions.
- **Broken things** — MCP commands that don't exist, hooks pointing at missing scripts, enabled plugins that aren't installed, invalid JSON, skills missing frontmatter.
- **Security** — secrets/tokens in settings or `.mcp.json`, over-broad permissions (`Bash(*)`, bypass mode, wide `additionalDirectories`), hooks running unreviewed commands, untrusted MCP servers.
- **Unused / stale** — disabled-but-installed plugins, empty folders, leftover experiments.
- **Gaps** — only if clearly useful (e.g. no deny rules for `.env`, no CLAUDE.md in an active project).

## 3. Report

Keep it short and scannable:

1. **Inventory** — one line of counts per area (e.g. `Skills 12 · Agents 3 · MCP 5 · Plugins 4 · Hooks 2`).
2. **Findings** — grouped by 🔴 fix now / 🟡 worth fixing / 🟢 fine. One line each: what, where (file path), why it matters, suggested fix.
3. **Top 3 actions** — the highest-impact fixes.

Rules:
- Cite file paths for every finding.
- No padding; skip empty sections.
- Never print secret values — show only the key name and file.
- Offer to apply fixes, but wait for a yes.
