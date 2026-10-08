#!/usr/bin/env python3
"""Print what this Claude Code session actually did, from its transcript on disk.

Parses ~/.claude/projects/<cwd-slug>/<session-id>.jsonl (plus any subagent
transcripts under <session-id>/subagents/) and reports, as evidence rather than
recall: files edited (grouped by git repo), repos touched (with a live git-state
snapshot), shell commands that wrote to disk or changed git state, background
jobs, subagents, worktrees entered, files handed to the user, questions asked,
skills invoked, schedulers, the last todo list, compaction count + tokens
dropped, and the session temp dir.

Read-only. Runs git plumbing (rev-parse, status, rev-list, stash/worktree list)
against touched repos and nothing else.

Usage: session-facts.py [--session-id ID] [--json]
  --session-id  defaults to $CLAUDE_CODE_SESSION_ID; failing that, the newest
                transcript is used and a warning is printed.
  --json        emit one JSON object instead of the human-readable report.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")

GIT_WRITE_RX = re.compile(r"\bgit(\s+-[Cc]\s+\S+)*\s+(commit|push|stash\s+(push|pop|apply|drop|save)|stash\s*($|[;&|])|switch\s+-c|checkout\s+(-b|--)|worktree\s+add|rebase|merge|reset|branch\s+-[dDm]|tag\s+(?!-l)\S|cherry-pick|am|add|rm|mv|apply|restore|revert|pull|clean|init)\b", re.I)
# Writes the model does through the shell: redirects (not `->` / `>=`), in-place editors, heredoc scripts that write
# files, formatters/package managers that rewrite the tree. Opus edits mostly this way, not via Edit/Write.
FS_WRITE_RX = re.compile(r"(?<![\d\-=])>{1,2}\s*[^&\s=]|\bsed\s+-i\b|\bperl\s+-[a-z]*i|\brm\s|\bmv\s|\bcp\s|\btee\b|\bmkdir\b|\btouch\b|\bunlink\b|\bln\s+-s\b|\bchmod\b|\binstall\s+-|\bpatch\b|\.write_(text|bytes)\(|\bopen\([^)]*['\"][wax]b?\+?['\"]|--write\b|--fix\b|\b(npm|pnpm|yarn)\s+(install|i|add|ci|update)\b|\buv\s+(add|remove|lock|sync)\b|\bcargo\s+fmt\b|\bruff\s+format\b(?!\s+--check)", re.I)
# Absolute paths in shell commands (/..., ~/..., $HOME/..., quoted with spaces) - feeds shell-touched repo detection.
PATH_RX = re.compile(r"""(?<![\w/.])(?:/|~/|\$HOME/|\$\{HOME\}/)[^\s'"`|;&<>()]*|(?<=")/[^"]+(?=")|(?<=')/[^']+(?=')""")
# Relative targets too: `cd ../lib && ...`, `git -C other commit` - resolved against the record's cwd.
CD_RX = re.compile(r"""(?:\bcd|\s-C)\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|)]+))""")
PROCESS_RX = re.compile(r"\bnohup\b|\bsetsid\b|\bdisown\b|(?<![&>|])&(?![&>\d])|\bnpm\s+(run\s+)?(dev|start)\b|\bpnpm\s+(run\s+)?(dev|start)\b|\byarn\s+(dev|start)\b|\bgo\s+run\b|\buvicorn\b|\bflask\s+run\b|\bnext\s+(dev|start)\b|\bvite\b(?!\.config)|\bpython3?\s+-m\s+http\.server\b|\bssh\s+-[fN]|\bdocker(-compose|\s+compose)?\s+(run|up)\b|\bpm2\s+start\b|\btmux\s+new|\bscreen\s+-d|\bsystemd-run\b", re.I)


def parse_ts(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def find_transcript(session_id, warnings):
    if session_id:
        hits = glob.glob(os.path.join(PROJECTS, "*", f"{session_id}.jsonl"))
        if not hits:
            sys.exit(f"No transcript named {session_id}.jsonl under {PROJECTS}")
        return hits[0], session_id
    hits = glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))
    if not hits:
        sys.exit(f"No transcripts found under {PROJECTS}")
    newest = max(hits, key=os.path.getmtime)
    sid = os.path.basename(newest)[:-6]
    warnings.append(f"No session id given and $CLAUDE_CODE_SESSION_ID unset; using newest transcript ({sid}). With parallel sessions this may be the wrong one.")
    return newest, sid


def first_uuid(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                u = json.loads(line).get("uuid")
            except (ValueError, AttributeError):
                continue
            if u:
                return u
    return None


def first_nonempty(d, keys):
    for k in keys:
        v = d.get(k)
        if v is not None and str(v).strip():
            return str(v)
    return None


def trunc(s, n):
    return s if len(s) <= n else s[: n - 3] + "..."


class Facts:
    def __init__(self):
        self.edits = {}  # path -> {count, tools, sidechain}
        self.shell, self.background, self.agents = [], [], []
        self.schedulers, self.worktrees, self.handoffs = [], [], []
        self.questions, self.skills = [], []
        self.last_todos = None
        self.tasks, self.pending_creates = {}, {}  # TaskCreate/TaskUpdate (the todo tools since TodoWrite was retired)
        self.cwds, self.branches = [], []
        self.shell_paths = set()
        self.agent_ids = set()  # a fork's transcript opens with a replay of the Agent call that launched it
        self.first_ts = self.last_ts = None
        self.compactions = self.dropped = self.user_turns = 0
        self.assistant_turns = self.tool_calls = self.bad_lines = 0

    def add_edit(self, path, tool, sidechain):
        if not path or not path.strip():
            return
        path = os.path.realpath(os.path.expanduser(path))  # a symlinked path and its target are one file
        e = self.edits.setdefault(path, {"count": 0, "tools": set(), "sidechain": False})
        e["count"] += 1
        e["tools"].add(tool)
        e["sidechain"] |= sidechain

    def read(self, path, force_sidechain):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    self.bad_lines += 1
                    continue
                if not isinstance(r, dict):
                    continue
                try:
                    self.record(r, force_sidechain)
                except (TypeError, ValueError, AttributeError):  # one odd record must not sink the whole report
                    self.bad_lines += 1

    def record(self, r, force_sidechain):
        typ, ts = r.get("type"), r.get("timestamp")
        if ts:
            if not self.first_ts or ts < self.first_ts:
                self.first_ts = ts
            if not self.last_ts or ts > self.last_ts:
                self.last_ts = ts
        if r.get("cwd") and r["cwd"] not in self.cwds:
            self.cwds.append(r["cwd"])
        if r.get("gitBranch") and r["gitBranch"] not in self.branches:
            self.branches.append(r["gitBranch"])
        sidechain = force_sidechain or r.get("isSidechain") is True

        if typ == "worktree-state" and isinstance(r.get("worktreeSession"), dict):  # `claude -w <name>` sessions
            ws = r["worktreeSession"]
            detail = f"{ws.get('worktreePath')} (branch {ws.get('worktreeBranch')}, from {ws.get('originalBranch')})"
            if not any(w["Detail"] == detail for w in self.worktrees):
                self.worktrees.append({"Time": ts, "Tool": "claude --worktree", "Detail": detail})
            return
        if typ == "system" and r.get("subtype") == "compact_boundary":
            self.compactions += 1
            meta = r.get("compactMetadata")
            if isinstance(meta, dict) and meta.get("cumulativeDroppedTokens"):
                self.dropped = max(self.dropped, int(meta["cumulativeDroppedTokens"]))
            return
        msg = r.get("message") if isinstance(r.get("message"), dict) else {}
        content = msg.get("content")
        if typ == "user" and not sidechain and isinstance(content, list) and self.pending_creates:
            # TaskCreate's id only appears in its result: "Task #3 created successfully".
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in self.pending_creates:
                    subject = self.pending_creates.pop(b["tool_use_id"])
                    m = re.search(r"Task #(\d+)", json.dumps(b.get("content")))
                    if m:
                        self.tasks[m.group(1)] = {"Status": "pending", "Content": subject}
        if typ == "user" and not sidechain and not r.get("isMeta"):
            # Tool results come back as 'user' records too; count only real prompts.
            if isinstance(content, str) or (
                isinstance(content, list)
                and not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
            ):
                self.user_turns += 1
        if typ != "assistant":
            return
        if not sidechain:
            self.assistant_turns += 1
        if not isinstance(content, list):
            return
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            self.tool_calls += 1
            self.tool_use(str(b.get("name") or ""), b.get("input") if isinstance(b.get("input"), dict) else {}, ts, sidechain,
                          r.get("cwd") or "", b.get("id"))

    def tool_use(self, name, inp, ts, sidechain, cwd="", use_id=None):
        if name in ("Edit", "Write", "MultiEdit"):
            self.add_edit(str(inp.get("file_path") or ""), name, sidechain)
        elif name == "NotebookEdit":
            self.add_edit(str(inp.get("notebook_path") or ""), name, sidechain)
        elif name in ("Bash", "PowerShell"):
            cmd = str(inp.get("command") or "")
            flags = []
            if inp.get("run_in_background") is True:
                flags.append("background")
            if GIT_WRITE_RX.search(cmd):
                flags.append("git-write")
            if FS_WRITE_RX.search(cmd):
                flags.append("fs-write")
            if PROCESS_RX.search(cmd):
                flags.append("process")
            # cd / -C targets from EVERY command: `cd ../lib && ./fmt.sh` writes without any write-looking token.
            # Inclusion below still needs dirty/unpushed state, and PreExistingDirty separates the user's own WIP.
            for m in CD_RX.finditer(cmd):
                p = re.sub(r"^(~|\$HOME|\$\{HOME\})(?=/)", lambda _: HOME, next(g for g in m.groups() if g))
                if cwd and not os.path.isabs(p):
                    p = os.path.normpath(os.path.join(cwd, p))
                if os.path.isabs(p):
                    self.shell_paths.add(p)
            if flags:
                for m in PATH_RX.finditer(cmd):
                    p = re.sub(r"^(~|\$HOME|\$\{HOME\})(?=/)", lambda _: HOME, m.group(0))
                    self.shell_paths.add(p)
                rec = {"Time": ts, "Tool": name, "Flags": ",".join(flags), "Sidechain": sidechain,
                       "Command": trunc(" ".join(cmd.split()), 180)}
                self.shell.append(rec)
                if "background" in flags:
                    self.background.append(rec)
        elif name == "Agent":
            if use_id and use_id in self.agent_ids:
                return
            self.agent_ids.add(use_id)
            iso = str(inp.get("isolation") or "")
            self.agents.append({"Time": ts, "Type": str(inp.get("subagent_type") or ""),
                                "Description": str(inp.get("description") or ""), "Isolation": iso, "Sidechain": sidechain})
            if iso == "worktree":
                self.worktrees.append({"Time": ts, "Tool": "Agent(isolation:worktree)", "Detail": str(inp.get("description") or "")})
        elif name in ("EnterWorktree", "ExitWorktree"):
            detail = first_nonempty(inp, ["path", "name", "branch", "worktree", "description"]) or json.dumps(inp)
            self.worktrees.append({"Time": ts, "Tool": name, "Detail": detail})
        elif name == "SendUserFile":
            p = first_nonempty(inp, ["path", "file_path", "filePath", "file"])
            self.handoffs.append({"Time": ts, "Path": p or "(unknown path)", "Sidechain": sidechain})
        elif name == "AskUserQuestion":
            qs = inp.get("questions") if isinstance(inp.get("questions"), list) else []
            hdrs = [str(q.get("header") or "") for q in qs if isinstance(q, dict)]
            self.questions.append({"Time": ts, "Headers": ", ".join(hdrs)})
        elif name == "Skill":
            self.skills.append({"Time": ts, "Name": str(inp.get("skill") or ""), "Args": str(inp.get("args") or "")})
        elif name in ("CronCreate", "ScheduleWakeup", "Monitor", "RemoteTrigger"):
            summary = str(inp.get("prompt") or inp.get("command") or json.dumps(inp))
            self.schedulers.append({"Time": ts, "Tool": name, "Detail": trunc(summary, 140)})
        elif name == "Workflow" or name.endswith(("__preview_start", "__run_in_terminal")):
            # Workflows run in the background; preview/terminal MCP tools start servers the window close kills.
            detail = str(inp.get("scriptPath") or inp.get("name") or inp.get("command") or inp.get("script") or json.dumps(inp))
            self.background.append({"Time": ts, "Tool": name, "Flags": "background", "Sidechain": sidechain,
                                    "Command": f"{name}: " + trunc(" ".join(detail.split()), 160)})
        elif name == "TodoWrite" and not sidechain:
            self.last_todos = inp.get("todos")
        elif name == "TaskCreate" and not sidechain and use_id:
            self.pending_creates[use_id] = str(inp.get("subject") or inp.get("description") or "")
        elif name == "TaskUpdate" and not sidechain:
            t = self.tasks.setdefault(str(inp.get("taskId")), {"Status": "pending", "Content": "(created before this transcript)"})
            if inp.get("status"):
                t["Status"] = str(inp["status"])
            if inp.get("subject"):
                t["Content"] = str(inp["subject"])


def git(root, *args):
    p = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return p.returncode == 0, lines


_repo_cache = {}
SELF_REPO = None


def repo_root(path):
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d and d != "/" and not os.path.isdir(d):  # the file's directory may have been deleted since
        d = os.path.dirname(d)
    if not d:
        return None
    if d not in _repo_cache:
        root = None
        if os.path.isdir(d):
            ok, out = git(d, "rev-parse", "--show-toplevel")
            if ok and out:
                root = out[0]
        _repo_cache[d] = root
    return _repo_cache[d]


def default_branch(root, branch):
    """Offline: <remote>/HEAD, else <remote>/main|master. None when unknown (never guess the current branch)."""
    ok, out = git(root, "config", f"branch.{branch}.remote")
    remotes = git(root, "remote")[1]
    rem = out[0] if ok and out else (remotes[0] if remotes else None)
    if not rem:
        return None
    ok, out = git(root, "symbolic-ref", "--short", f"refs/remotes/{rem}/HEAD")
    if ok and out:
        return out[0][len(rem) + 1:]
    for cand in ("main", "master"):
        if git(root, "rev-parse", "-q", "--verify", f"refs/remotes/{rem}/{cand}")[0]:
            return cand
    return None


def repo_state(root, since_epoch=None):
    ok, out = git(root, "symbolic-ref", "--short", "HEAD")
    branch = out[0] if ok and out else "(detached/unborn)"
    porcelain = git(root, "status", "--porcelain")[1]
    # Dirty paths untouched since the session started are the user's own work, not ours to commit.
    pre = sum(1 for l in porcelain if since_epoch and os.path.exists(os.path.join(root, l[3:].split(" -> ")[-1].strip('"')))
              and os.path.getmtime(os.path.join(root, l[3:].split(" -> ")[-1].strip('"'))) < since_epoch)
    has_up = git(root, "rev-parse", "--abbrev-ref", "@{u}")[0]
    ahead = 0
    if has_up:
        ok, out = git(root, "rev-list", "--count", "@{u}..HEAD")
        if ok and out:
            ahead = int(out[0])
    elif git(root, "remote")[1]:  # remote but no upstream: commits on no remote at all are still unpushed
        ok, out = git(root, "rev-list", "--count", "HEAD", "--not", "--remotes")
        ahead = int(out[0]) if ok and out else 0
    default = default_branch(root, branch)
    unmerged = 0
    if default and branch not in (default, "(detached/unborn)"):
        ok, out = git(root, "rev-list", "--count", f"{default}..HEAD")
        unmerged = int(out[0]) if ok and out else 0
    return {"Repo": root, "Branch": branch, "Default": default, "DirtyFiles": len(porcelain), "PreExistingDirty": pre,
            "HasUpstream": has_up, "Ahead": ahead, "NotOnDefault": unmerged, "Stashes": len(git(root, "stash", "list")[1]),
            "Worktrees": len(git(root, "worktree", "list")[1]), "ViaShell": False}


def fmt_secs(s):  # spelled out: "(16s)" got reported as "about 16 minutes" in testing
    s = int(s)
    if s >= 3600:
        return f"{s // 3600} h {(s % 3600) // 60} min"
    if s >= 60:
        return f"{s // 60} min {s % 60} sec"
    return f"{s} sec"


def fmt_bytes(n):
    if n >= 1 << 20:
        return f"{n / (1 << 20):.1f} MB"
    if n >= 1 << 10:
        return f"{n / (1 << 10):.1f} KB"
    return f"{n} bytes"


def main():
    ap = argparse.ArgumentParser(description="Print what this Claude Code session did, from its transcript.")
    ap.add_argument("--session-id", default=os.environ.get("CLAUDE_CODE_SESSION_ID"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    warnings = []
    transcript, sid = find_transcript(a.session_id, warnings)
    # A resumed session gets a new id whose transcript copies the old history, but the old id keeps its
    # subagents and tmp dir: siblings that start with the same record are the same session.
    ids = [sid]
    head = first_uuid(transcript)
    for p in glob.glob(os.path.join(os.path.dirname(transcript), "*.jsonl")):
        other = os.path.basename(p)[:-6]
        if other != sid and head and first_uuid(p) == head:
            ids.append(other)
    # Workflow agents nest under subagents/workflows/<run>/; journal.jsonl is the workflow's log, not an agent.
    sub_files = sorted(x for i in ids for x in glob.glob(os.path.join(os.path.dirname(transcript), i, "subagents", "**", "*.jsonl"),
                                                        recursive=True) if os.path.basename(x) != "journal.jsonl")

    f = Facts()
    f.read(transcript, False)
    for sf in sub_files:
        f.read(sf, True)
    since = parse_ts(f.first_ts).timestamp() if f.first_ts else None
    global SELF_REPO
    SELF_REPO = repo_root(os.path.dirname(os.path.realpath(__file__)))

    # ---------- group edits by git repo ----------
    by_repo = {}
    for p, e in f.edits.items():
        key = repo_root(p) or "(not in a git repo)"
        by_repo.setdefault(key, []).append({"Path": p, "Edits": e["count"], "Tools": "+".join(sorted(e["tools"])),
                                            "Sidechain": e["sidechain"], "Exists": os.path.exists(p)})
    repos = [k for k in by_repo if k != "(not in a git repo)"]
    states = [repo_state(r, since) for r in repos]

    # ---------- repos touched only through shell commands ----------
    # sed -i / heredoc / git commit never show up as Edit/Write, so a repo changed that
    # way would be skipped by Step 5. Candidates: every cwd, plus paths named (or cd'd
    # into) by flagged shell commands. Kept only if the repo has something to land:
    # dirty, unpushed, or a working branch not yet on its default branch.
    for c in list(f.cwds) + sorted(f.shell_paths):
        # Walk up to an existing ancestor: the command may have named a file it created or deleted.
        p = c
        while p and p != "/" and not os.path.exists(p):
            p = os.path.dirname(p)
        if not p or p == "/":
            continue
        root = repo_root(p)
        if not root or root in repos or root == SELF_REPO:  # running this skill's own scripts isn't touching its repo
            continue
        st = repo_state(root, since)
        if st["DirtyFiles"] > 0 or st["Ahead"] > 0 or st["NotOnDefault"] > 0:
            st["ViaShell"] = True
            repos.append(root)
            states.append(st)

    # ---------- session temp dir (/tmp/claude-<uid>/<slug>/<session-id>; %TEMP%\claude\... on Windows) ----------
    if hasattr(os, "getuid"):
        tmp_root = os.path.join(os.environ.get("TMPDIR") or "/tmp", f"claude-{os.getuid()}")
    else:
        tmp_root = os.path.join(os.environ.get("TEMP") or os.environ.get("TMP") or "", "claude")
    tmp_hits = [h for i in ids for h in glob.glob(os.path.join(tmp_root, "*", i))]
    if tmp_hits:
        files = [os.path.join(dp, n) for h in tmp_hits for dp, _, ns in os.walk(h) for n in ns]
        tmpdir = {"Path": tmp_hits[0], "Files": len(files), "Bytes": sum(os.path.getsize(x) for x in files if os.path.isfile(x)),
                  "Missing": False}
    else:
        tmpdir = {"Path": os.path.join(tmp_root, "<slug>", sid), "Files": 0, "Bytes": 0, "Missing": True}

    open_todos, todos_written = [], f.last_todos is not None or bool(f.tasks)
    if isinstance(f.last_todos, list):
        open_todos = [{"Status": t.get("status"), "Content": t.get("content")}
                      for t in f.last_todos if isinstance(t, dict) and t.get("status") != "completed"]
    open_todos += [dict(t, Id=k) for k, t in f.tasks.items() if t["Status"] not in ("completed", "deleted")]

    idle = None
    if f.last_ts:
        idle = int((datetime.now(timezone.utc) - parse_ts(f.last_ts)).total_seconds())

    result = {
        "SessionId": sid, "Transcript": transcript, "SubagentFiles": len(sub_files),
        "Started": f.first_ts, "LastActivity": f.last_ts, "IdleSeconds": idle,
        "Cwd": f.cwds, "GitBranches": f.branches, "Compactions": f.compactions, "DroppedTokens": f.dropped,
        "UserTurns": f.user_turns, "AssistantTurns": f.assistant_turns, "ToolCalls": f.tool_calls,
        "UnparsedLines": f.bad_lines, "ReposTouched": repos, "RepoState": states, "EditsByRepo": by_repo,
        "ShellOfInterest": f.shell, "Background": f.background, "Agents": f.agents, "Worktrees": f.worktrees,
        "Handoffs": f.handoffs, "Questions": f.questions, "Skills": f.skills, "Schedulers": f.schedulers,
        "OpenTodos": open_todos, "TodosWritten": todos_written, "SessionTmp": tmpdir, "Warnings": warnings,
    }
    if a.json:
        print(json.dumps(result, indent=2))
        return

    # ---------- human report ----------
    out = print
    out(f"SESSION {sid}")
    out(f"  transcript : {transcript}")
    if sub_files:
        out(f"  subagents  : {len(sub_files)} transcript(s) included")
    if f.first_ts and f.last_ts:
        s, e = parse_ts(f.first_ts).astimezone(), parse_ts(f.last_ts).astimezone()
        out(f"  span       : {s:%Y-%m-%d %H:%M} -> {e:%Y-%m-%d %H:%M}  ({fmt_secs((e - s).total_seconds())}), idle {fmt_secs(idle)}")
    line = f"  turns      : {f.user_turns:,} user / {f.assistant_turns:,} assistant, {f.tool_calls:,} tool calls, {f.compactions} compaction(s)"
    if f.compactions and f.dropped:
        line += f", ~{f.dropped:,} tokens dropped (recall unreliable)"
    out(line)
    out(f"  cwd        : {'; '.join(f.cwds)}")
    if f.branches:
        out(f"  branches   : {'; '.join(f.branches)}")
    if f.bad_lines:
        out(f"  unparsed   : {f.bad_lines} line(s) skipped")
    for w in warnings:
        out(f"  WARNING    : {w}")

    out(f"\nFILES EDITED (Edit/Write/NotebookEdit): {len(f.edits)}")
    if not f.edits:
        out("  none")
    for k, items in by_repo.items():
        out(f"  [{k}]")
        for it in sorted(items, key=lambda x: x["Path"]):
            tags = (["subagent"] if it["Sidechain"] else []) + ([] if it["Exists"] else ["MISSING NOW"])
            tag = f"  <{', '.join(tags)}>" if tags else ""
            out(f"    {it['Path']}  ({it['Edits']}x {it['Tools']}){tag}")

    out(f"\nREPOS TOUCHED: {len(repos)}")
    if not repos:
        out("  none")
    for s in states:
        up = f"ahead {s['Ahead']}" if s["HasUpstream"] else "no upstream"
        extra = ([f"{s['Stashes']} stash"] if s["Stashes"] else []) + ([f"{s['Worktrees']} worktrees"] if s["Worktrees"] > 1 else [])
        via = "  <via shell - files not in FILES EDITED, use git status>" if s["ViaShell"] else ""
        out(f"  {s['Repo']}{via}")
        pre = f" ({s['PreExistingDirty']} untouched since session start = user's own)" if s.get("PreExistingDirty") else ""
        nod = f" · {s['NotOnDefault']} commit(s) not on {s['Default']}" if s.get("NotOnDefault") else ""
        out(f"      on {s['Branch']} (default {s['Default'] or 'unknown'}) · dirty {s['DirtyFiles']}{pre} · {up}{nod}"
            + (" · " + ", ".join(extra) if extra else ""))

    out(f"\nSHELL COMMANDS THAT WROTE / CHANGED GIT / LAUNCHED PROCESSES: {len(f.shell)}")
    for s in f.shell:
        out(f"  [{s['Flags']}]{' (subagent)' if s['Sidechain'] else ''} {s['Command']}")
    if not f.shell:
        out("  none")

    def section(title, items, fmt):
        out(f"\n{title}: {len(items)}")
        for it in items:
            out("  " + fmt(it))
        if not items:
            out("  none")

    section("BACKGROUND COMMANDS (run_in_background)", f.background, lambda b: b["Command"])
    section("SUBAGENTS LAUNCHED", f.agents, lambda x: f"{x['Type'] or 'general-purpose'}: {x['Description']}"
            + (f" [isolation: {x['Isolation']}]" if x["Isolation"] else ""))
    section("WORKTREES ENTERED (EnterWorktree / Agent isolation:worktree)", f.worktrees, lambda w: f"{w['Tool']}: {w['Detail']}")
    section("FILES HANDED TO USER (SendUserFile)", f.handoffs, lambda h: h["Path"])
    section("QUESTIONS ASKED (AskUserQuestion)", f.questions, lambda q: q["Headers"])
    section("SKILLS INVOKED", f.skills, lambda s: s["Name"] + (f" {s['Args']}" if s["Args"] else ""))
    section("SCHEDULERS / WATCHES (CronCreate, ScheduleWakeup, Monitor, RemoteTrigger)", f.schedulers, lambda s: f"{s['Tool']}: {s['Detail']}")

    out("")
    if not todos_written:
        out("TODO LIST: never written this session")
    else:
        total = (len(f.last_todos) if isinstance(f.last_todos, list) else 0) + len(f.tasks)
        out(f"TODO LIST: {len(open_todos)} open of {total}")
        for t in open_todos:
            out(f"  [{t['Status']}] {t['Content']}")

    out("")
    if tmpdir.get("Missing"):
        out(f"SESSION TMP: {tmpdir['Path']} (does not exist)")
    else:
        out(f"SESSION TMP: {tmpdir['Path']}  ({tmpdir['Files']} file(s), {fmt_bytes(tmpdir['Bytes'])})")


if __name__ == "__main__":
    main()
