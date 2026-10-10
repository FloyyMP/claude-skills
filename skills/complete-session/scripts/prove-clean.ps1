#Requires -Version 7
<#
.SYNOPSIS
  Emit the Step 7 "prove clean" table for one or more repos, every row backed by a
  git command run now. Read-only. Exit 0 = every repo clean, 1 = open items, 2 = usage error.

.DESCRIPTION
  Per repo: working tree clean, nothing unpushed, push landed (local HEAD == upstream),
  no op in progress, on default branch, no stashes, single worktree, no unmerged
  branches. The default branch is derived per repo, never hardcoded. Rows are ok, OPEN,
  note (informational, never blocks) or n/a. Port of prove-clean.sh.

.PARAMETER Repo
  One or more repo roots (take them from session-facts ReposTouched). Required.

.PARAMETER Since
  Unix seconds (13-digit milliseconds are accepted too); only stashes, branches and
  worktrees created at or after it count. Defaults to $env:SINCE, else 0 (count everything).
  Anything else exits 2.
#>
[CmdletBinding()]
param(
    [string[]]$Repo,
    [string]$Since
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (-not $Repo) { [Console]::Error.WriteLine('ERROR: -Repo is required (one or more repo roots)'); exit 2 }
if (-not $Since) { $Since = $env:SINCE }
if (-not $Since) { $Since = '0' }
if ($Since -match '^[0-9]{13}$') { $sinceSec = [long][Math]::Floor([long]$Since / 1000) }
elseif ($Since -match '^(0|[0-9]{9,10})$') { $sinceSec = [long]$Since }
else { [Console]::Error.WriteLine("ERROR: SINCE must be unix seconds (9-10 digits), got '$Since'"); exit 2 }

function G([string]$root, [string[]]$a) {
    $out = & git -C $root @a 2>$null
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = @($out | Where-Object { $_ -ne '' }) }
}
function First($r) { if ($r.Ok -and $r.Out.Count) { $r.Out[0] } }
function GitErr([string]$root, [string[]]$a) { # first stderr line of a failed git call
    $ErrorActionPreference = 'Continue'
    (& git -C $root @a 2>&1 | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Select-Object -First 1) -as [string]
}

$script:okCount = 0; $script:open = 0; $script:notes = 0
function Row([string]$label, [bool]$ok, [string]$detail) {
    if ($ok) { $script:okCount++ } else { $script:open++ }
    Write-Output ('  {0,-24} {1,-8} {2}' -f $label, ($ok ? 'ok' : 'OPEN'), $detail)
}
function Note([string]$label, [string]$detail) { # informational, never blocks
    $script:notes++
    Write-Output ('  {0,-24} {1,-8} {2}' -f $label, 'note', $detail)
}

function Born-Worktree([string]$p) { # creation time of a worktree's .git file; far future (= new) if unreadable
    $i = Get-Item -LiteralPath (Join-Path $p '.git') -Force -ErrorAction SilentlyContinue
    if ($i) { [DateTimeOffset]::new($i.CreationTimeUtc).ToUnixTimeSeconds() } else { [long]9999999999 }
}

function Born-Branch([string]$root, [string]$ref) { # oldest reflog entry, else (reflog expired/off) the tip commit date
    $oldest = (G $root @('reflog', 'show', '--date=unix', '--format=%gd', $ref, '--')).Out | Select-Object -Last 1
    if ($oldest -match '@\{([0-9]+)\}$') { return [long]$Matches[1] }
    $t = First (G $root @('log', '-1', '--format=%ct', $ref, '--'))
    if ($t) { [long]$t } else { [long]9999999999 }
}

function LsRemoteHead([string]$root, [string]$rem) {
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($x in @('-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=5', '-C', $root, 'ls-remote', '--symref', $rem, 'HEAD')) { $psi.ArgumentList.Add($x) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o ConnectTimeout=5'
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(8000)) { $p.Kill($true); return $null }
    foreach ($l in ($out.Result -split "`r?`n")) { if ($l -match '^ref: refs/heads/(.+)\tHEAD$') { return $Matches[1] } }
}

function Default-Branch([string]$root) { # $null = unknown -> row is OPEN (fail closed)
    $cur = First (G $root @('symbolic-ref', '--short', 'HEAD'))
    $rems = @((G $root @('remote')).Out)
    if (-not $rems) { # local-only: never the current branch (tautology)
        foreach ($b in @((First (G $root @('config', 'init.defaultBranch'))), 'main', 'master')) {
            if ($b -and (G $root @('show-ref', '-q', '--verify', "refs/heads/$b")).Ok) { return $b }
        }
        if ((G $root @('for-each-ref', 'refs/heads')).Out.Count -le 1) { return $cur }
        return $null
    }
    $rems = @($rems | Where-Object { $_ -ceq 'origin' }) + @($rems | Where-Object { $_ -cne 'origin' }) # origin first
    # Local refs before any network call. A refs/remotes/<rem>/HEAD whose branch is gone doesn't count.
    foreach ($rem in $rems) {
        $b = First (G $root @('symbolic-ref', '--short', "refs/remotes/$rem/HEAD"))
        if ($b) {
            $b = $b.Substring($rem.Length + 1)
            if ((G $root @('show-ref', '-q', '--verify', "refs/remotes/$rem/$b")).Ok) { return $b }
        }
        foreach ($b in 'main', 'master') { if ((G $root @('show-ref', '-q', '--verify', "refs/remotes/$rem/$b")).Ok) { return $b } }
    }
    return LsRemoteHead $root $rems[0]
}

foreach ($r in $Repo) {
    Write-Output "repo $r"
    if (-not (Test-Path -LiteralPath $r -PathType Container)) { $script:open++; Write-Output '  ERROR: path not found'; continue }
    if ((First (G $r @('rev-parse', '--is-bare-repository'))) -eq 'true') { $script:notes++; Write-Output '  bare repo (skipped)'; continue }
    if (-not (G $r @('rev-parse', '--show-toplevel')).Ok) { $script:open++; Write-Output '  ERROR: not a git repo'; continue }

    $def = Default-Branch $r
    $noHead = -not (G $r @('rev-parse', '-q', '--verify', 'HEAD')).Ok
    $branch = (First (G $r @('symbolic-ref', '--short', 'HEAD'))) ?? '(detached/unborn)'
    $dirty = (G $r @('status', '--porcelain', '--untracked-files=normal')).Out.Count
    Row 'working tree clean' ($dirty -eq 0) "git status --porcelain        ($dirty dirty)"

    $hasRemote = (G $r @('remote')).Out.Count -gt 0
    if ($hasRemote -and $noHead) {
        Write-Output ('  {0,-24} {1,-8} {2}' -f 'nothing unpushed', 'n/a', 'unborn (no commits)')
    } elseif ((G $r @('rev-parse', '--abbrev-ref', '@{u}')).Ok) {
        $ahead = [int](First (G $r @('rev-list', '--count', '@{u}..HEAD')))
        $behind = [int](First (G $r @('rev-list', '--count', 'HEAD..@{u}')))
        Row 'nothing unpushed' ($ahead -eq 0) "git rev-list --count @{u}..  ($ahead ahead)"
        if ((First (G $r @('rev-parse', 'HEAD'))) -eq (First (G $r @('rev-parse', '@{u}')))) {
            Row 'push landed (sha match)' $true 'git rev-parse HEAD vs @{u}'
        } elseif ($ahead -eq 0) {
            Note 'push landed (sha match)' "behind $behind (pull needed)"
        } else {
            Row 'push landed (sha match)' $false "git rev-parse HEAD vs @{u}  (ahead $ahead, behind $behind)"
        }
    } elseif ($hasRemote) { # remote but no/gone upstream
        $c = G $r @('rev-list', '--count', 'HEAD', '--not', '--remotes')
        $ahead = $c.Ok ? [int]$c.Out[0] : -1
        Row 'nothing unpushed' ($ahead -eq 0) "git rev-list --count HEAD --not --remotes ($ahead, no upstream)"
    } else {
        Write-Output ('  {0,-24} {1,-8} {2}' -f 'nothing unpushed', 'n/a', '(no remote)')
    }

    $op = @(foreach ($f in 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply') {
        $p = First (G $r @('rev-parse', '--path-format=absolute', '--git-path', $f))
        if ($p -and (Test-Path -LiteralPath $p)) { $f }
    })
    Row 'no op in progress' ($op.Count -eq 0) "git rev-parse --git-path ...    ($($op ? ($op -join ' ') : 'none'))"

    Row 'on default branch' ([bool]$def -and $branch -ceq $def) "git symbolic-ref --short HEAD ($branch, default $($def ?? 'none'))"
    $stashes = @((G $r @('stash', 'list', '--format=%ct')).Out | Where-Object { [long]$_ -ge $sinceSec }).Count
    Row 'no stashes' ($stashes -eq 0) "git stash list                ($stashes)"
    $wts = @((G $r @('worktree', 'list', '--porcelain')).Out | Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring(9) })
    $wt = $wts.Count # the first entry is the main worktree; a linked one's creation time is its .git file's
    $wtold = @($wts | Select-Object -Skip 1 | Where-Object { (Born-Worktree $_) -lt $sinceSec }).Count
    if ($wt -le 1) { Row 'single worktree' $true "git worktree list             ($wt)" }
    elseif ($wtold -eq $wt - 1) { Note 'single worktree' "git worktree list             ($wt, all linked ones predate SINCE)" }
    else { Row 'single worktree' $false "git worktree list             ($wt$($wtold ? ", $wtold predate SINCE" : ''))" }
    if ($noHead) {
        Write-Output ('  {0,-24} {1,-8} {2}' -f 'no unmerged branches', 'n/a', 'unborn (no commits)')
    } elseif (-not $def) {
        Row 'no unmerged branches' $false 'git branch --no-merged ?  (default branch unknown, not checked)'
    } else {
        $l = G $r @('for-each-ref', "--no-merged=$def", '--format=%(refname)', 'refs/heads')
        if (-not $l.Ok) {
            Row 'no unmerged branches' $false "git branch --no-merged $def  (error: $(GitErr $r @('for-each-ref', "--no-merged=$def", '--format=%(refname)', 'refs/heads')))"
        } else {
            $unmerged = @($l.Out | Where-Object { (Born-Branch $r $_) -ge $sinceSec }).Count
            Row 'no unmerged branches' ($unmerged -eq 0) "git branch --no-merged $def  ($unmerged)"
        }
    }
}

Write-Output ''
Write-Output "checks ok: $($script:okCount), open: $($script:open), notes: $($script:notes)"
if ($script:open -eq 0) { Write-Output 'ALL CLEAN'; exit 0 }
Write-Output "OPEN ITEMS: $($script:open)"
exit 1
