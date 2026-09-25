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
  dropped, and the scratchpad directory.

  Read-only. Runs git plumbing (rev-parse, status, rev-list, stash/worktree list)
  against touched repos and nothing else.

.PARAMETER SessionId
  The session UUID. Take it from the scratchpad path in the system prompt
  (.../claude/<slug>/<session-id>/scratchpad). If omitted, the newest transcript
  under ~/.claude/projects is used and a warning is printed - with parallel
  sessions that can be the wrong one.

.PARAMETER Json
  Emit a single JSON object instead of the human-readable report.
#>
[CmdletBinding()]
param(
    [string]$SessionId,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectsRoot = Join-Path $HOME '.claude' 'projects'

# ---------- locate the transcript ----------
$warnings = [System.Collections.Generic.List[string]]::new()
if ($SessionId) {
    $transcript = Get-ChildItem -Path $projectsRoot -Filter "$SessionId.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $transcript) { throw "No transcript named $SessionId.jsonl under $projectsRoot" }
} else {
    $transcript = Get-ChildItem -Path $projectsRoot -Filter '*.jsonl' -Recurse -File -Depth 1 -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.FullName -eq (Split-Path $_.FullName -Parent) -and $_.Directory.Parent.FullName -eq $projectsRoot } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $transcript) { throw "No transcripts found under $projectsRoot" }
    $SessionId = $transcript.BaseName
    $warnings.Add("No -SessionId given; using newest transcript ($SessionId). With parallel sessions this may be the wrong one.")
}
$projectDir = $transcript.Directory.FullName
$sessionDir = Join-Path $projectDir $SessionId
$subagentFiles = @()
if (Test-Path (Join-Path $sessionDir 'subagents')) {
    $subagentFiles = @(Get-ChildItem (Join-Path $sessionDir 'subagents') -Filter '*.jsonl' -File)
}

# ---------- accumulators ----------
$edits      = [ordered]@{}   # path -> @{ Count; Tools; Sidechain; First }
$shell      = [System.Collections.Generic.List[object]]::new()
$background  = [System.Collections.Generic.List[object]]::new()
$agents     = [System.Collections.Generic.List[object]]::new()
$schedulers = [System.Collections.Generic.List[object]]::new()
$worktrees  = [System.Collections.Generic.List[object]]::new()
$handoffs   = [System.Collections.Generic.List[object]]::new()
$questions  = [System.Collections.Generic.List[object]]::new()
$skills     = [System.Collections.Generic.List[object]]::new()
$lastTodos  = $null
$cwds       = [System.Collections.Generic.HashSet[string]]::new()
$branches   = [System.Collections.Generic.HashSet[string]]::new()
$firstTs = $null; $lastTs = $null
$compactions = 0; $droppedTokens = 0; $userTurns = 0; $assistantTurns = 0; $toolCalls = 0; $badLines = 0

$gitWriteRx = '(?i)\bgit\b.*\b(commit|push|stash|switch\s+-c|checkout\s+-b|worktree\s+add|rebase|merge|reset|branch\s+-[dDm]|tag|cherry-pick|am)\b'
$fsWriteRx  = '(?i)(?<!\d)>{1,2}\s*[^&\s]|\bsed\s+-i\b|\bSet-Content\b|\bOut-File\b|\bAdd-Content\b|\bNew-Item\b|\bCopy-Item\b|\bMove-Item\b|\bRemove-Item\b|\brm\s+-|\bmv\s|\bcp\s|\btee\b|\bmkdir\b|\bRename-Item\b|\btouch\b|\bunlink\b'
$processRx  = '(?i)\bStart-Process\b|\bStart-Job\b|\bnohup\b|&\s*$|\bnpm\s+(run\s+)?(dev|start)\b|\bpnpm\s+(run\s+)?dev\b|\byarn\s+dev\b|\bgo\s+run\b|\buvicorn\b|\bflask\s+run\b|\bnext\s+dev\b|\bvite\b|\bpython\s+-m\s+http\.server\b|\bssh\s+-[fN]'

function Add-Edit([string]$path, [string]$tool, [bool]$sidechain, [string]$ts) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (-not $edits.Contains($path)) {
        $edits[$path] = @{ Count = 0; Tools = [System.Collections.Generic.HashSet[string]]::new(); Sidechain = $false; First = $ts }
    }
    $e = $edits[$path]
    $e.Count++
    [void]$e.Tools.Add($tool)
    if ($sidechain) { $e.Sidechain = $true }
}

function First-NonEmpty([System.Collections.IDictionary]$h, [string[]]$keys) {
    foreach ($k in $keys) { if ($h.Contains($k) -and -not [string]::IsNullOrWhiteSpace([string]$h[$k])) { return [string]$h[$k] } }
    return $null
}

function Read-Transcript([string]$file, [bool]$forceSidechain) {
    foreach ($line in [System.IO.File]::ReadLines($file)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $r = $line | ConvertFrom-Json -Depth 64 -AsHashtable } catch { $script:badLines++; continue }
        $type = $r['type']
        $ts = $r['timestamp']
        if ($ts) {
            if (-not $script:firstTs -or $ts -lt $script:firstTs) { $script:firstTs = $ts }
            if (-not $script:lastTs  -or $ts -gt $script:lastTs)  { $script:lastTs  = $ts }
        }
        if ($r['cwd'])       { [void]$script:cwds.Add($r['cwd']) }
        if ($r['gitBranch']) { [void]$script:branches.Add($r['gitBranch']) }
        $sidechain = $forceSidechain -or ($r['isSidechain'] -eq $true)

        if ($type -eq 'system' -and $r['subtype'] -eq 'compact_boundary') {
            $script:compactions++
            $meta = $r['compactMetadata']
            if ($meta -is [System.Collections.IDictionary] -and $meta['cumulativeDroppedTokens']) {
                $v = [long]$meta['cumulativeDroppedTokens']
                if ($v -gt $script:droppedTokens) { $script:droppedTokens = $v }
            }
            continue
        }
        if ($type -eq 'user' -and -not $sidechain -and -not $r['isMeta']) {
            # Tool results come back as 'user' records too; count only real prompts.
            $uc = $r['message']?['content']
            $isPrompt = ($uc -is [string]) -or
                ($uc -is [System.Collections.IList] -and -not ($uc | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['type'] -eq 'tool_result' }))
            if ($isPrompt) { $script:userTurns++ }
        }
        if ($type -ne 'assistant') { continue }
        if (-not $sidechain) { $script:assistantTurns++ }

        $content = $r['message']?['content']
        if ($content -isnot [System.Collections.IList]) { continue }
        foreach ($b in $content) {
            if ($b -isnot [System.Collections.IDictionary] -or $b['type'] -ne 'tool_use') { continue }
            $script:toolCalls++
            $name = [string]$b['name']
            $in = $b['input']
            if ($in -isnot [System.Collections.IDictionary]) { $in = @{} }
            switch -Regex ($name) {
                '^(Edit|Write|MultiEdit)$' { Add-Edit ([string]$in['file_path']) $name $sidechain $ts }
                '^NotebookEdit$'          { Add-Edit ([string]$in['notebook_path']) $name $sidechain $ts }
                '^(Bash|PowerShell)$' {
                    $cmd = [string]$in['command']
                    $flags = [System.Collections.Generic.List[string]]::new()
                    if ($in['run_in_background'] -eq $true) { $flags.Add('background') }
                    if ($cmd -match $gitWriteRx) { $flags.Add('git-write') }
                    if ($cmd -match $fsWriteRx)  { $flags.Add('fs-write') }
                    if ($cmd -match $processRx)  { $flags.Add('process') }
                    if ($flags.Count -gt 0) {
                        $one = ($cmd -replace '\s+', ' ').Trim()
                        if ($one.Length -gt 180) { $one = $one.Substring(0, 177) + '...' }
                        $rec = [pscustomobject]@{ Time = $ts; Tool = $name; Flags = ($flags -join ','); Sidechain = $sidechain; Command = $one }
                        $script:shell.Add($rec)
                        if ($flags -contains 'background') { $script:background.Add($rec) }
                    }
                }
                '^Agent$' {
                    $iso = [string]$in['isolation']
                    $script:agents.Add([pscustomobject]@{
                        Time = $ts; Type = [string]$in['subagent_type']; Description = [string]$in['description']; Isolation = $iso; Sidechain = $sidechain })
                    if ($iso -eq 'worktree') {
                        $script:worktrees.Add([pscustomobject]@{ Time = $ts; Tool = 'Agent(isolation:worktree)'; Detail = [string]$in['description'] })
                    }
                }
                '^(EnterWorktree|ExitWorktree)$' {
                    $detail = First-NonEmpty $in @('path','name','branch','worktree','description')
                    if (-not $detail) { $detail = ($in | ConvertTo-Json -Compress -Depth 4) }
                    $script:worktrees.Add([pscustomobject]@{ Time = $ts; Tool = $name; Detail = $detail })
                }
                '^SendUserFile$' {
                    $p = First-NonEmpty $in @('path','file_path','filePath','file')
                    $script:handoffs.Add([pscustomobject]@{ Time = $ts; Path = ($p ?? '(unknown path)'); Sidechain = $sidechain })
                }
                '^AskUserQuestion$' {
                    $hdrs = @()
                    if ($in['questions'] -is [System.Collections.IList]) {
                        $hdrs = @($in['questions'] | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { [string]$_['header'] } })
                    }
                    $script:questions.Add([pscustomobject]@{ Time = $ts; Headers = ($hdrs -join ', ') })
                }
                '^Skill$' {
                    $script:skills.Add([pscustomobject]@{ Time = $ts; Name = [string]$in['skill']; Args = [string]$in['args'] })
                }
                '^(CronCreate|ScheduleWakeup|Monitor|RemoteTrigger)$' {
                    $summary = if ($in['prompt']) { [string]$in['prompt'] } elseif ($in['command']) { [string]$in['command'] } else { ($in | ConvertTo-Json -Compress -Depth 4) }
                    if ($summary.Length -gt 140) { $summary = $summary.Substring(0, 137) + '...' }
                    $script:schedulers.Add([pscustomobject]@{ Time = $ts; Tool = $name; Detail = $summary })
                }
                '^TodoWrite$' { if (-not $sidechain) { $script:lastTodos = $in['todos'] } }
            }
        }
    }
}

Read-Transcript $transcript.FullName $false
foreach ($sf in $subagentFiles) { Read-Transcript $sf.FullName $true }

# ---------- group edits by git repo ----------
$repoCache = @{}
function Get-RepoRoot([string]$path) {
    $dir = if (Test-Path -LiteralPath $path -PathType Container) { $path } else { Split-Path -Parent $path }
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    if ($repoCache.ContainsKey($dir)) { return $repoCache[$dir] }
    $root = $null
    if (Test-Path -LiteralPath $dir) {
        $out = & git -C $dir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { $root = ($out | Select-Object -First 1) -replace '/', '\' }
    }
    $repoCache[$dir] = $root
    return $root
}

$byRepo = [ordered]@{}
foreach ($p in $edits.Keys) {
    $root = Get-RepoRoot $p
    $key = if ($root) { $root } else { '(not in a git repo)' }
    if (-not $byRepo.Contains($key)) { $byRepo[$key] = [System.Collections.Generic.List[object]]::new() }
    $e = $edits[$p]
    $byRepo[$key].Add([pscustomobject]@{
        Path = $p; Edits = $e.Count; Tools = (($e.Tools | Sort-Object) -join '+'); Sidechain = $e.Sidechain
        Exists = (Test-Path -LiteralPath $p)
    })
}
$repos = @($byRepo.Keys | Where-Object { $_ -ne '(not in a git repo)' })

# ---------- live git state per touched repo ----------
function Get-RepoState([string]$root) {
    $branch = (& git -C $root symbolic-ref --short HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { $branch = '(detached/unborn)' }
    $dirty = @(& git -C $root status --porcelain 2>$null)
    $up = (& git -C $root rev-parse --abbrev-ref '@{u}' 2>$null | Select-Object -First 1)
    $hasUp = ($LASTEXITCODE -eq 0 -and $up)
    $ahead = 0
    if ($hasUp) {
        $c = (& git -C $root rev-list --count '@{u}..HEAD' 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $c) { $ahead = [int]$c }
    }
    $def = (& git -C $root symbolic-ref --short refs/remotes/origin/HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $def) { $def = $def -replace '^origin/', '' } else { $def = $null }
    $stashes = @(& git -C $root stash list 2>$null).Count
    $wt = @(& git -C $root worktree list 2>$null).Count
    [pscustomobject]@{
        Repo = $root; Branch = $branch; Default = $def; DirtyFiles = $dirty.Count
        HasUpstream = [bool]$hasUp; Ahead = $ahead; Stashes = $stashes; Worktrees = $wt
    }
}
$repoState = [System.Collections.Generic.List[object]]::new()
foreach ($r in $repos) { $repoState.Add((Get-RepoState $r)) }

# ---------- scratchpad ----------
$scratchpad = $null
$primaryCwd = if ($cwds.Count -gt 0) { ($cwds | Select-Object -First 1) } else { $null }
if ($primaryCwd) {
    $slug = $primaryCwd -replace '[:\\/]', '-'
    $cand = Join-Path $env:TEMP 'claude' $slug $SessionId 'scratchpad'
    if (Test-Path -LiteralPath $cand) {
        $files = @(Get-ChildItem -LiteralPath $cand -Recurse -File -ErrorAction SilentlyContinue)
        [long]$bytes = 0
        foreach ($f in $files) { $bytes += $f.Length }
        $scratchpad = [pscustomobject]@{ Path = $cand; Files = $files.Count; Bytes = $bytes }
    } else {
        $scratchpad = [pscustomobject]@{ Path = $cand; Files = 0; Bytes = 0; Missing = $true }
    }
}

$openTodos = @()
if ($lastTodos -is [System.Collections.IList]) {
    $openTodos = @($lastTodos | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['status'] -ne 'completed' } |
        ForEach-Object { [pscustomobject]@{ Status = $_['status']; Content = $_['content'] } })
}

$idleSec = $null
if ($lastTs) { $idleSec = [int]((Get-Date).ToUniversalTime() - ([datetime]$lastTs).ToUniversalTime()).TotalSeconds }

$result = [ordered]@{
    SessionId      = $SessionId
    Transcript     = $transcript.FullName
    SubagentFiles  = $subagentFiles.Count
    Started        = $firstTs
    LastActivity   = $lastTs
    IdleSeconds    = $idleSec
    Cwd            = @($cwds)
    GitBranches    = @($branches)
    Compactions    = $compactions
    DroppedTokens  = $droppedTokens
    UserTurns      = $userTurns
    AssistantTurns = $assistantTurns
    ToolCalls      = $toolCalls
    UnparsedLines  = $badLines
    ReposTouched   = $repos
    RepoState      = @($repoState)
    EditsByRepo    = $byRepo
    ShellOfInterest = @($shell)
    Background     = @($background)
    Agents         = @($agents)
    Worktrees      = @($worktrees)
    Handoffs       = @($handoffs)
    Questions      = @($questions)
    Skills         = @($skills)
    Schedulers     = @($schedulers)
    OpenTodos      = $openTodos
    Scratchpad     = $scratchpad
    Warnings       = @($warnings)
}

if ($Json) { $result | ConvertTo-Json -Depth 8; return }

# ---------- human report ----------
function Fmt-Dur([datetime]$a, [datetime]$b) {
    $d = $b - $a
    if ($d.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][math]::Floor($d.TotalHours), $d.Minutes) }
    if ($d.TotalMinutes -ge 1) { return ('{0}m {1}s' -f $d.Minutes, $d.Seconds) }
    return ('{0}s' -f [int]$d.TotalSeconds)
}
function Fmt-Secs([int]$s) {
    if ($s -ge 3600) { return ('{0}h {1}m' -f [int][math]::Floor($s / 3600), [int](($s % 3600) / 60)) }
    if ($s -ge 60)   { return ('{0}m {1}s' -f [int][math]::Floor($s / 60), ($s % 60)) }
    return "${s}s"
}
function Fmt-Bytes([long]$n) {
    if ($n -ge 1MB) { return ('{0:N1} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return "$n bytes"
}

Write-Output "SESSION $SessionId"
Write-Output "  transcript : $($transcript.FullName)"
if ($subagentFiles.Count) { Write-Output "  subagents  : $($subagentFiles.Count) transcript(s) included" }
if ($firstTs -and $lastTs) {
    $a = ([datetime]$firstTs).ToLocalTime(); $b = ([datetime]$lastTs).ToLocalTime()
    Write-Output ("  span       : {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}  ({2}), idle {3}" -f $a, $b, (Fmt-Dur $a $b), (Fmt-Secs $idleSec))
}
$compLine = "  turns      : {0:N0} user / {1:N0} assistant, {2:N0} tool calls, {3} compaction(s)" -f $userTurns, $assistantTurns, $toolCalls, $compactions
if ($compactions -gt 0 -and $droppedTokens -gt 0) { $compLine += (", ~{0:N0} tokens dropped (recall unreliable)" -f $droppedTokens) }
Write-Output $compLine
Write-Output "  cwd        : $($cwds -join '; ')"
if ($branches.Count) { Write-Output "  branches   : $($branches -join '; ')" }
if ($badLines) { Write-Output "  unparsed   : $badLines line(s) skipped" }
foreach ($w in $warnings) { Write-Output "  WARNING    : $w" }

Write-Output ""
Write-Output ("FILES EDITED (Edit/Write/NotebookEdit): {0}" -f $edits.Count)
if ($edits.Count -eq 0) { Write-Output "  none" }
foreach ($k in $byRepo.Keys) {
    Write-Output "  [$k]"
    foreach ($f in ($byRepo[$k] | Sort-Object Path)) {
        $tags = @()
        if ($f.Sidechain) { $tags += 'subagent' }
        if (-not $f.Exists) { $tags += 'MISSING NOW' }
        $tagStr = if ($tags.Count) { '  <' + ($tags -join ', ') + '>' } else { '' }
        Write-Output ("    {0}  ({1}x {2}){3}" -f $f.Path, $f.Edits, $f.Tools, $tagStr)
    }
}

Write-Output ""
Write-Output ("REPOS TOUCHED: {0}" -f $repos.Count)
if ($repos.Count -eq 0) { Write-Output "  none" }
foreach ($s in $repoState) {
    $up = if ($s.HasUpstream) { "ahead $($s.Ahead)" } else { 'no upstream' }
    $extra = @()
    if ($s.Stashes -gt 0)   { $extra += "$($s.Stashes) stash" }
    if ($s.Worktrees -gt 1) { $extra += "$($s.Worktrees) worktrees" }
    $extraStr = if ($extra.Count) { ' · ' + ($extra -join ', ') } else { '' }
    Write-Output ("  {0}" -f $s.Repo)
    Write-Output ("      on {0} (default {1}) · dirty {2} · {3}{4}" -f $s.Branch, ($s.Default ?? 'none'), $s.DirtyFiles, $up, $extraStr)
}

Write-Output ""
Write-Output ("SHELL COMMANDS THAT WROTE / CHANGED GIT / LAUNCHED PROCESSES: {0}" -f $shell.Count)
if ($shell.Count -eq 0) { Write-Output "  none" }
foreach ($s in $shell) {
    $sc = if ($s.Sidechain) { ' (subagent)' } else { '' }
    Write-Output ("  [{0}]{1} {2}" -f $s.Flags, $sc, $s.Command)
}

Write-Output ""
Write-Output ("BACKGROUND COMMANDS (run_in_background): {0}" -f $background.Count)
foreach ($b in $background) { Write-Output "  $($b.Command)" }
if ($background.Count -eq 0) { Write-Output "  none" }

Write-Output ""
Write-Output ("SUBAGENTS LAUNCHED: {0}" -f $agents.Count)
foreach ($a in $agents) {
    $iso = if ($a.Isolation) { " [isolation: $($a.Isolation)]" } else { '' }
    Write-Output ("  {0}: {1}{2}" -f ($a.Type ?? 'general-purpose'), $a.Description, $iso)
}
if ($agents.Count -eq 0) { Write-Output "  none" }

Write-Output ""
Write-Output ("WORKTREES ENTERED (EnterWorktree / Agent isolation:worktree): {0}" -f $worktrees.Count)
foreach ($w in $worktrees) { Write-Output ("  {0}: {1}" -f $w.Tool, $w.Detail) }
if ($worktrees.Count -eq 0) { Write-Output "  none" }

Write-Output ""
Write-Output ("FILES HANDED TO USER (SendUserFile): {0}" -f $handoffs.Count)
foreach ($h in $handoffs) { Write-Output "  $($h.Path)" }
if ($handoffs.Count -eq 0) { Write-Output "  none" }

Write-Output ""
Write-Output ("QUESTIONS ASKED (AskUserQuestion): {0}" -f $questions.Count)
foreach ($q in $questions) { Write-Output "  $($q.Headers)" }
if ($questions.Count -eq 0) { Write-Output "  none" }

Write-Output ""
Write-Output ("SKILLS INVOKED: {0}" -f $skills.Count)
foreach ($s in $skills) { $ar = if ($s.Args) { " $($s.Args)" } else { '' }; Write-Output ("  {0}{1}" -f $s.Name, $ar) }
if ($skills.Count -eq 0) { Write-Output "  none" }

Write-Output ""
Write-Output ("SCHEDULERS / WATCHES (CronCreate, ScheduleWakeup, Monitor, RemoteTrigger): {0}" -f $schedulers.Count)
foreach ($s in $schedulers) { Write-Output ("  {0}: {1}" -f $s.Tool, $s.Detail) }
if ($schedulers.Count -eq 0) { Write-Output "  none" }

Write-Output ""
if ($null -eq $lastTodos) {
    Write-Output "TODO LIST: never written this session"
} else {
    Write-Output ("TODO LIST: {0} open of {1}" -f $openTodos.Count, @($lastTodos).Count)
    foreach ($t in $openTodos) { Write-Output ("  [{0}] {1}" -f $t.Status, $t.Content) }
}

Write-Output ""
if ($scratchpad) {
    if ($scratchpad.PSObject.Properties['Missing']) {
        Write-Output "SCRATCHPAD: $($scratchpad.Path) (does not exist)"
    } else {
        Write-Output ("SCRATCHPAD: {0}  ({1} file(s), {2})" -f $scratchpad.Path, $scratchpad.Files, (Fmt-Bytes $scratchpad.Bytes))
    }
}
