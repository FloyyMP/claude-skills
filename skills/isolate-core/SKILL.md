---
name: isolate-core
description: "Manual-only. Run ONLY when the user explicitly invokes /isolate-core or says \"run isolate-core\". Never trigger on its own. Strips a project to its core source and zips it."
disable-model-invocation: true
---

# isolate-core

**Explicit invocation only.** Do not run this because a request sounds related ("clean up the repo", "summarise the architecture"). The user must name the skill. If in doubt, ask: "Want me to run isolate-core?" and wait.

Produce `<project>-core.zip`: only the files that carry the project's logic and architecture. Stripped: VCS, docs, editor/CI config, secrets, caches, build output, deps, lockfiles, tests, generated code, binaries and data. The original project is never modified.

## Rules

- Run from the project root (cwd). Never `rm`, `mv` or edit anything inside it.
- Zip goes to the parent of the **git repo root** (so monorepo packages don't pollute the repo). Override with `--out`.
- Kept on purpose: dependency manifests, `tsconfig.json`, `Makefile`, `CMakeLists.txt`, `Dockerfile*`, `docker-compose*`, root `README.md` — they define the architecture. Strip any with `--file`.
- Inside a git repo the script seeds from `git ls-files` (tracked + untracked-not-ignored), so anything gitignored is already gone. Outside git it walks the tree.
- Needs only Python 3. **Never edit or copy the script** — run it in place from this skill's folder; all per-project tweaks are flags.
- Keep responses short: numbers, tree, zip path.

## Steps

1. **Sanity check.** cwd must look like a project root (manifest or `src/`). If not, stop and ask which directory is the root.

2. **Dry run** (default): `python3 <this skill's folder>/scripts/isolate_core.py`. Read the output:
   - `Files kept: 0` → wrong directory; ask.
   - **"Kept files over N MB"** or a suspicious entry in **"Largest kept files"** → data/vendored junk survived; add `--file '<glob>'` or `--dir <name>` and rerun.
   - **"Pruned dirs that MIGHT be real source"** → peek inside each; if it holds real modules, add `--keep-dir <name>` and rerun.
   - Real source stripped by a default pattern → `--keep '<glob>'`.
   Iterate until the per-dir table and largest-files list look like pure source.

3. **Build.** Same command + `--build`. Report: original → core size, file count, zip path.

4. **Verify.** `python3 -m zipfile -l <zip>` and skim for leftovers (`.env`, lockfiles, `node_modules`, tests, `*.pem`, data blobs). Fix flags and rebuild if anything slipped through.

5. Mention any flags you used in the final report.

## Flags

| Flag | Effect |
|------|--------|
| `--build` | write the zip (omit = dry run) |
| `--dir NAME` | extra dir name to strip (repeatable) |
| `--file GLOB` | extra basename glob to strip (repeatable) |
| `--keep GLOB` | exempt basename glob from stripping |
| `--keep-dir NAME` | un-strip a default dir (e.g. `bin`, `build`) |
| `--max-mb N` | large-file warning threshold (default 1) |
| `--no-git` | force a tree walk instead of `git ls-files` |
| `--out PATH` | zip path |
