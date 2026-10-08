# Audit checks

Run every check against what Step 1 collected. Each hit becomes a finding with a file path.

## Cross-cutting
- **Duplicates / overlap** — skills, commands or agents that do the same job; same MCP server in several scopes; a plugin shipping something also installed standalone.
- **Context bloat** — every skill/agent description and every MCP tool definition loads each session; flag large totals.
- **Unused / stale** — empty folders, leftover experiments, things nothing references.
- **Gaps** — only if clearly useful (no deny rules for secrets, no CLAUDE.md in an active project).

## CLAUDE.md
- Very long files (hundreds of lines) — loaded every session; suggest trimming or moving detail to skills/references.
- Contradictions between user, project and nested CLAUDE.md files.
- `@path` imports pointing at missing files; instructions referencing scripts, paths or commands that no longer exist.
- Secrets or tokens pasted inline.

## Settings & permissions
- Invalid JSON in any settings file.
- `defaultMode: "bypassPermissions"` set as a standing default.
- Over-broad allow rules: bare `Bash`, `Bash(*)`, `Bash(rm:*)`, `Bash(curl:*)`, `Bash(sudo:*)`, unscoped `WebFetch`, `Write`/`Edit` without a path.
- Allow and deny rules that overlap (deny wins, so the allow is dead or misleading).
- No deny rules for secret files (`Read(./.env)`, `Read(./.env.*)`, `Read(./secrets/**)`, key files).
- `additionalDirectories` covering `~`, `/` or other broad roots.
- Tokens/API keys in `env` — report key name and file only.
- `.claude/settings.local.json` tracked in git (it's meant to be personal and gitignored).

## Skills
- Missing or malformed frontmatter; `name` not matching its folder.
- Vague descriptions with no "use when …" trigger — won't fire reliably; or so broad they fire on unrelated requests.
- Very long descriptions (context cost every session).
- Same skill name in user and project scope (shadowing, unclear which runs).
- `scripts/` or `references/` files mentioned in SKILL.md that don't exist.
- Destructive or side-effecting skills without `disable-model-invocation: true`.

## Subagents
- Missing `description`, or one too vague for automatic delegation.
- `tools` omitted — agent inherits every tool; flag when its job is read-only.
- Agents overlapping each other or a skill.

## Slash commands
- Same name in user and project scope, or same name as a skill.
- Commands that duplicate a skill's job.
- `allowed-tools` broader than the command needs.

## Hooks
- `command` pointing at a missing or non-executable script; relative paths instead of `$CLAUDE_PROJECT_DIR`.
- Slow commands without an explicit `timeout`.
- Heavy `PreToolUse`/`PostToolUse` hooks with a catch-all matcher — run on every tool call.
- `Stop`/`SubagentStop` hooks that block without checking `stop_hook_active` — can loop forever.
- Commands that download and execute remote code (`curl … | sh`), or that nobody has reviewed.

## MCP servers
- `command` binary not on PATH; servers failing or disconnected in `claude mcp list`.
- Secrets written inline in `.mcp.json` (often committed) instead of `${VAR}` expansion.
- Unpinned `npx -y pkg` / `@latest` from unknown publishers.
- Same server defined in more than one scope.
- Many servers enabled at once — tool definitions crowd the context.

## Plugins
- `enabledPlugins` entries that aren't installed; installed plugins left disabled.
- Marketplaces from unknown sources.
- Plugin skills/MCP/hooks duplicating standalone ones.
