#!/usr/bin/env python3
"""Mechanical consistency check of a Claude Code memory dir: every file indexed, every
index line points at a file, every file has valid frontmatter, and every inline
[[wikilink]] resolves. Read-only; prints findings. Exit 0 = consistent (dead
wikilinks are informational and do NOT fail), 1 = structural findings.

Usage: memory-index-check.py [--memory-dir DIR] [--stats]
  --memory-dir  defaults to the auto-memory dir for this session's git root
                (~/.claude/projects/<root-slug>/memory; session found via $CLAUDE_CODE_SESSION_ID),
                else for the current directory's git root. No memory files at all = pass.
  --stats       also print memory count by type and orphan memories (nothing links to them).
Archive folders (see ARCHIVE_DIRS) are skipped; their file count is printed.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

PROJECTS = os.path.expanduser("~/.claude/projects")
ARCHIVE_DIRS = {"archive", "archived", "unused", "deprecated"}


def session_cwd():
    """The session's working dir: first cwd recorded in its transcript, else ours."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    for t in glob.glob(os.path.join(PROJECTS, "*", f"{sid}.jsonl")) if sid else []:
        with open(t, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                cwd = re.search(r'"cwd":"((?:[^"\\]|\\.)*)"', line)
                if cwd:
                    return cwd.group(1)
    return os.getcwd()


def default_memory_dir():
    # Auto-memory is keyed by the git root of the MAIN worktree, not by the launch dir: a session started
    # in a subdirectory or a linked worktree keeps its transcript under a different slug than its memory.
    cwd = session_cwd()
    root = cwd
    p = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       capture_output=True, text=True)
    if p.returncode == 0 and p.stdout.strip().endswith("/.git"):
        root = os.path.dirname(p.stdout.strip())
    return os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", root), "memory")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory-dir", default=None)
    ap.add_argument("--stats", action="store_true")
    a = ap.parse_args()
    mem = os.path.realpath(a.memory_dir or default_memory_dir())

    if not os.path.isfile(os.path.join(mem, "MEMORY.md")):
        if not glob.glob(os.path.join(glob.escape(mem), "**", "*.md"), recursive=True):
            print(f"memory dir: {mem}\nmemory files: 0 (nothing saved in this project yet)")
            sys.exit(0)
        print(f"MEMORY.md missing at {os.path.join(mem, 'MEMORY.md')}")
        sys.exit(1)

    rel = lambda p: os.path.relpath(p, mem)
    archived = lambda p: any(d.lower() in ARCHIVE_DIRS for d in rel(p).split(os.sep)[:-1])
    found = sorted(glob.glob(os.path.join(glob.escape(mem), "**", "*.md"), recursive=True))
    all_md = [f for f in found if not archived(f)]
    skipped = len(found) - len(all_md)
    files = [f for f in all_md if os.path.basename(f) != "MEMORY.md"]
    indexes = [f for f in all_md if os.path.basename(f) == "MEMORY.md"]

    # Links from ALL MEMORY.md files (root + subfolders), resolved relative to the index containing them.
    # Any .md link on a line indexes its file (grouped lines like "VPN: [a](a.md); [b](b.md)" are fine), but only
    # the first link per line is that line's entry, so "indexed twice" counts entries, not cross-refs.
    linked, entries = set(), {}
    for idx in indexes:
        with open(idx, encoding="utf-8-sig", errors="replace") as fh:
            text = re.sub(r"<!--.*?-->|^```.*?^```", "", fh.read(), flags=re.S | re.M)
        for line in text.splitlines():
            ms = re.findall(r"\]\(<?(?![a-z][a-z0-9+.-]*:)([^)>#\s]+\.md)(?:#[^)>\s]*)?>?(?:\s+\"[^\"]*\")?\)", line)
            rs = [rel(os.path.normpath(os.path.join(os.path.dirname(idx), t))) for t in ms]
            linked.update(rs)
            if rs:
                entries[rs[0]] = entries.get(rs[0], 0) + 1

    base_names = {os.path.splitext(os.path.basename(f))[0] for f in files}
    findings, dead_wiki, inbound, type_count = [], [], {}, {}
    for f in files:
        name = os.path.basename(f)
        base = os.path.splitext(name)[0]
        if rel(f) not in linked:
            findings.append(f"not in index : {rel(f)}")
        try:
            with open(f, encoding="utf-8-sig") as fh:
                body = fh.read()
        except (OSError, UnicodeError) as e:
            findings.append(f"unreadable   : {rel(f)} ({e.__class__.__name__})")
            continue
        lines = body.splitlines()
        end = next((i for i, l in enumerate(lines[1:], 1) if l.strip() == "---"), 0) if lines[:1] == ["---"] else 0
        head = lines[:end]  # frontmatter only; [] when missing/unclosed
        for m in re.finditer(r"\[\[([^\]|#]+)[^\]]*\]\]", re.sub(r"```.*?```|`[^`\n]*`", "", body, flags=re.S)):
            t = m.group(1).strip().removesuffix(".md")
            if t in base_names:
                inbound[t] = inbound.get(t, 0) + 1
            else:
                dead_wiki.append(f"{name} -> [[{t}]]")
        if not head:
            findings.append(f"no frontmatter: {name}")
            continue
        nm = next((re.match(r"^name:\s*(\S+)", l).group(1) for l in head if re.match(r"^name:\s*\S+", l)), None)
        if not nm:
            findings.append(f"no name:      {name}")
        elif nm.strip("\"'") != base:
            findings.append(f"name/file mismatch: {name} has name: {nm}")
        if not any(re.match(r"^description:\s*\S", l) for l in head):
            findings.append(f"no description: {name}")
        tyre = r"^\s*type:\s*[\"']?(user|feedback|project|reference)[\"']?\s*(#.*)?$"
        ty = next((re.match(tyre, l).group(1) for l in head if re.match(tyre, l)), None)
        if not ty:
            findings.append(f"bad/missing type: {name}")
        else:
            type_count[ty] = type_count.get(ty, 0) + 1
    for r in sorted(linked):
        if not os.path.exists(os.path.join(mem, r)):
            findings.append(f"dangling link : {r}")
    for r, n in entries.items():
        if n > 1:
            findings.append(f"indexed twice : {r}")

    print(f"memory dir: {mem}")
    print(f"memory files: {len(files)}   indexed files: {len(linked)}   findings: {len(findings)}   dead wikilinks: {len(dead_wiki)}")
    if skipped:
        print(f"archived (skipped): {skipped} files in {', '.join(sorted(ARCHIVE_DIRS))} folders")
    for x in findings:
        print(f"  {x}")
    if dead_wiki:
        print("  dead [[wikilink]] targets (forward refs are allowed; listed for awareness):")
        for d in dead_wiki:
            print(f"    {d}")
    if a.stats:
        print("\nSTATS")
        print("  by type: " + ", ".join(f"{k}={v}" for k, v in type_count.items()))
        orphans = sorted(b for b in base_names if b not in inbound)
        print(f"  orphans (no inbound [[wikilink]]): {len(orphans)}")
        for o in orphans:
            print(f"    {o}")
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
