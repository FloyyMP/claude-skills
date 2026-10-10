#!/usr/bin/env python3
"""Mechanical consistency check of a Claude Code memory dir: every file indexed, every
index line points at a file, every file has valid frontmatter, and every inline
[[wikilink]] resolves. Read-only; prints findings. Exit 0 = consistent (dead
wikilinks and rot warnings are informational and do NOT fail), 1 = structural findings.

Usage: memory-index-check.py [--memory-dir DIR] [--stats]
  --memory-dir  defaults to the first hit of: autoMemoryDirectory in <project root>/.claude/settings.local.json,
                <project root>/.claude/settings.json, ~/.claude/settings.local.json, ~/.claude/settings.json;
                else the derived auto-memory dir (~/.claude/projects/<root-slug>/memory) for this session's
                git root (session found via $CLAUDE_CODE_SESSION_ID), else for the current directory's git root.
                The first output line names the source. No memory files at all = pass.
  --stats       also print memory count by type and orphan memories (not in any MEMORY.md, no inbound [[wikilink]]).
Archive folders (see ARCHIVE_DIRS) and dot-folders are skipped; the archived file count is printed.
Rot warnings ("warn: ...", never change the exit code): oversized MEMORY.md, long or multi-link index lines,
duplicate descriptions, staleness markers in index lines.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from urllib.parse import unquote

PROJECTS = os.path.expanduser("~/.claude/projects")
ARCHIVE_DIRS = {"archive", "archived", "unused", "deprecated"}
# group 1 = <angle target, may contain spaces>, group 2 = plain target
LINK_RE = re.compile(r"\]\((?:<(?![a-z][a-z0-9+.-]*:)([^>#]+\.md)(?:#[^>]*)?>"
                     r"|(?![a-z][a-z0-9+.-]*:)([^)>#\s]+\.md)(?:#[^)>\s]*)?)(?:\s+\"[^\"]*\")?\)")
# Explicit status phrases only: bare words like "stale"/"verify" are mostly rule text ("Memory can be stale").
STALE_RE = re.compile(r"(\(some stale\)|\(verify\b[^)]*\)|\bon hold\b|\bunregistered\b|\bdeprecated\b|\boutdated\b)", re.I)


def session_cwd():
    """The session's working dir: first cwd recorded in its transcript, else ours."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    for t in glob.glob(os.path.join(PROJECTS, "*", f"{sid}.jsonl")) if sid else []:
        try:
            with open(t, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    cwd = re.search(r'"cwd":"((?:[^"\\]|\\.)*)"', line)
                    if cwd:
                        return json.loads(f'"{cwd.group(1)}"')
        except (OSError, ValueError):
            continue
    return os.getcwd()


def project_root(cwd):
    # Auto-memory is keyed by the git root of the MAIN worktree, not by the launch dir: a session started
    # in a subdirectory or a linked worktree keeps its transcript under a different slug than its memory.
    p = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       capture_output=True, encoding="utf-8")
    if p.returncode == 0 and p.stdout.strip().endswith("/.git"):
        return os.path.dirname(p.stdout.strip())
    return cwd


def slug_dir(root):
    # Claude Code slugs with a JS replace() over UTF-16 units, so an astral char becomes two dashes.
    slug = "".join(c if c.isascii() and c.isalnum() else "-" * (1 + (ord(c) > 0xFFFF)) for c in root)
    try:
        names = sorted(os.listdir(PROJECTS))
    except OSError:
        names = []
    hit = slug if slug in names else next((n for n in names if n.lower() == slug.lower()), slug)
    return os.path.join(PROJECTS, hit, "memory")


def resolve_memory_dir(arg):
    """-> (absolute path, source label)."""
    if arg:
        return os.path.abspath(arg), "--memory-dir"
    root = project_root(session_cwd())
    home = os.path.expanduser("~")
    for f in (os.path.join(root, ".claude", "settings.local.json"), os.path.join(root, ".claude", "settings.json"),
              os.path.join(home, ".claude", "settings.local.json"), os.path.join(home, ".claude", "settings.json")):
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding="utf-8-sig") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            print(f"settings file unreadable (ignored): {f}")
            continue
        v = d.get("autoMemoryDirectory") if isinstance(d, dict) else None
        if isinstance(v, str) and v.strip():
            return os.path.abspath(os.path.expanduser(v)), f"autoMemoryDirectory {f}"
    return os.path.abspath(slug_dir(root)), "derived"


def capped(items, n=10):
    return ", ".join(items[:n]) + (f" (+{len(items) - n} more)" if len(items) > n else "")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory-dir", default=None)
    ap.add_argument("--stats", action="store_true")
    a = ap.parse_args()
    mem, source = resolve_memory_dir(a.memory_dir)
    print(f"memory dir: {mem} (source: {source})")

    if not os.path.isdir(mem):
        if source != "derived":
            print(f"  memory dir missing: {mem}")
            sys.exit(1)
        print("memory files: 0 (nothing saved in this project yet; derived dir does not exist)")
        sys.exit(0)

    rel = lambda p: os.path.relpath(p, mem)
    archived = lambda p: any(d.lower() in ARCHIVE_DIRS for d in rel(p).split(os.sep)[:-1])
    found = sorted(glob.glob(os.path.join(glob.escape(mem), "**", "*.md"), recursive=True))  # skips dot-files/dirs
    all_md = [f for f in found if not archived(f)]
    skipped = len(found) - len(all_md)
    archived_line = f"archived (skipped): {skipped} files in {', '.join(sorted(ARCHIVE_DIRS))} folders"
    if not all_md:
        print("memory files: 0 (nothing saved in this project yet)")
        if skipped:
            print(archived_line)
        sys.exit(0)
    if not os.path.isfile(os.path.join(mem, "MEMORY.md")):
        print(f"MEMORY.md missing at {os.path.join(mem, 'MEMORY.md')}")
        sys.exit(1)
    files = [f for f in all_md if os.path.basename(f) != "MEMORY.md"]
    indexes = [f for f in all_md if os.path.basename(f) == "MEMORY.md"]

    # Links from ALL MEMORY.md files (root + subfolders), resolved relative to the index containing them.
    # Any .md link on a line indexes its file (grouped lines like "VPN: [a](a.md); [b](b.md)" are fine), but only
    # the first link per line is that line's entry, so "indexed twice" counts entries within one index, not cross-refs.
    linked, twice, long_lines, multi, stale, warns = set(), set(), [], [], [], []
    for idx in indexes:
        with open(idx, encoding="utf-8-sig", errors="replace") as fh:
            raw = fh.read()
        # blank comments/fences but keep their newlines so reported line numbers stay right
        text = re.sub(r"<!--.*?-->|^```.*?^```", lambda m: "\n" * m.group().count("\n"), raw, flags=re.S | re.M)
        lines = text.splitlines()
        if rel(idx) == "MEMORY.md":
            nb = os.path.getsize(idx)
            if len(lines) > 150 or nb > 20480:
                warns.append(f"warn: MEMORY.md is {len(lines)} lines / {nb} bytes (warn above 150 lines / 20480 bytes); "
                             "Claude Code loads only the first 200 lines / 25 KB of MEMORY.md each session, the rest is never seen")
        ent = {}
        for n, line in enumerate(lines, 1):
            where = f"{rel(idx)}:{n}"
            if len(line) > 150:
                long_lines.append(where)
            if line.count("](") > 1:
                multi.append(where)
            if (s := STALE_RE.search(line)):
                stale.append(f"{where} [{s.group(1).lower()}] {line.strip()[:60]}")
            rs = [rel(os.path.normpath(os.path.join(os.path.dirname(idx), unquote(m.group(1) or m.group(2)))))
                  for m in LINK_RE.finditer(line)]
            linked.update(rs)
            if rs:
                ent[rs[0]] = ent.get(rs[0], 0) + 1
        twice.update(r for r, c in ent.items() if c > 1)

    base_names = {os.path.splitext(os.path.basename(f))[0] for f in files}
    archived_names = {os.path.splitext(os.path.basename(f))[0] for f in found
                      if archived(f) and os.path.basename(f) != "MEMORY.md"}
    findings, dead_wiki, archived_wiki, inbound, type_count, descs = [], [], [], {}, {}, {}
    for f in files:
        name = os.path.basename(f)
        base = os.path.splitext(name)[0]
        if rel(f) not in linked:
            findings.append(f"not in index : {rel(f)}")
        try:
            with open(f, encoding="utf-8-sig") as fh:
                body = fh.read()
        except (OSError, UnicodeError) as e:
            findings.append(f"unreadable   : {rel(f)} ({'invalid UTF-8' if isinstance(e, UnicodeError) else 'read error'})")
            continue
        lines = body.splitlines()
        end = next((i for i, l in enumerate(lines[1:], 1) if l.strip() == "---"), 0) if lines[:1] == ["---"] else 0
        head = lines[:end]  # frontmatter only; [] when missing/unclosed
        for m in re.finditer(r"\[\[([^\]|#]+)[^\]]*\]\]", re.sub(r"```.*?```|`[^`\n]*`", "", body, flags=re.S)):
            t = m.group(1).strip().removesuffix(".md")
            if t in base_names:
                inbound[t] = inbound.get(t, 0) + 1
            elif t in archived_names:
                archived_wiki.append(f"{name} -> [[{t}]] points to archived file")
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
        dm = next((m for l in head if (m := re.match(r"^description:\s*(\S.*?)\s*$", l))), None)
        if not dm:
            findings.append(f"no description: {name}")
        elif not re.fullmatch(r"[>|][-+0-9]*", dm.group(1)):  # block scalar indicator, not a value
            descs.setdefault(dm.group(1).strip("\"'"), []).append(rel(f))
        tyre = r"^\s*type:\s*[\"']?(user|feedback|project|reference)[\"']?\s*(#.*)?$"
        ty = next((re.match(tyre, l).group(1) for l in head if re.match(tyre, l)), None)
        if not ty:
            findings.append(f"bad/missing type: {name}")
        else:
            type_count[ty] = type_count.get(ty, 0) + 1
    for r in sorted(linked):
        if not os.path.exists(os.path.join(mem, r)):
            findings.append(f"dangling link : {r}")
    for r in sorted(twice):
        findings.append(f"indexed twice : {r}")

    if long_lines:
        warns.append(f"warn: {len(long_lines)} index lines over 150 characters: {capped(long_lines)}")
    if multi:
        warns.append(f"warn: {len(multi)} index lines with more than one link: {capped(multi)}")
    for d, names in descs.items():
        if len(names) > 1:
            warns.append(f"warn: duplicate description in {', '.join(names)}: {d[:60]}")
    if stale:
        warns.append(f"warn: {len(stale)} index lines with staleness markers:"
                     + "".join(f"\n    {s}" for s in stale[:10]) + (f"\n    (+{len(stale) - 10} more)" if len(stale) > 10 else ""))

    print(f"memory files: {len(files)}   indexed files: {len(linked)}   findings: {len(findings)}   "
          f"dead wikilinks: {len(dead_wiki)}   rot warnings: {len(warns)}")
    if skipped:
        print(archived_line)
    for x in findings:
        print(f"  {x}")
    for w in warns:
        print(w)
    for title, items in (("dead [[wikilink]] targets (forward refs are allowed; listed for awareness)", dead_wiki),
                         ("[[wikilink]] targets in archive folders (informational)", archived_wiki)):
        if items:
            print(f"  {title}: {len(items)}, first {min(5, len(items))}:")
            for d in items[:5]:
                print(f"    {d}")
    if a.stats:
        print("\nSTATS")
        print("  by type: " + ", ".join(f"{k}={v}" for k, v in type_count.items()))
        orphans = [rel(f) for f in files if rel(f) not in linked and os.path.splitext(os.path.basename(f))[0] not in inbound]
        print(f"  orphans (not in any MEMORY.md, no inbound [[wikilink]]): {len(orphans)}")
        if len(orphans) <= 10:
            for o in orphans:
                print(f"    {o}")
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
