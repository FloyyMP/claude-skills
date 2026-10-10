---
name: automation-advisor
version: 1.1.0
description: Analyze a codebase and produce a rated report of recommended Claude Code automations (MCP servers, skills, plugins, hooks, subagents, CLAUDE.md/config), each verified against live sources; installs nothing until the user picks. Use when the user asks for automation recommendations or a report, asks which Claude Code features/hooks/subagents they should use, or wants to optimize their Claude Code workflow. To find and install plugins/skills/CLI tools directly, use find-tooling instead.
allowed-tools: Read, Glob, Grep, Bash, WebSearch, WebFetch
---

# Claude Automation Advisor

Scan the repo, search real sources, then output a **rated, visual report** of every automation that's genuinely worth adding. Read-only: don't create or change files until the user picks IDs.

## Rules

- **List everything good, not a fixed number.** Include every item scoring **6/10 or higher**. Usually 3–8 per category, max 10. If a category only has 1 good pick, list 1. If none, say so in one line.
- **Verify before recommending.** Every third-party item needs a real URL you found this session. Never invent package names, MCP servers or commands.
- **Tie every pick to this repo.** The "Why" must cite something you actually found (a dependency, a config file, a folder, a pattern).
- **Skip what's already installed.** List those under "Already set up" instead.
- **Commands match the OS.** On Windows give PowerShell. For `npx skills add`, always add `--agent claude-code -g`.

## Phase 1: Scan the project

Gather, quickly (don't read the whole codebase):

- Manifests: `package.json`, `pyproject.toml`, `requirements*.txt`, `Cargo.toml`, `go.mod`, `pom.xml`, `*.csproj`, `Dockerfile`, `docker-compose*`
- Tooling configs: formatter, linter, type checker, test runner, CI (`.github/workflows`), `.env*`, lock files
- Structure: top-level folders, rough file count, languages
- External services: SDK imports and env var names (Stripe, Supabase, AWS, OpenAI, Sentry, etc.)
- Existing Claude setup, project **and** user level:
  - `CLAUDE.md`, `.claude/` (settings, skills, agents), `.mcp.json`
  - `~/.claude/settings.json`, `~/.claude/skills/`, `~/.claude/agents/`
  - `claude mcp list`, installed plugins
- Recent pain: `git log --oneline -30` (repeated fix-ups, reverts, lint/format commits = hook candidates)

## Phase 2: Search sources

Search broadly. For each important library/service found, run targeted searches. If subagents are available, run the category searches in parallel.

| Source | Look for |
|--------|----------|
| Local marketplace catalogs | Plugins and MCP servers across every added marketplace, ranked with installs/review/token cost: `python -I ~/.claude/skills/find-tooling/scripts/search.py <3-5 terms>` (one call per need; never Read marketplace.json) |
| `anthropics/claude-plugins-official` | Official plugins and skills |
| `anthropics/skills` | Official skills |
| Vendor docs / GitHub | Official MCP servers or skills from the library's own maintainers (best trust) |
| Official MCP registry (registry.modelcontextprotocol.io) | MCP servers |
| skills.sh, Smithery, mcpmarket | Community skills and MCPs |
| awesome-claude-code lists, GitHub search | Hooks, subagents, plugins |
| Web search | `"<library> MCP server"`, `"<library> claude code skill"`, `"claude code hook <tool>"` |

For each candidate, note: source URL, official vs community, stars and last update if visible. Drop anything unmaintained for 12+ months unless nothing else exists.

Also consider things to **create** (custom skills, hooks, subagents, CLAUDE.md additions) based on the repo's own workflows. These don't need a URL.

## Phase 3: Rate

Score each item 1–10 using judgment across:

- **Impact**: how much time or pain it saves in *this* repo
- **Fit**: how strong the evidence is that the repo needs it
- **Trust**: official > popular/maintained > small/new
- **Effort**: cheaper setup nudges the score up a little

Effort labels: 🟢 under 5 min · 🟡 under 30 min · 🔴 more
Source labels: ✅ Official · ⭐ Popular community · 🧪 Small/new · 🛠️ Create yourself

Score bar: one `█` per point, `░` for the rest, e.g. `████████░░ 8`

## Phase 4: Output

Use exactly this layout. Give each item an ID (M = MCP, S = Skill, P = Plugin, H = Hook, A = Agent, C = Config). Sort each table by score, highest first.

**Keep tables narrow.** The terminal turns wide tables into stacked "ID: / Name: / Score:" blocks. So in tables:
- Name: max ~30 chars, no commands or code
- Source: the emoji label only, never a URL (links go in Setup)
- Why: max ~8 words
- Put commands, configs and links only in the Setup section

```markdown
# 🧭 Claude Code Automation Report: <repo name>

**Stack:** <languages, frameworks, key services>
**Size:** ~<N> files · **Already set up:** <list, or "nothing yet">

## 🏆 Top picks
| ID | Pick | Type | Score | Effort | Why |
|----|------|------|-------|--------|-----|
| M1 | context7 | MCP | █████████░ 9 | 🟢 | Next 15 + Prisma APIs change often |
(best 5 across all categories)

## 🔌 MCP Servers
| ID | Name | Score | Effort | Source | Why for this repo |
|----|------|-------|--------|--------|-------------------|

## 🎯 Skills
| ID | Name | Score | Effort | Source | Why for this repo |
|----|------|-------|--------|--------|-------------------|

## 📦 Plugins
(same table)

## ⚡ Hooks
(same table; Name = event + action, e.g. "PostToolUse: ruff format")

## 🤖 Subagents
(same table)

## 📝 CLAUDE.md & Config
(same table; permissions, CLAUDE.md gaps, settings)

## 🔧 Setup
- **M1**: `claude mcp add ...`  ([source](url))
- **S2**: `npx skills add <repo> --skill <name> --agent claude-code -g`
- **H1**: add to `.claude/settings.json` → PostToolUse, matcher `Edit|Write`, runs `<command>`
- **A1**: create `.claude/agents/<name>.md`
(one line per item, same order as the report)

## ⏭️ Skipped
<one line each for categories with nothing ≥6, or notable options you rejected and why>

---
**Reply with IDs (e.g. `M1 H2 S3`) and I'll set them up.**
```

Omit a category's section entirely if it has no items (mention it under Skipped instead).

## Quick reference: where things live

| Type | Location |
|------|----------|
| MCP (project, shared) | `.mcp.json` or `claude mcp add --scope project` |
| MCP (user) | `claude mcp add --scope user` |
| Skills | `.claude/skills/<name>/SKILL.md` or `~/.claude/skills/<name>/SKILL.md` |
| Subagents | `.claude/agents/<name>.md` or `~/.claude/agents/<name>.md` |
| Hooks & permissions | `.claude/settings.json` (shared) or `.claude/settings.local.json` (personal) |
| Plugins | `/plugin` in Claude Code |

Skill invocation: `disable-model-invocation: true` = user-only (side effects like deploy/commit). `user-invocable: false` = Claude-only (background knowledge). Omit both = either.
