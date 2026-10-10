"""Search every locally cached Claude Code marketplace for plugins matching 3-5 terms.

Usage: python -I search.py <term> <term> ... [--top N] | --selftest
"""
import argparse
import json
import math
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PLUGINS = Path.home() / ".claude" / "plugins"
INDEX = PLUGINS / "find-tooling-index.json"
SCHEMA = 1
SKIP_DIRS = {".git", "node_modules"}
STALE_DAYS = 14

# First match wins; unknown marketplaces rank between the two lists, aggregators last.
PRIORITY = ["claude-plugins-official", "anthropic-agent-skills", "trailofbits", "claude-code-workflows",
            "superpowers-marketplace", "voltagent-subagents", "parallel-agent-skills", "ecc", "taste-skill",
            "ponytail", "universal-modder", "claude-community", "claude-code-plugins-plus",
            "claude-code-skills", "han", "claude-settings"]
AGGREGATORS = ["agentic-awesome-skills", "buildwithclaude", "awesome-claude-code-plugins"]

# (field, weight), best first, so the first hit is the best hit.
FIELDS = (("nm", 5), ("kw", 3), ("desc", 2), ("comp", 1))


def mkt_rank(mkt):
    if mkt in PRIORITY:
        return PRIORITY.index(mkt)
    if mkt in AGGREGATORS:
        return 100 + AGGREGATORS.index(mkt)
    return 50


# ---------- matching / scoring (pure, covered by --selftest) ----------

def term_pattern(term):
    # Word-prefix match. Exceptions: a term starting with a symbol (".net") has no word start to anchor to, so it is
    # a substring; a 1-2 char term ("go", "ui") must be a whole word or it hits google/guide/etc.
    start = r"(?<!\w)" if re.match(r"\w", term) else ""
    end = r"s?(?!\w)" if len(term) <= 2 else ""
    return re.compile(start + re.escape(term) + end)


def score(plugin, patterns):
    """Return (terms matched anywhere, terms matched in name/keywords/description, summed best-field weights).

    Plugin fields are lowercase. Terms hit only through inner components are counted separately because a
    giant bundle matches almost every term that way.
    """
    hits = direct = total = 0
    for term, pat in patterns:
        best = 0
        for field, weight in FIELDS:
            text = plugin[field]
            # Substring test first: it is far cheaper than the regex over the large "comp" text.
            if term in text and pat.search(text):
                best = weight
                break
        if best:
            hits += 1
            direct += best > 1
            total += best
    return hits, direct, total


def quality(plugin):
    q = math.log10(plugin["installs"] + 1) if plugin.get("installs") else 0.0
    return q + {"anthropic": 2, "partner": 1}.get(plugin.get("reviewed"), 0)


def sort_key(plugin):
    tokens = plugin["tokens"] if plugin.get("tokens") is not None else 10 ** 9
    return (-plugin["direct"], -plugin["hits"], -plugin["weight"], -quality(plugin), tokens)


def dedup(plugins, keyfn=lambda p: p["name"].lower()):
    """Keep one entry per key (highest-priority marketplace, then shorter name), counting the others."""
    best = {}
    for p in plugins:
        key = keyfn(p)
        cur = best.get(key)
        if cur is None:
            best[key] = dict(p, copies=p.get("copies", 0))
        else:
            copies = cur["copies"] + p.get("copies", 0) + 1
            installed = p["installed"] or cur["installed"]
            if (mkt_rank(p["mkt"]), len(p["name"])) < (mkt_rank(cur["mkt"]), len(cur["name"])):
                cur = best[key] = dict(p)
            cur["copies"], cur["installed"] = copies, installed
    return list(best.values())


def desc_key(p):
    # Renamed copies (e.g. python@han vs jutsu-python@han) share a description; short ones are too generic to merge.
    d = " ".join(p.get("desc", "").lower().split())
    return d if len(d) >= 40 else ("name", p["name"].lower())


def search(plugins, terms):
    patterns = [(t, term_pattern(t)) for t in terms]
    found = []
    for p in plugins:
        hits, direct, weight = score(p, patterns)
        if hits:
            found.append(dict(p, hits=hits, direct=direct, weight=weight))
    return sorted(dedup(dedup(found), desc_key), key=sort_key)


# ---------- indexing of the on-disk marketplaces ----------

def read_head(path, size=3000):
    with path.open(encoding="utf-8") as f:
        return f.read(size)


def front_field(text, field):
    """Rough YAML frontmatter reader: quoted, plain, multi-line plain and >/| block values."""
    text = text.lstrip("﻿").replace("\r\n", "\n")
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    lines = text[3:end if end > 0 else len(text)].split("\n")
    for i, line in enumerate(lines):
        m = re.match(rf"{field}\s*:\s*(.*)$", line)
        if not m:
            continue
        value = m.group(1).strip()
        block = re.match(r"[>|][+-]?\d*$", value)
        parts = [] if block else [value]
        for nxt in lines[i + 1:]:
            if nxt.strip() and not nxt[0].isspace():
                break
            parts.append(nxt.strip())
        joined = " ".join(p for p in parts if p)
        if len(joined) > 1 and joined[0] == joined[-1] and joined[0] in "\"'":
            joined = joined[1:-1]
        return joined
    return ""


def repo_key(url, path=""):
    u = url.strip().lower()
    u = re.sub(r"^(https?://(www\.)?github\.com/|git@github\.com:)", "", u)
    u = u.removesuffix("/").removesuffix(".git").removesuffix("/")
    p = (path or "").strip().strip("/").lower()
    p = p.removeprefix("./")
    return f"{u}#{'' if p == '.' else p}"


def as_text(value):
    if isinstance(value, (list, tuple)):
        return " ".join(str(v) for v in value)
    return str(value or "")


def scan_plugin(pdir, skill_paths):
    """Return (components {(kind, name): description}, skipped file count) for a vendored plugin dir."""
    comps = {}
    skipped = 0

    def add(kind, name, path):
        nonlocal skipped
        try:
            comps.setdefault((kind, name), front_field(read_head(path), "description"))
        except (OSError, ValueError):
            skipped += 1

    for root in [pdir / s for s in skill_paths] or [pdir]:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            if "SKILL.md" in filenames:
                d = Path(dirpath)
                add("skill", d.name, d / "SKILL.md")
    if not skill_paths:
        for kind in ("agent", "command"):
            for f in (pdir / f"{kind}s").glob("*.md"):
                add(kind, f.stem, f)
        # Some marketplaces (voltagent) keep subagents as loose .md files in the plugin root.
        for f in pdir.glob("*.md"):
            try:
                head = read_head(f)
            except (OSError, ValueError):
                skipped += 1
                continue
            if front_field(head, "name") and front_field(head, "description"):
                comps.setdefault(("agent", f.stem), front_field(head, "description"))
    return comps, skipped


def vendored_dir(root, mdir, src, skills):
    """Resolve a relative plugin source to (plugin dir, skill dirs), or None if it is external/missing/outside."""
    try:
        pdir = (mdir / src).resolve()
        # Manifests are third-party: never walk outside the marketplace checkout.
        if not (pdir.is_dir() and pdir.is_relative_to(root)):
            return None
        skills = skills if isinstance(skills, list) else []
        return pdir, [s for s in skills if isinstance(s, str) and (pdir / s).resolve().is_relative_to(root)]
    except (OSError, ValueError):
        return None


def build_marketplace(mdir, repo_url, pool):
    """Index one marketplace dir. Returns (compact plugin entries, skipped file count)."""
    try:
        manifest = json.loads((mdir / ".claude-plugin" / "marketplace.json").read_text(encoding="utf-8"))
        entries = manifest["plugins"]
    except (OSError, ValueError, KeyError, TypeError):
        return [], 1
    root = mdir.resolve()
    out = []
    jobs = []  # (entry, plugin manifest entry, plugin dir, scan future)
    for p in entries:
        if not isinstance(p, dict) or not p.get("name"):
            continue
        src = p.get("source")
        entry = {"n": str(p["name"]), "d": as_text(p.get("description"))[:400],
                 "k": " ".join(as_text(p.get(f)) for f in ("keywords", "tags", "category")).lower(),
                 "c": "", "t": None, "x": None, "r": ""}
        out.append(entry)
        if isinstance(src, dict):
            url = src.get("url") or (f"https://github.com/{src['repo']}" if src.get("repo") else "")
            if url:
                entry["r"] = repo_key(url, src.get("path", ""))
        elif isinstance(src, str) and (found := vendored_dir(root, mdir, src, p.get("skills"))):
            if repo_url:
                entry["r"] = repo_key(repo_url, Path(src).as_posix())
            jobs.append((entry, p, found[0], pool.submit(scan_plugin, *found)))
    skipped = 0
    for entry, p, pdir, future in jobs:
        comps, bad = future.result()
        skipped += bad
        counts = [sum(1 for k in comps if k[0] == kind) for kind in ("skill", "agent", "command")]
        hooks = (pdir / "hooks" / "hooks.json").is_file() or "hooks" in p
        mcp = (pdir / ".mcp.json").is_file() or "mcpServers" in p
        entry["c"] = "\n".join(f"{n} {d}"[:300] for (_, n), d in comps.items()).lower()
        entry["t"] = round(sum(len(n) + len(d) for (_, n), d in comps.items()) / 4)
        entry["x"] = counts + [int(hooks), int(mcp)]
    return out, skipped


def marketplace_key(mdir):
    """git HEAD sha of the checkout; marketplace.json mtime when there is no usable .git."""
    git = mdir / ".git"
    try:
        head = (git / "HEAD").read_text(encoding="utf-8").strip()
        if not head.startswith("ref: "):
            return head
        ref = head[5:]
        if (git / ref).is_file():
            return (git / ref).read_text(encoding="utf-8").strip()
        for line in (git / "packed-refs").read_text(encoding="utf-8").splitlines():
            if line.endswith(" " + ref):
                return line.split()[0]
    except OSError:
        pass
    return "mtime:" + str((mdir / ".claude-plugin" / "marketplace.json").stat().st_mtime_ns)


def marketplace_age_days(mdir):
    for f in (mdir / ".git" / "FETCH_HEAD", mdir / ".git" / "HEAD", mdir / ".claude-plugin" / "marketplace.json"):
        try:
            return (time.time() - f.stat().st_mtime) / 86400
        except OSError:
            continue
    return 0.0


def load_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def source_url(spec):
    if not isinstance(spec, dict):
        return ""
    return spec.get("url") or (f"https://github.com/{spec['repo']}" if spec.get("repo") else "")


def load_index(mdirs):
    """Return {marketplace: {"plugins": [...], "skipped": n}}, rebuilding only changed marketplaces."""
    known = load_json(PLUGINS / "known_marketplaces.json", {})
    old = load_json(INDEX, {})
    old = old.get("m", {}) if old.get("v") == SCHEMA else {}
    keys = {}
    stale = []
    for m in mdirs:
        repo = source_url(known.get(m.name, {}).get("source"))
        keys[m.name] = f"{marketplace_key(m)}|{repo}"
        if old.get(m.name, {}).get("key") != keys[m.name]:
            stale.append((m, repo))
    if stale:
        with ThreadPoolExecutor(max_workers=16) as pool:  # file reads release the GIL
            for m, repo in stale:
                plugins, skipped = build_marketplace(m, repo, pool)
                old[m.name] = {"key": keys[m.name], "plugins": plugins, "skipped": skipped}
    index = {m.name: old[m.name] for m in mdirs}
    if stale or len(old) != len(index):
        tmp = INDEX.with_name(f"{INDEX.name}.{os.getpid()}.tmp")
        try:
            tmp.write_bytes(json.dumps({"v": SCHEMA, "m": index}, separators=(",", ":")).encode("utf-8"))
            tmp.replace(INDEX)
        except OSError:
            # Best effort: parallel runs race on this file and a lost write only costs a rebuild next time.
            tmp.unlink(missing_ok=True)
    return index


# ---------- joining the official / directory / installed data ----------

def build_plugins(index):
    catalog = load_json(PLUGINS / "plugin-catalog-cache.json", {}).get("catalog", {}).get("plugins", {})
    reviewed = {}
    for item in load_json(PLUGINS / "plugin-directory-cache-v2.json", {}).get("listings", []):
        try:
            repo = item["source"]["repository"]
            by = item["checks"]["review"]
            kind = by["by"]["type"] if by["state"] == "done" else None
        except (KeyError, TypeError):
            continue
        if kind in ("anthropic", "partner"):
            key = repo_key(repo["url"], repo.get("path", ""))
            if reviewed.get(key) != "anthropic":
                reviewed[key] = kind
    installed = load_json(PLUGINS / "installed_plugins.json", {}).get("plugins", {})
    installed_names = {k.split("@")[0].lower() for k in installed}

    plugins = []
    for mkt, data in index.items():
        for e in data["plugins"]:
            p = {"name": e["n"], "nm": e["n"].lower(), "mkt": mkt, "desc": e["d"].lower(), "desc_raw": e["d"], "kw": e["k"],
                 "comp": e["c"], "tokens": e["t"], "exact": False, "counts": e["x"], "installs": None,
                 "reviewed": reviewed.get(e["r"]) if e["r"] else None,
                 "installed": e["n"].lower() in installed_names}
            cat = catalog.get(f"{e['n']}@{mkt}")
            if cat:
                comps = cat.get("components", {})
                always = [t.get("always_on") for t in (cat.get("tokens") or {}).values() if isinstance(t, dict)]
                p["tokens"] = max((a for a in always if a is not None), default=p["tokens"])
                p["exact"] = bool(always)
                p["installs"] = cat.get("unique_installs")
                p["counts"] = [len(comps.get(k) or []) for k in
                               ("skills", "agents", "commands", "hooks", "mcpServers")]
                names = "\n".join(c.get("name", "") for k in ("skills", "agents", "commands")
                                  for c in comps.get(k) or [] if isinstance(c, dict)).lower()
                p["comp"] = p["comp"] or names
            plugins.append(p)
    return plugins


# ---------- output ----------

def short_count(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(n)


def format_line(p, n_terms):
    tags = []
    if p["installed"]:
        tags.append("[INSTALLED]")
    if p["reviewed"]:
        tags.append(f"[reviewed:{p['reviewed']}]")
    if p["installs"]:
        tags.append(f"[{short_count(p['installs'])} installs]")
    if p["tokens"] is not None:
        tags.append(f"[{'' if p['exact'] else '~'}{p['tokens']} tok always-on]")
    if p["counts"]:
        s, a, c, h, m = p["counts"]
        tags.append(f"[S{s} A{a} C{c} H{h} M{m}]")
    desc = " ".join(p["desc_raw"].split())
    if len(desc) > 110:
        desc = desc[:107].rstrip() + "..."
    # "3+2/5": 3 terms hit the plugin itself, 2 more only via inner skills/agents/commands.
    via = p["hits"] - p["direct"]
    head = f"{p['direct']}{f'+{via}' if via else ''}/{n_terms} {p['name']}@{p['mkt']}"
    parts = [head, " ".join(tags), f"+{p['copies']} copies" if p["copies"] else ""]
    return "  ".join(x for x in parts if x) + f" — {desc}"


# ---------- self-check ----------

def selftest():
    def plug(name, mkt="m", **kw):
        base = {"name": name, "nm": name.lower(), "mkt": mkt, "desc": "", "kw": "", "comp": "", "tokens": None, "installs": None,
                "reviewed": None, "installed": False}
        base.update({k: v.lower() if isinstance(v, str) and k in ("desc", "kw", "comp") else v
                     for k, v in kw.items()})
        return base

    nextjs = [("next", term_pattern("next"))]
    assert score(plug("nextjs-dev"), nextjs) == (1, 1, 5), "word-prefix: next hits nextjs"
    assert score(plug("x", desc="uses MongoDB"), [("go", term_pattern("go"))]) == (0, 0, 0), "go must not hit mongo"
    assert score(plug("x", desc="google cloud"), [("go", term_pattern("go"))]) == (0, 0, 0), "go must not hit google"
    assert score(plug("x", desc="a go-based tool"), [("go", term_pattern("go"))]) == (1, 1, 2), "go hits the word go"
    assert score(plug("x", kw="asp.net core"), [(".net", term_pattern(".net"))]) == (1, 1, 3), "symbol-led term"
    assert score(plug("x", desc="a prefix scraper", comp="scraper"), [("scraper", term_pattern("scraper"))]) == (1, 1, 2)
    assert score(plug("x", comp="scraper"), [("scraper", term_pattern("scraper"))]) == (1, 0, 1), "comp-only hit"

    heavy = plug("prisma-pro")  # one term, name weight 5
    broad = plug("db-tools", desc="prisma and postgres helper")  # two terms, weight 2+2
    ranked = search([heavy, broad], ["prisma", "postgres"])
    assert [p["name"] for p in ranked] == ["db-tools", "prisma-pro"], "distinct terms beat raw weight"
    assert search([plug("zzz")], ["prisma"]) == [], "zero-term plugins dropped"
    bundle = plug("mega", comp="prisma postgres")  # matches every term, but only via inner components
    assert [p["name"] for p in search([bundle, broad], ["prisma", "postgres"])] == ["db-tools", "mega"], "bundle ranks below"

    tie_a = plug("a", desc="prisma", installs=10)
    tie_b = plug("b", desc="prisma", installs=100000)
    tie_c = plug("c", desc="prisma", installs=10, reviewed="anthropic")
    assert [p["name"] for p in search([tie_a, tie_b, tie_c], ["prisma"])] == ["b", "c", "a"], "quality tiebreak"
    cheap, costly = plug("d", desc="prisma", tokens=100), plug("e", desc="prisma", tokens=900)
    assert [p["name"] for p in search([costly, cheap], ["prisma"])] == ["d", "e"], "fewer tokens first"

    copies = [plug("Foo", "buildwithclaude", desc="prisma"), plug("foo", "claude-community", desc="prisma"),
              plug("foo", "claude-plugins-official", desc="prisma"), plug("foo", "some-new-marketplace", desc="prisma")]
    kept = search(copies, ["prisma"])
    assert len(kept) == 1 and kept[0]["mkt"] == "claude-plugins-official" and kept[0]["copies"] == 3, kept
    assert mkt_rank("claude-community") < mkt_rank("unknown") < mkt_rank("buildwithclaude")
    long_desc = "Advanced Python skills for type system and async patterns."
    renamed = search([plug("jutsu-python", "han", desc=long_desc), plug("python", "han", desc=long_desc),
                      plug("x", desc="prisma python"), plug("y", desc="prisma python")], ["python"])
    assert sorted((p["name"], p["copies"]) for p in renamed) == [("python", 1), ("x", 0), ("y", 0)], renamed

    assert front_field("---\nname: x\ndescription: >\n  folded\n  text\nother: 1\n---\n", "description") == "folded text"
    assert front_field('---\ndescription: "quoted: yes"\n---', "description") == "quoted: yes"
    assert front_field("no frontmatter", "description") == ""
    assert repo_key("https://github.com/Foo/Bar.git/", "./sub/") == repo_key("foo/bar", "sub") == "foo/bar#sub"
    print("selftest ok")


# ---------- main ----------

def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # -I ignores PYTHONIOENCODING; pipes default to cp1252
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("terms", nargs="*")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    terms = list(dict.fromkeys(t.lower() for t in args.terms if t.strip()))
    if not terms:
        print(__doc__.strip())
        return 0

    mdirs = sorted(d for d in (PLUGINS / "marketplaces").iterdir()
                   if (d / ".claude-plugin" / "marketplace.json").is_file())
    index = load_index(mdirs)
    results = search(build_plugins(index), terms)
    for p in results[:args.top]:
        print(format_line(p, len(terms)))
    if not results:
        print("no matches")
    skipped = sum(v["skipped"] for v in index.values())
    if skipped:
        print(f"skipped {skipped} unreadable files")
    ages = {m.name: marketplace_age_days(m) for m in mdirs}
    oldest = max(ages, key=ages.get)
    days = int(ages[oldest])
    print(f"catalog freshness: oldest marketplace {oldest} is {days} days old")
    if days > STALE_DAYS:
        print(f"Catalogs {days} days old: run claude plugin marketplace update")
    return 0


if __name__ == "__main__":
    sys.exit(main())
