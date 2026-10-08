#Requires -Version 7
<#
.SYNOPSIS
  Detect a repo's languages and run each one's verification gate, every step bounded by a
  hard timeout so a hung check can never stall the close. Prints a verdict per step.
  Exit 0 = every step that ran passed, 1 = a failure, 2 = a timeout (unverified),
       3 = nothing runnable (no recognized gate, toolchain/deps missing, placeholder/watch scripts).
  Port of run-gates.sh.

.DESCRIPTION
  Python (pyproject.toml) - never mutates the user's environment:
    ruff, only if configured ([tool.ruff] / ruff.toml / .ruff.toml): ruff check --no-fix . ; ruff format --check .
    tests: uv.lock -> uv run --frozen pytest ; else .venv python -m pytest ; else not runnable
    (pytest exit 5 = "no tests collected" is reported, not failed)
  Go     (every go.mod): gofmt -l (skips vendor/, testdata/) must print nothing ; go vet ./... ; go test [-race] ./...
  Node   (package.json): the project's own typecheck / lint / test / build scripts, whichever exist
  Steps run in a child pwsh, so npm.cmd / pnpm.cmd resolve as they do in a terminal.

.PARAMETER Repo
  Repo root to check. Required.

.PARAMETER TimeoutSec
  Per-step wall-clock timeout in seconds (default 300).

.PARAMETER Tail
  Output lines shown for a step that didn't pass (default 30).
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [int]$TimeoutSec = 300,
    [int]$Tail = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function NotRunnable([string]$msg) { Write-Output $msg; Write-Output 'RESULT: not runnable (nothing was verified)'; exit 3 }
if (-not $Repo -or -not (Test-Path -LiteralPath $Repo -PathType Container)) { NotRunnable "not a directory: $($Repo ? $Repo : '<none>') (use -Repo)" }
if ($TimeoutSec -le 0) { NotRunnable '-TimeoutSec must be whole seconds > 0' }
$env:NO_COLOR = '1'; $env:CI = '1'; $env:PYTHONDONTWRITEBYTECODE = '1'
Remove-Item Env:FORCE_COLOR, Env:CLICOLOR_FORCE -ErrorAction SilentlyContinue # keep logs plain

function In([string]$p) { Join-Path $Repo $p }
# Each step: Label, Rule (exit0 | emptyout | pytest | notrun), Dir, Cmd (pwsh; for notrun, the reason)
$steps = [Collections.Generic.List[object]]::new()
$langs = [Collections.Generic.List[string]]::new()
function Step($label, $rule, $dir, $cmd) { $steps.Add([pscustomobject]@{ Label = $label; Rule = $rule; Dir = $dir; Cmd = $cmd }) }

if (Test-Path -LiteralPath (In 'pyproject.toml')) {
    $langs.Add('python')
    $cfg = @('pyproject.toml', '.pre-commit-config.yaml') | ForEach-Object { In $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ((Select-String -LiteralPath $cfg -Pattern 'ruff' -Quiet) -or (Test-Path -LiteralPath (In 'ruff.toml')) -or (Test-Path -LiteralPath (In '.ruff.toml'))) {
        $ruff = 'uvx ruff'
        if ((Test-Path -LiteralPath (In 'uv.lock')) -and (Select-String -LiteralPath (In 'uv.lock') -Pattern '^name = "ruff"$' -CaseSensitive -Quiet)) { $ruff = 'uv run --frozen ruff' }
        Step 'ruff check' 'exit0' '.' "$ruff check --no-fix ."
        Step 'ruff format --check' 'exit0' '.' "$ruff format --check ."
    }
    $venvPy = @('.venv/Scripts/python.exe', '.venv/bin/python') | Where-Object { Test-Path -LiteralPath (In $_) -PathType Leaf } | Select-Object -First 1
    if (Test-Path -LiteralPath (In 'uv.lock')) { Step 'pytest' 'pytest' '.' 'uv run --frozen pytest -p no:cacheprovider' }
    elseif ($venvPy) { Step 'pytest' 'pytest' '.' "& './$venvPy' -m pytest -p no:cacheprovider" }
    else { Step 'pytest' 'notrun' '.' "no uv.lock and no .venv: use the test command the repo's CLAUDE.md/README names" }
}
$mods = @(Get-ChildItem -LiteralPath $Repo -Filter 'go.mod' -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/](vendor|node_modules)[\\/]' } |
    ForEach-Object { $d = [IO.Path]::GetRelativePath($Repo, $_.DirectoryName) -replace '\\', '/'; $d -eq '.' ? '.' : "./$d" } | Sort-Object)
foreach ($d in $mods) {
    $langs.Add("go:$d")
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Step "go ($d)" 'notrun' '.' 'go toolchain not installed'; continue }
    Push-Location -LiteralPath (In $d); $cgo = & go env CGO_ENABLED 2>$null; Pop-Location
    $race = $cgo -eq '1' ? ' -race' : ''
    Step "gofmt ($d)" 'emptyout' $d '$f = @(Get-ChildItem -Recurse -File -Filter *.go | Where-Object { $_.FullName -notmatch ''[\\/](vendor|testdata)[\\/]'' } | Resolve-Path -Relative); if ($f) { gofmt -l @f }'
    Step "go vet ($d)" 'exit0' $d 'go vet ./...'
    Step "go test$race ($d)" 'exit0' $d "go test$race ./..."
}
if (Test-Path -LiteralPath (In 'package.json')) {
    $langs.Add('node')
    $pm = (Test-Path -LiteralPath (In 'yarn.lock')) ? 'yarn' : (Test-Path -LiteralPath (In 'pnpm-lock.yaml')) ? 'pnpm' : 'npm'
    $pj = Get-Content -LiteralPath (In 'package.json') -Raw | ConvertFrom-Json -AsHashtable
    $scripts = ($pj -is [Collections.IDictionary] -and $pj['scripts'] -is [Collections.IDictionary]) ? $pj['scripts'] : @{}
    foreach ($s in 'typecheck', 'lint', 'test', 'build') {
        $body = [string]$scripts[$s]
        if (-not $body) { continue }
        if ($body -like '*no test specified*') { Step "$pm run $s" 'notrun' '.' 'placeholder script (npm init default)' }
        elseif ($body -match '(^|\s)(--watch|-w|watch)(\s|$)') { Step "$pm run $s" 'notrun' '.' "watch mode would never exit: $body" }
        else { Step "$pm run $s" 'exit0' '.' "$pm run $s" }
    }
}
if (-not $langs.Count) { NotRunnable "no recognized gate (no pyproject.toml / go.mod / package.json) in $Repo" }

# Child pwsh: plain output, stderr merged in order, a missing command exits 127 (like a shell), a native exit code passes through.
$wrap = '$PSStyle.OutputRendering = "PlainText"; $ErrorActionPreference = "Stop"; trap [System.Management.Automation.CommandNotFoundException] { "$_"; exit 127 }; & { CMD } 2>&1 | ForEach-Object { "$_" }; exit $LASTEXITCODE'

$pwsh = (Get-Process -Id $PID).Path # same pwsh that runs this script, even if not on PATH
Write-Output "GATE ($($langs -join ' ')) for $Repo  (timeout ${TimeoutSec}s/step)"
$anyFail = $anyTimeout = $anyPass = $anyNotrun = $false
$before = @(git -C $Repo status --porcelain 2>$null)
foreach ($s in $steps) {
    if ($s.Rule -eq 'notrun') { $anyNotrun = $true; Write-Output ('  {0,-26} {1}' -f $s.Label, "NOT RUNNABLE: $($s.Cmd)"); continue }
    $psi = [Diagnostics.ProcessStartInfo]::new($pwsh) # ArgumentList quotes each arg; Start-Process doesn't
    foreach ($a in '-NoProfile', '-NonInteractive', '-Command', $wrap.Replace('CMD', $s.Cmd)) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = In $s.Dir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close() # like </dev/null: a prompt gets EOF instead of hanging
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { $p.Kill($true) } # whole tree, so orphans can't keep writing
    $p.WaitForExit()
    $code = $p.ExitCode
    $log = @(foreach ($t in $o, $e) { if ($t.Wait(5000)) { $t.Result -split "`r?`n" } })
    $show = $true
    if ($timedOut) { $anyTimeout = $true; $verdict = "TIMEOUT after ${TimeoutSec}s (unverified)" }
    elseif ($code -in 126, 127 -or ($log -match '^error: Failed to spawn|: command not found$|: not found$|is not recognized as a name of')) {
        $anyNotrun = $true; $verdict = "NOT RUNNABLE (exit ${code}: tool or dependency missing)"
    }
    elseif ($s.Rule -eq 'pytest' -and $code -eq 5) { $anyNotrun = $true; $verdict = 'no tests collected (nothing verified)'; $show = $false }
    elseif ($code -eq 0 -and ($s.Rule -ne 'emptyout' -or -not ($log -join ''))) { $anyPass = $true; $verdict = 'pass'; $show = $false }
    else { $anyFail = $true; $verdict = "FAIL (exit $code)" }
    Write-Output ('  {0,-26} {1}' -f $s.Label, $verdict)
    if ($show) { $log | Where-Object { $_ -match '\S' } | Select-Object -Last $Tail | ForEach-Object { "      | $_" } }
}
$after = @(git -C $Repo status --porcelain 2>$null)
$new = @($after | Where-Object { $_ -notin $before })
if ($new) { Write-Output '  WARN: the gate changed the working tree:'; $new | ForEach-Object { "      $_" } }
Write-Output ''
if ($anyFail) { Write-Output 'RESULT: FAIL'; exit 1 }
if ($anyTimeout) { Write-Output 'RESULT: unverified (a step timed out)'; exit 2 }
if ($anyNotrun -and -not $anyPass) { Write-Output 'RESULT: not runnable (nothing was verified)'; exit 3 }
if ($anyNotrun) { Write-Output 'RESULT: pass (partial: some steps could not run, see above)'; exit 0 }
Write-Output 'RESULT: pass'
exit 0
