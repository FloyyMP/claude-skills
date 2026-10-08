#!/usr/bin/env python3
"""isolate-core: zip a project's core source, stripping everything else. Never modifies the source.
Usage: python3 isolate_core.py [--build] [--dir NAME]... [--file GLOB]... [--keep GLOB]... [--keep-dir NAME]... [--max-mb N] [--no-git] [--out PATH]
"""
import argparse, fnmatch, os, subprocess, sys, zipfile
from collections import defaultdict

DIRS = {
    ".git", ".hg", ".svn", ".github", ".gitlab", ".circleci",
    "docs", "doc",
    ".claude", ".cursor", ".windsurf", ".vscode", ".idea", ".vs", ".devcontainer", ".husky", ".storybook",
    "node_modules", "vendor", "Pods", ".venv", "venv", "env", "__pycache__", ".pytest_cache", ".mypy_cache",
    ".ruff_cache", ".tox", ".cache", ".parcel-cache", ".turbo", ".next", ".nuxt", ".output", ".svelte-kit",
    ".astro", ".expo", ".wrangler", ".vercel", ".netlify", ".serverless", ".dart_tool", ".terraform", ".gradle",
    ".eggs", ".ipynb_checkpoints", "_build", "deps", "dist", "build", "out", "target", "coverage", "htmlcov",
    ".nyc_output", "bin", "obj", "tmp", "temp", "logs", "DerivedData",
    "test", "tests", "__tests__", "spec", "cypress", "e2e", "fixtures", "__mocks__", "__snapshots__",
}
AMBIGUOUS = {"build", "out", "bin", "obj", "env", "spec", "fixtures", "dist", "deps", "tmp"}
FILES = [
    ".gitignore", ".gitattributes", ".gitmodules", ".gitlab-ci.yml", ".travis.yml", "Jenkinsfile",
    "azure-pipelines.yml", "bitbucket-pipelines.yml", "renovate.json", "dependabot.yml",
    "*.md", "*.mdx", "*.rst", "LICENSE*", "LICENCE*", "CHANGELOG*", "CONTRIBUTING*", "CODEOWNERS", "AUTHORS*", "NOTICE*",
    ".env", ".env.*", "*.pem", "*.p12", "*.pfx", "id_rsa*", "id_ed25519*", "secrets.json", "secrets.y*ml",
    "credentials.json", "service-account*.json", ".npmrc", ".yarnrc", ".yarnrc.yml", ".pypirc", ".netrc",
    ".editorconfig", ".prettierrc*", "prettier.config.*", ".eslintrc*", "eslint.config.*", ".stylelintrc*",
    ".babelrc*", "babel.config.*", ".pre-commit-config.yaml", ".tool-versions", ".nvmrc", ".python-version",
    ".dockerignore", "Procfile", "Vagrantfile", "netlify.toml", "vercel.json", "fly.toml", "commitlint*", "*.stories.*",
    "*.pyc", "*.pyo", "*.log", "*.map", "*.min.js", "*.min.css", "*.egg-info", ".DS_Store", "Thumbs.db",
    "*.lock", "package-lock.json", "pnpm-lock.yaml", "bun.lockb", "go.sum", "Package.resolved", "packages.lock.json",
    "*.pb.go", "*_pb2.py", "*_pb2_grpc.py", "*.g.dart", "*.freezed.dart", "*.generated.*", "*.gen.*",
    "*.test.js", "*.test.jsx", "*.test.ts", "*.test.tsx", "*.test.mjs", "*.test.cjs",
    "*.spec.js", "*.spec.jsx", "*.spec.ts", "*.spec.tsx", "*.spec.mjs", "*.spec.cjs",
    "*_test.go", "test_*.py", "*_test.py", "conftest.py", "jest.config.*", "vitest.config.*", "pytest.ini", ".coveragerc",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.ico", "*.svg", "*.webp", "*.mp4", "*.mp3", "*.wav",
    "*.woff", "*.woff2", "*.ttf", "*.otf", "*.pdf", "*.zip", "*.tar", "*.tar.gz", "*.tgz", "*.7z",
    "*.db", "*.sqlite", "*.sqlite3", "*.jsonl", "*.csv", "*.tsv", "*.parquet", "*.pkl", "*.pickle", "*.npy", "*.npz",
    "*.h5", "*.onnx", "*.pt", "*.pth", "*.safetensors", "*.bin", "*.dat", "*.dump",
    "*.so", "*.dll", "*.dylib", "*.exe", "*.o", "*.a", "*.wasm", "*.class", "*.jar", "*.war",
]
ROOT_KEEP = {"readme.md", "readme.rst"}  # root-level only

ap = argparse.ArgumentParser()
ap.add_argument("--build", action="store_true", help="write the zip (default is dry run)")
ap.add_argument("--dir", action="append", default=[], help="extra dir name to strip")
ap.add_argument("--file", action="append", default=[], help="extra basename glob to strip")
ap.add_argument("--keep", action="append", default=[], help="basename glob exempt from stripping")
ap.add_argument("--keep-dir", action="append", default=[], help="dir name to NOT strip (e.g. bin)")
ap.add_argument("--max-mb", type=float, default=1.0, help="warn on kept files larger than this")
ap.add_argument("--no-git", action="store_true", help="don't seed from git ls-files")
ap.add_argument("--out", help="zip path (default: <repo parent>/<name>-core.zip)")
a = ap.parse_args()
DIRS = (DIRS | set(a.dir)) - set(a.keep_dir); FILES += a.file

SRC = os.path.abspath(os.getcwd()); NAME = os.path.basename(SRC) or "project"

def git(*args):
    try:
        r = subprocess.run(["git", *args], cwd=SRC, capture_output=True, text=True, timeout=60)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

top = None if a.no_git else (git("rev-parse", "--show-toplevel") or "").strip() or None
OUT = a.out or os.path.join(os.path.dirname(top or SRC), f"{NAME}-core.zip")

def strip_file(rel):
    name = os.path.basename(rel)
    if rel.lower() in ROOT_KEEP or any(fnmatch.fnmatch(name, k) for k in a.keep):
        return False
    return any(fnmatch.fnmatch(name, p) for p in FILES)

def strip_dir(rel):  # any path component in DIRS
    return any(part in DIRS for part in rel.split(os.sep)[:-1])

# candidates: git-tracked + untracked-not-ignored when possible, else full walk
candidates, source = None, "walk"
if top:
    ls = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    if ls is not None:
        candidates = [p.replace("/", os.sep) for p in ls.split("\0") if p]; source = "git ls-files"

total_src, kept, warn_dirs = 0, [], []
for root, dirs, files in os.walk(SRC):
    for d in dirs:
        rel = os.path.relpath(os.path.join(root, d), SRC)
        if d in AMBIGUOUS and d in DIRS and (candidates is None or any(c.startswith(rel + os.sep) for c in candidates)):
            warn_dirs.append(rel)
    for f in files:
        try: total_src += os.path.getsize(os.path.join(root, f))
        except OSError: pass
if candidates is None:
    candidates = []
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in DIRS]
        candidates += [os.path.relpath(os.path.join(root, f), SRC) for f in files]

for rel in sorted(set(candidates)):
    p = os.path.join(SRC, rel)
    if not os.path.isfile(p) or strip_dir(rel) or strip_file(rel):
        continue
    kept.append((rel, os.path.getsize(p)))

mb = lambda b: f"{b/1e6:.2f} MB"
total_kept = sum(s for _, s in kept)
print(f"Source: {source}   Original: {mb(total_src)}   Core: {mb(total_kept)}   Files kept: {len(kept)}\n")
by_dir = defaultdict(lambda: [0, 0])
for rel, sz in kept:
    d = "/".join(rel.split(os.sep)[:-1][:2]) or "."
    by_dir[d][0] += 1; by_dir[d][1] += sz
for d, (n, sz) in sorted(by_dir.items()):
    print(f"  {d:<40} {n:>5} files  {mb(sz):>10}")
big = [(r, s) for r, s in kept if s > a.max_mb * 1e6]
if big:
    print(f"\nKept files over {a.max_mb} MB — probably not source:")
    for r, s in sorted(big, key=lambda x: -x[1]): print(f"  {mb(s):>10}  {r}")
print("\nLargest kept files:")
for r, s in sorted(kept, key=lambda x: -x[1])[:10]: print(f"  {mb(s):>10}  {r}")
if warn_dirs:
    print("\nPruned dirs that MIGHT be real source — check, and rerun with --keep-dir NAME if so:")
    for d in sorted(warn_dirs): print(f"  {d}")

if not kept:
    sys.exit("No source files kept — check you're in the project root.")
if a.build:
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for rel, _ in kept:
            z.write(os.path.join(SRC, rel), os.path.join(NAME, rel))
    print(f"\nZip: {OUT} ({mb(os.path.getsize(OUT))})")
else:
    print(f"\nDry run. Zip would be: {OUT}   (add --build)")
