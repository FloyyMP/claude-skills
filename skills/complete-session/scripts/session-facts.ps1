#Requires -Version 7
<#
.SYNOPSIS
  Print what this Claude Code session actually did, from its transcript on disk.

.DESCRIPTION
  Parses ~/.claude/projects/<cwd-slug>/<session-id>.jsonl (plus any subagent
  transcripts under <session-id>/subagents/) and reports, as evidence rather than
  recall: files edited (grouped by git repo, or classified when outside any repo),
  repos touched (with a live git-state snapshot and the dirty paths the session
  did not edit), external effects (git writes, installs, plugins, MCP, GitHub,
  schedulers, registry/env, detached processes, deletes), background jobs,
  subagents, worktrees entered, files handed to the user, questions asked, skills
  invoked, schedulers, the last todo list, compaction count + tokens dropped, and
  the session temp dir. Tool calls whose result was an error are excluded.
  Port of session-facts.py.

  Writes no files. Runs git (rev-parse, status, rev-list, config, remote,
  symbolic-ref, stash/worktree list) against touched repos with --no-optional-locks
  (no index refresh) and nothing else.

  Exit codes: 0 = report produced (even with warnings), 1 = transcript not found,
  unreadable or bad session id.

.PARAMETER SessionId
  Defaults to $env:CLAUDE_CODE_SESSION_ID; failing that, the newest transcript is
  used and a warning is printed. [A-Za-z0-9_-] only.

.PARAMETER Json
  Emit one JSON object instead of the human-readable report.

.PARAMETER Brief
  Header, warnings, repos, outside-repo edits, external effects, counts and open
  todos only.
#>
[CmdletBinding()]
param(
    [string]$SessionId = $env:CLAUDE_CODE_SESSION_ID,
    [switch]$Json,
    [switch]$Brief
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Piped output defaults to the OEM code page (cp850) and mangles non-ASCII paths. No console attached: keep the default.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { $null = $_ }

$inv = [cultureinfo]::InvariantCulture
$utf8 = [Text.UTF8Encoding]::new($false)
$claudeDir = Join-Path $HOME '.claude'
$projectsRoot = Join-Path $claudeDir 'projects'
$ic = [Text.RegularExpressions.RegexOptions]::IgnoreCase
$sl = [Text.RegularExpressions.RegexOptions]::Singleline
$noRepo = '(not in a git repo)'
$sep = [IO.Path]::DirectorySeparatorChar

$gitWriteRx = [regex]::new('\bgit(\s+-[Cc]\s+\S+)*\s+(commit|push|stash\s+(push|pop|apply|drop|save)|stash\s*($|[;&|])|switch\s+-c|checkout\s+(-b|--)|worktree\s+add|rebase|merge|reset|branch\s+-[dDm]|tag\s+(?!-l)\S|cherry-pick|am|add|rm|mv|apply|restore|revert|pull|clean|init)\b', $ic)
# Writes the model does through the shell: redirects (not `->` / `>=`), in-place editors, heredoc scripts that write
# files, formatters/package managers that rewrite the tree, and the PowerShell file cmdlets.
$fsWriteRx = [regex]::new('(?<![\d\-=])>{1,2}\s*[^&\s=]|\bsed\s+-i\b|\bperl\s+-[a-z]*i|\brm\s|\bmv\s|\bcp\s|\btee\b|\bmkdir\b|\btouch\b|\bunlink\b|\bln\s+-s\b|\bchmod\b|\binstall\s+-|\bpatch\b|\.write_(text|bytes)\(|\bopen\([^)]*[''"][wax]b?\+?[''"]|--write\b|--fix\b|\b(npm|pnpm|yarn)\s+(install|i|add|ci|update)\b|\buv\s+(add|remove|lock|sync)\b|\bcargo\s+fmt\b|\bruff\s+format\b(?!\s+--check)|\b(Set-Content|Out-File|Add-Content|New-Item|Copy-Item|Move-Item|Remove-Item|Rename-Item|Expand-Archive)\b', $ic)
# Absolute paths in shell commands (/..., ~/..., $HOME/..., C:\..., quoted with spaces) - feeds shell-touched repo detection.
# Not after `scheme:` (https://host/x), and Add-ShellPath drops anything starting // or \\ (a UNC probe stalls for seconds).
$pathRx = [regex]::new('(?<![\w/.:\\])(?:/|~[/\\]|\$HOME[/\\]|\$\{HOME\}[/\\]|[A-Za-z]:[/\\])[^\s''"`|;&<>()]*|(?<=")(?:/|[A-Za-z]:[/\\])[^"]+(?=")|(?<='')(?:/|[A-Za-z]:[/\\])[^'']+(?='')')
# Relative targets too: `cd ../lib && ...`, `git -C other commit` - resolved against the record's cwd.
$cdRx = [regex]::new('(?:\bcd|\bSet-Location|\bPush-Location|\s-C)\s+(?:"([^"]+)"|''([^'']+)''|([^\s;&|)]+))')
$processRx = [regex]::new('\bnohup\b|\bsetsid\b|\bdisown\b|\bnpm\s+(run\s+)?(dev|start)\b|\bpnpm\s+(run\s+)?(dev|start)\b|\byarn\s+(dev|start)\b|\bgo\s+run\b|\buvicorn\b|\bflask\s+run\b|\bnext\s+(dev|start)\b|\bvite\b(?!\.config)|\bpython3?\s+-m\s+http\.server\b|\bssh\s+-[fN]|\bdocker(-compose|\s+compose)?\s+(run|up)\b|\bpm2\s+start\b|\btmux\s+new|\bscreen\s+-d|\bsystemd-run\b|\b(Start-Process|Start-Job)\b', $ic)
# A bare `&` backgrounds in bash but is the call operator in PowerShell, so only Bash commands get this check.
$bashAmpRx = [regex]::new('(?<![&>|])&(?![&>\d])')

# Shell command -> statements. Groups: 1 redirection (dropped), 2 separator, 3 word (quoted chunks stay inside it).
# Bash honours \" inside double quotes; in PowerShell a backslash is just a path character ("C:\dir\").
function New-TokenRx([string]$dq) { [regex]::new('(\d*>&-?\d*|&>>?)|(&&|\|\||[;|\n]|&)|((?:[^\s;&|"'']|' + $dq + '|''[^'']*'')+)') }
$tokenRx = @{ Bash = (New-TokenRx '"(?:[^"\\]|\\.)*"'); PowerShell = (New-TokenRx '"[^"]*"') }
$envChars = [char[]]@('$', '%')
$quoteChars = [char[]]@('"', "'")
$unquoteRx = [regex]::new('"([^"]*)"|''([^'']*)''')
$heredocRx = [regex]::new('(?<!<)<<-?\s*([''"]?)(\w+)\1([^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|$)', $sl)
$herestrRx = [regex]::new('@([''"])\n.*?\n\1@', $sl)
$substRx = [regex]::new('\$\([^()]*\)')
$envAssignRx = [regex]::new('^[A-Za-z_]\w*=')
$skipWords = @('sudo', 'env', 'time', 'command', 'exec', 'builtin', '{', '}', '(', ')', '!', 'then', 'do', 'else', 'elif', 'if')
$secretRx = [regex]::new('(\bauthorization\s*[=:]\s*(?:(?:bearer|basic|token)\s+)?|(?:[\w.-]*(?:token|key|secret|passw(?:or)?d)[\w.-]*)\s*[=:]\s*|(?<![\w-])--?[\w-]*(?:token|key|secret|passw(?:or)?d)[\w-]*\s+|\bbearer\s+)("[^"]*"|''[^'']*''|[^\s''"]+)', $ic)
$urlCredRx = [regex]::new('(?<=://)[^/@\s]+@')
$regArgRx = [regex]::new('^(hk(cu|lm|cr|u|cc)[:\\]|hkey_|registry::)', $ic)
$regCmdlets = @('set-itemproperty', 'new-itemproperty', 'remove-itemproperty')
$wrappers = @{ bash = 'Bash'; sh = 'Bash'; zsh = 'Bash'; pwsh = 'PowerShell'; powershell = 'PowerShell'; cmd = 'PowerShell' }
$deleteCmds = @('rm', 'rmdir', 'del', 'erase', 'rd', 'ri', 'remove-item', 'unlink')
$psValueFlags = @('-filter', '-include', '-exclude', '-erroraction', '-ea')  # Remove-Item switches that take a value
# Programs Get-Kind can classify: anything else is skipped before the (slow) pipeline-heavy classification.
$knownProgs = [Collections.Generic.HashSet[string]]::new([string[]](@('git', 'python', 'python3', 'py', 'pip', 'pip3', 'pipx', 'uv', 'npm', 'pnpm', 'yarn', 'winget', 'choco', 'scoop', 'cargo', 'go', 'claude', 'npx', 'gh', 'schtasks', 'crontab', 'reg', 'setx', 'nohup', 'setsid', 'disown', 'start-process', 'start-job') + $regCmdlets + $deleteCmds))
$deferred = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Bash', 'PowerShell', 'Skill', 'Agent')  # wait for their tool_result

$warnings = [Collections.Generic.List[string]]::new()
function Add-Warning([string]$msg) { if (-not $warnings.Contains($msg)) { $warnings.Add($msg) } }

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
function Is-Flag([string]$x) { $x.Length -gt 0 -and $x[0] -eq '-' }
function Tail-Of($a, [int]$from) { if ($from -ge @($a).Count) { , @() } else { , @(@($a)[$from..(@($a).Count - 1)]) } }
function Redact([string]$s) { $urlCredRx.Replace($secretRx.Replace($s, '$1<redacted>'), '<redacted>@') }

# ---------- paths ----------
function Expand-Home([string]$p) { if ($p.Length -eq 0 -or ($p[0] -ne [char]'~' -and $p[0] -ne [char]'$')) { return $p }; $p -replace '^(~|\$HOME|\$\{HOME\})(?=[/\\])', $HOME.Replace('$', '$$') }
function Expand-Env([string]$p) {
    if ($p.IndexOfAny($envChars) -lt 0) { return $p }
    [regex]::Replace($p, '\$env:(\w+)|\$\{(\w+)\}|\$(\w+)|%(\w+)%', {
        param($m)
        $name = @($m.Groups[1], $m.Groups[2], $m.Groups[3], $m.Groups[4] | Where-Object Success)[0].Value
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { $v } else { $m.Value }
    })
}
function Full-Path([string]$p) {
    $p = Expand-Home $p
    if ($IsWindows) {
        if ($p -match '^/([A-Za-z])(/.*)?$') { $p = "$($Matches[1].ToUpperInvariant()):$($Matches[2] ?? '/')" } # Git Bash /c/... -> C:/...
        elseif ($p -match '^/tmp(/|$)') { $p = ($env:TEMP ?? $env:TMP ?? '') + $p.Substring(4) } # Git Bash mounts /tmp on %TEMP%
    }
    $full = [IO.Path]::GetFullPath($p)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\', '/') }  # abspath drops a trailing separator too
    return $full
}
$realCache = @{}
function Real-Path([string]$p) {
    # A symlinked/junctioned path and its target are one file: resolve every component and take its on-disk case (os.path.realpath does both).
    $full = Full-Path $p
    $root = [IO.Path]::GetPathRoot($full)
    $cur = $root
    foreach ($part in ($full.Substring($root.Length) -split '[\\/]')) {
        if (-not $part) { continue }
        $key = [IO.Path]::Combine($cur, $part)
        if (-not $realCache.ContainsKey($key)) {
            $res = $key
            if ([IO.Directory]::Exists($key) -or [IO.File]::Exists($key)) {
                foreach ($e in [IO.DirectoryInfo]::new($cur).EnumerateFileSystemInfos($part)) {
                    $res = $e.FullName
                    if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $e.LinkTarget) { $t = $e.ResolveLinkTarget($true); if ($t) { $res = $t.FullName } }
                    break
                }
            }
            $realCache[$key] = $res
        }
        $cur = $realCache[$key]
    }
    if ($IsWindows -and $cur.Length -gt 1 -and $cur[1] -eq ':' -and [IO.Directory]::Exists($root)) { $cur = $cur.Substring(0, 1).ToUpperInvariant() + $cur.Substring(1) }
    return $cur
}
function Test-Rooted([string]$p) { if ($IsWindows) { $p -match '^([A-Za-z]:[/\\]|[/\\])' } else { $p.StartsWith('/') } }
function Path-Exists([string]$p) { [IO.File]::Exists($p) -or [IO.Directory]::Exists($p) }
function Up-To([string]$p, [scriptblock]$ok) {
    # Nearest ancestor of p (p included) satisfying ok. A root has no parent, so stop there.
    while ($p -and -not (& $ok $p)) {
        $parent = [IO.Path]::GetDirectoryName($p)
        if (-not $parent -or $parent -eq $p) { return $null }
        $p = $parent
    }
    if ($p) { return $p } else { return $null }
}
function Norm-Case([string]$p) { if ($IsWindows) { $p.Replace('/', '\').ToLowerInvariant() } else { $p } }
function Under([string]$p, [string]$d) {
    $p = Norm-Case $p; $d = (Norm-Case $d).TrimEnd('\', '/')
    return ($p -ceq $d) -or $p.StartsWith($d + $sep, [StringComparison]::Ordinal)
}
function Resolve-Target([string]$t, $cur) {
    $t = Expand-Home (Expand-Env $t)
    if ($t -match '\$|%\w+%') { return $null }  # an unexpanded variable: no way to know what it names
    if (-not (Test-Rooted $t)) {
        if (-not $cur) { return $null }
        $t = [IO.Path]::Combine($cur, $t)
    }
    return Real-Path $t
}
function First-Uuid([string]$path) {
    foreach ($line in [IO.File]::ReadLines($path)) {
        try { $u = ($line | ConvertFrom-Json -AsHashtable -Depth 1024)['uuid'] } catch { continue }
        if ($u) { return $u }
    }
    return $null
}

# ---------- shell command -> external effects ----------
function Get-Statements([string]$cmd, [string]$tool) {
    # Split a shell command into statements (Words, Amp). Quotes keep words whole; heredoc bodies are dropped.
    $cmd = $cmd.Replace("`r`n", "`n")
    $cmd = $heredocRx.Replace($herestrRx.Replace($cmd, "''"), '$3')
    for ($i = 0; $i -lt 3; $i++) { $cmd = $substRx.Replace($cmd, 'SUBST') }
    $cmd = $cmd.Replace($(if ($tool -eq 'PowerShell') { '`' } else { '\' }) + "`n", ' ')  # line continuation
    $out = [Collections.Generic.List[object]]::new(); $cur = [Collections.Generic.List[string]]::new()
    foreach ($m in $tokenRx[$tool].Matches($cmd)) {
        $g = $m.Groups
        if ($g[1].Success) { continue }
        if ($g[2].Success) {
            if ($cur.Count) { $out.Add(@{ Words = $cur.ToArray(); Amp = ($tool -eq 'Bash' -and $g[2].Value -eq '&') }) }
            $cur = [Collections.Generic.List[string]]::new()
        } else {
            $w = $g[3].Value
            if ($w.IndexOfAny($quoteChars) -ge 0) { $w = $unquoteRx.Replace($w, '$1$2') }  # a group that did not take part adds nothing
            $cur.Add($w)
        }
    }
    if ($cur.Count) { $out.Add(@{ Words = $cur.ToArray(); Amp = $false }) }
    return , $out
}
function Prog-Name([string]$w) {
    $w = $w.TrimStart('(', '{')
    $i = [math]::Max($w.LastIndexOf('\'), $w.LastIndexOf('/')); if ($i -ge 0) { $w = $w.Substring($i + 1) }
    foreach ($e in '.exe', '.cmd', '.bat', '.ps1', '.com') { if ($w.EndsWith($e, [StringComparison]::OrdinalIgnoreCase)) { return $w.Substring(0, $w.Length - 4) } }
    return $w
}

function Git-Split([string[]]$r) {  # git args -> global options, subcommand, args
    $j = 0
    while ($j -lt $r.Count -and (Is-Flag $r[$j])) { if ($r[$j] -cin '-C', '-c', '--git-dir', '--work-tree', '--namespace') { $j += 2 } else { $j++ } }
    [pscustomobject]@{ G = $(if ($j) { @($r[0..([math]::Min($j, $r.Count) - 1)]) } else { @() }); Sub = $(if ($j -lt $r.Count) { $r[$j].ToLowerInvariant() } else { '' }); Args = (Tail-Of $r ($j + 1)) }
}
function Split-Args([string[]]$a) {  # lower-cased positionals and the set of lower-cased flags
    $pos = [Collections.Generic.List[string]]::new(); $fl = [Collections.Generic.HashSet[string]]::new()
    foreach ($x in $a) { if ($x.Length -gt 0 -and $x[0] -eq '-') { [void]$fl.Add($x.ToLowerInvariant()) } else { $pos.Add($x.ToLowerInvariant()) } }
    [pscustomobject]@{ Pos = $pos.ToArray(); Fl = $fl }
}
function Git-Writes([string]$sub, [string[]]$a) {
    $sa = Split-Args $a; $pos = $sa.Pos; $fl = $sa.Fl
    switch ($sub) {
        { $_ -in 'commit', 'push', 'merge', 'rebase', 'reset', 'pull', 'fetch', 'cherry-pick', 'revert', 'am', 'init' } { return $true }
        'tag' { return ($pos.Count -gt 0 -and -not $fl.Overlaps([string[]]@('-l', '--list'))) }
        'stash' { return (-not $pos.Count -or $pos[0] -notin 'list', 'show') }
        'config' { return ($pos.Count -gt 1 -or $fl.Overlaps([string[]]@('--unset', '--unset-all', '--add', '--replace-all', '--edit', '-e', '--remove-section', '--rename-section'))) }
        'worktree' { return ($pos.Count -gt 0 -and $pos[0] -in 'add', 'remove', 'move', 'prune', 'lock', 'unlock', 'repair') }
        { $_ -in 'checkout', 'switch' } { return ($fl.Overlaps([string[]]@('-b', '-c', '--orphan')) -or (-not $fl.Contains('--') -and $pos.Count -eq 1 -and $pos[0] -ne '.')) }  # ponytail: a lone positional is taken as a branch; `git checkout <file>` also lands here
        'branch' {
            if ($fl.Overlaps([string[]]@('-a', '-r', '-l', '-v', '-vv', '--all', '--remotes', '--list', '--verbose', '--show-current', '--contains', '--merged', '--no-merged'))) { return $false }
            return ($pos.Count -gt 0 -or $fl.Overlaps([string[]]@('-d', '-m', '-c', '--delete', '--move', '--copy', '--set-upstream-to', '-u', '--unset-upstream')))
        }
    }
    return $false
}
function Get-Kind([string]$name, [string[]]$r) {
    # Effect kind of one statement (program name + args), or $null when it stays inside the working tree.
    if ($name -in 'python', 'python3', 'py' -and $r.Count -ge 2 -and $r[0] -ceq '-m' -and $r[1] -ceq 'pip') { $name = 'pip'; $r = [string[]](Tail-Of $r 2) }
    $sa = Split-Args $r; $pos = $sa.Pos; $fl = $sa.Fl
    $p0 = if ($pos.Count -gt 0) { $pos[0] } else { '' }
    $p1 = if ($pos.Count -gt 1) { $pos[1] } else { '' }
    if ($fl.Overlaps([string[]]@('--help', '-h', '--version'))) { return $null }
    switch -Regex ($name) {
        '^git$' { $g = Git-Split $r; if (Git-Writes $g.Sub $g.Args) { return 'git-write' } else { return $null } }
        '^(pip|pip3|pipx)$' { if ($p0 -in 'install', 'uninstall') { return 'install' } else { return $null } }
        '^uv$' { if ($p0 -in 'pip', 'tool' -and $p1 -in 'install', 'uninstall', 'upgrade') { return 'install' } else { return $null } }
        '^(npm|pnpm|yarn)$' {
            if (($p0 -in 'install', 'i', 'add', 'uninstall', 'remove', 'rm', 'update', 'up', 'upgrade' -and $fl.Overlaps([string[]]@('-g', '--global'))) -or $p0 -eq 'global') { return 'install' } else { return $null }
        }
        '^(winget|choco|scoop)$' { if ($p0 -in 'install', 'upgrade', 'uninstall', 'update', 'remove') { return 'install' } else { return $null } }
        '^(cargo|go)$' { if ($p0 -eq 'install') { return 'install' } else { return $null } }
        '^claude$' {
            if ($p0 -in 'plugin', 'plugins') {
                if ($p1 -in 'install', 'uninstall', 'enable', 'disable', 'update' -or ($p1 -eq 'marketplace' -and $pos.Count -gt 2 -and $pos[2] -in 'add', 'remove', 'rm', 'update')) { return 'plugin' } else { return $null }
            }
            if ($p0 -eq 'mcp' -and $p1 -in 'add', 'remove', 'add-json') { return 'mcp' } else { return $null }
        }
        '^npx$' { if (($p0 -split '@')[0] -eq 'skills' -and $p1 -in 'add', 'remove', 'update') { return 'skill' } else { return $null } }
        '^gh$' {
            if ($p0 -in 'repo', 'release', 'pr', 'issue') {
                if ($p1 -in 'create', 'edit', 'delete') { return 'github' } else { return $null }
            }
            if ($p0 -eq 'api' -and ($r -join ' ') -match '(?i)(?:^|\s)(?:-X|--method)[=\s]*(POST|PUT|PATCH|DELETE)\b') { return 'github' } else { return $null }
        }
        '^schtasks$' { if (@($r | Where-Object { $_.ToLowerInvariant() -in '/create', '/delete', '/change', '/end', '/run' }).Count) { return 'schedule' } else { return $null } }
        '^(register|unregister|set|enable|disable)-scheduledtask$' { return 'schedule' }
        '^crontab$' { if ($pos.Count -or @($fl | Where-Object { $_ -ne '-l' }).Count) { return 'schedule' } else { return $null } }
        '^reg$' { if ($p0 -in 'add', 'delete', 'import') { return 'registry' } else { return $null } }
    }
    if ($name -in $regCmdlets -and @($r | Where-Object { $regArgRx.IsMatch($_) }).Count) { return 'registry' }
    $s = (@($name) + $r) -join ' '
    if ($name -eq 'setx' -or ($s.Contains('setenvironmentvariable', [StringComparison]::OrdinalIgnoreCase) -and $s -match '(?i)\b(user|machine)\b')) { return 'env' }
    if ($name -in $deleteCmds) { return 'delete' }
    if ($name -in 'nohup', 'setsid', 'disown', 'start-process', 'start-job') { return 'process' }
    return $null
}
function Delete-Targets([string[]]$r) {
    $out = [Collections.Generic.List[string]]::new(); $take = $false; $skip = $false
    foreach ($x in $r) {
        $lx = $x.ToLowerInvariant()
        if ($take) { $out.Add($x); $take = $false }
        elseif ($skip) { $skip = $false }
        elseif ($lx -in '-path', '-literalpath') { $take = $true }
        elseif ($lx -in $psValueFlags) { $skip = $true }
        elseif ((Is-Flag $x) -or $lx -in '/s', '/q', '/f', '/p', '/a') { continue }
        else { $out.Add($x) }
    }
    return , $out.ToArray()
}
function Tail-Path([string]$p, [int]$n = 48) { if ($p.Length -le $n) { $p } else { '...' + $p.Substring($p.Length - ($n - 3)) } }  # the end of a path is the part that names the target
function Summary([string[]]$words) {
    # One statement as <=100 chars: redirections and block braces dropped, secrets redacted.
    $keep = [Collections.Generic.List[string]]::new(); $skip = $false
    foreach ($x in $words) {
        if ($skip) { $skip = $false }
        elseif ($x -match '^(\d*>>?|<)$') { $skip = $true }  # `> file`: drop the target too
        elseif ($x -cne '{' -and $x -cne '}' -and $x -notmatch '^\d*[<>]') { $keep.Add($x) }
    }
    Trunc (Redact (One-Line ($keep -join ' '))) 100
}
function Git-Dir($g, $cur) {
    # Directory a git command acts in: its -C argument (resolved against cur) or cur.
    $d = $null
    for ($j = 0; $j -lt @($g).Count - 1; $j++) { if (@($g)[$j] -ceq '-C') { $d = @($g)[$j + 1]; break } }
    if ($d) { return (Resolve-Target $d $cur) ?? $d } else { return $cur }
}
function Under-SessionTmp([string]$p) {
    if (-not $script:tmpRoot -or -not (Under $p $script:tmpRoot)) { return $false }
    $parts = $p.Substring($script:tmpRoot.TrimEnd('\', '/').Length).TrimStart('\', '/') -split '[\\/]'
    return ($parts.Count -gt 1 -and $parts[1] -in $script:sessionIds)
}
function Get-ShellEffects([string]$cmd, [string]$tool, [string]$cwd, [bool]$bg, [int]$depth = 0) {
    # -> Fx (Kind, Summary) and Dels (resolved delete targets). Only commands that reach beyond the repo working tree.
    $fx = [Collections.Generic.List[object]]::new(); $dels = [Collections.Generic.List[string]]::new(); $cur = $cwd; $first = $null
    $hasSetEnv = $cmd.Contains('setenvironmentvariable', [StringComparison]::OrdinalIgnoreCase)
    foreach ($st in (Get-Statements $cmd $tool)) {
        $a = [string[]]$st.Words
        $b = [array]::IndexOf($a, '{'); if ($b -ge 0) { $a = [string[]](Tail-Of $a ($b + 1)) }
        $i = 0
        while ($i -lt $a.Count -and ($a[$i].ToLowerInvariant() -in $skipWords -or $envAssignRx.IsMatch($a[$i]))) { $i++ }
        if ($i -ge $a.Count) { continue }
        if ($i) { $a = [string[]](Tail-Of $a $i) }
        $disp = Prog-Name $a[0]; $r = [string[]]@(if ($a.Count -gt 1) { $a[1..($a.Count - 1)] })
        $name = $disp.ToLowerInvariant()
        if ($name -in 'cd', 'chdir', 'set-location', 'sl', 'push-location', 'pushd') {
            $t = @($r | Where-Object { -not (Is-Flag $_) })
            if ($t.Count) { $cur = Resolve-Target $t[0] $cur }  # $null for `cd $DIR`: where we are is unknown from here on
            continue
        }
        if ($bg -and -not $first) { $first = @($disp) + $r }
        if ($wrappers.ContainsKey($name) -and $depth -lt 2) {
            $k = -1
            for ($j = 0; $j -lt $r.Count; $j++) { if ($r[$j].ToLowerInvariant() -in '-c', '-command', '/c') { $k = $j; break } }
            if ($k -ge 0 -and $k + 1 -lt $r.Count) {
                $sub = Get-ShellEffects ((Tail-Of $r ($k + 1)) -join ' ') $wrappers[$name] $cur $false ($depth + 1)
                foreach ($e in $sub.Fx) { $fx.Add($e) }
                foreach ($d in $sub.Dels) { $dels.Add($d) }
            }
            continue
        }
        $kind = if ($knownProgs.Contains($name) -or $name.EndsWith('-scheduledtask') -or ($hasSetEnv -and (@($disp) + $r -join ' ').Contains('setenvironmentvariable', [StringComparison]::OrdinalIgnoreCase))) { Get-Kind $name $r }
        if ($kind -eq 'delete') {
            $raw = [string[]](Delete-Targets $r)
            $res = @(foreach ($t in $raw) { Resolve-Target $t $cur })
            foreach ($x in $res) { if ($x) { $dels.Add($x) } }
            $shown = @(for ($j = 0; $j -lt $raw.Count; $j++) {
                $x = $res[$j] ?? $raw[$j]
                if (-not ((Test-Rooted $x) -and (Under-SessionTmp $x))) { $x }
            })
            if (-not $raw.Count -or $shown.Count) {
                $tg = (@($shown | Select-Object -First 3 | ForEach-Object { Tail-Path $(if (Test-Rooted $_) { [IO.Path]::GetFullPath($_) } else { $_ }) }) -join ', ') + $(if ($shown.Count -gt 3) { " (+$($shown.Count - 3))" } else { '' })
                $fx.Add(@{ Kind = 'delete'; Summary = (Trunc (Redact "$disp $(if ($tg) { $tg } else { '(piped)' })") 100) })
            }
            continue
        }
        if (-not $kind -and $st.Amp) { $kind = 'process' }
        if (-not $kind) { continue }
        $words = @($disp) + $r
        if ($kind -eq 'git-write') {
            $g = Git-Split $r
            $where = Git-Dir $g.G $cur
            if ($where -and (Test-Rooted $where) -and (Under-SessionTmp $where)) { continue }  # a scratch repo inside the session temp dir
            $words = @('git', $g.Sub) + @($g.Args)
            $leaf = if ($where) { [IO.Path]::GetFileName([IO.Path]::GetFullPath($where).TrimEnd('\', '/')) } else { '' }  # not Split-Path: it reads 'C:' as the drive's current dir
            if ($leaf -and $leaf -cne [IO.Path]::GetFileName($HOME.TrimEnd('\', '/'))) { $words += "($leaf)" }
        }
        $fx.Add(@{ Kind = $kind; Summary = (Summary $words) })
    }
    if ($bg -and $depth -eq 0) {
        $bgWords = if ($first) { @($first | Select-Object -First 6) } else { @('?') }
        $fx.Insert(0, @{ Kind = 'process'; Summary = (Summary (@('background:') + $bgWords)) })
    }
    return [pscustomobject]@{ Fx = $fx; Dels = $dels }
}
function Glob-Rx([string]$pat) {
    # A deleted path pattern -> regex matching it, anything inside it, and (for `dir/*`) its children.
    $pat = Norm-Case $pat
    $body = -join ($pat.ToCharArray() | ForEach-Object { if ($_ -eq '*') { '[^\\/]*' } elseif ($_ -eq '?') { '.' } else { [regex]::Escape([string]$_) } })
    [regex]::new('^' + $body.TrimEnd('\', '/') + '(?:[\\/].*)?$', $sl)
}

# ---------- locate the transcript ----------
if ($SessionId) {
    if ($SessionId -notmatch '^[A-Za-z0-9_-]+$') { [Console]::Error.WriteLine("Invalid session id '$SessionId': only letters, digits, - and _ are allowed"); exit 1 }
    $transcript = Get-ChildItem -Path (Join-Path $projectsRoot '*' "$SessionId.jsonl") -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $transcript) { [Console]::Error.WriteLine("No transcript named $SessionId.jsonl under $projectsRoot"); exit 1 }
} else {
    $transcript = Get-ChildItem -Path (Join-Path $projectsRoot '*' '*.jsonl') -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $transcript) { [Console]::Error.WriteLine("No transcripts found under $projectsRoot"); exit 1 }
    $SessionId = $transcript.BaseName
    Add-Warning "No session id given and `$CLAUDE_CODE_SESSION_ID unset; using newest transcript ($SessionId). With parallel sessions this may be the wrong one."
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

# ---------- session temp dir (/tmp/claude-<uid>/<slug>/<session-id>; %TEMP%\claude\... on Windows) ----------
$tmpRootRaw = if ($IsWindows) { Join-Path ($env:TEMP ?? $env:TMP ?? '') 'claude' } else { Join-Path ($env:TMPDIR ? $env:TMPDIR : '/tmp') "claude-$(& id -u)" }
$script:tmpRoot = Real-Path $tmpRootRaw
$script:sessionIds = [string[]]$ids.ToArray()
$tmpHits = @(foreach ($i in $ids) { Get-ChildItem -Path (Join-Path $tmpRootRaw '*' $i) -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName })
if ($tmpHits) {
    $files = @(foreach ($h in $tmpHits) { Get-ChildItem -LiteralPath $h -File -Recurse -Force -ErrorAction SilentlyContinue })
    [long]$bytes = 0
    foreach ($f in $files) {  # follow symlinks (task .output files link to transcripts); broken links count 0
        if (-not $f.LinkTarget) { $bytes += $f.Length; continue }
        $t = $f.ResolveLinkTarget($true); if ($t -and $t.Exists -and $t -is [IO.FileInfo]) { $bytes += $t.Length }
    }
    $tmpdir = [ordered]@{ Path = $tmpHits[0]; Files = $files.Count; Bytes = $bytes; Missing = $false }
} else {
    $tmpdir = [ordered]@{ Path = (Join-Path $tmpRootRaw '<slug>' $SessionId); Files = 0; Bytes = 0; Missing = $true }
}

# ---------- accumulators ----------
$edits = [ordered]@{}   # path -> @{ count; tools; sidechain }
$effects = [Collections.Generic.List[object]]::new(); $background = [Collections.Generic.List[object]]::new()
$agents = [Collections.Generic.List[object]]::new(); $schedulers = [Collections.Generic.List[object]]::new()
$worktrees = [Collections.Generic.List[object]]::new(); $handoffs = [Collections.Generic.List[object]]::new()
$questions = [Collections.Generic.List[object]]::new(); $skills = [Collections.Generic.List[object]]::new()
$lastTodos = $null
$tasks = [ordered]@{}; $pendingCreates = @{}   # TaskCreate/TaskUpdate (the todo tools since TodoWrite was retired)
$cwds = [Collections.Generic.List[string]]::new(); $branches = [Collections.Generic.List[string]]::new()
$shellPaths = [Collections.Generic.HashSet[string]]::new()
$deletes = [Collections.Generic.List[string]]::new()  # resolved targets of successful rm / Remove-Item calls (may hold wildcards)
$calls = [Collections.Generic.List[object]]::new(); $errors = [Collections.Generic.HashSet[string]]::new()  # tool_use blocks wait until every tool_result has been seen
$asstIds = [Collections.Generic.HashSet[string]]::new()
$agentIds = [Collections.Generic.HashSet[string]]::new()  # a fork's transcript opens with a replay of the Agent call that launched it
$firstTs = $null; $lastTs = $null
$compactions = 0; [long]$dropped = 0; $userTurns = 0; $assistantTurns = 0; $toolCalls = 0; $badLines = 0

function Add-Edit([string]$path, [string]$tool, [bool]$sidechain) {
    if (-not $path.Trim()) { return }
    $path = Real-Path $path
    if (-not $edits.Contains($path)) { $edits[$path] = @{ count = 0; tools = [Collections.Generic.HashSet[string]]::new(); sidechain = $false } }
    $e = $edits[$path]; $e.count++; [void]$e.tools.Add($tool); if ($sidechain) { $e.sidechain = $true }
}
function Add-ShellPath([string]$p) {
    if (-not $p.Replace('\', '/').StartsWith('//')) { [void]$shellPaths.Add($p) }  # URLs, Git Bash flags (taskkill //F) and regex debris look like UNC shares
}

function Tool-Use([string]$name, [Collections.IDictionary]$inp, $ts, [bool]$sidechain, [string]$cwd, $useId, [bool]$failed = $false) {
    if ($failed -and $name -notin 'Bash', 'PowerShell') { return }  # refused / interrupted / errored: it did not happen
    switch -Regex ($name) {
        '^(Edit|Write|MultiEdit)$' { Add-Edit (Str $inp['file_path']) $name $sidechain; return }
        '^NotebookEdit$' { Add-Edit (Str $inp['notebook_path']) $name $sidechain; return }
        '^(Bash|PowerShell)$' {
            $cmd = Str $inp['command']
            $bg = $inp['run_in_background'] -eq $true
            $flags = [Collections.Generic.List[string]]::new()
            if ($bg) { $flags.Add('background') }
            if ($gitWriteRx.IsMatch($cmd)) { $flags.Add('git-write') }
            if ($fsWriteRx.IsMatch($cmd)) { $flags.Add('fs-write') }
            if ($processRx.IsMatch($cmd) -or ($name -eq 'Bash' -and $bashAmpRx.IsMatch($cmd))) { $flags.Add('process') }
            # cd / -C targets from EVERY command: `cd ../lib && ./fmt.sh` writes without any write-looking token.
            # Inclusion later still needs dirty/unpushed state, and PreExistingDirty separates the user's own WIP.
            foreach ($m in $cdRx.Matches($cmd)) {
                $g = @($m.Groups[1], $m.Groups[2], $m.Groups[3] | Where-Object Success)[0].Value
                $p = Expand-Home $g
                try { if ($cwd -and -not (Test-Rooted $p)) { $p = [IO.Path]::GetFullPath([IO.Path]::Combine($cwd, $p)) } } catch { continue }
                if (Test-Rooted $p) { Add-ShellPath $p }
            }
            if ($flags.Count) { foreach ($m in $pathRx.Matches($cmd)) { Add-ShellPath (Expand-Home $m.Value) } }
            if ($failed) { return }
            $res = Get-ShellEffects $cmd $name $cwd $bg
            foreach ($e in $res.Fx) { $effects.Add([ordered]@{ Time = $ts; Kind = $e.Kind; Summary = $e.Summary }) }
            foreach ($d in $res.Dels) { $deletes.Add($d) }
            if ($bg) { $background.Add([ordered]@{ Time = $ts; Tool = $name; Flags = ($flags -join ','); Sidechain = $sidechain; Command = (Trunc (Redact (One-Line $cmd)) 180) }) }
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
            $text = if ($inp['prompt']) { Str $inp['prompt'] } elseif ($inp['command']) { Str $inp['command'] } else { To-JsonStr $inp }
            $schedulers.Add([ordered]@{ Time = $ts; Tool = $name; Detail = (Trunc $text 140) }); return
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
    if ($typ -eq 'user' -and $content -is [Collections.IList]) {
        foreach ($b in $content) {
            if ($b -is [Collections.IDictionary] -and $b['type'] -eq 'tool_result' -and $b['is_error'] -eq $true) { [void]$errors.Add([string]$b['tool_use_id']) }
        }
    }
    if ($typ -eq 'user' -and -not $sidechain -and $content -is [Collections.IList] -and $pendingCreates.Count) {
        # TaskCreate's id only appears in its result: "Task #3 created successfully".
        foreach ($b in $content) {
            if ($b -is [Collections.IDictionary] -and $b['type'] -eq 'tool_result' -and $b['tool_use_id'] -and $pendingCreates.ContainsKey($b['tool_use_id'])) {
                $subject = $pendingCreates[$b['tool_use_id']]; $pendingCreates.Remove($b['tool_use_id'])
                if ((To-JsonStr $b['content']) -match 'Task #(\d+)') { $tasks[$Matches[1]] = [ordered]@{ Status = 'pending'; Content = $subject } }
            }
        }
    }
    if ($typ -eq 'user' -and -not $sidechain -and -not $r['isMeta'] -and -not $r['isCompactSummary']) {
        # Tool results come back as 'user' records too; count only real prompts (not task notifications,
        # interrupt markers or the compaction summary).
        if ($content -is [string] -or ($content -is [Collections.IList] -and
                -not ($content | Where-Object { $_ -is [Collections.IDictionary] -and $_['type'] -eq 'tool_result' }))) {
            $text = if ($content -is [string]) { $content } else {
                [string](@($content | Where-Object { $_ -is [Collections.IDictionary] -and $_['type'] -eq 'text' } | ForEach-Object { Str $_['text'] })[0])
            }
            if ($text.TrimStart() -notmatch '^(<task-notification>|\[Request interrupted by user|This session is being continued from a previous conversation)') { $script:userTurns++ }
        }
    }
    if ($typ -ne 'assistant') { return }
    if (-not $sidechain) {  # one message is several records (one per content block) sharing message.id
        if ($msg['id']) { [void]$asstIds.Add([string]$msg['id']) } else { $script:assistantTurns++ }
    }
    if ($content -isnot [Collections.IList]) { return }
    foreach ($b in $content) {
        if ($b -isnot [Collections.IDictionary] -or $b['type'] -ne 'tool_use') { continue }
        $script:toolCalls++
        $inp = if ($b['input'] -is [Collections.IDictionary]) { $b['input'] } else { @{} }
        $nm = Str $b['name']
        if ($nm -in $deferred) { $calls.Add(@{ Name = $nm; Inp = $inp; Ts = $ts; Sidechain = $sidechain; Cwd = (Str $r['cwd']); Id = $b['id'] }) }
        else { Tool-Use $nm $inp $ts $sidechain (Str $r['cwd']) $b['id'] }
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

try {
    Read-Transcript $transcript.FullName $false
    foreach ($sf in $subFiles) { Read-Transcript $sf $true }
} catch [System.IO.IOException], [System.UnauthorizedAccessException] {
    [Console]::Error.WriteLine("Cannot read transcript: $($_.Exception.Message)"); exit 1
}
foreach ($c in $calls) {
    try { Tool-Use $c.Name $c.Inp $c.Ts $c.Sidechain $c.Cwd $c.Id ($null -ne $c.Id -and $errors.Contains([string]$c.Id)) }
    catch { $badLines++ }  # one odd call must not sink the whole report
}
$calls.Clear()
# Chronological across main + subagent transcripts. Ordinal sort with the position as tiebreak keeps it stable.
$wrapped = [object[]]@(for ($i = 0; $i -lt $effects.Count; $i++) { [pscustomobject]@{ I = $i; E = $effects[$i] } })
[Array]::Sort($wrapped, [Comparison[object]] { param($x, $y) $c = [string]::CompareOrdinal([string]$x.E.Time, [string]$y.E.Time); if ($c) { $c } else { $x.I - $y.I } })
$sortedEffects = @($wrapped | ForEach-Object { $_.E })
$since = if ($firstTs) { (Parse-Ts $firstTs).UtcDateTime } else { $null }

# ---------- git helpers ----------
$gitOpts = @('--no-optional-locks', '-c', 'core.quotepath=false', '-c', 'core.fsmonitor=false')
function Invoke-Git([string]$root, [string[]]$a, [switch]$Probe) {
    # Ok, Out (stdout lines), Err (first stderr line). A failed non-probe call adds a WARNING; probes (@{u}, config lookups) fail normally.
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($x in $gitOpts + @('-C', $root) + $a) { $psi.ArgumentList.Add($x) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    [void]$psi.Environment.Remove('GIT_DIR'); [void]$psi.Environment.Remove('GIT_WORK_TREE')  # an inherited GIT_DIR points every -C at one repo
    $ok = $false; $stdout = ''; $err = ''
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit(20000)) { $p.WaitForExit(); $ok = ($p.ExitCode -eq 0); $stdout = $so.Result; $err = $se.Result }
        else { try { $p.Kill($true) } catch { $null = $_ }; $err = 'timed out after 20s' }
        $p.Dispose()
    } catch { $err = $_.Exception.Message }
    $errLine = $err -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1
    $err = if ($errLine) { $errLine.Trim() } else { '' }
    if (-not $ok -and -not $Probe) { Add-Warning "git $($a[0]) failed in ${root}: $(if ($err) { $err } else { 'no output' })" }
    [pscustomobject]@{ Ok = $ok; Out = @($stdout -split '\r?\n' | Where-Object { $_.Trim() }); Err = $err }
}
function Git-First($r) { if ($r.Ok -and $r.Out.Count) { $r.Out[0] } }

$repoCache = @{}
function Find-DotGit([string]$d) {
    $x = Up-To $d { param($q) Path-Exists ([IO.Path]::Combine($q, '.git')) }
    if ($x) { [IO.Path]::GetFullPath($x) } else { $null }
}
function Repo-Root([string]$path) {
    $d = Up-To $(if ([IO.Directory]::Exists($path)) { $path } else { [IO.Path]::GetDirectoryName($path) }) { param($q) [IO.Directory]::Exists($q) }  # the file's directory may have been deleted since
    if (-not $d) { return $null }
    if (-not $repoCache.ContainsKey($d)) {
        $r = if (Find-DotGit $d) { Invoke-Git $d @('rev-parse', '--show-toplevel') -Probe } else { [pscustomobject]@{ Ok = $false; Out = @(); Err = 'not a git repository' } }  # no .git above: skip the git process
        if ($r.Ok -and $r.Out.Count) { $root = [IO.Path]::GetFullPath($r.Out[0]) }
        elseif ($r.Err.Contains('not a git repository')) { $root = $null }
        else {  # dubious ownership, unreadable .git, ...: the repo exists, git just won't talk to it
            $root = Find-DotGit $d
            Add-Warning "git rev-parse failed in ${d}: $(if ($r.Err) { $r.Err } else { 'no output' })$(if ($root) { " (treating $root as a repo)" })"
        }
        $repoCache[$d] = $root
    }
    return $repoCache[$d]
}

function Default-Branch([string]$root, [string]$branch, $remotes) {
    # Offline: <remote>/HEAD, else <remote>/main|master. $null when unknown (never guess the current branch).
    $rem = (Git-First (Invoke-Git $root @('config', "branch.$branch.remote") -Probe)) ?? $(if (@($remotes).Count) { @($remotes)[0] })
    if (-not $rem) { return $null }
    $b = Git-First (Invoke-Git $root @('symbolic-ref', '--short', "refs/remotes/$rem/HEAD") -Probe)
    if ($b) { return $b.Substring($rem.Length + 1) }
    foreach ($c in 'main', 'master') { if ((Invoke-Git $root @('rev-parse', '-q', '--verify', "refs/remotes/$rem/$c") -Probe).Ok) { return $c } }
    return $null
}

function Repo-State([string]$root, $edited) {
    $branch = (Git-First (Invoke-Git $root @('symbolic-ref', '--short', 'HEAD') -Probe)) ?? '(detached/unborn)'
    $statusR = Invoke-Git $root @('status', '--porcelain')
    if (-not $statusR.Ok) {  # git can't read this repo: one warning, no half-truths from the remaining calls
        return [ordered]@{ Repo = $root; Branch = $branch; Default = $null; DirtyFiles = $null; PreExistingDirty = 0; HasUpstream = $false
            Ahead = $null; NotOnDefault = $null; Stashes = $null; Worktrees = $null; ViaShell = $false; Unknown = $true
            Unedited = @(); UneditedMore = 0 }
    }
    $bad = $false
    $porcelain = $statusR.Out
    $pre = 0; $unedited = [Collections.Generic.List[object]]::new()
    foreach ($l in $porcelain) {
        $rel = ($l.Substring(3) -split ' -> ')[-1].Trim('"')
        try { $full = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $rel)).TrimEnd('\', '/') } catch { $full = Join-Path $root $rel }
        # Dirty paths untouched since the session started are the user's own work, not ours to commit.
        $old = $false
        if ($since) {
            if ([IO.File]::Exists($full)) { $old = [IO.File]::GetLastWriteTimeUtc($full) -lt $since }
            elseif ([IO.Directory]::Exists($full)) { $old = [IO.Directory]::GetLastWriteTimeUtc($full) -lt $since }
        }
        if ($old) { $pre++ }
        $key = Norm-Case $full
        $under = $false
        if ($rel.EndsWith('/')) { foreach ($e in $edited) { if ($e.StartsWith($key + $sep, [StringComparison]::Ordinal)) { $under = $true; break } } }
        if (-not $edited.Contains($key) -and -not $under) {
            $unedited.Add([ordered]@{ Path = $rel; Status = $l.Substring(0, 2).Trim(); Source = $(if ($old) { 'pre-existing' } else { 'via shell' }) })
        }
    }
    $hasUp = (Invoke-Git $root @('rev-parse', '--abbrev-ref', '@{u}') -Probe).Ok
    $remotesR = Invoke-Git $root @('remote'); if (-not $remotesR.Ok) { $bad = $true }
    $remotes = $remotesR.Out
    $ahead = 0
    if ($hasUp) {
        $cr = Invoke-Git $root @('rev-list', '--count', '@{u}..HEAD'); if (-not $cr.Ok) { $bad = $true }
        $c = Git-First $cr; if ($c) { $ahead = [int]$c }
    } elseif ($remotes.Count) {  # remote but no upstream: commits on no remote at all are still unpushed
        $cr = Invoke-Git $root @('rev-list', '--count', 'HEAD', '--not', '--remotes'); if (-not $cr.Ok) { $bad = $true }
        $c = Git-First $cr; $ahead = if ($c) { [int]$c } else { 0 }
    }
    $default = Default-Branch $root $branch $remotes
    $unmerged = 0
    if ($default -and $branch -notin @($default, '(detached/unborn)')) {
        $cr = Invoke-Git $root @('rev-list', '--count', "$default..HEAD"); if (-not $cr.Ok) { $bad = $true }
        $c = Git-First $cr; $unmerged = if ($c) { [int]$c } else { 0 }
    }
    $stashR = Invoke-Git $root @('stash', 'list'); if (-not $stashR.Ok) { $bad = $true }
    $wtR = Invoke-Git $root @('worktree', 'list'); if (-not $wtR.Ok) { $bad = $true }
    [ordered]@{ Repo = $root; Branch = $branch; Default = $default; DirtyFiles = $porcelain.Count; PreExistingDirty = $pre
        HasUpstream = $hasUp; Ahead = $ahead; NotOnDefault = $unmerged; Stashes = $stashR.Out.Count
        Worktrees = $wtR.Out.Count; ViaShell = $false; Unknown = $bad
        Unedited = @($unedited | Select-Object -First 20); UneditedMore = [math]::Max(0, $unedited.Count - 20) }
}

$selfRepo = $null
# Running this skill's own scripts isn't touching its repo - but only the installed copy; from the clone itself that's real work.
if ((Under $PSScriptRoot (Join-Path $claudeDir 'skills')) -or (Under $PSScriptRoot (Join-Path $HOME '.agents' 'skills'))) {
    $selfRepo = Repo-Root (Real-Path $PSScriptRoot)
}

# ---------- group edits by git repo ----------
$delRx = @(foreach ($d in $deletes) { Glob-Rx $d })
$byRepo = [ordered]@{}
foreach ($p in $edits.Keys) {
    $key = (Repo-Root $p) ?? $noRepo
    if (-not $byRepo.Contains($key)) { $byRepo[$key] = [Collections.Generic.List[object]]::new() }
    $e = $edits[$p]
    $tools = [string[]]@($e.tools); [Array]::Sort($tools, [StringComparer]::Ordinal)
    $exists = Path-Exists $p
    $deleted = $false
    if (-not $exists) { $np = Norm-Case $p; foreach ($rx in $delRx) { if ($rx.IsMatch($np)) { $deleted = $true; break } } }
    $byRepo[$key].Add([ordered]@{ Path = $p; Edits = $e.count; Tools = ($tools -join '+'); Sidechain = $e.sidechain; Exists = $exists; Deleted = $deleted })
}
$repos = [Collections.Generic.List[string]]::new()
foreach ($k in $byRepo.Keys) { if ($k -ne $noRepo) { $repos.Add($k) } }
$editedSet = [Collections.Generic.HashSet[string]]::new([string[]]@($edits.Keys | ForEach-Object { Norm-Case $_ }))
$states = [Collections.Generic.List[object]]::new()
foreach ($r in $repos) { $states.Add((Repo-State $r $editedSet)) }

# ---------- repos touched only through shell commands ----------
# sed -i / heredoc / git commit never show up as Edit/Write, so a repo changed that way would be skipped by
# Step 5. Candidates: every cwd, plus paths named (or cd'd into) by flagged shell commands. Kept only if the
# repo has something to land: dirty, unpushed, or a working branch not yet on its default branch.
$sortedPaths = [string[]]@($shellPaths); [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
foreach ($c in @($cwds) + $sortedPaths) {
    try { $p = Up-To (Full-Path $c) { param($q) Path-Exists $q } } catch { continue }  # the command may have named a file it created or deleted
    $root = if ($p) { Repo-Root $p }
    if (-not $root -or $repos.Contains($root) -or $root -eq $selfRepo) { continue }
    $st = Repo-State $root $editedSet
    if ($st.Unknown -or $st.DirtyFiles -or $st.Ahead -gt 0 -or $st.NotOnDefault -gt 0) { $st.ViaShell = $true; $repos.Add($root); $states.Add($st) }
}

# ---------- edits outside any repo ----------
$settingsMem = $null
try { $settingsMem = (Get-Content -LiteralPath (Join-Path $claudeDir 'settings.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['autoMemoryDirectory'] } catch { $null = $_ }
$memDir = if ($settingsMem -is [string] -and $settingsMem) { Real-Path $settingsMem } else { Real-Path (Join-Path $projectDir 'memory') }
$skillDirs = @((Real-Path (Join-Path $claudeDir 'skills')), (Real-Path (Join-Path $HOME '.agents' 'skills')))
$claudeReal = Norm-Case (Real-Path $claudeDir)
$cfgFile = Norm-Case (Real-Path (Join-Path $HOME 'AGENTS.md'))
$cfgDirs = @((Real-Path (Join-Path $HOME '.codex')), (Real-Path (Join-Path $claudeDir 'scripts')))
function Outside-Kind([string]$p) {
    if (Under-SessionTmp $p) { return 'session-tmp' }
    if (Under $p $memDir) { return 'memory' }
    foreach ($d in $skillDirs) { if (Under $p $d) { return 'installed-skill' } }
    $base = Split-Path -Leaf $p
    if (((Norm-Case (Split-Path -Parent $p)) -ceq $claudeReal -and ($base -ceq 'CLAUDE.md' -or $base -like 'settings*.json')) -or (Norm-Case $p) -ceq $cfgFile) { return 'global-config' }
    foreach ($d in $cfgDirs) { if (Under $p $d) { return 'global-config' } }
    return 'other'
}
$outside = [Collections.Generic.List[object]]::new()
if ($byRepo.Contains($noRepo)) {
    foreach ($it in $byRepo[$noRepo]) { $outside.Add([ordered]@{ Path = $it.Path; Kind = (Outside-Kind $it.Path); Exists = $it.Exists; Deleted = $it.Deleted }) }
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
$assistantTotal = $assistantTurns + $asstIds.Count

$result = [ordered]@{
    SessionId = $SessionId; Transcript = $transcript.FullName; SubagentFiles = $subFiles.Count
    Started = $firstTs; LastActivity = $lastTs; IdleSeconds = $idle
    Cwd = @($cwds); GitBranches = @($branches); Compactions = $compactions; DroppedTokens = $dropped
    UserTurns = $userTurns; AssistantTurns = $assistantTotal; ToolCalls = $toolCalls
    UnparsedLines = $badLines; ReposTouched = @($repos); RepoState = @($states); EditsByRepo = $byRepo
    OutsideRepoEdits = @($outside); ExternalEffects = @($sortedEffects)
    Background = @($background); Agents = @($agents); Worktrees = @($worktrees)
    Handoffs = @($handoffs); Questions = @($questions); Skills = @($skills); Schedulers = @($schedulers)
    OpenTodos = @($openTodos); TodosWritten = $todosWritten; SessionTmp = $tmpdir; Warnings = @($warnings)
}
if ($Json) { $result | ConvertTo-Json -Depth 20; exit 0 }

# ---------- human report ----------
function Fmt-Dur([long]$s) {  # "45m 41s" / "37s" / "1h 2m": never "min" or "sec" (a bare "16s" was once read as 16 minutes)
    if ($s -ge 3600) { return "$([math]::Floor($s / 3600))h $([math]::Floor(($s % 3600) / 60))m" }
    if ($s -ge 60) { return "$([math]::Floor($s / 60))m $($s % 60)s" }
    return "${s}s"
}
function Fmt-Bytes([long]$n) {
    if ($n -ge 1MB) { return ($n / 1MB).ToString('0.0', $inv) + ' MB' }
    if ($n -ge 1KB) { return ($n / 1KB).ToString('0.0', $inv) + ' KB' }
    return "$n bytes"
}
function N([long]$n) { $n.ToString('N0', $inv) }
function Local-Ts($ts, [bool]$timeOnly) { if ($ts) { (Parse-Ts $ts).ToLocalTime().ToString($(if ($timeOnly) { 'HH:mm' } else { 'MM-dd HH:mm' }), $inv) } else { '??' } }

$gap = if ($Brief) { '' } else { "`n" }  # -Brief drops the blank lines between sections
$span = ''
if ($firstTs -and $lastTs) {
    $s = (Parse-Ts $firstTs).ToLocalTime(); $e = (Parse-Ts $lastTs).ToLocalTime()
    $span = '{0} -> {1}  ({2}), idle {3}' -f $s.ToString('yyyy-MM-dd HH:mm', $inv), $e.ToString('yyyy-MM-dd HH:mm', $inv),
        (Fmt-Dur ([long][math]::Truncate(($e - $s).TotalSeconds))), (Fmt-Dur $idle)
}
$turns = "$(N $userTurns) user / $(N $assistantTotal) assistant, $(N $toolCalls) tool calls, $compactions compaction(s)"
if ($compactions -and $dropped) { $turns += ", ~$(N $dropped) tokens dropped (recall unreliable)" }
Write-Output "SESSION $SessionId"
if ($Brief) {
    Write-Output "  $span | $compactions compaction(s)$(if ($compactions -and $dropped) { ", ~$(N $dropped) tokens dropped (recall unreliable)" })"
} else {
    Write-Output "  transcript : $($transcript.FullName)"
    if ($subFiles.Count) { Write-Output "  subagents  : $($subFiles.Count) transcript(s) included" }
    if ($span) { Write-Output "  span       : $span" }
    Write-Output "  turns      : $turns"
    Write-Output "  cwd        : $($cwds -join '; ')"
    if ($badLines) { Write-Output "  unparsed   : $badLines line(s) skipped" }
}
foreach ($w in $warnings) { Write-Output "WARNING: $w" }

if (-not $Brief) {
    Write-Output "`nFILES EDITED (Edit/Write/NotebookEdit): $($edits.Count)"
    if (-not $edits.Count) { Write-Output '  none' }
    foreach ($k in $byRepo.Keys) {
        if ($k -eq $noRepo) { continue }
        Write-Output "  [$k]"
        $items = [object[]]$byRepo[$k].ToArray()
        [Array]::Sort($items, [Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Path, $y.Path) })
        foreach ($it in $items) {
            $tags = @(if ($it.Sidechain) { 'subagent' }) + @(if (-not $it.Exists) { if ($it.Deleted) { 'deleted' } else { 'MISSING NOW' } })
            $tag = if ($tags) { "  <$($tags -join ', ')>" } else { '' }
            Write-Output "    $($it.Path)  ($($it.Edits)x $($it.Tools))$tag"
        }
    }
}

Write-Output "${gap}REPOS TOUCHED: $($repos.Count)"
if (-not $repos.Count) { Write-Output '  none' }
foreach ($s in $states) {
    $up = if ($s.HasUpstream) { "ahead $($s.Ahead)" } else { 'no upstream' }
    $extra = @(if ($s.Stashes) { "$($s.Stashes) stash" }) + @(if ($s.Worktrees -and $s.Worktrees -gt 1) { "$($s.Worktrees) worktrees" })
    $via = if ($s.ViaShell) { if ($Brief) { '  <via shell>' } else { '  <via shell - files not in FILES EDITED, use git status>' } } else { '' }
    Write-Output "  $($s.Repo)$via"
    if ($s.Unknown) {
        Write-Output '      state UNKNOWN (git failed, see WARNING) - check by hand, do not treat as clean'
    } else {
        $pre = if ($s.PreExistingDirty) { " ($($s.PreExistingDirty) untouched since session start = user's own)" } else { '' }
        $nod = if ($s.NotOnDefault) { " | $($s.NotOnDefault) commit(s) not on $($s.Default)" } else { '' }
        Write-Output ("      on $($s.Branch) (default $($s.Default ?? 'unknown')) | dirty $($s.DirtyFiles)$pre | $up$nod" + $(if ($extra) { ' | ' + ($extra -join ', ') } else { '' }))
    }
    if ($s.Unedited.Count) {
        $total = $s.Unedited.Count + $s.UneditedMore
        $cap = if ($Brief) { 8 } else { 20 }
        Write-Output "      dirty, not edited $(if ($Brief) { 'here' } else { 'this session' }) ($total):"
        foreach ($u in ($s.Unedited | Select-Object -First $cap)) { Write-Output "        $($u.Status) $($u.Path)  [$($u.Source)]" }
        if ($total -gt $cap) { Write-Output "        ... +$($total - $cap) more" }
    }
}

$kindOrder = 'memory', 'global-config', 'installed-skill', 'other', 'session-tmp'
$kindHint = @{ 'memory' = 'no commit; Step 6 handles memory'
    'global-config' = 'live config; apply to any mirror (Step 4)'
    'installed-skill' = 'installed copy: edit the source clone instead'
    'other' = 'outside any repo: save or clean up'
    'session-tmp' = 'scratch; Step 2 sweeps it' }
Write-Output "${gap}OUTSIDE ANY REPO: $($outside.Count)"
if (-not $outside.Count) { Write-Output '  none' }
foreach ($kind in $kindOrder) {
    $items = [object[]]@($outside | Where-Object { $_.Kind -eq $kind })
    if (-not $items.Count) { continue }
    [Array]::Sort($items, [Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Path, $y.Path) })
    Write-Output "  $kind ($($items.Count)) - $($kindHint[$kind])"
    if ($Brief -and $kind -in 'memory', 'session-tmp') { continue }  # only the count matters for these
    $cap = if ($Brief) { 8 } else { 25 }
    $shown = @($items | Select-Object -First $cap)
    $tags = @($shown | ForEach-Object { if ($_.Exists) { '' } elseif ($_.Deleted) { ' <deleted>' } else { ' <MISSING NOW>' } })
    if ($Brief) {  # names on one line; a repeated name gets its parent dir
        $names = @($shown | ForEach-Object { Split-Path -Leaf $_.Path })
        $labels = for ($j = 0; $j -lt $shown.Count; $j++) {
            $n = $names[$j]
            $(if (@($names | Where-Object { $_ -ceq $n }).Count -gt 1) { (Split-Path -Leaf (Split-Path -Parent $shown[$j].Path)) + '/' + $n } else { $n }) + $tags[$j]
        }
        Write-Output ('    ' + ($labels -join ', ') + $(if ($items.Count -gt $cap) { ", +$($items.Count - $cap)" } else { '' }))
        continue
    }
    for ($j = 0; $j -lt $shown.Count; $j++) { Write-Output "    $($shown[$j].Path)$($tags[$j])" }
    if ($items.Count -gt $cap) { Write-Output "    ... +$($items.Count - $cap) more" }
}

$cap = if ($Brief) { 15 } else { 30 }
Write-Output "${gap}EXTERNAL EFFECTS: $($sortedEffects.Count)"
if (-not $sortedEffects.Count) { Write-Output '  none' }
foreach ($x in ($sortedEffects | Select-Object -First $cap)) {
    Write-Output "  $(Local-Ts $x.Time $Brief) [$($x.Kind)] $(if ($Brief) { Trunc $x.Summary 62 } else { $x.Summary })"
}
if ($sortedEffects.Count -gt $cap) { Write-Output "  ... +$($sortedEffects.Count - $cap) more" }

function Section([string]$title, $items, [scriptblock]$fmt) {
    Write-Output "`n${title}: $(@($items).Count)"
    foreach ($it in $items) { Write-Output ('  ' + (& $fmt $it)) }
    if (-not @($items).Count) { Write-Output '  none' }
}
if ($Brief) {  # counts on one line, names only for what exists
    $lists = @(
        @{ N = 'background'; I = @($background); F = { param($b) $b.Command } }
        @{ N = 'subagents'; I = @($agents); F = { param($x) if ($x.Type) { $x.Type } else { 'general-purpose' } } }
        @{ N = 'worktrees'; I = @($worktrees); F = { param($w) $w.Detail } }
        @{ N = 'schedulers'; I = @($schedulers); F = { param($s) $s.Tool } })
    Write-Output ("${gap}COUNTS: " + (($lists | ForEach-Object { "$($_.N) $($_.I.Count)" }) -join ' | '))
    foreach ($l in $lists) {
        if (-not $l.I.Count) { continue }
        $tally = [ordered]@{}
        foreach ($it in $l.I) { $k = Trunc ([string](& $l.F $it)) 40; $tally[$k] = 1 + $(if ($tally.Contains($k)) { $tally[$k] } else { 0 }) }
        $keys = @($tally.Keys)
        Write-Output ("  $($l.N): " + ((@($keys | Select-Object -First 6) | ForEach-Object { $_ + $(if ($tally[$_] -gt 1) { " x$($tally[$_])" } else { '' }) }) -join ', ') + $(if ($keys.Count -gt 6) { ", +$($keys.Count - 6)" } else { '' }))
    }
} else {
    Section 'BACKGROUND COMMANDS (run_in_background)' $background { param($b) $b.Command }
    Section 'SUBAGENTS LAUNCHED' $agents { param($x) "$(if ($x.Type) { $x.Type } else { 'general-purpose' }): $($x.Description)" + $(if ($x.Isolation) { " [isolation: $($x.Isolation)]" } else { '' }) }
    Section 'WORKTREES ENTERED (EnterWorktree / Agent isolation:worktree)' $worktrees { param($w) "$($w.Tool): $($w.Detail)" }
    Section 'FILES HANDED TO USER (SendUserFile)' $handoffs { param($h) $h.Path }
    Section 'QUESTIONS ASKED (AskUserQuestion)' $questions { param($q) $q.Headers }
    Section 'SKILLS INVOKED' $skills { param($s) $s.Name + $(if ($s.Args) { " $($s.Args)" } else { '' }) }
    Section 'SCHEDULERS / WATCHES (CronCreate, ScheduleWakeup, Monitor, RemoteTrigger)' $schedulers { param($s) "$($s.Tool): $($s.Detail)" }
}

if (-not $Brief) { Write-Output '' }
if (-not $todosWritten) {
    Write-Output $(if ($Brief) { 'TODO LIST: none written' } else { 'TODO LIST: never written this session' })
} else {
    $total = $(if ($lastTodos -is [Collections.IList]) { $lastTodos.Count } else { 0 }) + $tasks.Count
    Write-Output "TODO LIST: $($openTodos.Count) open of $total"
    foreach ($t in $openTodos) { Write-Output "  [$($t.Status)] $($t.Content)" }
}

if (-not $Brief) {
    Write-Output ''
    if ($tmpdir.Missing) { Write-Output "SESSION TMP: $($tmpdir.Path) (does not exist)" }
    else { Write-Output "SESSION TMP: $($tmpdir.Path)  ($($tmpdir.Files) file(s), $(Fmt-Bytes $tmpdir.Bytes))" }
}
exit 0
