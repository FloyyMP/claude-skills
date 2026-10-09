#Requires -Version 7
<#
.SYNOPSIS
  Emit the Step 7 "prove clean" table for one or more repos, every row backed by a
  git command run now. Read-only. Exit 0 = every repo clean, 1 = open items.

.DESCRIPTION
  Per repo: working tree clean, nothing unpushed, push landed (local HEAD == upstream),
  no op in progress, on default branch, no stashes, single worktree, no unmerged
  branches. The default branch is derived per repo, never hardcoded. Port of prove-clean.sh.

.PARAMETER Repo
  One or more repo roots (take them from session-facts ReposTouched). Required.

.PARAMETER Since
  Unix seconds; only stashes and branches created at or after it count. Defaults to
  $env:SINCE, else 0 (count everything).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Repo,
    [long]$Since = ($env:SINCE ? [long]$env:SINCE : 0)
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function G([string]$root, [string[]]$a) {
    $out = & git -C $root @a 2>$null
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = @($out | Where-Object { $_ -ne '' }) }
}
function First($r) { if ($r.Ok -and $r.Out.Count) { $r.Out[0] } }

$script:open = 0
function Row([string]$label, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:open++ }
    Write-Output ('  {0,-24} {1,-8} {2}' -f $label, ($ok ? 'ok' : 'OPEN'), $detail)
}

function LsRemoteHead([string]$root, [string]$rem) {
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($x in @('-C', $root, 'ls-remote', '--symref', $rem, 'HEAD')) { $psi.ArgumentList.Add($x) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o ConnectTimeout=5'
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(15000)) { $p.Kill($true); return $null }
    foreach ($l in ($out.Result -split "`r?`n")) { if ($l -match '^ref: refs/heads/(.+)\tHEAD$') { return $Matches[1] } }
}

function Default-Branch([string]$root) { # $null = unknown -> row is OPEN (fail closed)
    $cur = First (G $root @('symbolic-ref', '--short', 'HEAD'))
    $rem = if ($cur) { First (G $root @('config', "branch.$cur.remote")) }
    if (-not $rem) { $rem = First (G $root @('remote')) }
    if (-not $rem) { # local-only: never the current branch (tautology)
        foreach ($b in @((First (G $root @('config', 'init.defaultBranch'))), 'main', 'master')) {
            if ($b -and (G $root @('show-ref', '-q', '--verify', "refs/heads/$b")).Ok) { return $b }
        }
        if ((G $root @('for-each-ref', 'refs/heads')).Out.Count -le 1) { return $cur }
        return $null
    }
    $b = First (G $root @('symbolic-ref', '--short', "refs/remotes/$rem/HEAD"))
    if ($b) { return $b.Substring($rem.Length + 1) }
    return LsRemoteHead $root $rem
}

foreach ($r in $Repo) {
    Write-Output "repo $r"
    if (-not (Test-Path -LiteralPath $r -PathType Container)) { $script:open++; Write-Output '  ERROR: path not found'; continue }
    if (-not (G $r @('rev-parse', '--show-toplevel')).Ok) { $script:open++; Write-Output '  ERROR: not a git repo'; continue }

    $def = Default-Branch $r
    $branch = (First (G $r @('symbolic-ref', '--short', 'HEAD'))) ?? '(detached/unborn)'
    $dirty = (G $r @('status', '--porcelain')).Out.Count
    Row 'working tree clean' ($dirty -eq 0) "git status --porcelain        ($dirty dirty)"

    if ((G $r @('rev-parse', '--abbrev-ref', '@{u}')).Ok) {
        $ahead = [int](First (G $r @('rev-list', '--count', '@{u}..HEAD')))
        Row 'nothing unpushed' ($ahead -eq 0) "git rev-list --count @{u}..  ($ahead ahead)"
    } elseif ((G $r @('remote')).Out.Count -and (G $r @('rev-parse', '-q', '--verify', 'HEAD')).Ok) { # remote but no/gone upstream
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
    Row 'no op in progress' ($op.Count -eq 0) "git rev-parse --git-path …    ($($op ? ($op -join ' ') : 'none'))"

    Row 'on default branch' ([bool]$def -and $branch -eq $def) "git symbolic-ref --short HEAD ($branch, default $($def ?? 'none'))"
    $stashes = @((G $r @('stash', 'list', '--format=%ct')).Out | Where-Object { [long]$_ -ge $Since }).Count
    Row 'no stashes' ($stashes -eq 0) "git stash list                ($stashes)"
    $wt = (G $r @('worktree', 'list')).Out.Count
    Row 'single worktree' ($wt -le 1) "git worktree list             ($wt)"
    $unmerged = 0
    if ($def) {
        $unmerged = @((G $r @('for-each-ref', "--no-merged=$def", '--format=%(refname)', 'refs/heads')).Out | Where-Object {
            $oldest = (G $r @('reflog', 'show', '--date=unix', '--format=%gd', $_, '--')).Out | Select-Object -Last 1
            $created = ($oldest -match '@\{(\d+)\}$') ? [long]$Matches[1] : [long]9999999999
            $created -ge $Since
        }).Count
    }
    Row 'no unmerged branches' ($unmerged -eq 0) "git branch --no-merged $($def ?? '?')  ($unmerged)"
}

Write-Output ''
if ($script:open -eq 0) { Write-Output 'ALL CLEAN'; exit 0 }
Write-Output "OPEN ITEMS: $($script:open)"
exit 1
