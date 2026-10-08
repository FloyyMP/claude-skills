#Requires -Version 7
<#
.SYNOPSIS
  Print what this Claude Code session actually did, from its transcript on disk.

.DESCRIPTION
  Parses ~/.claude/projects/<cwd-slug>/<session-id>.jsonl (plus any subagent
  transcripts under <session-id>/subagents/) and reports, as evidence rather than
  recall: files edited (grouped by git repo), repos touched (with a live git-state
  snapshot), shell commands that wrote to disk or changed git state, background
  jobs, subagents, worktrees entered, files handed to the user, questions asked,
  skills invoked, schedulers, the last todo list, compaction count + tokens
  dropped, and the session temp dir. Port of session-facts.py.

  Read-only. Runs git plumbing (rev-parse, status, rev-list, stash/worktree list)
  against touched repos and nothing else.

.PARAMETER SessionId
  Defaults to $env:CLAUDE_CODE_SESSION_ID; failing that, the newest transcript is
  used and a warning is printed.

.PARAMETER Json
  Emit one JSON object instead of the human-readable report.
#>
[CmdletBinding()]
param(
    [string]$SessionId = $env:CLAUDE_CODE_SESSION_ID,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inv = [cultureinfo]::InvariantCulture
$projectsRoot = Join-Path $HOME '.claude' 'projects'
$ic = [Text.RegularExpressions.RegexOptions]::IgnoreCase

$gitWriteRx = [regex]::new('\bgit(\s+-[Cc]\s+\S+)*\s+(commit|push|stash\s+(push|pop|apply|drop|save)|stash\s*($|[;&|])|switch\s+-c|checkout\s+(-b|--)|worktree\s+add|rebase|merge|reset|branch\s+-[dDm]|tag\s+(?!-l)\S|cherry-pick|am|add|rm|mv|apply|restore|revert|pull|clean|init)\b', $ic)
# Writes the model does through the shell: redirects (not `->` / `>=`), in-place editors, heredoc scripts that write
# files, formatters/package managers that rewrite the tree, and the PowerShell file cmdlets.
$fsWriteRx = [regex]::new('(?<![\d\-=])>{1,2}\s*[^&\s=]|\bsed\s+-i\b|\bperl\s+-[a-z]*i|\brm\s|\bmv\s|\bcp\s|\btee\b|\bmkdir\b|\btouch\b|\bunlink\b|\bln\s+-s\b|\bchmod\b|\binstall\s+-|\bpatch\b|\.write_(text|bytes)\(|\bopen\([^)]*[''"][wax]b?\+?[''"]|--write\b|--fix\b|\b(npm|pnpm|yarn)\s+(install|i|add|ci|update)\b|\buv\s+(add|remove|lock|sync)\b|\bcargo\s+fmt\b|\bruff\s+format\b(?!\s+--check)|\b(Set-Content|Out-File|Add-Content|New-Item|Copy-Item|Move-Item|Remove-Item|Rename-Item)\b', $ic)
# Absolute paths in shell commands (/..., ~/..., $HOME/..., C:\..., quoted with spaces) - feeds shell-touched repo detection.
$pathRx = [regex]::new('(?<![\w/.])(?:/|~[/\\]|\$HOME[/\\]|\$\{HOME\}[/\\]|[A-Za-z]:[/\\])[^\s''"`|;&<>()]*|(?<=")(?:/|[A-Za-z]:[/\\])[^"]+(?=")|(?<='')(?:/|[A-Za-z]:[/\\])[^'']+(?='')')
# Relative targets too: `cd ../lib && ...`, `git -C other commit` - resolved against the record's cwd.
$cdRx = [regex]::new('(?:\bcd|\bSet-Location|\bPush-Location|\s-C)\s+(?:"([^"]+)"|''([^'']+)''|([^\s;&|)]+))')
$processRx = [regex]::new('\bnohup\b|\bsetsid\b|\bdisown\b|\bnpm\s+(run\s+)?(dev|start)\b|\bpnpm\s+(run\s+)?(dev|start)\b|\byarn\s+(dev|start)\b|\bgo\s+run\b|\buvicorn\b|\bflask\s+run\b|\bnext\s+(dev|start)\b|\bvite\b(?!\.config)|\bpython3?\s+-m\s+http\.server\b|\bssh\s+-[fN]|\bdocker(-compose|\s+compose)?\s+(run|up)\b|\bpm2\s+start\b|\btmux\s+new|\bscreen\s+-d|\bsystemd-run\b|\b(Start-Process|Start-Job)\b', $ic)
# A bare `&` backgrounds in bash but is the call operator in PowerShell, so only Bash commands get this check.
$bashAmpRx = [regex]::new('(?<![&>|])&(?![&>\d])')

function Norm-Ts($ts) { # ConvertFrom-Json turns ISO strings into DateTime; restore the transcript's format
    if ($ts -is [datetime]) { return $ts.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $inv) }
    if ($ts) { return [string]$ts }
    return $null
}
function Parse-Ts([string]$ts) { [DateTimeOffset]::Parse($ts, $inv) }
function Trunc([string]$s, [int]$n) { if ($s.Length -le $n) { $s } else { $s.Substring(0, $n - 3) + '...' } }
function One-Line([string]$s) { ($s -split '\s+' | Where-Object { $_ }) -join ' ' }
function Str($v) { if (-not $v) { '' } elseif ($v -is [datetime]) { Norm-Ts $v } else { [string]$v } }  # str(x or "")
function First-NonEmpty([Collections.IDictionary]$d, [string[]]$keys) {
    foreach ($k in $keys) { $v = $d[$k]; if ($null -ne $v -and ([string]$v).Trim()) { return [string]$v } }
    return $null
}
function To-JsonStr($v) { $v | ConvertTo-Json -Compress -Depth 20 }
function Expand-Home([string]$p) { $p -replace '^(~|\$HOME|\$\{HOME\})(?=[/\\])', $HOME.Replace('$', '$$') }
function Full-Path([string]$p) {
    if ($IsWindows -and $p -match '^/([A-Za-z])(/.*)?$') { $p = "$($Matches[1]):$($Matches[2] ?? '/')" } # Git Bash /c/... -> C:/...
    return [IO.Path]::GetFullPath($p)
}
function Real-Path([string]$p) {
    # ponytail: resolves a symlinked final component only; walk every component if nested links matter
    $full = Full-Path (Expand-Home $p)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkTarget) { $t = $item.ResolveLinkTarget($true); if ($t) { return $t.FullName } }
    return $full
}
function First-Uuid([string]$path) {
    foreach ($line in [IO.File]::ReadLines($path)) {
        try { $u = ($line | ConvertFrom-Json -AsHashtable -Depth 1024)['uuid'] } catch { continue }
        if ($u) { return $u }
    }
    return $null
}

# ---------- locate the transcript ----------
$warnings = [Collections.Generic.List[string]]::new()
if ($SessionId) {
    $transcript = Get-ChildItem -Path (Join-Path $projectsRoot '*' "$SessionId.jsonl") -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $transcript) { Write-Error "No transcript named $SessionId.jsonl under $projectsRoot"; exit 1 }
} else {
    $transcript = Get-ChildItem -Path (Join-Path $projectsRoot '*' '*.jsonl') -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $transcript) { Write-Error "No transcripts found under $projectsRoot"; exit 1 }
    $SessionId = $transcript.BaseName
    $warnings.Add("No session id given and `$CLAUDE_CODE_SESSION_ID unset; using newest transcript ($SessionId). With parallel sessions this may be the wrong one.")
}
$projectDir = $transcript.DirectoryName
# A resumed session gets a new id whose transcript copies the old history, but the old id keeps its
# subagents and tmp dir: siblings that start with the same record are the same session.
$ids = [Collections.Generic.List[string]]::new(); $ids.Add($SessionId)
$head = First-Uuid $transcript.FullName
foreach ($p in Get-ChildItem -LiteralPath $projectDir -Filter '*.jsonl' -File) {
    if ($p.BaseName -ne $SessionId -and $head -and (First-Uuid $p.FullName) -eq $head) { $ids.Add($p.BaseName) }
}
# Workflow agents nest under subagents/workflows/<run>/; journal.jsonl is the workflow's log, not an agent.
$subFiles = [string[]]@(foreach ($i in $ids) {
    $d = Join-Path $projectDir $i 'subagents'
    if (Test-Path -LiteralPath $d -PathType Container) {
        Get-ChildItem -LiteralPath $d -Filter '*.jsonl' -File -Recurse | Where-Object Name -ne 'journal.jsonl' | ForEach-Object FullName
    }
})
[Array]::Sort($subFiles, [StringComparer]::Ordinal)

# ---------- accumulators ----------
$edits = [ordered]@{}   # path -> @{ count; tools; sidechain }
$shell = [Collections.Generic.List[object]]::new(); $background = [Collections.Generic.List[object]]::new()
$agents = [Collections.Generic.List[object]]::new(); $schedulers = [Collections.Generic.List[object]]::new()
$worktrees = [Collections.Generic.List[object]]::new(); $handoffs = [Collections.Generic.List[object]]::new()
$questions = [Collections.Generic.List[object]]::new(); $skills = [Collections.Generic.List[object]]::new()
$lastTodos = $null
$tasks = [ordered]@{}; $pendingCreates = @{}   # TaskCreate/TaskUpdate (the todo tools since TodoWrite was retired)
$cwds = [Collections.Generic.List[string]]::new(); $branches = [Collections.Generic.List[string]]::new()
$shellPaths = [Collections.Generic.HashSet[string]]::new()
$agentIds = [Collections.Generic.HashSet[string]]::new()  # a fork's transcript opens with a replay of the Agent call that launched it
$firstTs = $null; $lastTs = $null
$compactions = 0; [long]$dropped = 0; $userTurns = 0; $assistantTurns = 0; $toolCalls = 0; $badLines = 0

function Add-Edit([string]$path, [string]$tool, [bool]$sidechain) {
    if (-not $path.Trim()) { return }
    $path = Real-Path $path  # a symlinked path and its target are one file
    if (-not $edits.Contains($path)) { $edits[$path] = @{ count = 0; tools = [Collections.Generic.HashSet[string]]::new(); sidechain = $false } }
    $e = $edits[$path]; $e.count++; [void]$e.tools.Add($tool); if ($sidechain) { $e.sidechain = $true }
}

function Tool-Use([string]$name, [Collections.IDictionary]$inp, $ts, [bool]$sidechain, [string]$cwd, $useId) {
    switch -Regex ($name) {
        '^(Edit|Write|MultiEdit)$' { Add-Edit (Str $inp['file_path']) $name $sidechain; return }
        '^NotebookEdit$' { Add-Edit (Str $inp['notebook_path']) $name $sidechain; return }
        '^(Bash|PowerShell)$' {
            $cmd = Str $inp['command']
            $flags = [Collections.Generic.List[string]]::new()
            if ($inp['run_in_background'] -eq $true) { $flags.Add('background') }
            if ($gitWriteRx.IsMatch($cmd)) { $flags.Add('git-write') }
            if ($fsWriteRx.IsMatch($cmd)) { $flags.Add('fs-write') }
            if ($processRx.IsMatch($cmd) -or ($name -eq 'Bash' -and $bashAmpRx.IsMatch($cmd))) { $flags.Add('process') }
            # cd / -C targets from EVERY command: `cd ../lib && ./fmt.sh` writes without any write-looking token.
            # Inclusion below still needs dirty/unpushed state, and PreExistingDirty separates the user's own WIP.
            foreach ($m in $cdRx.Matches($cmd)) {
                $g = @($m.Groups[1], $m.Groups[2], $m.Groups[3] | Where-Object Success)[0].Value
                $p = Expand-Home $g
                try { if ($cwd -and -not [IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::GetFullPath((Join-Path $cwd $p)) } } catch { continue }
                if ([IO.Path]::IsPathRooted($p)) { [void]$shellPaths.Add($p) }
            }
            if ($flags.Count) {
                foreach ($m in $pathRx.Matches($cmd)) { [void]$shellPaths.Add((Expand-Home $m.Value)) }
                $rec = [ordered]@{ Time = $ts; Tool = $name; Flags = ($flags -join ','); Sidechain = $sidechain; Command = (Trunc (One-Line $cmd) 180) }
                $shell.Add($rec)
                if ($flags -contains 'background') { $background.Add($rec) }
            }
            return
        }
        '^Agent$' {
            if ($useId -and $agentIds.Contains($useId)) { return }
            [void]$agentIds.Add([string]$useId)
            $iso = Str $inp['isolation']
            $agents.Add([ordered]@{ Time = $ts; Type = (Str $inp['subagent_type']); Description = (Str $inp['description']); Isolation = $iso; Sidechain = $sidechain })
            if ($iso -eq 'worktree') { $worktrees.Add([ordered]@{ Time = $ts; Tool = 'Agent(isolation:worktree)'; Detail = (Str $inp['description']) }) }
            return
        }
        '^(EnterWorktree|ExitWorktree)$' {
            $detail = (First-NonEmpty $inp @('path', 'name', 'branch', 'worktree', 'description')) ?? (To-JsonStr $inp)
            $worktrees.Add([ordered]@{ Time = $ts; Tool = $name; Detail = $detail }); return
        }
        '^SendUserFile$' {
            $p = First-NonEmpty $inp @('path', 'file_path', 'filePath', 'file')
            $handoffs.Add([ordered]@{ Time = $ts; Path = ($p ?? '(unknown path)'); Sidechain = $sidechain }); return
        }
        '^AskUserQuestion$' {
            $hdrs = @(if ($inp['questions'] -is [Collections.IList]) { foreach ($q in $inp['questions']) { if ($q -is [Collections.IDictionary]) { Str $q['header'] } } })
            $questions.Add([ordered]@{ Time = $ts; Headers = ($hdrs -join ', ') }); return
        }
        '^Skill$' { $skills.Add([ordered]@{ Time = $ts; Name = (Str $inp['skill']); Args = (Str $inp['args']) }); return }
        '^(CronCreate|ScheduleWakeup|Monitor|RemoteTrigger)$' {
            $summary = if ($inp['prompt']) { Str $inp['prompt'] } elseif ($inp['command']) { Str $inp['command'] } else { To-JsonStr $inp }
            $schedulers.Add([ordered]@{ Time = $ts; Tool = $name; Detail = (Trunc $summary 140) }); return
        }
        '^Workflow$|__preview_start$|__run_in_terminal$' {
            # Workflows run in the background; preview/terminal MCP tools start servers the window close kills.
            $detail = foreach ($k in 'scriptPath', 'name', 'command', 'script') { if ($inp[$k]) { Str $inp[$k]; break } }
            if (-not $detail) { $detail = To-JsonStr $inp }
            $background.Add([ordered]@{ Time = $ts; Tool = $name; Flags = 'background'; Sidechain = $sidechain; Command = "${name}: " + (Trunc (One-Line $detail) 160) })
            return
        }
        '^TodoWrite$' { if (-not $sidechain) { $script:lastTodos = $inp['todos'] }; return }
        '^TaskCreate$' { if (-not $sidechain -and $useId) { $pendingCreates[$useId] = (First-NonEmpty $inp @('subject', 'description')) ?? '' }; return }
        '^TaskUpdate$' {
            if ($sidechain) { return }
            $id = Str $inp['taskId']; if ($null -eq $inp['taskId']) { $id = 'None' }
            if (-not $tasks.Contains($id)) { $tasks[$id] = [ordered]@{ Status = 'pending'; Content = '(created before this transcript)' } }
            if ($inp['status']) { $tasks[$id].Status = Str $inp['status'] }
            if ($inp['subject']) { $tasks[$id].Content = Str $inp['subject'] }
        }
    }
}

function Read-Record([Collections.IDictionary]$r, [bool]$forceSidechain) {
    $typ = $r['type']; $ts = Norm-Ts $r['timestamp']
    if ($ts) {
        if (-not $script:firstTs -or [string]::CompareOrdinal($ts, $script:firstTs) -lt 0) { $script:firstTs = $ts }
        if (-not $script:lastTs -or [string]::CompareOrdinal($ts, $script:lastTs) -gt 0) { $script:lastTs = $ts }
    }
    if ($r['cwd'] -and -not $cwds.Contains([string]$r['cwd'])) { $cwds.Add([string]$r['cwd']) }
    if ($r['gitBranch'] -and -not $branches.Contains([string]$r['gitBranch'])) { $branches.Add([string]$r['gitBranch']) }
    $sidechain = $forceSidechain -or ($r['isSidechain'] -eq $true)

    if ($typ -eq 'worktree-state' -and $r['worktreeSession'] -is [Collections.IDictionary]) {  # `claude -w <name>` sessions
        $ws = $r['worktreeSession']
        $detail = "$(Str $ws['worktreePath']) (branch $(Str $ws['worktreeBranch']), from $(Str $ws['originalBranch']))"
        if (-not ($worktrees | Where-Object { $_.Detail -eq $detail })) { $worktrees.Add([ordered]@{ Time = $ts; Tool = 'claude --worktree'; Detail = $detail }) }
        return
    }
    if ($typ -eq 'system' -and $r['subtype'] -eq 'compact_boundary') {
        $script:compactions++
        $meta = $r['compactMetadata']
        if ($meta -is [Collections.IDictionary] -and $meta['cumulativeDroppedTokens']) {
            $script:dropped = [math]::Max($script:dropped, [long]$meta['cumulativeDroppedTokens'])
        }
        return
    }
    $msg = if ($r['message'] -is [Collections.IDictionary]) { $r['message'] } else { @{} }
    $content = $msg['content']
    if ($typ -eq 'user' -and -not $sidechain -and $content -is [Collections.IList] -and $pendingCreates.Count) {
        # TaskCreate's id only appears in its result: "Task #3 created successfully".
        foreach ($b in $content) {
            if ($b -is [Collections.IDictionary] -and $b['type'] -eq 'tool_result' -and $b['tool_use_id'] -and $pendingCreates.ContainsKey($b['tool_use_id'])) {
                $subject = $pendingCreates[$b['tool_use_id']]; $pendingCreates.Remove($b['tool_use_id'])
                if ((To-JsonStr $b['content']) -match 'Task #(\d+)') { $tasks[$Matches[1]] = [ordered]@{ Status = 'pending'; Content = $subject } }
            }
        }
    }
    if ($typ -eq 'user' -and -not $sidechain -and -not $r['isMeta']) {
        # Tool results come back as 'user' records too; count only real prompts.
        if ($content -is [string] -or ($content -is [Collections.IList] -and
                -not ($content | Where-Object { $_ -is [Collections.IDictionary] -and $_['type'] -eq 'tool_result' }))) { $script:userTurns++ }
    }
    if ($typ -ne 'assistant') { return }
    if (-not $sidechain) { $script:assistantTurns++ }
    if ($content -isnot [Collections.IList]) { return }
    foreach ($b in $content) {
        if ($b -isnot [Collections.IDictionary] -or $b['type'] -ne 'tool_use') { continue }
        $script:toolCalls++
        $inp = if ($b['input'] -is [Collections.IDictionary]) { $b['input'] } else { @{} }
        Tool-Use (Str $b['name']) $inp $ts $sidechain (Str $r['cwd']) $b['id']
    }
}

function Read-Transcript([string]$file, [bool]$forceSidechain) {
    foreach ($line in [IO.File]::ReadLines($file)) {
        if (-not $line.Trim()) { continue }
        try { $r = $line | ConvertFrom-Json -AsHashtable -Depth 1024 } catch { $script:badLines++; continue }
        if ($r -isnot [Collections.IDictionary]) { continue }
        try { Read-Record $r $forceSidechain } catch { $script:badLines++ }  # one odd record must not sink the whole report
    }
}

Read-Transcript $transcript.FullName $false
foreach ($sf in $subFiles) { Read-Transcript $sf $true }
$since = if ($firstTs) { (Parse-Ts $firstTs).UtcDateTime } else { $null }

# ---------- git helpers ----------
function Invoke-Git([string]$root, [string[]]$a) {
    $out = & git -C $root @a 2>$null
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = @($out | Where-Object { $_ -and $_.Trim() }) }
}
function Git-First($r) { if ($r.Ok -and $r.Out.Count) { $r.Out[0] } }

$repoCache = @{}
function Repo-Root([string]$path) {
    $d = if (Test-Path -LiteralPath $path -PathType Container) { $path } else { [IO.Path]::GetDirectoryName($path) }
    while ($d -and $d -ne '/' -and -not (Test-Path -LiteralPath $d -PathType Container)) { $d = [IO.Path]::GetDirectoryName($d) }  # the file's directory may have been deleted since
    if (-not $d) { return $null }
    if (-not $repoCache.ContainsKey($d)) {
        $top = Git-First (Invoke-Git $d @('rev-parse', '--show-toplevel'))
        $repoCache[$d] = if ($top) { [IO.Path]::GetFullPath($top) } else { $null }
    }
    return $repoCache[$d]
}

function Default-Branch([string]$root, [string]$branch) {
    # Offline: <remote>/HEAD, else <remote>/main|master. $null when unknown (never guess the current branch).
    $rem = (Git-First (Invoke-Git $root @('config', "branch.$branch.remote"))) ?? (Git-First (Invoke-Git $root @('remote')))
    if (-not $rem) { return $null }
    $b = Git-First (Invoke-Git $root @('symbolic-ref', '--short', "refs/remotes/$rem/HEAD"))
    if ($b) { return $b.Substring($rem.Length + 1) }
    foreach ($c in 'main', 'master') { if ((Invoke-Git $root @('rev-parse', '-q', '--verify', "refs/remotes/$rem/$c")).Ok) { return $c } }
    return $null
}

function Repo-State([string]$root) {
    $branch = (Git-First (Invoke-Git $root @('symbolic-ref', '--short', 'HEAD'))) ?? '(detached/unborn)'
    $porcelain = (Invoke-Git $root @('status', '--porcelain')).Out
    # Dirty paths untouched since the session started are the user's own work, not ours to commit.
    $pre = @(if ($since) { foreach ($l in $porcelain) {
        $f = Join-Path $root (($l.Substring(3) -split ' -> ')[-1].Trim('"'))
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f -Force).LastWriteTimeUtc -lt $since) { 1 }
    } }).Count
    $hasUp = (Invoke-Git $root @('rev-parse', '--abbrev-ref', '@{u}')).Ok
    $ahead = 0
    if ($hasUp) {
        $c = Git-First (Invoke-Git $root @('rev-list', '--count', '@{u}..HEAD')); if ($c) { $ahead = [int]$c }
    } elseif ((Invoke-Git $root @('remote')).Out.Count) {  # remote but no upstream: commits on no remote at all are still unpushed
        $c = Git-First (Invoke-Git $root @('rev-list', '--count', 'HEAD', '--not', '--remotes')); $ahead = if ($c) { [int]$c } else { 0 }
    }
    $default = Default-Branch $root $branch
    $unmerged = 0
    if ($default -and $branch -notin @($default, '(detached/unborn)')) {
        $c = Git-First (Invoke-Git $root @('rev-list', '--count', "$default..HEAD")); $unmerged = if ($c) { [int]$c } else { 0 }
    }
    [ordered]@{ Repo = $root; Branch = $branch; Default = $default; DirtyFiles = $porcelain.Count; PreExistingDirty = $pre
        HasUpstream = $hasUp; Ahead = $ahead; NotOnDefault = $unmerged; Stashes = (Invoke-Git $root @('stash', 'list')).Out.Count
        Worktrees = (Invoke-Git $root @('worktree', 'list')).Out.Count; ViaShell = $false }
}

$selfRepo = Repo-Root $PSScriptRoot

# ---------- group edits by git repo ----------
$byRepo = [ordered]@{}
foreach ($p in $edits.Keys) {
    $key = (Repo-Root $p) ?? '(not in a git repo)'
    if (-not $byRepo.Contains($key)) { $byRepo[$key] = [Collections.Generic.List[object]]::new() }
    $e = $edits[$p]
    $tools = [string[]]@($e.tools); [Array]::Sort($tools, [StringComparer]::Ordinal)
    $byRepo[$key].Add([ordered]@{ Path = $p; Edits = $e.count; Tools = ($tools -join '+'); Sidechain = $e.sidechain; Exists = (Test-Path -LiteralPath $p) })
}
$repos = [Collections.Generic.List[string]]::new()
foreach ($k in $byRepo.Keys) { if ($k -ne '(not in a git repo)') { $repos.Add($k) } }
$states = [Collections.Generic.List[object]]::new()
foreach ($r in $repos) { $states.Add((Repo-State $r)) }

# ---------- repos touched only through shell commands ----------
# sed -i / heredoc / git commit never show up as Edit/Write, so a repo changed that way would be skipped by
# Step 5. Candidates: every cwd, plus paths named (or cd'd into) by flagged shell commands. Kept only if the
# repo has something to land: dirty, unpushed, or a working branch not yet on its default branch.
$sortedPaths = [string[]]@($shellPaths); [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
foreach ($c in @($cwds) + $sortedPaths) {
    # Walk up to an existing ancestor: the command may have named a file it created or deleted.
    try { $p = Full-Path $c } catch { continue }
    while ($p -and -not (Test-Path -LiteralPath $p)) { $p = [IO.Path]::GetDirectoryName($p) }  # $null past the root
    if (-not $p -or $p -eq '/') { continue }
    $root = Repo-Root $p
    if (-not $root -or $repos.Contains($root) -or $root -eq $selfRepo) { continue }  # running this skill's own scripts isn't touching its repo
    $st = Repo-State $root
    if ($st.DirtyFiles -gt 0 -or $st.Ahead -gt 0 -or $st.NotOnDefault -gt 0) { $st.ViaShell = $true; $repos.Add($root); $states.Add($st) }
}

# ---------- session temp dir (/tmp/claude-<uid>/<slug>/<session-id>; %TEMP%\claude\... on Windows) ----------
$tmpRoot = if ($IsWindows) { Join-Path ($env:TEMP ?? $env:TMP ?? '') 'claude' } else { Join-Path ($env:TMPDIR ? $env:TMPDIR : '/tmp') "claude-$(& id -u)" }
$tmpHits = @(foreach ($i in $ids) { Get-ChildItem -Path (Join-Path $tmpRoot '*' $i) -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName })
if ($tmpHits) {
    $files = @(foreach ($h in $tmpHits) { Get-ChildItem -LiteralPath $h -File -Recurse -Force -ErrorAction SilentlyContinue })
    [long]$bytes = 0
    foreach ($f in $files) {  # follow symlinks (task .output files link to transcripts); broken links count 0
        if (-not $f.LinkTarget) { $bytes += $f.Length; continue }
        $t = $f.ResolveLinkTarget($true); if ($t -and $t.Exists -and $t -is [IO.FileInfo]) { $bytes += $t.Length }
    }
    $tmpdir = [ordered]@{ Path = $tmpHits[0]; Files = $files.Count; Bytes = $bytes; Missing = $false }
} else {
    $tmpdir = [ordered]@{ Path = (Join-Path $tmpRoot '<slug>' $SessionId); Files = 0; Bytes = 0; Missing = $true }
}

$todosWritten = $null -ne $lastTodos -or $tasks.Count -gt 0
$openTodos = [Collections.Generic.List[object]]::new()
if ($lastTodos -is [Collections.IList]) {
    foreach ($t in $lastTodos) { if ($t -is [Collections.IDictionary] -and $t['status'] -ne 'completed') { $openTodos.Add([ordered]@{ Status = $t['status']; Content = $t['content'] }) } }
}
foreach ($k in $tasks.Keys) {
    $t = $tasks[$k]
    if ($t.Status -notin 'completed', 'deleted') { $openTodos.Add([ordered]@{ Status = $t.Status; Content = $t.Content; Id = $k }) }
}

$idle = if ($lastTs) { [long][math]::Truncate(([DateTimeOffset]::UtcNow - (Parse-Ts $lastTs)).TotalSeconds) } else { $null }

$result = [ordered]@{
    SessionId = $SessionId; Transcript = $transcript.FullName; SubagentFiles = $subFiles.Count
    Started = $firstTs; LastActivity = $lastTs; IdleSeconds = $idle
    Cwd = @($cwds); GitBranches = @($branches); Compactions = $compactions; DroppedTokens = $dropped
    UserTurns = $userTurns; AssistantTurns = $assistantTurns; ToolCalls = $toolCalls
    UnparsedLines = $badLines; ReposTouched = @($repos); RepoState = @($states); EditsByRepo = $byRepo
    ShellOfInterest = @($shell); Background = @($background); Agents = @($agents); Worktrees = @($worktrees)
    Handoffs = @($handoffs); Questions = @($questions); Skills = @($skills); Schedulers = @($schedulers)
    OpenTodos = @($openTodos); TodosWritten = $todosWritten; SessionTmp = $tmpdir; Warnings = @($warnings)
}
if ($Json) { $result | ConvertTo-Json -Depth 20; exit 0 }

# ---------- human report ----------
function Fmt-Secs([long]$s) {  # spelled out: "(16s)" got reported as "about 16 minutes" in testing
    if ($s -ge 3600) { return "$([math]::Floor($s / 3600)) h $([math]::Floor(($s % 3600) / 60)) min" }
    if ($s -ge 60) { return "$([math]::Floor($s / 60)) min $($s % 60) sec" }
    return "$s sec"
}
function Fmt-Bytes([long]$n) {
    if ($n -ge 1MB) { return ($n / 1MB).ToString('0.0', $inv) + ' MB' }
    if ($n -ge 1KB) { return ($n / 1KB).ToString('0.0', $inv) + ' KB' }
    return "$n bytes"
}
function N([long]$n) { $n.ToString('N0', $inv) }

Write-Output "SESSION $SessionId"
Write-Output "  transcript : $($transcript.FullName)"
if ($subFiles.Count) { Write-Output "  subagents  : $($subFiles.Count) transcript(s) included" }
if ($firstTs -and $lastTs) {
    $s = (Parse-Ts $firstTs).ToLocalTime(); $e = (Parse-Ts $lastTs).ToLocalTime()
    Write-Output ('  span       : {0} -> {1}  ({2}), idle {3}' -f $s.ToString('yyyy-MM-dd HH:mm', $inv), $e.ToString('yyyy-MM-dd HH:mm', $inv),
        (Fmt-Secs ([long][math]::Truncate(($e - $s).TotalSeconds))), (Fmt-Secs $idle))
}
$line = "  turns      : $(N $userTurns) user / $(N $assistantTurns) assistant, $(N $toolCalls) tool calls, $compactions compaction(s)"
if ($compactions -and $dropped) { $line += ", ~$(N $dropped) tokens dropped (recall unreliable)" }
Write-Output $line
Write-Output "  cwd        : $($cwds -join '; ')"
if ($branches.Count) { Write-Output "  branches   : $($branches -join '; ')" }
if ($badLines) { Write-Output "  unparsed   : $badLines line(s) skipped" }
foreach ($w in $warnings) { Write-Output "  WARNING    : $w" }

Write-Output "`nFILES EDITED (Edit/Write/NotebookEdit): $($edits.Count)"
if (-not $edits.Count) { Write-Output '  none' }
foreach ($k in $byRepo.Keys) {
    Write-Output "  [$k]"
    $items = [object[]]$byRepo[$k].ToArray()
    [Array]::Sort($items, [Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Path, $y.Path) })
    foreach ($it in $items) {
        $tags = @(if ($it.Sidechain) { 'subagent' }) + @(if (-not $it.Exists) { 'MISSING NOW' })
        $tag = if ($tags) { "  <$($tags -join ', ')>" } else { '' }
        Write-Output "    $($it.Path)  ($($it.Edits)x $($it.Tools))$tag"
    }
}

Write-Output "`nREPOS TOUCHED: $($repos.Count)"
if (-not $repos.Count) { Write-Output '  none' }
foreach ($s in $states) {
    $up = if ($s.HasUpstream) { "ahead $($s.Ahead)" } else { 'no upstream' }
    $extra = @(if ($s.Stashes) { "$($s.Stashes) stash" }) + @(if ($s.Worktrees -gt 1) { "$($s.Worktrees) worktrees" })
    $via = if ($s.ViaShell) { '  <via shell - files not in FILES EDITED, use git status>' } else { '' }
    Write-Output "  $($s.Repo)$via"
    $pre = if ($s.PreExistingDirty) { " ($($s.PreExistingDirty) untouched since session start = user's own)" } else { '' }
    $nod = if ($s.NotOnDefault) { " · $($s.NotOnDefault) commit(s) not on $($s.Default)" } else { '' }
    Write-Output ("      on $($s.Branch) (default $($s.Default ?? 'unknown')) · dirty $($s.DirtyFiles)$pre · $up$nod" + $(if ($extra) { ' · ' + ($extra -join ', ') } else { '' }))
}

Write-Output "`nSHELL COMMANDS THAT WROTE / CHANGED GIT / LAUNCHED PROCESSES: $($shell.Count)"
foreach ($s in $shell) { Write-Output "  [$($s.Flags)]$(if ($s.Sidechain) { ' (subagent)' }) $($s.Command)" }
if (-not $shell.Count) { Write-Output '  none' }

function Section([string]$title, $items, [scriptblock]$fmt) {
    Write-Output "`n${title}: $(@($items).Count)"
    foreach ($it in $items) { Write-Output ('  ' + (& $fmt $it)) }
    if (-not @($items).Count) { Write-Output '  none' }
}
Section 'BACKGROUND COMMANDS (run_in_background)' $background { param($b) $b.Command }
Section 'SUBAGENTS LAUNCHED' $agents { param($x) "$(if ($x.Type) { $x.Type } else { 'general-purpose' }): $($x.Description)" + $(if ($x.Isolation) { " [isolation: $($x.Isolation)]" } else { '' }) }
Section 'WORKTREES ENTERED (EnterWorktree / Agent isolation:worktree)' $worktrees { param($w) "$($w.Tool): $($w.Detail)" }
Section 'FILES HANDED TO USER (SendUserFile)' $handoffs { param($h) $h.Path }
Section 'QUESTIONS ASKED (AskUserQuestion)' $questions { param($q) $q.Headers }
Section 'SKILLS INVOKED' $skills { param($s) $s.Name + $(if ($s.Args) { " $($s.Args)" } else { '' }) }
Section 'SCHEDULERS / WATCHES (CronCreate, ScheduleWakeup, Monitor, RemoteTrigger)' $schedulers { param($s) "$($s.Tool): $($s.Detail)" }

Write-Output ''
if (-not $todosWritten) {
    Write-Output 'TODO LIST: never written this session'
} else {
    $total = $(if ($lastTodos -is [Collections.IList]) { $lastTodos.Count } else { 0 }) + $tasks.Count
    Write-Output "TODO LIST: $($openTodos.Count) open of $total"
    foreach ($t in $openTodos) { Write-Output "  [$($t.Status)] $($t.Content)" }
}

Write-Output ''
if ($tmpdir.Missing) { Write-Output "SESSION TMP: $($tmpdir.Path) (does not exist)" }
else { Write-Output "SESSION TMP: $($tmpdir.Path)  ($($tmpdir.Files) file(s), $(Fmt-Bytes $tmpdir.Bytes))" }
