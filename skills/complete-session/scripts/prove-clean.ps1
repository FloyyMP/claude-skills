#Requires -Version 7
<#
.SYNOPSIS
  Emit the Step 7 "prove clean" table for one or more repos, every row backed by a
  git command run now. Read-only. Exit 0 = every repo clean, 1 = open items.

.DESCRIPTION
  For each repo: working tree clean, nothing unpushed, on default branch, push
  actually landed (local HEAD == upstream), no stashes, single worktree, no
  unmerged branches. The default branch is derived per repo, never hardcoded.

.PARAMETER Repo
  One or more repo roots (take them from session-facts ReposTouched). Required.

.PARAMETER Json
  Emit a JSON array of per-repo results instead of the table.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Repo,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RepoGit([string]$root, [string[]]$a) {
    $out = & git -C $root @a 2>$null
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = @($out) }
}
function Default-Branch([string]$root) {
    $r = Invoke-RepoGit $root @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if ($r.Ok -and $r.Out) { return (($r.Out | Select-Object -First 1) -replace '^origin/', '') }
    $r = Invoke-RepoGit $root @('remote', 'show', 'origin')
    if ($r.Ok) { $h = $r.Out | Where-Object { $_ -match 'HEAD branch:\s*(\S+)' } | Select-Object -First 1; if ($h -match 'HEAD branch:\s*(\S+)') { return $Matches[1] } }
    $r = Invoke-RepoGit $root @('symbolic-ref', '--short', 'HEAD')
    if ($r.Ok -and $r.Out) { return ($r.Out | Select-Object -First 1) }
    return $null
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($root in $Repo) {
    if (-not (Test-Path -LiteralPath $root)) {
        $results.Add([pscustomobject]@{ Repo = $root; Error = 'path not found' }); continue
    }
    $top = Invoke-RepoGit $root @('rev-parse', '--show-toplevel')
    if (-not $top.Ok) { $results.Add([pscustomobject]@{ Repo = $root; Error = 'not a git repo' }); continue }

    $def = Default-Branch $root
    $branch = (Invoke-RepoGit $root @('symbolic-ref', '--short', 'HEAD')).Out | Select-Object -First 1
    if (-not $branch) { $branch = '(detached/unborn)' }
    $dirty = (Invoke-RepoGit $root @('status', '--porcelain')).Out
    $hasUp = (Invoke-RepoGit $root @('rev-parse', '--abbrev-ref', '@{u}')).Ok
    $ahead = 0; $landed = $null
    if ($hasUp) {
        $c = (Invoke-RepoGit $root @('rev-list', '--count', '@{u}..HEAD')).Out | Select-Object -First 1
        if ($c) { $ahead = [int]$c }
        $local  = (Invoke-RepoGit $root @('rev-parse', 'HEAD')).Out | Select-Object -First 1
        $remote = (Invoke-RepoGit $root @('rev-parse', '@{u}')).Out | Select-Object -First 1
        $landed = ($local -and $remote -and $local -eq $remote)
    }
    $stashes = @((Invoke-RepoGit $root @('stash', 'list')).Out).Count
    $wt = @((Invoke-RepoGit $root @('worktree', 'list')).Out).Count
    $unmerged = 0
    if ($def) { $unmerged = @((Invoke-RepoGit $root @('branch', '--no-merged', $def)).Out | Where-Object { $_.Trim() }).Count }

    $results.Add([pscustomobject]@{
        Repo = $root; Branch = $branch; Default = $def
        Clean = ($dirty.Count -eq 0); DirtyFiles = $dirty.Count
        HasUpstream = $hasUp; Ahead = $ahead; Landed = $landed
        OnDefault = ($def -and $branch -eq $def)
        Stashes = $stashes; Worktrees = $wt; UnmergedBranches = $unmerged
    })
}

if ($Json) { $results | ConvertTo-Json -Depth 6; exit (@($results | Where-Object { $_.PSObject.Properties['Error'] -or -not $_.Clean -or ($_.HasUpstream -and $_.Ahead -gt 0) -or $_.Stashes -gt 0 -or $_.Worktrees -gt 1 -or $_.UnmergedBranches -gt 0 }).Count -gt 0 ? 1 : 0) }

$open = 0
function Mark([bool]$ok) { if ($ok) { 'ok' } else { $script:open++; 'OPEN' } }
foreach ($r in $results) {
    Write-Output "repo $($r.Repo)"
    if ($r.PSObject.Properties['Error']) { $open++; Write-Output "  ERROR: $($r.Error)"; continue }
    Write-Output ("  {0,-24} {1,-8} git status --porcelain        ({2} dirty)" -f 'working tree clean', (Mark $r.Clean), $r.DirtyFiles)
    if ($r.HasUpstream) {
        Write-Output ("  {0,-24} {1,-8} git rev-list --count @{{u}}..  ({2} ahead)" -f 'nothing unpushed', (Mark ($r.Ahead -eq 0)), $r.Ahead)
        Write-Output ("  {0,-24} {1,-8} git rev-parse HEAD vs @{{u}}" -f 'push landed (sha match)', (Mark ([bool]$r.Landed)))
    } else {
        Write-Output ("  {0,-24} {1,-8} (no upstream)" -f 'nothing unpushed', 'n/a')
    }
    Write-Output ("  {0,-24} {1,-8} git symbolic-ref --short HEAD ({2}, default {3})" -f 'on default branch', (Mark ([bool]$r.OnDefault)), $r.Branch, ($r.Default ?? 'none'))
    Write-Output ("  {0,-24} {1,-8} git stash list                ({2})" -f 'no stashes', (Mark ($r.Stashes -eq 0)), $r.Stashes)
    Write-Output ("  {0,-24} {1,-8} git worktree list             ({2})" -f 'single worktree', (Mark ($r.Worktrees -le 1)), $r.Worktrees)
    Write-Output ("  {0,-24} {1,-8} git branch --no-merged {2,-6} ({3})" -f 'no unmerged branches', (Mark ($r.UnmergedBranches -eq 0)), ($r.Default ?? '?'), $r.UnmergedBranches)
}
Write-Output ""
Write-Output ($open -eq 0 ? 'ALL CLEAN' : "OPEN ITEMS: $open")
exit ($open -gt 0 ? 1 : 0)
