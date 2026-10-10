#Requires -Version 7
<#
.SYNOPSIS
  Detect a repo's languages and run each one's verification gate, every step bounded by a
  hard timeout so a hung check can never stall the close. Prints a verdict per step.
  Exit 0 = every step that ran passed and at least one was a test step, 1 = a failure,
       2 = a timeout or an exhausted -TotalTimeoutSec (unverified),
       3 = nothing runnable (no recognized gate, toolchain/deps missing, placeholder/watch/malformed, no test step ran).
  Port of run-gates.sh.

.DESCRIPTION
  Steps can write caches, lockfiles, a .venv and build output (uv, pytest, cargo, dotnet); a working-tree diff is reported.
  Python (pyproject.toml, at the root or one level down):
    ruff, only if configured ([tool.ruff] / ruff.toml / .ruff.toml): ruff check --no-fix . ; ruff format --check .
    tests: uv.lock -> uv run --frozen pytest ; else .venv python -m pytest ; else not runnable
    (pytest exit 5 = "no tests collected" is reported, not failed)
  Python (no root pyproject.toml; requirements.txt or *.py, plus tests/): syntax-check the .py files ;
    pytest -q if the .venv python (else python/python3) can import it
  Go     (every go.mod): gofmt -l (skips vendor/, testdata/) must print nothing ; go vet ./... ; go test [-race] ./...
  Node   (package.json, at the root or one level down): the project's own typecheck / lint / test / build scripts, whichever exist
  Rust   (Cargo.toml): cargo test --quiet
  .NET   (*.sln, else *.csproj): dotnet build --nologo -v q
  A manifest that is found but not gated is listed as "SKIP <path>: <reason>".
  Steps run in a child pwsh, so npm.cmd / pnpm.cmd resolve as they do in a terminal.

.PARAMETER Repo
  Repo root to check. Required.

.PARAMETER TimeoutSec
  Per-step wall-clock timeout in seconds (default 300).

.PARAMETER TotalTimeoutSec
  Wall-clock budget for all steps (default 540); steps left when it runs out are skipped as unverified.

.PARAMETER Tail
  Output lines shown for a step that didn't pass (default 30).

.PARAMETER NoBuild
  Skip the Node build script (it would clobber the output dir of a running dev server).
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [int]$TimeoutSec = 300,
    [int]$TotalTimeoutSec = 540,
    [int]$Tail = 30,
    [switch]$NoBuild
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function NotRunnable([string]$msg) { Write-Output $msg; Write-Output 'RESULT: not runnable (nothing was verified)'; exit 3 }
if (-not $Repo -or -not (Test-Path -LiteralPath $Repo -PathType Container)) { NotRunnable "not a directory: $($Repo ? $Repo : '<none>') (use -Repo)" }
if ($TimeoutSec -le 0) { NotRunnable '-TimeoutSec must be whole seconds > 0' }
if ($TotalTimeoutSec -le 0) { NotRunnable '-TotalTimeoutSec must be whole seconds > 0' }
$env:NO_COLOR = '1'; $env:CI = '1'; $env:PYTHONDONTWRITEBYTECODE = '1'
Remove-Item Env:FORCE_COLOR, Env:CLICOLOR_FORCE -ErrorAction SilentlyContinue # keep logs plain
$tAll = [Diagnostics.Stopwatch]::StartNew()

function In([string]$p) { Join-Path $Repo $p }
# Repo-relative ('./x/y') manifests at the root and one level down, never inside vendor/ or node_modules/.
function Manifests([string]$pat) {
    Get-ChildItem -LiteralPath $Repo -Filter $pat -File -Recurse -Depth 1 -ErrorAction SilentlyContinue |
        ForEach-Object { './' + ([IO.Path]::GetRelativePath($Repo, $_.FullName) -replace '\\', '/') } |
        Where-Object { $_ -notmatch '/(vendor|node_modules)/' -and ($_ -split '/')[-1] -like $pat } | Sort-Object # -Filter *.sln also matches .slnx
}
# The venv python of dir $d, relative to it (Windows or Linux layout); $null if there is none.
function VenvPy([string]$d) { '.venv/Scripts/python.exe', '.venv/bin/python' | Where-Object { Test-Path -LiteralPath (In "$d/$_") -PathType Leaf } | Select-Object -First 1 }
function Runs([string]$exe, [string]$code) { try { & $exe -c $code *> $null; $LASTEXITCODE -eq 0 } catch { $false } }
# Manifests deeper than one level, to report as SKIP (same depth and pruning as the find in run-gates.sh).
function Deep([string]$dir, [int]$depth) {
    foreach ($e in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
        if ($e.PSIsContainer) { if ($depth -lt 3 -and $e.Name -notin 'vendor', 'node_modules', '.git', '.venv', '.next', 'target', 'dist', 'build') { Deep $e.FullName ($depth + 1) } }
        elseif ($depth -ge 2 -and $e.Name -in 'package.json', 'pyproject.toml') { $e.FullName }
    }
}
# Compiles without writing .pyc files (compileall would litter a repo that has no .gitignore).
$pycheck = 'import sys; [compile(open(f, "rb").read(), f, "exec") for f in sys.argv[1:]]'

# Each step: Label, Rule (exit0 | emptyout | pytest | test | notrun), Dir, Cmd (pwsh; for notrun, the reason)
# (pytest and test steps are what make a pass count: lint/build/syntax-only results exit 3)
$steps = [Collections.Generic.List[object]]::new()
$langs = [Collections.Generic.List[string]]::new()
$skips = [Collections.Generic.List[string]]::new()
function Step($label, $rule, $dir, $cmd) { $steps.Add([pscustomobject]@{ Label = $label; Rule = $rule; Dir = $dir; Cmd = $cmd }) }

foreach ($pp in Manifests 'pyproject.toml') {
    $d = $pp -replace '/[^/]+$', ''
    $sfx = $d -eq '.' ? '' : " ($d)"
    $langs.Add($d -eq '.' ? 'python' : "python:$d")
    if ((Select-String -LiteralPath (In $pp) -Pattern '^\s*\[tool\.ruff' -Quiet) -or (Test-Path -LiteralPath (In "$d/ruff.toml")) -or (Test-Path -LiteralPath (In "$d/.ruff.toml"))) {
        $ruff = 'uvx ruff'
        if ((Test-Path -LiteralPath (In "$d/uv.lock")) -and (Select-String -LiteralPath (In "$d/uv.lock") -Pattern '^name = "ruff"$' -CaseSensitive -Quiet)) { $ruff = 'uv run --frozen ruff' }
        Step "ruff check$sfx" 'exit0' $d "$ruff check --no-fix ."
        Step "ruff format --check$sfx" 'exit0' $d "$ruff format --check ."
    }
    $venv = VenvPy $d
    if (Test-Path -LiteralPath (In "$d/uv.lock")) { Step "pytest$sfx" 'pytest' $d 'uv run --frozen pytest -p no:cacheprovider' }
    elseif ($venv) { Step "pytest$sfx" 'pytest' $d "& './$venv' -m pytest -p no:cacheprovider" }
    else { Step "pytest$sfx" 'notrun' '.' "no uv.lock and no .venv: use the test command the repo's CLAUDE.md/README names" }
}
if (-not (Test-Path -LiteralPath (In 'pyproject.toml')) -and ((Test-Path -LiteralPath (In 'requirements.txt')) -or (Get-ChildItem -LiteralPath $Repo -Filter '*.py' -File | Select-Object -First 1))) {
    if (Test-Path -LiteralPath (In 'tests') -PathType Container) {
        $langs.Add('python')
        $venv = VenvPy '.'
        $py = $venv ? "./$venv" : ('python', 'python3' | Where-Object { Runs $_ 'pass' } | Select-Object -First 1)
        if (-not $py) { Step 'py syntax' 'notrun' '.' 'python not installed'; Step 'pytest' 'notrun' '.' 'python not installed' }
        else {
            Step 'py syntax' 'exit0' '.' "& '$py' -c '$pycheck' @(git -c core.quotepath=off ls-files -co --exclude-standard -- '*.py')"
            if (Runs ($venv ? (In $venv) : $py) 'import pytest') { Step 'pytest' 'pytest' '.' "& '$py' -m pytest -q -p no:cacheprovider" }
            else { Step 'pytest' 'notrun' '.' "pytest is not importable by $py" }
        }
    }
    else { $skips.Add('SKIP requirements.txt / *.py: no tests/ dir, so no Python gate') }
}
$mods = @(Get-ChildItem -LiteralPath $Repo -Filter 'go.mod' -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { [IO.Path]::GetRelativePath($Repo, $_.FullName) -notmatch '(^|[\\/])(vendor|node_modules)[\\/]' } |
    ForEach-Object { $d = [IO.Path]::GetRelativePath($Repo, $_.DirectoryName) -replace '\\', '/'; $d -eq '.' ? '.' : "./$d" } | Sort-Object)
foreach ($d in $mods) {
    $langs.Add("go:$d")
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Step "go ($d)" 'notrun' '.' 'go toolchain not installed'; continue }
    Push-Location -LiteralPath (In $d); $cgo = & go env CGO_ENABLED 2>$null; Pop-Location
    $race = $cgo -eq '1' ? ' -race' : ''
    Step "gofmt ($d)" 'emptyout' $d '$f = @(Get-ChildItem -Recurse -File -Filter *.go | Resolve-Path -Relative | Where-Object { $_ -notmatch ''[\\/](vendor|testdata)[\\/]'' }); if ($f) { gofmt -l @f }'
    Step "go vet ($d)" 'exit0' $d 'go vet ./...'
    Step "go test$race ($d)" 'test' $d "go test$race ./..."
}
foreach ($cm in ((Test-Path -LiteralPath (In 'Cargo.toml')) ? './Cargo.toml' : (Manifests 'Cargo.toml'))) { # a root Cargo.toml already covers its workspace members
    $d = $cm -replace '/[^/]+$', ''
    $langs.Add("rust:$d")
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Step "cargo ($d)" 'notrun' '.' 'cargo toolchain not installed'; continue }
    Step "cargo test ($d)" 'test' $d 'cargo test --quiet'
}
$dn = @(Manifests '*.sln') + @(Manifests '*.slnx')
if (-not $dn) { $dn = @(Manifests '*.csproj') }
foreach ($proj in $dn) {
    $langs.Add('dotnet:' + ($proj -replace '/[^/]+$', ''))
    $name = $proj -replace '^\./', ''
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Step "dotnet ($name)" 'notrun' '.' 'dotnet toolchain not installed'; continue }
    Step "dotnet build ($name)" 'test' '.' "dotnet build --nologo -v q '$proj'" # the build is .NET's gate
}
foreach ($pj in Manifests 'package.json') {
    $d = $pj -replace '/[^/]+$', ''
    $sfx = $d -eq '.' ? '' : " ($d)"
    $langs.Add($d -eq '.' ? 'node' : "node:$d")
    $n = $steps.Count
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Step "node$sfx" 'notrun' '.' 'node toolchain not installed'; continue }
    $pm = 'npm'
    foreach ($l in $d, '.') {
        if (Test-Path -LiteralPath (In "$l/yarn.lock")) { $pm = 'yarn' } elseif (Test-Path -LiteralPath (In "$l/pnpm-lock.yaml")) { $pm = 'pnpm' }
        if ($pm -ne 'npm') { break }
    }
    try { $pjo = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (In $pj) -Raw) -AsHashtable } # an empty file is $null here, which throws like node does
    catch { Step "node$sfx" 'notrun' '.' "malformed $($pj -replace '^\./', '') (not valid JSON)"; continue }
    $scripts = ($pjo -is [Collections.IDictionary] -and $pjo['scripts'] -is [Collections.IDictionary]) ? $pjo['scripts'] : @{}
    foreach ($s in 'typecheck', 'lint', 'test', 'build') {
        $body = [string]$scripts[$s]
        if (-not $body) { continue }
        if ($s -eq 'build' -and $NoBuild) { $skips.Add("SKIP $($pj -replace '^\./', '') build script: -NoBuild"); continue }
        # typecheck/build verify a Node repo with no test script (Next.js sites); lint alone doesn't
        $rule = $s -in 'test', 'typecheck', 'build' ? 'test' : 'exit0'
        if ($body -like '*no test specified*') { Step "$pm run $s$sfx" 'notrun' '.' 'placeholder script (npm init default)' }
        elseif ($body -match '(^|\s)(--watch|-w|watch)(\s|$)') { Step "$pm run $s$sfx" 'notrun' '.' "watch mode would never exit: $body" }
        else { Step "$pm run $s$sfx" $rule $d "$pm run $s" }
    }
    if ($steps.Count -eq $n) { Step "node$sfx" 'notrun' '.' 'no gate steps found' }
}
foreach ($m in @(Deep $Repo 0)) { $skips.Add("SKIP $([IO.Path]::GetRelativePath($Repo, $m) -replace '\\', '/'): more than one level down") }
if (-not $langs.Count) {
    $skips | ForEach-Object { "  $_" }
    NotRunnable "no recognized gate (no pyproject.toml / go.mod / package.json / Cargo.toml / .sln / .csproj, no requirements.txt + tests/) in $Repo"
}

# Child pwsh: plain output, a missing command exits 127 (like a shell), a native exit code passes through.
# Its output goes straight to a file through cmd.exe, never a pipe: a daemon that a passing step leaves behind
# inherits the pipe, and the child (or this script's caller) would block until the daemon exits.
$wrap = '$PSStyle.OutputRendering = "PlainText"; $ErrorActionPreference = "Stop"; trap [System.Management.Automation.CommandNotFoundException] { "$_"; exit 127 }; & { CMD }; exit $LASTEXITCODE'
# Same reason: stop our own stdio handles (the caller's pipes) from being inherited by the steps and their daemons.
Add-Type -Namespace Gate -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n); [DllImport("kernel32.dll")] public static extern bool SetHandleInformation(IntPtr h, int mask, int flags);'
foreach ($h in -10, -11, -12) { $null = [Gate.Native]::SetHandleInformation([Gate.Native]::GetStdHandle($h), 1, 0) }
# A failure only counts as "tool or dependency missing" if it says so in its first lines; a real failure can print "not found" anywhere later.
$nrRe = '^error: Failed to spawn|^(bash|sh|/usr/bin/env): (\d+: |line \d+: )?\S+: (command )?not found$|is not recognized as an internal or external command|is not recognized as a name of|No module named ''?(pytest|ruff|mypy)''?$'

$pwsh = (Get-Process -Id $PID).Path # same pwsh that runs this script, even if not on PATH
Write-Output "GATE ($($langs -join ' ')) for $Repo  (timeout ${TimeoutSec}s/step, ${TotalTimeoutSec}s total)"
$skips | ForEach-Object { "  $_" }
$anyFail = $anyTimeout = $anyPass = $anyNotrun = $anyTest = $false
$before = @(git -C $Repo status --porcelain 2>$null)
foreach ($s in $steps) {
    if ($s.Rule -eq 'notrun') { $anyNotrun = $true; Write-Output ('  {0,-26} {1}' -f $s.Label, "NOT RUNNABLE: $($s.Cmd)"); continue }
    $left = $TotalTimeoutSec - [int]$tAll.Elapsed.TotalSeconds
    if ($left -le 0) { $anyTimeout = $true; Write-Output ('  {0,-26} {1}' -f $s.Label, "SKIPPED (total ${TotalTimeoutSec}s budget exhausted; unverified)"); continue }
    $stepSec = [Math]::Min($TimeoutSec, $left)
    $logFile = [IO.Path]::GetTempFileName() # one per step: a daemon still holding the last one must not write into the next
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrap.Replace('CMD', $s.Cmd)))
    $psi = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $psi.Arguments = "/d /s /c `"`"$pwsh`" -NoProfile -NonInteractive -EncodedCommand $enc > `"$logFile`" 2>&1`""
    $psi.WorkingDirectory = In $s.Dir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true # never read: they only keep our own stdio out of the child
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close() # like </dev/null: a prompt gets EOF instead of hanging
    $timedOut = -not $p.WaitForExit($stepSec * 1000)
    if ($timedOut) { & taskkill /T /F /PID $p.Id *> $null } # whole tree, so orphans can't keep writing
    $p.WaitForExit()
    $code = $p.ExitCode
    $log = @(Get-Content -LiteralPath $logFile -Encoding utf8)
    Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue # fails while a daemon holds it; it is only a temp file
    $show = $true
    if ($timedOut) { $anyTimeout = $true; $verdict = "TIMEOUT after ${stepSec}s (unverified)" }
    elseif ($code -ne 0 -and ($code -in 126, 127 -or ($log | Select-Object -First 10) -match $nrRe)) {
        $anyNotrun = $true; $verdict = "NOT RUNNABLE (exit ${code}: tool or dependency missing)"
    }
    elseif ($s.Rule -eq 'pytest' -and $code -eq 5) { $anyNotrun = $true; $verdict = 'no tests collected (nothing verified)'; $show = $false }
    elseif ($code -eq 0 -and ($s.Rule -ne 'emptyout' -or -not ($log -join ''))) {
        $anyPass = $true; $verdict = 'pass'; $show = $false
        if ($s.Rule -in 'test', 'pytest') { $anyTest = $true }
    }
    else { $anyFail = $true; $verdict = "FAIL (exit $code)" }
    Write-Output ('  {0,-26} {1}' -f $s.Label, $verdict)
    if ($show) { $log | Where-Object { $_ -match '\S' } | Select-Object -Last $Tail | ForEach-Object { "      | $_" } }
}
$after = @(git -C $Repo status --porcelain 2>$null)
$new = @($after | Where-Object { $_ -notin $before })
if ($new) { Write-Output '  WARN: the gate changed the working tree:'; $new | ForEach-Object { "      $_" } }
Write-Output ''
if ($anyFail) { Write-Output 'RESULT: FAIL'; exit 1 }
if ($anyTimeout) { Write-Output 'RESULT: unverified (a step timed out or the total budget ran out)'; exit 2 }
if (-not $anyPass) { Write-Output 'RESULT: not runnable (nothing was verified)'; exit 3 }
if (-not $anyTest) { Write-Output 'RESULT: not runnable (no test, typecheck or build step ran: lint/syntax checks alone do not verify behaviour)'; exit 3 }
if ($anyNotrun) { Write-Output 'RESULT: pass (partial: some steps could not run, see above)'; exit 0 }
Write-Output 'RESULT: pass'
exit 0
