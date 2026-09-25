#Requires -Version 7
<#
.SYNOPSIS
  Detect a repo's language and run its verification gate, each step bounded by a
  hard timeout so a hung check can never stall the close. Prints pass/fail per
  step. Exit 0 = all steps passed, 1 = a failure, 2 = a timeout.

.DESCRIPTION
  Gates (matching the user's global CLAUDE.md):
    Python (pyproject.toml): uvx ruff check . ; uvx ruff format --check . ; uv run pytest
      (pytest exit 5 = "no tests collected" is treated as a skip, not a failure)
    Go     (go.mod)        : gofmt -l . (must print nothing) ; go vet ./... ; go test -race ./...
    Node   (package.json)  : the project's own typecheck / lint / test / build scripts, whichever exist
  A killed (timed-out) step is reported unverified, not passed.

.PARAMETER Repo
  Repo root to check. Required.

.PARAMETER TimeoutSec
  Per-step wall-clock timeout in seconds (default 300).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [int]$TimeoutSec = 300
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Write-Output "not a directory: $Repo"; exit 1 }

# label, shell command, pass-rule: 'exit0' | 'emptyout' | 'pytest'
$steps = [System.Collections.Generic.List[object]]::new()
if (Test-Path (Join-Path $Repo 'go.mod')) {
    $lang = 'go'
    $steps.Add(@{ Label = 'gofmt -l .';       Cmd = 'gofmt -l .';        Rule = 'emptyout' })
    $steps.Add(@{ Label = 'go vet ./...';      Cmd = 'go vet ./...';      Rule = 'exit0' })
    $steps.Add(@{ Label = 'go test -race ./...'; Cmd = 'go test -race ./...'; Rule = 'exit0' })
}
elseif (Test-Path (Join-Path $Repo 'pyproject.toml')) {
    $lang = 'python'
    $steps.Add(@{ Label = 'ruff check';        Cmd = 'uvx ruff check .';          Rule = 'exit0' })
    $steps.Add(@{ Label = 'ruff format --check'; Cmd = 'uvx ruff format --check .'; Rule = 'exit0' })
    $steps.Add(@{ Label = 'pytest';            Cmd = 'uv run pytest';             Rule = 'pytest' })
}
elseif (Test-Path (Join-Path $Repo 'package.json')) {
    $lang = 'node'
    $pj = Get-Content (Join-Path $Repo 'package.json') -Raw | ConvertFrom-Json -AsHashtable
    $scripts = if ($pj.Contains('scripts') -and $pj['scripts'] -is [System.Collections.IDictionary]) { $pj['scripts'] } else { @{} }
    $pm = if (Test-Path (Join-Path $Repo 'pnpm-lock.yaml')) { 'pnpm' } elseif (Test-Path (Join-Path $Repo 'yarn.lock')) { 'yarn' } else { 'npm' }
    foreach ($s in @('typecheck', 'lint', 'test', 'build')) {
        if ($scripts.Contains($s)) { $steps.Add(@{ Label = "$pm run $s"; Cmd = "$pm run $s"; Rule = 'exit0' }) }
    }
    if ($steps.Count -eq 0) { Write-Output "node repo but no typecheck/lint/test/build script in package.json"; exit 1 }
}
else {
    Write-Output "no recognized gate (no go.mod / pyproject.toml / package.json) in $Repo"
    exit 1
}

function Run-Step([hashtable]$step) {
    $out = New-TemporaryFile; $err = New-TemporaryFile
    try {
        $p = Start-Process pwsh -PassThru -NoNewWindow -WorkingDirectory $Repo `
            -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $step.Cmd `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $timedOut = $false
        try { $p | Wait-Process -Timeout $TimeoutSec -ErrorAction Stop }
        catch { $timedOut = $true; try { $p.Kill($true) } catch {} }
        $stdout = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) ?? ''
        $code = if ($timedOut) { $null } else { $p.ExitCode }
        $pass = if ($timedOut) { $false }
                elseif ($step.Rule -eq 'emptyout') { $code -eq 0 -and [string]::IsNullOrWhiteSpace($stdout) }
                elseif ($step.Rule -eq 'pytest')   { $code -eq 0 -or $code -eq 5 }
                else { $code -eq 0 }
        [pscustomobject]@{ Label = $step.Label; Pass = $pass; Code = $code; TimedOut = $timedOut; Skipped = ($step.Rule -eq 'pytest' -and $code -eq 5) }
    }
    finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "GATE ($lang) for $Repo  (timeout ${TimeoutSec}s/step)"
$anyFail = $false; $anyTimeout = $false
foreach ($step in $steps) {
    $r = Run-Step $step
    if ($r.TimedOut) { $anyTimeout = $true; $verdict = "TIMEOUT after ${TimeoutSec}s (unverified)" }
    elseif ($r.Skipped) { $verdict = 'skip (no tests)' }
    elseif ($r.Pass) { $verdict = 'pass' }
    else { $anyFail = $true; $verdict = "FAIL (exit $($r.Code))" }
    Write-Output ("  {0,-22} {1}" -f $r.Label, $verdict)
}
Write-Output ""
if ($anyTimeout) { Write-Output 'RESULT: unverified (a step timed out)'; exit 2 }
if ($anyFail)    { Write-Output 'RESULT: FAIL'; exit 1 }
Write-Output 'RESULT: pass'
exit 0
