#!/usr/bin/env python3
"""Print what this Claude Code session actually did, from its transcript on disk.

Parses ~/.claude/projects/<cwd-slug>/<session-id>.jsonl (plus any subagent
transcripts under <session-id>/subagents/) and reports, as evidence rather than
recall: files edited (grouped by git repo, or classified when outside any repo),
repos touched (with a live git-state snapshot and the dirty paths the session
did not edit), external effects (git writes, installs, plugins, MCP, GitHub,
schedulers, registry/env, detached processes, deletes), background jobs,
subagents, worktrees entered, files handed to the user, questions asked, skills
invoked, schedulers, the last todo list, compaction count + tokens dropped, and
the session temp dir. Tool calls whose result was an error are excluded.

Writes no files. Runs git (rev-parse, status, rev-list, config, remote,
symbolic-ref, stash/worktree list) against touched repos with --no-optional-locks
(no index refresh) and nothing else.

Usage: session-facts.py [--session-id ID] [--json] [--brief]
  --session-id  defaults to $CLAUDE_CODE_SESSION_ID; failing that, the newest
                transcript is used and a warning is printed. [A-Za-z0-9_-] only.
  --json        emit one JSON object instead of the human-readable report.
  --brief       header, warnings, repos, outside-repo edits, external effects,
                counts and open todos only.
Exit codes: 0 = report produced (even with warnings), 1 = transcript not found,
unreadable or bad session id.
"""
import argparse
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
PROJECTS = os.path.join(CLAUDE, "projects")
WIN = os.name == "nt"
WARNINGS = []
NO_REPO = "(not in a git repo)"

GIT_WRITE_RX = re.compile(r"\bgit(\s+-[Cc]\s+\S+)*\s+(commit|push|stash\s+(push|pop|apply|drop|save)|stash\s*($|[;&|])|switch\s+-c|checkout\s+(-b|--)|worktree\s+add|rebase|merge|reset|branch\s+-[dDm]|tag\s+(?!-l)\S|cherry-pick|am|add|rm|mv|apply|restore|revert|pull|clean|init)\b", re.I)
# Writes the model does through the shell: redirects (not `->` / `>=`), in-place editors, heredoc scripts that write
# files, formatters/package managers that rewrite the tree, and the PowerShell file cmdlets.
FS_WRITE_RX = re.compile(r"(?<![\d\-=])>{1,2}\s*[^&\s=]|\bsed\s+-i\b|\bperl\s+-[a-z]*i|\brm\s|\bmv\s|\bcp\s|\btee\b|\bmkdir\b|\btouch\b|\bunlink\b|\bln\s+-s\b|\bchmod\b|\binstall\s+-|\bpatch\b|\.write_(text|bytes)\(|\bopen\([^)]*['\"][wax]b?\+?['\"]|--write\b|--fix\b|\b(npm|pnpm|yarn)\s+(install|i|add|ci|update)\b|\buv\s+(add|remove|lock|sync)\b|\bcargo\s+fmt\b|\bruff\s+format\b(?!\s+--check)|\b(Set-Content|Out-File|Add-Content|New-Item|Copy-Item|Move-Item|Remove-Item|Rename-Item|Expand-Archive)\b", re.I)
# Absolute paths in shell commands (/..., ~/..., $HOME/..., C:\..., quoted with spaces) - feeds shell-touched repo detection.
# Not after `scheme:` (https://host/x), and add_shell_path drops anything starting // or \\ (a UNC probe stalls for seconds).
PATH_RX = re.compile(r"""(?<![\w/.:\\])(?:/|~[/\\]|\$HOME[/\\]|\$\{HOME\}[/\\]|[A-Za-z]:[/\\])[^\s'"`|;&<>()]*|(?<=")(?:/|[A-Za-z]:[/\\])[^"]+(?=")|(?<=')(?:/|[A-Za-z]:[/\\])[^']+(?=')""")
# Relative targets too: `cd ../lib && ...`, `git -C other commit` - resolved against the record's cwd.
CD_RX = re.compile(r"""(?:\bcd|\bSet-Location|\bPush-Location|\s-C)\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|)]+))""")
PROCESS_RX = re.compile(r"\bnohup\b|\bsetsid\b|\bdisown\b|\bnpm\s+(run\s+)?(dev|start)\b|\bpnpm\s+(run\s+)?(dev|start)\b|\byarn\s+(dev|start)\b|\bgo\s+run\b|\buvicorn\b|\bflask\s+run\b|\bnext\s+(dev|start)\b|\bvite\b(?!\.config)|\bpython3?\s+-m\s+http\.server\b|\bssh\s+-[fN]|\bdocker(-compose|\s+compose)?\s+(run|up)\b|\bpm2\s+start\b|\btmux\s+new|\bscreen\s+-d|\bsystemd-run\b|\b(Start-Process|Start-Job)\b", re.I)
# A bare `&` backgrounds in bash but is the call operator in PowerShell, so only Bash commands get this check.
BASH_AMP_RX = re.compile(r"(?<![&>|])&(?![&>\d])")

# Shell command -> statements. Groups: 1 redirection (dropped), 2 separator, 3 word (quoted chunks stay inside it).
# Bash honours \" inside double quotes; in PowerShell a backslash is just a path character ("C:\dir\").
def _token_rx(dq):
    return re.compile(r"""(\d*>&-?\d*|&>>?)|(&&|\|\||[;|\n]|&)|((?:[^\s;&|"']|""" + dq + r"""|'[^']*')+)""")


TOKEN_RX = {"Bash": _token_rx(r'"(?:[^"\\]|\\.)*"'), "PowerShell": _token_rx(r'"[^"]*"')}
UNQUOTE_RX = re.compile(r"""\"([^\"]*)\"|'([^']*)'""")
HEREDOC_RX = re.compile(r"""(?<!<)<<-?\s*(['"]?)(\w+)\1([^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|$)""", re.S)
HERESTR_RX = re.compile(r"""@(['"])\n.*?\n\1@""", re.S)
SUBST_RX = re.compile(r"\$\([^()]*\)")
ENV_ASSIGN_RX = re.compile(r"[A-Za-z_]\w*=")
SKIP_WORDS = {"sudo", "env", "time", "command", "exec", "builtin", "{", "}", "(", ")", "!", "then", "do", "else", "elif", "if"}
SECRET_RX = re.compile(r"""(\bauthorization\s*[=:]\s*(?:(?:bearer|basic|token)\s+)?|(?:[\w.-]*(?:token|key|secret|passw(?:or)?d)[\w.-]*)\s*[=:]\s*|(?<![\w-])--?[\w-]*(?:token|key|secret|passw(?:or)?d)[\w-]*\s+|\bbearer\s+)("[^"]*"|'[^']*'|[^\s'"]+)""", re.I)
URL_CRED_RX = re.compile(r"(?<=://)[^/@\s]+@")
REG_ARG_RX = re.compile(r"(?i)(hk(cu|lm|cr|u|cc)[:\\]|hkey_|registry::)")
REG_CMDLETS = {"set-itemproperty", "new-itemproperty", "remove-itemproperty"}
WRAPPERS = {"bash": "Bash", "sh": "Bash", "zsh": "Bash", "pwsh": "PowerShell", "powershell": "PowerShell", "cmd": "PowerShell"}
DELETE_CMDS = {"rm", "rmdir", "del", "erase", "rd", "ri", "remove-item", "unlink"}
PS_VALUE_FLAGS = {"-filter", "-include", "-exclude", "-erroraction", "-ea"}  # Remove-Item switches that take a value
DEFERRED = {"Edit", "Write", "MultiEdit", "NotebookEdit", "Bash", "PowerShell", "Skill", "Agent"}  # wait for their tool_result

TMP_ROOT = ""        # set in main(): <tmp>/claude (POSIX: <tmp>/claude-<uid>)
SESSION_IDS = []


def parse_ts(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def warn(msg):
    if msg not in WARNINGS:
        WARNINGS.append(msg)


def find_transcript(session_id):
    if session_id:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
            sys.exit(f"Invalid session id {session_id!r}: only letters, digits, - and _ are allowed")
        hits = glob.glob(os.path.join(PROJECTS, "*", f"{session_id}.jsonl"))
        if not hits:
            sys.exit(f"No transcript named {session_id}.jsonl under {PROJECTS}")
        return hits[0], session_id
    hits = glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))
    if not hits:
        sys.exit(f"No transcripts found under {PROJECTS}")
    newest = max(hits, key=os.path.getmtime)
    sid = os.path.basename(newest)[:-6]
    warn(f"No session id given and $CLAUDE_CODE_SESSION_ID unset; using newest transcript ({sid}). With parallel sessions this may be the wrong one.")
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


def redact(s):
    return URL_CRED_RX.sub("<redacted>@", SECRET_RX.sub(r"\1<redacted>", s))


# ---------- paths ----------
def expand_home(p):
    return re.sub(r"^(~|\$HOME|\$\{HOME\})(?=[/\\])", lambda _: HOME, p)


def expand_env(p):
    def sub(m):
        name = next(g for g in m.groups() if g)
        return os.environ.get(name) or m.group(0)
    return re.sub(r"\$env:(\w+)|\$\{(\w+)\}|\$(\w+)|%(\w+)%", sub, p)


def full_path(p):
    if "\0" in p:
        raise ValueError("NUL in path")  # os.path accepts it; .NET (and the OS) don't
    p = expand_home(p)
    if WIN:
        m = re.match(r"^/([A-Za-z])(/.*)?$", p)  # Git Bash /c/... -> C:/...
        if m:
            p = f"{m[1].upper()}:{m[2] or '/'}"
        elif re.match(r"^/tmp(/|$)", p):  # Git Bash mounts /tmp on %TEMP%
            p = (os.environ.get("TEMP") or os.environ.get("TMP") or "") + p[4:]
    return os.path.abspath(p)


def real_path(p):  # a symlinked/junctioned path and its target are one file
    return os.path.realpath(full_path(p))


def rooted(p):
    return bool(re.match(r"[A-Za-z]:[/\\]|[/\\]", p)) if WIN else p.startswith("/")


def up_to(p, ok):
    """Nearest ancestor of p (p included) satisfying ok. A root is its own parent, so stop there."""
    while p and not ok(p):
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent
    return p or None


def under(p, d):
    p, d = os.path.normcase(p), os.path.normcase(d).rstrip("\\/")
    return p == d or p.startswith(d + os.sep)


def resolve_target(t, cur):
    t = expand_home(expand_env(t))
    if re.search(r"\$|%\w+%", t):  # an unexpanded variable: no way to know what it names
        return None
    if not rooted(t):
        if not cur:
            return None
        t = os.path.join(cur, t)
    return real_path(t)


# ---------- shell command -> external effects ----------
def statements(cmd, tool):
    """Split a shell command into (words, backgrounded) statements. Quotes keep words whole; heredoc bodies are dropped."""
    cmd = cmd.replace("\r\n", "\n")
    cmd = HEREDOC_RX.sub(r"\3", HERESTR_RX.sub("''", cmd))
    for _ in range(3):
        cmd = SUBST_RX.sub("SUBST", cmd)
    cmd = re.sub(r"`\n" if tool == "PowerShell" else r"\\\n", " ", cmd)  # line continuation
    out, cur = [], []
    for m in TOKEN_RX[tool].finditer(cmd):
        if m.group(1):
            continue
        if m.group(2) is not None:
            if cur:
                out.append((cur, tool == "Bash" and m.group(2) == "&"))
            cur = []
        else:
            cur.append(UNQUOTE_RX.sub(lambda q: q.group(1) if q.group(1) is not None else q.group(2), m.group(3)))
    if cur:
        out.append((cur, False))
    return out


def prog_name(w):
    return re.sub(r"(?i)\.(exe|cmd|bat|ps1|com)$", "", re.split(r"[\\/]", w.lstrip("({"))[-1])


def git_split(r):
    """git args -> (global options, subcommand, args)."""
    j = 0
    while j < len(r) and r[j].startswith("-"):
        j += 2 if r[j] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") else 1
    return r[:j], (r[j].lower() if j < len(r) else ""), r[j + 1:]


def git_writes(sub, args):
    pos = [x.lower() for x in args if not x.startswith("-")]
    fl = {x.lower() for x in args if x.startswith("-")}
    if sub in ("commit", "push", "merge", "rebase", "reset", "pull", "fetch", "cherry-pick", "revert", "am", "init"):
        return True
    if sub == "tag":
        return bool(pos) and not fl & {"-l", "--list"}
    if sub == "stash":
        return not pos or pos[0] not in ("list", "show")
    if sub == "config":
        return len(pos) > 1 or bool(fl & {"--unset", "--unset-all", "--add", "--replace-all", "--edit", "-e", "--remove-section", "--rename-section"})
    if sub == "worktree":
        return bool(pos) and pos[0] in ("add", "remove", "move", "prune", "lock", "unlock", "repair")
    if sub in ("checkout", "switch"):  # ponytail: a lone positional is taken as a branch; `git checkout <file>` also lands here
        return bool(fl & {"-b", "-c", "--orphan"}) or ("--" not in fl and len(pos) == 1 and pos[0] != ".")
    if sub == "branch":
        if fl & {"-a", "-r", "-l", "-v", "-vv", "--all", "--remotes", "--list", "--verbose", "--show-current", "--contains", "--merged", "--no-merged"}:
            return False
        return bool(pos) or bool(fl & {"-d", "-m", "-c", "--delete", "--move", "--copy", "--set-upstream-to", "-u", "--unset-upstream"})
    return False


def classify(name, r):
    """Effect kind of one statement (program name + args), or None when it stays inside the working tree."""
    if name in ("python", "python3", "py") and r[:2] == ["-m", "pip"]:
        name, r = "pip", r[2:]
    pos = [x.lower() for x in r if not x.startswith("-")]
    fl = {x.lower() for x in r if x.startswith("-")}
    p0, p1 = (pos + ["", ""])[:2]
    s = " ".join([name, *r]).lower()
    if fl & {"--help", "-h", "--version"}:
        return None
    if name == "git":
        _, sub, args = git_split(r)
        return "git-write" if git_writes(sub, args) else None
    if name in ("pip", "pip3", "pipx"):
        return "install" if p0 in ("install", "uninstall") else None
    if name == "uv":
        return "install" if p0 in ("pip", "tool") and p1 in ("install", "uninstall", "upgrade") else None
    if name in ("npm", "pnpm", "yarn"):
        return "install" if (p0 in ("install", "i", "add", "uninstall", "remove", "rm", "update", "up", "upgrade") and fl & {"-g", "--global"}) or p0 == "global" else None
    if name in ("winget", "choco", "scoop"):
        return "install" if p0 in ("install", "upgrade", "uninstall", "update", "remove") else None
    if name in ("cargo", "go"):
        return "install" if p0 == "install" else None
    if name == "claude":
        if p0 in ("plugin", "plugins"):
            return "plugin" if p1 in ("install", "uninstall", "enable", "disable", "update") or (p1 == "marketplace" and pos[2:3] and pos[2] in ("add", "remove", "rm", "update")) else None
        return "mcp" if p0 == "mcp" and p1 in ("add", "remove", "add-json") else None
    if name == "npx":
        return "skill" if p0.split("@")[0] == "skills" and p1 in ("add", "remove", "update") else None
    if name == "gh":
        if p0 in ("repo", "release", "pr", "issue"):
            return "github" if p1 in ("create", "edit", "delete") else None
        return "github" if p0 == "api" and re.search(r"(?i)(?:^|\s)(?:-X|--method)[=\s]*(POST|PUT|PATCH|DELETE)\b", " ".join(r)) else None
    if name == "schtasks":
        return "schedule" if {x.lower() for x in r} & {"/create", "/delete", "/change", "/end", "/run"} else None
    if name in ("register-scheduledtask", "unregister-scheduledtask", "set-scheduledtask", "enable-scheduledtask", "disable-scheduledtask"):
        return "schedule"
    if name == "crontab":
        return "schedule" if pos or fl - {"-l"} else None
    if name == "reg":
        return "registry" if p0 in ("add", "delete", "import") else None
    if name in REG_CMDLETS and any(REG_ARG_RX.match(x) for x in r):
        return "registry"
    if name == "setx" or ("setenvironmentvariable" in s and re.search(r"\b(user|machine)\b", s)):
        return "env"
    if name in DELETE_CMDS:
        return "delete"
    if name in ("nohup", "setsid", "disown", "start-process", "start-job"):
        return "process"
    return None


def delete_targets(r):
    out, take, skip = [], False, False
    for x in r:
        lx = x.lower()
        if take:
            out.append(x)
            take = False
        elif skip:
            skip = False
        elif lx in ("-path", "-literalpath"):
            take = True
        elif lx in PS_VALUE_FLAGS:
            skip = True
        elif x.startswith("-") or lx in ("/s", "/q", "/f", "/p", "/a"):
            continue
        else:
            out.append(x)
    return out


def tail(p, n=48):  # the end of a path is the part that names the target
    return p if len(p) <= n else "..." + p[3 - n:]


def summary(words):
    """One statement as <=100 chars: redirections and block braces dropped, secrets redacted."""
    keep, skip = [], False
    for x in words:
        if skip:
            skip = False
        elif re.fullmatch(r"\d*>>?|<", x):
            skip = True  # `> file`: drop the target too
        elif x not in ("{", "}") and not re.match(r"\d*[<>]", x):
            keep.append(x)
    return trunc(redact(" ".join(" ".join(keep).split())), 100)


def git_dir(g, cur):
    """Directory a git command acts in: its -C argument (resolved against cur) or cur."""
    d = next((g[j + 1] for j in range(len(g) - 1) if g[j] == "-C"), None)
    return (resolve_target(d, cur) or d) if d else cur


def shell_effects(cmd, tool, cwd, bg, depth=0):
    """-> ([(kind, summary)], resolved delete targets). Only commands that reach beyond the repo working tree."""
    fx, dels, cur, first = [], [], cwd, None
    for a, amp in statements(cmd, tool):
        if "{" in a:
            a = a[a.index("{") + 1:]
        i = 0
        while i < len(a) and (a[i].lower() in SKIP_WORDS or ENV_ASSIGN_RX.match(a[i])):
            i += 1
        if i == len(a):
            continue
        a = a[i:]
        disp, r = prog_name(a[0]), a[1:]
        name = disp.lower()
        if name in ("cd", "chdir", "set-location", "sl", "push-location", "pushd"):
            t = [x for x in r if not x.startswith("-")]
            if t:
                cur = resolve_target(t[0], cur)  # None for `cd $DIR`: where we are is unknown from here on
            continue
        first = first or [disp, *r]
        if name in WRAPPERS and depth < 2:
            k = next((j for j, x in enumerate(r) if x.lower() in ("-c", "-command", "/c")), None)
            if k is not None and k + 1 < len(r):
                f2, d2 = shell_effects(" ".join(r[k + 1:]), WRAPPERS[name], cur, False, depth + 1)
                fx += f2
                dels += d2
            continue
        kind = classify(name, r)
        if kind == "delete":
            raw = delete_targets(r)
            res = [resolve_target(t, cur) for t in raw]
            dels += [x for x in res if x]
            shown = [x for x in (res[j] or raw[j] for j in range(len(raw))) if not (rooted(x) and under_session_tmp(x))]
            if not raw or shown:
                tg = ", ".join(tail(os.path.normpath(x) if rooted(x) else x) for x in shown[:3]) + (f" (+{len(shown) - 3})" if len(shown) > 3 else "")
                fx.append(("delete", trunc(redact(f"{disp} {tg or '(piped)'}"), 100)))
            continue
        if kind is None and amp:
            kind = "process"
        if kind is None:
            continue
        words = [disp, *r]
        if kind == "git-write":
            g, sub, args = git_split(r)
            where = git_dir(g, cur)
            if where and rooted(where) and under_session_tmp(where):
                continue  # a scratch repo inside the session temp dir
            words = ["git", sub, *args]
            leaf = os.path.basename(os.path.normpath(where)) if where else ""
            if leaf and leaf != os.path.basename(HOME):
                words.append(f"({leaf})")
        fx.append((kind, summary(words)))
    if bg and depth == 0:
        fx.insert(0, ("process", summary(["background:", *(first or ["?"])[:6]])))
    return fx, dels


def under_session_tmp(p):
    if not TMP_ROOT or not under(p, TMP_ROOT):
        return False
    parts = os.path.normpath(os.path.relpath(p, TMP_ROOT)).split(os.sep)
    return len(parts) > 1 and parts[1] in SESSION_IDS


def glob_rx(pat):
    """A deleted path pattern -> regex matching it, anything inside it, and (for `dir/*`) its children."""
    pat = os.path.normcase(pat)
    body = "".join("[^\\\\/]*" if c == "*" else "." if c == "?" else re.escape(c) for c in pat)
    return re.compile(body.rstrip("\\/") + r"(?:[\\/].*)?$", re.S)


# ---------- transcript ----------
class Facts:
    def __init__(self):
        self.edits = {}  # path -> {count, tools, sidechain}
        self.effects, self.background, self.agents = [], [], []
        self.schedulers, self.worktrees, self.handoffs = [], [], []
        self.questions, self.skills = [], []
        self.last_todos = None
        self.tasks, self.pending_creates = {}, {}  # TaskCreate/TaskUpdate (the todo tools since TodoWrite was retired)
        self.cwds, self.branches = [], []
        self.shell_paths = set()
        self.deletes = []  # resolved targets of successful rm / Remove-Item calls (may hold wildcards)
        self.calls, self.errors = [], set()  # tool_use blocks wait until every tool_result has been seen
        self.asst_ids = set()
        self.agent_ids = set()  # a fork's transcript opens with a replay of the Agent call that launched it
        self.first_ts = self.last_ts = None
        self.compactions = self.dropped = self.user_turns = 0
        self.assistant_turns = self.tool_calls = self.bad_lines = 0

    def add_edit(self, path, tool, sidechain):
        if not path or not path.strip():
            return
        path = real_path(path)
        e = self.edits.setdefault(path, {"count": 0, "tools": set(), "sidechain": False})
        e["count"] += 1
        e["tools"].add(tool)
        e["sidechain"] |= sidechain

    def add_shell_path(self, p):
        if not p.replace("\\", "/").startswith("//"):  # URLs, Git Bash flags (taskkill //F) and regex debris look like UNC shares
            self.shell_paths.add(p)

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
        if typ == "user" and isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error") is True:
                    self.errors.add(b.get("tool_use_id"))
        if typ == "user" and not sidechain and isinstance(content, list) and self.pending_creates:
            # TaskCreate's id only appears in its result: "Task #3 created successfully".
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in self.pending_creates:
                    subject = self.pending_creates.pop(b["tool_use_id"])
                    m = re.search(r"Task #(\d+)", json.dumps(b.get("content")))
                    if m:
                        self.tasks[m.group(1)] = {"Status": "pending", "Content": subject}
        if typ == "user" and not sidechain and not r.get("isMeta") and not r.get("isCompactSummary"):
            # Tool results come back as 'user' records too; count only real prompts (not task notifications,
            # interrupt markers or the compaction summary).
            if isinstance(content, str) or (
                isinstance(content, list)
                and not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
            ):
                text = content if isinstance(content, str) else next(
                    (str(b.get("text") or "") for b in content if isinstance(b, dict) and b.get("type") == "text"), "")
                if not text.lstrip().startswith(("<task-notification>", "[Request interrupted by user", "This session is being continued from a previous conversation")):
                    self.user_turns += 1
        if typ != "assistant":
            return
        if not sidechain:  # one message is several records (one per content block) sharing message.id
            if msg.get("id"):
                self.asst_ids.add(msg["id"])
            else:
                self.assistant_turns += 1
        if not isinstance(content, list):
            return
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            self.tool_calls += 1
            name, inp = str(b.get("name") or ""), b.get("input") if isinstance(b.get("input"), dict) else {}
            args = (name, inp, ts, sidechain, r.get("cwd") or "", b.get("id"))
            if name in DEFERRED:
                self.calls.append(args)
            else:
                self.tool_use(*args)

    def finish(self):
        for args in self.calls:
            try:
                self.tool_use(*args, failed=args[5] in self.errors)
            except (TypeError, ValueError, AttributeError, OSError):  # one odd call must not sink the whole report
                self.bad_lines += 1
        self.calls = []
        self.effects.sort(key=lambda e: e["Time"] or "")

    def tool_use(self, name, inp, ts, sidechain, cwd="", use_id=None, failed=False):
        if failed and name not in ("Bash", "PowerShell"):
            return  # refused / interrupted / errored: it did not happen
        if name in ("Edit", "Write", "MultiEdit"):
            self.add_edit(str(inp.get("file_path") or ""), name, sidechain)
        elif name == "NotebookEdit":
            self.add_edit(str(inp.get("notebook_path") or ""), name, sidechain)
        elif name in ("Bash", "PowerShell"):
            cmd = str(inp.get("command") or "")
            bg = inp.get("run_in_background") is True
            flags = ["background"] if bg else []
            if GIT_WRITE_RX.search(cmd):
                flags.append("git-write")
            if FS_WRITE_RX.search(cmd):
                flags.append("fs-write")
            if PROCESS_RX.search(cmd) or (name == "Bash" and BASH_AMP_RX.search(cmd)):
                flags.append("process")
            # cd / -C targets from EVERY command: `cd ../lib && ./fmt.sh` writes without any write-looking token.
            # Inclusion later still needs dirty/unpushed state, and PreExistingDirty separates the user's own WIP.
            for m in CD_RX.finditer(cmd):
                p = expand_home(next(g for g in m.groups() if g))
                if cwd and not rooted(p):
                    p = os.path.normpath(os.path.join(cwd, p))
                if rooted(p):
                    self.add_shell_path(p)
            if flags:
                for m in PATH_RX.finditer(cmd):
                    self.add_shell_path(expand_home(m.group(0)))
            if failed:
                return
            fx, dels = shell_effects(cmd, name, cwd, bg)
            self.effects += [{"Time": ts, "Kind": k, "Summary": s} for k, s in fx]
            self.deletes += dels
            if bg:
                self.background.append({"Time": ts, "Tool": name, "Flags": ",".join(flags), "Sidechain": sidechain,
                                        "Command": trunc(redact(" ".join(cmd.split())), 180)})
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
            text = str(inp.get("prompt") or inp.get("command") or json.dumps(inp))
            self.schedulers.append({"Time": ts, "Tool": name, "Detail": trunc(text, 140)})
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


# ---------- git ----------
GIT_ENV = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE")}  # an inherited GIT_DIR points every -C at one repo
GIT_OPTS = ["--no-optional-locks", "-c", "core.quotepath=false", "-c", "core.fsmonitor=false"]


def git(root, *args, probe=False):
    """-> (ok, stdout lines, first stderr line). A failed non-probe call adds a WARNING; probes (@{u}, config lookups) fail normally."""
    try:
        p = subprocess.run(["git", *GIT_OPTS, "-C", root, *args], capture_output=True, timeout=20, env=GIT_ENV)
        ok, out, err = p.returncode == 0, p.stdout, p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        ok, out, err = False, b"", "timed out after 20s"
    except OSError as e:
        ok, out, err = False, b"", str(e)
    err = next((l.strip() for l in err.splitlines() if l.strip()), "")
    if not ok and not probe:
        warn(f"git {args[0]} failed in {root}: {err or 'no output'}")
    return ok, [l for l in out.decode("utf-8", "replace").splitlines() if l.strip()], err


_repo_cache = {}
SELF_REPO = None


def find_dotgit(d):
    d = up_to(d, lambda x: os.path.exists(os.path.join(x, ".git")))
    return os.path.normpath(d) if d else None


def repo_root(path):
    d = up_to(path if os.path.isdir(path) else os.path.dirname(path), os.path.isdir)  # the file's directory may have been deleted since
    if not d:
        return None
    if d not in _repo_cache:
        # no .git above: skip the git process
        ok, out, err = git(d, "rev-parse", "--show-toplevel", probe=True) if find_dotgit(d) else (False, [], "not a git repository")
        if ok and out:
            root = os.path.normpath(out[0])
        elif "not a git repository" in err:
            root = None
        else:  # dubious ownership, unreadable .git, ...: the repo exists, git just won't talk to it
            root = find_dotgit(d)
            warn(f"git rev-parse failed in {d}: {err or 'no output'}" + (f" (treating {root} as a repo)" if root else ""))
        _repo_cache[d] = root
    return _repo_cache[d]


def default_branch(root, branch, remotes):
    """Offline: <remote>/HEAD, else <remote>/main|master. None when unknown (never guess the current branch)."""
    ok, out, _ = git(root, "config", f"branch.{branch}.remote", probe=True)
    rem = out[0] if ok and out else (remotes[0] if remotes else None)
    if not rem:
        return None
    ok, out, _ = git(root, "symbolic-ref", "--short", f"refs/remotes/{rem}/HEAD", probe=True)
    if ok and out:
        return out[0][len(rem) + 1:]
    for cand in ("main", "master"):
        if git(root, "rev-parse", "-q", "--verify", f"refs/remotes/{rem}/{cand}", probe=True)[0]:
            return cand
    return None


def repo_state(root, since_epoch, edited):
    bad = []

    def run(*a, probe=False):
        ok, out, _ = git(root, *a, probe=probe)
        if not ok and not probe:
            bad.append(a[0])
        return ok, out

    ok, out = run("symbolic-ref", "--short", "HEAD", probe=True)
    branch = out[0] if ok and out else "(detached/unborn)"
    st_ok, porcelain = run("status", "--porcelain")
    if not st_ok:  # git can't read this repo: one warning, no half-truths from the remaining calls
        return {"Repo": root, "Branch": branch, "Default": None, "DirtyFiles": None, "PreExistingDirty": 0, "HasUpstream": False,
                "Ahead": None, "NotOnDefault": None, "Stashes": None, "Worktrees": None, "ViaShell": False, "Unknown": True,
                "Unedited": [], "UneditedMore": 0}
    pre, unedited = 0, []
    for l in porcelain:
        rel = l[3:].split(" -> ")[-1].strip('"')
        full = os.path.normpath(os.path.join(root, rel))
        # Dirty paths untouched since the session started are the user's own work, not ours to commit.
        old = bool(since_epoch) and os.path.exists(full) and os.path.getmtime(full) < since_epoch
        pre += old
        key = os.path.normcase(full)
        if key not in edited and not (rel.endswith("/") and any(e.startswith(key + os.sep) for e in edited)):
            unedited.append({"Path": rel, "Status": l[:2].strip(), "Source": "pre-existing" if old else "via shell"})
    has_up = run("rev-parse", "--abbrev-ref", "@{u}", probe=True)[0]
    remotes = run("remote")[1]
    ahead = 0
    if has_up:
        ok, out = run("rev-list", "--count", "@{u}..HEAD")
        ahead = int(out[0]) if ok and out else 0
    elif remotes:  # remote but no upstream: commits on no remote at all are still unpushed
        ok, out = run("rev-list", "--count", "HEAD", "--not", "--remotes")
        ahead = int(out[0]) if ok and out else 0
    default = default_branch(root, branch, remotes)
    unmerged = 0
    if default and branch not in (default, "(detached/unborn)"):
        ok, out = run("rev-list", "--count", f"{default}..HEAD")
        unmerged = int(out[0]) if ok and out else 0
    stashes, worktrees = len(run("stash", "list")[1]), len(run("worktree", "list")[1])
    return {"Repo": root, "Branch": branch, "Default": default, "DirtyFiles": len(porcelain), "PreExistingDirty": pre,
            "HasUpstream": has_up, "Ahead": ahead, "NotOnDefault": unmerged, "Stashes": stashes,
            "Worktrees": worktrees, "ViaShell": False, "Unknown": bool(bad),
            "Unedited": unedited[:20], "UneditedMore": max(0, len(unedited) - 20)}


# ---------- formatting ----------
def fmt_dur(s):  # "45m 41s" / "37s" / "1h 2m": never "min" or "sec" (a bare "16s" was once read as 16 minutes)
    s = int(s)
    if s >= 3600:
        return f"{s // 3600}h {(s % 3600) // 60}m"
    if s >= 60:
        return f"{s // 60}m {s % 60}s"
    return f"{s}s"


def fmt_bytes(n):
    if n >= 1 << 20:
        return f"{n / (1 << 20):.1f} MB"
    if n >= 1 << 10:
        return f"{n / (1 << 10):.1f} KB"
    return f"{n} bytes"


def local_ts(ts, time_only=False):
    return parse_ts(ts).astimezone().strftime("%H:%M" if time_only else "%m-%d %H:%M") if ts else "??"


KIND_ORDER = ["memory", "global-config", "installed-skill", "other", "session-tmp"]
KIND_HINT = {"memory": "no commit; Step 6 handles memory",
             "global-config": "live config; apply to any mirror (Step 4)",
             "installed-skill": "installed copy: edit the source clone instead",
             "other": "outside any repo: save or clean up",
             "session-tmp": "scratch; Step 2 sweeps it"}


def main():
    ap = argparse.ArgumentParser(description="Print what this Claude Code session did, from its transcript.")
    ap.add_argument("--session-id", default=os.environ.get("CLAUDE_CODE_SESSION_ID"))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--brief", action="store_true")
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):  # piped stdout is cp1252 on Windows and chokes on non-ASCII paths
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    transcript, sid = find_transcript(a.session_id)
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

    # ---------- session temp dir (/tmp/claude-<uid>/<slug>/<session-id>; %TEMP%\claude\... on Windows) ----------
    global TMP_ROOT, SESSION_IDS
    if hasattr(os, "getuid"):
        tmp_root = os.path.join(os.environ.get("TMPDIR") or "/tmp", f"claude-{os.getuid()}")
    else:
        tmp_root = os.path.join(os.environ.get("TEMP") or os.environ.get("TMP") or "", "claude")
    TMP_ROOT, SESSION_IDS = os.path.realpath(tmp_root), ids
    tmp_hits = [h for i in ids for h in glob.glob(os.path.join(tmp_root, "*", i))]
    if tmp_hits:
        files = [os.path.join(dp, n) for h in tmp_hits for dp, _, ns in os.walk(h) for n in ns]
        tmpdir = {"Path": tmp_hits[0], "Files": len(files), "Bytes": sum(os.path.getsize(x) for x in files if os.path.isfile(x)),
                  "Missing": False}
    else:
        tmpdir = {"Path": os.path.join(tmp_root, "<slug>", sid), "Files": 0, "Bytes": 0, "Missing": True}

    f = Facts()
    try:
        f.read(transcript, False)
        for sf in sub_files:
            f.read(sf, True)
    except OSError as e:
        sys.exit(f"Cannot read transcript: {e}")
    f.finish()
    since = parse_ts(f.first_ts).timestamp() if f.first_ts else None
    global SELF_REPO
    script = os.path.abspath(__file__)
    # Running this skill's own scripts isn't touching its repo - but only the installed copy; from the clone itself that's real work.
    if any(under(script, d) for d in (os.path.join(CLAUDE, "skills"), os.path.join(HOME, ".agents", "skills"))):
        SELF_REPO = repo_root(os.path.dirname(os.path.realpath(__file__)))

    # ---------- group edits by git repo ----------
    del_rx = [glob_rx(d) for d in f.deletes]
    by_repo = {}
    for p, e in f.edits.items():
        key = repo_root(p) or NO_REPO
        exists = os.path.exists(p)
        deleted = not exists and any(rx.match(os.path.normcase(p)) for rx in del_rx)
        by_repo.setdefault(key, []).append({"Path": p, "Edits": e["count"], "Tools": "+".join(sorted(e["tools"])),
                                            "Sidechain": e["sidechain"], "Exists": exists, "Deleted": deleted})
    repos = [k for k in by_repo if k != NO_REPO]
    edited = {os.path.normcase(p) for p in f.edits}
    states = [repo_state(r, since, edited) for r in repos]

    # ---------- repos touched only through shell commands ----------
    # sed -i / heredoc / git commit never show up as Edit/Write, so a repo changed that
    # way would be skipped by Step 5. Candidates: every cwd, plus paths named (or cd'd
    # into) by flagged shell commands. Kept only if the repo has something to land:
    # dirty, unpushed, or a working branch not yet on its default branch.
    for c in list(f.cwds) + sorted(f.shell_paths):
        try:
            p = up_to(full_path(c), os.path.exists)  # the command may have named a file it created or deleted
        except ValueError:
            continue
        root = repo_root(p) if p else None
        if not root or root in repos or root == SELF_REPO:
            continue
        st = repo_state(root, since, edited)
        if st["Unknown"] or st["DirtyFiles"] or st["Ahead"] > 0 or st["NotOnDefault"] > 0:
            st["ViaShell"] = True
            repos.append(root)
            states.append(st)

    # ---------- edits outside any repo ----------
    settings_mem = None
    try:
        with open(os.path.join(CLAUDE, "settings.json"), encoding="utf-8") as fh:
            settings_mem = json.load(fh).get("autoMemoryDirectory")
    except (OSError, ValueError, AttributeError):
        pass
    mem_dir = real_path(settings_mem) if isinstance(settings_mem, str) and settings_mem else real_path(os.path.join(os.path.dirname(transcript), "memory"))
    skill_dirs = [real_path(os.path.join(CLAUDE, "skills")), real_path(os.path.join(HOME, ".agents", "skills"))]
    claude_real = os.path.normcase(real_path(CLAUDE))
    cfg_file = os.path.normcase(real_path(os.path.join(HOME, "AGENTS.md")))
    cfg_dirs = [real_path(os.path.join(HOME, ".codex")), real_path(os.path.join(CLAUDE, "scripts"))]

    def outside_kind(p):
        if under_session_tmp(p):
            return "session-tmp"
        if under(p, mem_dir):
            return "memory"
        if any(under(p, d) for d in skill_dirs):
            return "installed-skill"
        base = os.path.basename(p)
        if (os.path.normcase(os.path.dirname(p)) == claude_real and (base == "CLAUDE.md" or fnmatch.fnmatch(base, "settings*.json"))) \
                or os.path.normcase(p) == cfg_file or any(under(p, d) for d in cfg_dirs):
            return "global-config"
        return "other"

    outside = [{"Path": it["Path"], "Kind": outside_kind(it["Path"]), "Exists": it["Exists"], "Deleted": it["Deleted"]}
               for it in by_repo.get(NO_REPO, [])]

    open_todos, todos_written = [], f.last_todos is not None or bool(f.tasks)
    if isinstance(f.last_todos, list):
        open_todos = [{"Status": t.get("status"), "Content": t.get("content")}
                      for t in f.last_todos if isinstance(t, dict) and t.get("status") != "completed"]
    open_todos += [dict(t, Id=k) for k, t in f.tasks.items() if t["Status"] not in ("completed", "deleted")]

    idle = None
    if f.last_ts:
        idle = int((datetime.now(timezone.utc) - parse_ts(f.last_ts)).total_seconds())
    assistant_turns = f.assistant_turns + len(f.asst_ids)

    result = {
        "SessionId": sid, "Transcript": transcript, "SubagentFiles": len(sub_files),
        "Started": f.first_ts, "LastActivity": f.last_ts, "IdleSeconds": idle,
        "Cwd": f.cwds, "GitBranches": f.branches, "Compactions": f.compactions, "DroppedTokens": f.dropped,
        "UserTurns": f.user_turns, "AssistantTurns": assistant_turns, "ToolCalls": f.tool_calls,
        "UnparsedLines": f.bad_lines, "ReposTouched": repos, "RepoState": states, "EditsByRepo": by_repo,
        "OutsideRepoEdits": outside, "ExternalEffects": f.effects,
        "Background": f.background, "Agents": f.agents, "Worktrees": f.worktrees,
        "Handoffs": f.handoffs, "Questions": f.questions, "Skills": f.skills, "Schedulers": f.schedulers,
        "OpenTodos": open_todos, "TodosWritten": todos_written, "SessionTmp": tmpdir, "Warnings": WARNINGS,
    }
    if a.json:
        print(json.dumps(result, indent=2))
        return

    # ---------- human report ----------
    out = print
    brief = a.brief
    gap = "" if brief else "\n"  # --brief drops the blank lines between sections
    span = ""
    if f.first_ts and f.last_ts:
        s, e = parse_ts(f.first_ts).astimezone(), parse_ts(f.last_ts).astimezone()
        span = f"{s:%Y-%m-%d %H:%M} -> {e:%Y-%m-%d %H:%M}  ({fmt_dur((e - s).total_seconds())}), idle {fmt_dur(idle)}"
    turns = f"{f.user_turns:,} user / {assistant_turns:,} assistant, {f.tool_calls:,} tool calls, {f.compactions} compaction(s)"
    if f.compactions and f.dropped:
        turns += f", ~{f.dropped:,} tokens dropped (recall unreliable)"
    out(f"SESSION {sid}")
    if brief:
        out(f"  {span} | {f.compactions} compaction(s)" + (f", ~{f.dropped:,} tokens dropped (recall unreliable)" if f.compactions and f.dropped else ""))
    else:
        out(f"  transcript : {transcript}")
        if sub_files:
            out(f"  subagents  : {len(sub_files)} transcript(s) included")
        if span:
            out(f"  span       : {span}")
        out(f"  turns      : {turns}")
        out(f"  cwd        : {'; '.join(f.cwds)}")
        if f.bad_lines:
            out(f"  unparsed   : {f.bad_lines} line(s) skipped")
    for w in WARNINGS:
        out(f"WARNING: {w}")

    if not brief:
        out(f"\nFILES EDITED (Edit/Write/NotebookEdit): {len(f.edits)}")
        if not f.edits:
            out("  none")
        for k, items in by_repo.items():
            if k == NO_REPO:
                continue
            out(f"  [{k}]")
            for it in sorted(items, key=lambda x: x["Path"]):
                tags = (["subagent"] if it["Sidechain"] else []) + ([] if it["Exists"] else ["deleted" if it["Deleted"] else "MISSING NOW"])
                tag = f"  <{', '.join(tags)}>" if tags else ""
                out(f"    {it['Path']}  ({it['Edits']}x {it['Tools']}){tag}")

    out(f"{gap}REPOS TOUCHED: {len(repos)}")
    if not repos:
        out("  none")
    for s in states:
        up = f"ahead {s['Ahead']}" if s["HasUpstream"] else "no upstream"
        extra = ([f"{s['Stashes']} stash"] if s["Stashes"] else []) + ([f"{s['Worktrees']} worktrees"] if s["Worktrees"] and s["Worktrees"] > 1 else [])
        via = ("  <via shell>" if brief else "  <via shell - files not in FILES EDITED, use git status>") if s["ViaShell"] else ""
        out(f"  {s['Repo']}{via}")
        if s["Unknown"]:
            out("      state UNKNOWN (git failed, see WARNING) - check by hand, do not treat as clean")
        else:
            pre = f" ({s['PreExistingDirty']} untouched since session start = user's own)" if s.get("PreExistingDirty") else ""
            nod = f" | {s['NotOnDefault']} commit(s) not on {s['Default']}" if s.get("NotOnDefault") else ""
            out(f"      on {s['Branch']} (default {s['Default'] or 'unknown'}) | dirty {s['DirtyFiles']}{pre} | {up}{nod}"
                + (" | " + ", ".join(extra) if extra else ""))
        if s["Unedited"]:
            total = len(s["Unedited"]) + s["UneditedMore"]
            out(f"      dirty, not edited {'here' if brief else 'this session'} ({total}):")
            for u in s["Unedited"][:8 if brief else 20]:
                out(f"        {u['Status']} {u['Path']}  [{u['Source']}]")
            if total > (8 if brief else 20):
                out(f"        ... +{total - (8 if brief else 20)} more")

    out(f"{gap}OUTSIDE ANY REPO: {len(outside)}")
    if not outside:
        out("  none")
    for kind in KIND_ORDER:
        items = sorted((o for o in outside if o["Kind"] == kind), key=lambda x: x["Path"])
        if not items:
            continue
        out(f"  {kind} ({len(items)}) - {KIND_HINT[kind]}")
        if brief and kind in ("memory", "session-tmp"):  # only the count matters for these
            continue
        cap = 8 if brief else 25
        tags = [("" if o["Exists"] else (" <deleted>" if o["Deleted"] else " <MISSING NOW>")) for o in items[:cap]]
        if brief:  # names on one line; a repeated name gets its parent dir
            names = [os.path.basename(o["Path"]) for o in items[:cap]]
            names = [os.path.basename(os.path.dirname(o["Path"])) + "/" + n if names.count(n) > 1 else n for o, n in zip(items, names)]
            out("    " + ", ".join(n + g for n, g in zip(names, tags)) + (f", +{len(items) - cap}" if len(items) > cap else ""))
            continue
        for o, g in zip(items, tags):
            out(f"    {o['Path']}{g}")
        if len(items) > cap:
            out(f"    ... +{len(items) - cap} more")

    cap = 15 if brief else 30
    out(f"{gap}EXTERNAL EFFECTS: {len(f.effects)}")
    if not f.effects:
        out("  none")
    for x in f.effects[:cap]:
        out(f"  {local_ts(x['Time'], brief)} [{x['Kind']}] {trunc(x['Summary'], 62) if brief else x['Summary']}")
    if len(f.effects) > cap:
        out(f"  ... +{len(f.effects) - cap} more")

    def section(title, items, fmt):
        out(f"\n{title}: {len(items)}")
        for it in items:
            out("  " + fmt(it))
        if not items:
            out("  none")

    if brief:  # counts on one line, names only for what exists
        lists = [("background", f.background, lambda b: b["Command"]), ("subagents", f.agents, lambda x: x["Type"] or "general-purpose"),
                 ("worktrees", f.worktrees, lambda w: w["Detail"]), ("schedulers", f.schedulers, lambda s: s["Tool"])]
        out(f"{gap}COUNTS: " + " | ".join(f"{n} {len(i)}" for n, i, _ in lists))
        for n, i, fm in lists:
            tally = {}
            for it in i:
                k = trunc(fm(it), 40)
                tally[k] = tally.get(k, 0) + 1
            if i:
                out(f"  {n}: " + ", ".join(k + (f" x{c}" if c > 1 else "") for k, c in list(tally.items())[:6]) + (f", +{len(tally) - 6}" if len(tally) > 6 else ""))
    else:
        section("BACKGROUND COMMANDS (run_in_background)", f.background, lambda b: b["Command"])
        section("SUBAGENTS LAUNCHED", f.agents, lambda x: f"{x['Type'] or 'general-purpose'}: {x['Description']}"
                + (f" [isolation: {x['Isolation']}]" if x["Isolation"] else ""))
        section("WORKTREES ENTERED (EnterWorktree / Agent isolation:worktree)", f.worktrees, lambda w: f"{w['Tool']}: {w['Detail']}")
        section("FILES HANDED TO USER (SendUserFile)", f.handoffs, lambda h: h["Path"])
        section("QUESTIONS ASKED (AskUserQuestion)", f.questions, lambda q: q["Headers"])
        section("SKILLS INVOKED", f.skills, lambda s: s["Name"] + (f" {s['Args']}" if s["Args"] else ""))
        section("SCHEDULERS / WATCHES (CronCreate, ScheduleWakeup, Monitor, RemoteTrigger)", f.schedulers, lambda s: f"{s['Tool']}: {s['Detail']}")

    if not brief:
        out("")
    if not todos_written:
        out("TODO LIST: none written" if brief else "TODO LIST: never written this session")
    else:
        total = (len(f.last_todos) if isinstance(f.last_todos, list) else 0) + len(f.tasks)
        out(f"TODO LIST: {len(open_todos)} open of {total}")
        for t in open_todos:
            out(f"  [{t['Status']}] {t['Content']}")

    if not brief:
        out("")
        if tmpdir.get("Missing"):
            out(f"SESSION TMP: {tmpdir['Path']} (does not exist)")
        else:
            out(f"SESSION TMP: {tmpdir['Path']}  ({tmpdir['Files']} file(s), {fmt_bytes(tmpdir['Bytes'])})")


if __name__ == "__main__":
    main()
