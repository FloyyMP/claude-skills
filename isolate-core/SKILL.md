---
name: "isolate-core"
description: "Manual-only. Run ONLY when the user explicitly invokes /isolate-core or says \"run isolate-core\". Never trigger on its own. Strips a project to its core source and zips it."
disable-model-invocation: true
---

# isolate-core

**Explicit invocation only.** Do not run this because a request sounds related ("clean up the repo", "summarise the architecture", etc.). The user must name the skill. If in doubt, ask: "Want me to run isolate-core?" and wait.

Produce `<project>-core.zip`: only the source files that carry the project's logic and architecture. Everything else is stripped — git, docs, dot-dirs, env/tooling config, secrets, caches, build output, deps, lockfiles, tests, binaries, big data files. The original project is never modified.

## Rules

- Run from the project root (cwd). Never `rm`, `mv` or edit anything inside it.
- The zip is written to the **parent** directory so it can't pollute the repo.
- Kept on purpose: dependency manifests (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`…), `tsconfig.json`, `Makefile`, `Dockerfile`, compose files — they define the architecture.
- Every dot-dir (`.git`, `.vscode`, `.aws`…) and every dotfile (`.env`, `.envrc`, `.npmrc`…) is stripped. To keep a dot-dir, add it to `DOT_DIR_ALLOW`; to keep a dotfile, add it to `KEEP`.
- Text data (`*.txt`, `*.csv`, `*.jsonl`…) is stripped by default: it's where combo lists, proxy lists and dumps live.
- `KEEP` entries are patterns matched against the name **or** the path relative to root (forward slashes), for files and dirs: `app/docs`, `*prompts/*.md`.
- Files whose content looks like a secret are **stripped** and reported. Only the user can clear one, by path, via `SECRET_OK`.
- Name matching is case-insensitive. Patterns in the script are lowercase.
- Needs only Python 3 (no rsync/zip binaries).
- Keep responses short: numbers, tree, zip path.

## Commands by shell

| | bash / zsh | PowerShell |
|---|---|---|
| List root | `ls -la` | `Get-ChildItem -Force` |
| Temp dir | `/tmp` (or `$TMPDIR`) | `$env:TEMP` |
| Dry run | `DRY=1 python3 <tmp>/isolate_core_tmp.py` | `$env:DRY=1; python <tmp>\isolate_core_tmp.py` |
| Build | `DRY=0 python3 <tmp>/isolate_core_tmp.py` | `$env:DRY=0; python <tmp>\isolate_core_tmp.py` |
| List zip | `python3 -m zipfile -l <zip>` | `python -m zipfile -l <zip>` |

On Windows, if `python` isn't found, try `py`.

## Steps

1. **Sanity check.** Confirm cwd looks like a project root (has a manifest or a `src/` dir). If not, stop and ask which directory is the root.

2. **Project analysis — do this before writing or running the script.**

   List every top-level entry. For each directory **not already matched by `DIRS`**, peek one level deeper:

   | What you see inside | Decision |
   |---------------------|----------|
   | Source files (`.go`, `.rs`, `.ts`, `.py`, …) | Keep — it's a real module |
   | Runtime data, uploads, results, dumps, databases | Add to `DIRS` |
   | Generated / cache / build output | Add to `DIRS` |
   | Vendor / third-party code | Add to `DIRS` |
   | Config/tooling for this project only | Keep or add to `FILES` |

   Also check for a top-level `bin/` with real entry scripts (common in Node CLIs). If found, add `"bin"` to `KEEP`.

   Prompt-driven projects (skills, plugins, LLM apps with a `prompts/` dir): their `.md` files are source. Add them to `KEEP` (`skill.md` is kept by default; add e.g. `*prompts/*.md`, `*commands/*.md`, `*agents/*.md`).

   Scan root-level files for non-source extensions not already in `FILES` (`.parquet`, `.xlsx`…) and add patterns. Big files (> `MAX_BYTES`) and binaries anywhere are auto-skipped.

   Write one short paragraph on what you found and how you classified it. Then pre-populate `DIRS`/`FILES`. Goal: the first dry run is nearly clean.

3. **Dry run.** Save the script to the **OS temp dir** (never the project root, so it can't land in the zip). Run the dry-run command from the project root. Read each report section:
   - `Files kept: 0` → wrong directory or unusual layout; ask.
   - **"Stripped dirs that hold source files"** → covers any depth (e.g. a Next.js `app/docs/` route). If one is a real module, add its path to `KEEP` (e.g. `"app/docs"`) and rerun. Test and dependency dirs are never listed.
   - **"Stripped by \*secret\*/\*credential\* name"** → if a file is real source (e.g. `secretsManager.ts`) and contains no secrets, add its name to `KEEP` and rerun.
   - **"Skipped, over 1.0 MB"** / **"binary content"** → fine unless one is real source; then raise `MAX_BYTES` or add it to `KEEP`.
   - **"⚠ Stripped: content looks like a hardcoded secret"** → already excluded. Tell the user each file and line. Don't edit the source. Only if the user says a file is safe, add its path to `SECRET_OK` and rerun.
   - Project-specific noise survived → add it to `DIRS`/`FILES` and rerun. If noise survived despite the analysis step, explain why.
4. **Build.** Run the build command from the project root. Report: original → core size, file count, zip path. If the report says an existing zip was overwritten, mention it.
5. **Verify.** List the zip and skim for leftovers (dotfiles, `*.env`, data files, lockfiles, `node_modules`, tests, `*.pem`). Fix and rebuild if anything slipped through.
6. **Clean up.** Delete the temp script.
7. Mention any per-project tweaks you made in the final report.

## Script

```python
#!/usr/bin/env python3
"""isolate-core: zip a project's core source, stripping everything else. Never modifies the source."""
import fnmatch, os, re, sys, zipfile
from collections import Counter

DRY = os.environ.get("DRY", "1") != "0"
SRC = os.path.abspath(os.getcwd())
NAME = os.path.basename(SRC)
OUT = os.path.join(os.path.dirname(SRC), f"{NAME}-core.zip")
MAX_BYTES = 1_000_000  # bigger files are skipped and reported

# Dir name patterns stripped anywhere, silently: deps, caches, tests (lowercase; matched case-insensitively)
QUIET_DIRS = [
    "node_modules", "vendor", "pods", "venv", "__pycache__", "*.egg-info", "target", "coverage", "obj",
    "test", "tests", "__tests__", "spec", "cypress", "e2e", "fixtures", "__mocks__", "__snapshots__",
]
# Dir name patterns stripped anywhere, but reported when they hold source files
# (a Node CLI's bin/, a Next.js app/docs/ route). Project-specific junk dirs go here.
DIRS = ["docs", "doc", "dist", "build", "out", "bin", "env"]
# Every dot-dir (.git, .vscode, .aws, .ssh, ...) is stripped unless listed here
DOT_DIR_ALLOW = set()
# What counts as source when checking a stripped dir
SOURCE_EXT = {".py", ".go", ".rs", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte", ".java", ".kt",
              ".cs", ".c", ".cc", ".cpp", ".h", ".hpp", ".rb", ".php", ".swift", ".lua", ".sh", ".ps1"}
# File name patterns stripped anywhere (lowercase; matched case-insensitively).
# Every dotfile (.env, .envrc, .npmrc, .gitignore, ...) is stripped too unless it's in KEEP.
FILES = [
    # CI
    "jenkinsfile", "azure-pipelines.yml", "bitbucket-pipelines.yml", "renovate.json", "dependabot.yml",
    # Docs
    "*.md", "*.mdx", "*.rst", "license*", "licence*", "changelog*", "contributing*", "codeowners", "authors*", "notice*",
    # Secrets / env
    "*.env", "*.pem", "*.key", "*.p12", "*.pfx", "*.keystore", "*.jks", "id_rsa*", "id_ed25519*",
    "*.tfvars", "*.tfstate*", "serviceaccount*.json",
    # Tooling / deploy config
    "prettier.config.*", "eslint.config.*", "babel.config.*",
    "procfile", "vagrantfile", "netlify.toml", "vercel.json", "fly.toml", "commitlint*", "*.stories.*",
    # Caches / build junk
    "*.pyc", "*.pyo", "*.log", "*.map", "*.min.js", "*.min.css", "thumbs.db",
    # Lockfiles
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "pipfile.lock",
    "poetry.lock", "uv.lock", "cargo.lock", "go.sum", "gemfile.lock", "composer.lock",
    # Tests
    "*.test.*", "*.spec.*", "*_test.go", "test_*.py", "*_test.py", "conftest.py",
    "jest.config.*", "vitest.config.*", "pytest.ini",
    # Text data (combo/proxy lists, dumps, exports)
    "*.txt", "*.csv", "*.tsv", "*.jsonl", "*.ndjson",
    # Binary media / archives / data
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.ico", "*.svg", "*.webp", "*.mp4", "*.mp3",
    "*.woff", "*.woff2", "*.ttf", "*.otf", "*.pdf", "*.zip", "*.tar.gz",
    "*.db", "*.sqlite*", "*.exe", "*.dll", "*.so", "*.dylib", "*.bin",
]
# Stripped, but listed in the report (these also catch real source like secretsManager.ts)
SECRET_NAMES = ["*secret*", "*credential*"]
# Always kept, even if a pattern above matches. Matched against the name or the relative
# path (forward slashes), for files and dirs: "app/docs", "*prompts/*.md".
KEEP = ["package.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements*.txt", "cargo.toml",
        "go.mod", "gemfile", "composer.json", "pom.xml", "build.gradle", "build.gradle.kts", "tsconfig.json",
        "makefile", "cmakelists.txt", "dockerfile", "docker-compose.yml", "docker-compose.yaml",
        "compose.yml", "compose.yaml", "skill.md"]
# Relative paths (forward slashes) the user confirmed are safe despite a secret-content hit
SECRET_OK = set()
# Content that looks like a hardcoded secret — the file is stripped and reported
SECRET_RE = re.compile(
    rb"AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY"
    rb"|\bsk-[A-Za-z0-9_-]{20,}|\b[sr]k_live_[A-Za-z0-9]{20,}|\bAIza[0-9A-Za-z_-]{35}"
    rb"|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bxox[abprs]-[A-Za-z0-9-]{10,}"
    rb"|hooks\.slack\.com/services/\S+|discord(?:app)?\.com/api/webhooks/\d+/[\w-]+"
    rb"|\b[MNO][\w-]{23,27}\.[\w-]{6}\.[\w-]{27,40}"  # Discord bot token
    rb"|://[^/\s:@'\"{}$<>]+:[^/\s@'\"{}$<>]+@"  # user:pass inside a URL; skips {templated} parts
    rb"|^[\w.+-]+@[\w-]+\.[\w.-]+:\S+",  # email:password combo line
    re.M)


def match(name, pats):
    n = name.lower()
    return any(fnmatch.fnmatchcase(n, p) for p in pats)


def keep(name, relp):
    return match(name, KEEP) or match(relp.replace(os.sep, "/"), KEEP)


def skip_dir(d, relp):
    if keep(d, relp): return False
    return (d.startswith(".") and d.lower() not in DOT_DIR_ALLOW) or match(d, DIRS + QUIET_DIRS)


def scan(path):
    """Total size and source-file count under path."""
    t = n = 0
    for r, _, fs in os.walk(path):
        for f in fs:
            try: t += os.path.getsize(os.path.join(r, f))
            except OSError: pass
            n += os.path.splitext(f)[1].lower() in SOURCE_EXT
    return t, n


rel = lambda p: os.path.relpath(p, SRC)
kept, ambiguous, secret_named, big, binary, links, hits = [], [], [], [], [], [], []
total_src = total_kept = 0

for root, dirs, files in os.walk(SRC):
    drop = []
    for d in dirs:
        p = os.path.join(root, d)
        if os.path.islink(p):
            links.append(rel(p)); drop.append(d)
        elif skip_dir(d, rel(p)):
            drop.append(d)
            sz, n = scan(p); total_src += sz
            if n and not d.startswith(".") and not match(d, QUIET_DIRS):
                ambiguous.append(f"{rel(p)} ({n} source files)")
    dirs[:] = sorted(d for d in dirs if d not in drop)
    for f in sorted(files):
        p = os.path.join(root, f)
        if os.path.islink(p):
            links.append(rel(p)); continue
        try: sz = os.path.getsize(p)
        except OSError: continue
        total_src += sz
        relp = rel(p)
        if not keep(f, relp):
            if match(f, SECRET_NAMES): secret_named.append(relp); continue
            if f.startswith(".") or match(f, FILES): continue
        if sz > MAX_BYTES: big.append(f"{relp} ({sz/1e6:.1f} MB)"); continue
        with open(p, "rb") as fh: data = fh.read()
        if b"\0" in data[:8192]: binary.append(relp); continue
        m = SECRET_RE.search(data)
        # Line number only — never print the matched text, it may be the secret itself
        if m and relp.replace(os.sep, "/") not in SECRET_OK:
            line = data.count(b"\n", 0, m.start()) + 1
            hits.append(f"{relp}:{line}"); continue
        kept.append(relp); total_kept += sz

mb = lambda b: f"{b/1e6:.1f} MB"
print(f"Original: {mb(total_src)}   Core: {mb(total_kept)}   Files kept: {len(kept)}\n")
counts = Counter("/".join(k.split(os.sep)[:-1][:2]) or "." for k in kept)
for d, n in sorted(counts.items()):
    print(f"  {d:<40} {n} files")


def section(title, items):
    if items:
        print(f"\n{title}")
        for i in items: print(f"  {i}")


section("Stripped dirs that hold source files — real modules? (KEEP by path to include):", ambiguous)
section("Stripped by *secret*/*credential* name — real source?", secret_named)
section(f"Skipped, over {mb(MAX_BYTES)}:", big)
section("Skipped, binary content:", binary)
section("Skipped symlinks:", links)
section("⚠ Stripped: content looks like a hardcoded secret (file:line) — SECRET_OK to include:", hits)

if not kept:
    sys.exit("No source files kept — check you're in the project root.")
if os.path.exists(OUT):
    print(f"\nNote: {OUT} exists and will be overwritten.")
if not DRY:
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for k in kept:
            z.write(os.path.join(SRC, k), os.path.join(NAME, k))
    print(f"\nZip: {OUT} ({mb(os.path.getsize(OUT))})")
```
