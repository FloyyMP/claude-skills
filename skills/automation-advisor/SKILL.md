---
name: automation-advisor
version: 1.2.0
description: Analyze a codebase and produce a rated report of recommended Claude Code automations (MCP servers, skills, plugins, hooks, subagents, CLAUDE.md/config), each verified against live sources; installs nothing until the user picks. Use when the user asks for automation recommendations or a report, asks which Claude Code features/hooks/subagents they should use, or wants to optimize their Claude Code workflow. To find and install plugins/skills/CLI tools directly, use find-tooling instead.
allowed-tools: Read, Glob, Grep, Bash, WebSearch, WebFetch
---

# Claude Automation Advisor

Scan the repo, search real sources, then output a **rated, visual report** of every automation that's genuinely worth adding. Read-only until the user picks IDs; then set up exactly those (Phase 5).

## Rules

- **List everything good, not a fixed number.** Include every item scoring **6/10 or higher**. Usually 3–8 per category, max 10. If a category only has 1 good pick, list 1. If none, say so in one line.
- **Verify before recommending.** Every third-party item needs a real URL you found this session. Never invent package names, MCP servers or commands. Claude Code features themselves (hook events, frontmatter fields, settings keys) change often: check the docs at `code.claude.com/docs` before naming one.
- **Tie every pick to this repo.** The "Why" must cite something you actually found (a dependency, a config file, a folder, a commit pattern).
- **Skip what's already installed.** List those under "Already set up" instead. Also skip anything that duplicates an installed item's job.
- **One tool, one ID.** If the same tool exists as an MCP server, a plugin and a skill, recommend the best form once and mention the others in Skipped.
- **CLI beats MCP when Claude can just run it.** If an official CLI covers the job (`gh`, `aws`, `stripe`, `supabase`, `vercel`…), prefer it (or a skill that wraps it) over an MCP server. Recommend the MCP only for what the CLI can't do (OAuth-only APIs, live browser, rich queries).
- **Commands match the OS.** On Windows give PowerShell. For `npx skills add`, always add `--agent claude-code -g`.

## Phase 1: Scan the project

Gather, quickly (don't read the whole codebase). Run independent commands in parallel.

- Manifests: `package.json`, `pyproject.toml`, `requirements*.txt`, `Cargo.toml`, `go.mod`, `pom.xml`, `*.csproj`, `Dockerfile`, `docker-compose*`
- Tooling configs: formatter, linter, type checker, test runner, CI (`.github/workflows`), `.env*` (names only, never values), lock files
- Structure: top-level folders, rough file count, languages
- External services: SDK imports and env var names (Stripe, Supabase, AWS, OpenAI, Sentry, etc.)
- Existing Claude setup, project **and** user level:
  - `CLAUDE.md`, `.claude/` (settings, skills, agents), `.mcp.json`
  - `~/.claude/settings.json` (note existing `hooks`, `permissions`, `statusLine`), `~/.claude/skills/`, `~/.claude/agents/`
  - `claude mcp list`, `claude plugin list`
- Recent pain: `git log --oneline -50`. Repeated "fix lint"/"format"/"fix types" commits = PostToolUse hook candidates. Reverts or "oops" commits on the same files = PreToolUse guard or CLAUDE.md rule candidates. Repeated manual release/deploy steps = skill candidates.

Write a 3-line summary for yourself (stack, services, pain points) and search against that, not the raw file list.

## Phase 2: Search sources

One search per real need, not per dependency. Use subagents for the category searches in parallel when available. Budget: about 15 web searches total; stop a category once you have strong official options.

| Source | Look for |
|--------|----------|
| Local marketplace catalogs | Plugins and MCP servers across every added marketplace, ranked with installs/review/token cost: `python -I ~/.claude/skills/find-tooling/scripts/search.py <3-5 terms>` (one call per need; never Read marketplace.json). Skip this row if the script isn't installed. |
| `npx -y skills find <2-3 terms>` | Community skills, ranked by installs (`owner/repo@skill`) |
| `anthropics/claude-plugins-official`, `anthropics/skills` | Official plugins and skills |
| Vendor docs / GitHub | Official MCP servers, skills or CLIs from the library's own maintainers (best trust) |
| Official MCP registry (registry.modelcontextprotocol.io) | MCP servers |
| awesome-claude-code lists, GitHub search | Hooks, subagents, plugins |
| Web search | `"<library> MCP server"`, `"<library> claude code skill"`, `"claude code hook <tool>"` |

For each candidate, note: source URL, official vs community, stars and last update if visible. Drop anything unmaintained for 12+ months unless nothing else exists. For plugins, `claude plugin details <name>@<marketplace>` shows its always-on token cost; big bundles with one useful skill score low.

Also consider things to **create** (custom skills, hooks, subagents, CLAUDE.md additions) based on the repo's own workflows. These don't need a URL.

**Subagent ideas.** Always propose some; a good subagent does one job, in its own context, with only the tools it needs. Look for:

- Reviewers for this repo's risk areas: security (auth, payments, user input), DB migrations, API contracts, accessibility for UI repos
- Runners that keep noisy output out of the main context: test runner/fixer, build or CI-log triager, dependency upgrader
- Researchers: codebase explorer for large repos, docs researcher for fast-moving libraries found in Phase 1
- Domain checkers from git history: whatever keeps getting fixed after the fact (e.g. i18n keys, schema drift, changelog entries)

Give each one a name, a one-line job, its `tools` and a `model` (`haiku` for narrow checks). Also search ready-made ones (`VoltAgent/awesome-claude-code-subagents`, `wshobson/agents`) and prefer adapting a maintained one over writing from scratch.

Config ideas worth checking:

- `permissions.allow` for the repo's safe, frequent commands (test, lint, build) to cut prompts
- Missing or stale `CLAUDE.md` facts: build/test commands, gotchas found in git history
- `statusLine`, output style, GitHub Actions (`anthropics/claude-code-action`) for PR review, scheduled routines (`/schedule`) for recurring chores

## Phase 3: Rate

Score each item 1–10 using judgment across:

- **Impact**: how much time or pain it saves in *this* repo
- **Fit**: how strong the evidence is that the repo needs it
- **Trust**: official > popular/maintained > small/new
- **Cost**: setup effort and always-on context tokens; cheap and light nudges the score up, heavy bundles down

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
- **H1**: `.claude/settings.json` → PostToolUse, matcher `Edit|Write`, runs `<command>`
- **A1**: create `.claude/agents/<name>.md`
(one line per item, same order as the report)

## ⏭️ Skipped
<one line each for categories with nothing ≥6, or notable options you rejected and why>

---
**Reply with IDs (e.g. `M1 H2 S3`), or `top` for the Top picks, and I'll set them up.**
```

Omit a category's section entirely if it has no items (mention it under Skipped instead).

## Phase 5: Set up the picks

Only the IDs the user chose. For each one:

1. **Install or create** it per the table below. Project-specific → project scope; general-purpose → user scope.
2. **Merge, don't overwrite.** Read the settings file first and add to existing `hooks`/`permissions` arrays. Check the JSON parses afterwards.
3. **Test it.** MCP: `claude mcp get <name>` shows it connected. Hook: pipe a sample event into the command and check the exit code (see below). Skill/agent: the file exists with valid frontmatter. Plugin: `claude plugin list` shows it enabled.
4. **Report** one line per ID: done / failed (why, and what to do next). Plugins, skills and new MCP servers need `/reload-plugins` or a restart; Claude can't run slash commands, so tell the user.

### Hook template

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "<command>" }]
      }
    ]
  }
}
```

- The hook gets the event as JSON on stdin; the edited file is `tool_input.file_path`. Format/lint only that file, not the whole repo.
- Exit 0 = fine. Exit 2 = feed stderr back to Claude (PreToolUse: also blocks the tool). Keep hooks fast and quiet on success.
- On Windows, `command` runs in Git Bash if installed, else PowerShell. Add `"shell": "powershell"` for a PowerShell command.
- Test before reporting done: `'{"tool_name":"Edit","tool_input":{"file_path":"<a real file>"}}' | <command>` (PowerShell) or `echo '<same json>' | <command>` (bash).

## Quick reference: where things live

| Type | Location |
|------|----------|
| MCP (project, shared) | `.mcp.json` or `claude mcp add --scope project` |
| MCP (user) | `claude mcp add --scope user` |
| Skills | `.claude/skills/<name>/SKILL.md` or `~/.claude/skills/<name>/SKILL.md` |
| Subagents | `.claude/agents/<name>.md` or `~/.claude/agents/<name>.md` |
| Hooks & permissions | `.claude/settings.json` (shared) or `.claude/settings.local.json` (personal) |
| Plugins | `claude plugin install <name>@<marketplace> [--scope project]` |

Skill frontmatter: `disable-model-invocation: true` = user-only (side effects like deploy/commit). `user-invocable: false` = Claude-only (background knowledge). Omit both = either. Prefer skills over `.claude/commands/` for new slash commands.

Subagent frontmatter: `name` and `description` required; set `tools` to the minimum it needs, and `model` (e.g. `haiku`) for cheap, narrow jobs.
