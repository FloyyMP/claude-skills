#Requires -Version 7
<#
.SYNOPSIS
  Mechanical consistency check of a Claude Code memory dir: every file indexed, every
  index line points at a file, every file has valid frontmatter, and every inline
  [[wikilink]] resolves. Read-only; prints findings. Exit 0 = consistent (dead
  wikilinks and rot warnings are informational and do NOT fail), 1 = structural findings.
  Port of memory-index-check.py.

.PARAMETER MemoryDir
  Defaults to the first hit of: autoMemoryDirectory in <project root>/.claude/settings.local.json,
  <project root>/.claude/settings.json, ~/.claude/settings.local.json, ~/.claude/settings.json;
  else the derived auto-memory dir (~/.claude/projects/<root-slug>/memory) for this session's git root
  (session found via $env:CLAUDE_CODE_SESSION_ID), else for the current directory's git root.
  The first output line names the source. No memory files at all = pass.

.PARAMETER Stats
  Also print memory count by type and orphan memories (not in any MEMORY.md, no inbound [[wikilink]]).

.DESCRIPTION
  Archive folders and dot-folders are skipped; the archived file count is printed.
  Rot warnings ("warn: ...", never change the exit code): oversized MEMORY.md, long or multi-link index
  lines, duplicate descriptions, staleness markers in index lines.
#>
[CmdletBinding()]
param(
    [string]$MemoryDir,
    [switch]$Stats
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$projects = Join-Path $HOME '.claude' 'projects'
$archiveDirs = 'archive', 'archived', 'unused', 'deprecated'
# group 1 = <angle target, may contain spaces>, group 2 = plain target
$linkRe = '\]\((?:<(?![a-z][a-z0-9+.-]*:)([^>#]+\.md)(?:#[^>]*)?>|(?![a-z][a-z0-9+.-]*:)([^)>#\s]+\.md)(?:#[^)>\s]*)?)(?:\s+"[^"]*")?\)'
# Explicit status phrases only: bare words like "stale"/"verify" are mostly rule text ("Memory can be stale").
$staleRe = [regex]::new('(\(some stale\)|\(verify\b[^)]*\)|\bon hold\b|\bunregistered\b|\bdeprecated\b|\boutdated\b)', 'IgnoreCase, CultureInvariant')

function Sorted([string[]]$a) { # ordinal, like Python's sorted()
    $l = [Collections.Generic.List[string]]::new($a)
    $l.Sort([StringComparer]::Ordinal)
    , $l
}
function Cut([string]$s, [int]$n) { $s.Substring(0, [Math]::Min($n, $s.Length)) }
function Capped($a) { (@($a | Select-Object -First 10) -join ', ') + ($a.Count -gt 10 ? " (+$($a.Count - 10) more)" : '') }
function Full([string]$p) { # absolute, no trailing separator, like Python's os.path.abspath
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($p, (Get-Location).ProviderPath))
}
function Read-Text([string]$p, [bool]$strict) { # like Python's utf-8-sig; $strict throws on invalid bytes
    $s = [Text.UTF8Encoding]::new($false, $strict).GetString([IO.File]::ReadAllBytes($p))
    if ($s.Length -and $s[0] -eq [char]0xFEFF) { $s.Substring(1) } else { $s }
}

function Session-Cwd {
    $sid = $env:CLAUDE_CODE_SESSION_ID
    if ($sid) {
        foreach ($t in @(Get-ChildItem -Path (Join-Path $projects '*' "$sid.jsonl") -File -ErrorAction SilentlyContinue)) {
            try {
                foreach ($line in [IO.File]::ReadLines($t.FullName)) {
                    if ($line -cmatch '"cwd":"((?:[^"\\]|\\.)*)"') { return ConvertFrom-Json ('"' + $Matches[1] + '"') }
                }
            } catch { continue } # unreadable/garbled transcript: try the next one, then fall back to our cwd
        }
    }
    return (Get-Location).ProviderPath
}

function Project-Root([string]$cwd) {
    # Auto-memory is keyed by the git root of the MAIN worktree, not the launch dir: a session started in a
    # subdirectory or a linked worktree keeps its transcript under a different slug than its memory.
    $common = & git -C $cwd rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -eq 0 -and $common -match '[\\/]\.git$') { return $common.Substring(0, $common.Length - 5) }
    return $cwd
}

function Slug-Dir([string]$root) {
    $slug = $root -creplace '[^A-Za-z0-9]', '-' # UTF-16 units, like Claude Code's JS replace()
    $names = Sorted @(Get-ChildItem -LiteralPath $projects -Name -Force -ErrorAction SilentlyContinue)
    $hit = $slug
    if (-not $names.Contains($slug)) { $hit = ($names | Where-Object { $_ -ieq $slug } | Select-Object -First 1) ?? $slug }
    return Join-Path $projects $hit 'memory'
}

$mem = $null
if ($MemoryDir) { $mem = Full $MemoryDir; $source = '--memory-dir' }
else {
    $root = Project-Root (Session-Cwd)
    foreach ($f in (Join-Path $root '.claude' 'settings.local.json'), (Join-Path $root '.claude' 'settings.json'),
                   (Join-Path $HOME '.claude' 'settings.local.json'), (Join-Path $HOME '.claude' 'settings.json')) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        try { $d = Read-Text $f $false | ConvertFrom-Json } catch { Write-Output "settings file unreadable (ignored): $f"; continue }
        $v = ($d -is [pscustomobject]) ? $d.PSObject.Properties['autoMemoryDirectory']?.Value : $null
        if ($v -is [string] -and $v.Trim()) {
            if ($v -match '^~([\\/]|$)') { $v = $HOME + $v.Substring(1) }
            $mem = Full $v; $source = "autoMemoryDirectory $f"
            break
        }
    }
    if (-not $mem) { $mem = Full (Slug-Dir $root); $source = 'derived' }
}
Write-Output "memory dir: $mem (source: $source)"

if (-not (Test-Path -LiteralPath $mem -PathType Container)) {
    if ($source -ne 'derived') { Write-Output "  memory dir missing: $mem"; exit 1 }
    Write-Output 'memory files: 0 (nothing saved in this project yet; derived dir does not exist)'; exit 0
}

function Rel([string]$p) { [IO.Path]::GetRelativePath($mem, $p) }
function Archived([string]$p) {
    foreach ($d in ((Rel $p) -split '[\\/]' | Select-Object -SkipLast 1)) { if ($d.ToLower() -in $archiveDirs) { return $true } }
    return $false
}
# dot-files/dirs are skipped, like Python's glob
$found = Sorted @(Get-ChildItem -LiteralPath $mem -Filter '*.md' -File -Recurse -Force | ForEach-Object FullName |
    Where-Object { (Rel $_) -notmatch '(^|[\\/])\.' })
$allMd = @($found | Where-Object { -not (Archived $_) })
$skipped = $found.Count - $allMd.Count
$archivedLine = "archived (skipped): $skipped files in $((Sorted $archiveDirs) -join ', ') folders"
if (-not $allMd) {
    Write-Output 'memory files: 0 (nothing saved in this project yet)'
    if ($skipped) { Write-Output $archivedLine }
    exit 0
}
if (-not (Test-Path -LiteralPath (Join-Path $mem 'MEMORY.md') -PathType Leaf)) { Write-Output "MEMORY.md missing at $(Join-Path $mem 'MEMORY.md')"; exit 1 }
$files = @($allMd | Where-Object { (Split-Path $_ -Leaf) -ne 'MEMORY.md' })
$indexes = @($allMd | Where-Object { (Split-Path $_ -Leaf) -eq 'MEMORY.md' })

# Links from ALL MEMORY.md files (root + subfolders), resolved relative to the index containing them.
# Any .md link on a line indexes its file, but only the first link per line is that line's entry,
# so "indexed twice" counts entries within one index, not cross-refs.
$linked = [Collections.Generic.HashSet[string]]::new()
$twice = [Collections.Generic.HashSet[string]]::new()
$longLines = [Collections.Generic.List[string]]::new()
$multi = [Collections.Generic.List[string]]::new()
$stale = [Collections.Generic.List[string]]::new()
$warns = [Collections.Generic.List[string]]::new()
$blank = [Text.RegularExpressions.MatchEvaluator]{ param($m) "`n" * ($m.Value.Split("`n").Count - 1) }
foreach ($idx in $indexes) {
    $raw = Read-Text $idx $false
    # blank comments/fences but keep their newlines so reported line numbers stay right
    $text = [regex]::Replace($raw, '(?sm)<!--.*?-->|^```.*?^```', $blank)
    $lines = [regex]::Split($text, '\r?\n')
    $n = $lines.Count - ($lines[-1] -eq '' ? 1 : 0) # a trailing newline is not another line
    if ((Rel $idx) -ceq 'MEMORY.md') {
        $nb = (Get-Item -LiteralPath $idx).Length
        if ($n -gt 150 -or $nb -gt 20480) {
            $warns.Add("warn: MEMORY.md is $n lines / $nb bytes (warn above 150 lines / 20480 bytes); " +
                'Claude Code loads only the first 200 lines / 25 KB of MEMORY.md each session, the rest is never seen')
        }
    }
    $ent = [hashtable]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $n; $i++) {
        $line = $lines[$i]
        $where = "$(Rel $idx):$($i + 1)"
        if ($line.Length -gt 150) { $longLines.Add($where) }
        if ([regex]::Matches($line, '\]\(').Count -gt 1) { $multi.Add($where) }
        $s = $staleRe.Match($line)
        if ($s.Success) { $stale.Add("$where [$($s.Groups[1].Value.ToLowerInvariant())] $(Cut ($line.Trim()) 60)") }
        $rs = @(foreach ($m in [regex]::Matches($line, $linkRe)) {
            $t = [Uri]::UnescapeDataString(($m.Groups[1].Success ? $m.Groups[1].Value : $m.Groups[2].Value))
            Rel ([IO.Path]::GetFullPath((Join-Path (Split-Path $idx) $t)))
        })
        foreach ($x in $rs) { $null = $linked.Add($x) }
        if ($rs) { $ent[$rs[0]] = 1 + ($ent[$rs[0]] ?? 0) }
    }
    foreach ($k in $ent.Keys) { if ($ent[$k] -gt 1) { $null = $twice.Add($k) } }
}

$baseNames = [Collections.Generic.HashSet[string]]::new([string[]]@($files | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }))
$archivedNames = [Collections.Generic.HashSet[string]]::new([string[]]@($found |
    Where-Object { (Archived $_) -and (Split-Path $_ -Leaf) -ne 'MEMORY.md' } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }))
$findings = [Collections.Generic.List[string]]::new()
$deadWiki = [Collections.Generic.List[string]]::new()
$archivedWiki = [Collections.Generic.List[string]]::new()
$inbound = [hashtable]::new([StringComparer]::Ordinal)
$descs = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new([StringComparer]::Ordinal)
$typeCount = [ordered]@{}
$typeRe = '^\s*type:\s*["'']?(user|feedback|project|reference)["'']?\s*(#.*)?$'
foreach ($f in $files) {
    $name = Split-Path $f -Leaf
    $base = [IO.Path]::GetFileNameWithoutExtension($f)
    $relf = Rel $f
    if (-not $linked.Contains($relf)) { $findings.Add("not in index : $relf") }
    try { $body = Read-Text $f $true }
    catch {
        $e = $_.Exception.InnerException ?? $_.Exception
        $findings.Add("unreadable   : $relf ($($e -is [Text.DecoderFallbackException] ? 'invalid UTF-8' : 'read error'))"); continue
    }
    $lines = $body -split "`r?`n"
    $end = 0
    if ($lines[0] -eq '---') { for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } } }
    $head = $end ? $lines[0..($end - 1)] : @()
    $stripped = [regex]::Replace($body, '(?s)```.*?```|`[^`\n]*`', '')
    foreach ($m in [regex]::Matches($stripped, '\[\[([^\]|#]+)[^\]]*\]\]')) {
        $t = $m.Groups[1].Value.Trim() -creplace '\.md$', ''
        if ($baseNames.Contains($t)) { $inbound[$t] = 1 + ($inbound[$t] ?? 0) }
        elseif ($archivedNames.Contains($t)) { $archivedWiki.Add("$name -> [[$t]] points to archived file") }
        else { $deadWiki.Add("$name -> [[$t]]") }
    }
    if (-not $head) { $findings.Add("no frontmatter: $name"); continue }
    $nm = $head | ForEach-Object { if ($_ -cmatch '^name:\s*(\S+)') { $Matches[1] } } | Select-Object -First 1
    if (-not $nm) { $findings.Add("no name:      $name") }
    elseif ($nm.Trim('"', "'") -cne $base) { $findings.Add("name/file mismatch: $name has name: $nm") }
    $dv = $head | ForEach-Object { if ($_ -cmatch '^description:\s*(\S.*?)\s*$') { $Matches[1] } } | Select-Object -First 1
    if (-not $dv) { $findings.Add("no description: $name") }
    elseif ($dv -cnotmatch '^[>|][-+0-9]*$') { # block scalar indicator, not a value
        $key = $dv.Trim('"', "'")
        if (-not $descs.ContainsKey($key)) { $descs[$key] = [Collections.Generic.List[string]]::new() }
        $descs[$key].Add($relf)
    }
    $ty = $head | ForEach-Object { if ($_ -cmatch $typeRe) { $Matches[1] } } | Select-Object -First 1
    if (-not $ty) { $findings.Add("bad/missing type: $name") } else { $typeCount[$ty] = 1 + ($typeCount[$ty] ?? 0) }
}
foreach ($r in (Sorted @($linked))) {
    if (-not (Test-Path -LiteralPath (Join-Path $mem $r))) { $findings.Add("dangling link : $r") }
}
foreach ($r in (Sorted @($twice))) { $findings.Add("indexed twice : $r") }

if ($longLines.Count) { $warns.Add("warn: $($longLines.Count) index lines over 150 characters: $(Capped $longLines)") }
if ($multi.Count) { $warns.Add("warn: $($multi.Count) index lines with more than one link: $(Capped $multi)") }
foreach ($d in $descs.Keys) {
    if ($descs[$d].Count -gt 1) { $warns.Add("warn: duplicate description in $($descs[$d] -join ', '): $(Cut $d 60)") }
}
if ($stale.Count) {
    $w = "warn: $($stale.Count) index lines with staleness markers:"
    foreach ($s in ($stale | Select-Object -First 10)) { $w += "`n    $s" }
    if ($stale.Count -gt 10) { $w += "`n    (+$($stale.Count - 10) more)" }
    $warns.Add($w)
}

Write-Output ("memory files: $($files.Count)   indexed files: $($linked.Count)   findings: $($findings.Count)   " +
    "dead wikilinks: $($deadWiki.Count)   rot warnings: $($warns.Count)")
if ($skipped) { Write-Output $archivedLine }
foreach ($x in $findings) { Write-Output "  $x" }
foreach ($w in $warns) { foreach ($x in ($w -split "`n")) { Write-Output $x } }
foreach ($b in @(@('dead [[wikilink]] targets (forward refs are allowed; listed for awareness)', $deadWiki),
                 @('[[wikilink]] targets in archive folders (informational)', $archivedWiki))) {
    $title = $b[0]; $items = $b[1]
    if ($items.Count) {
        Write-Output "  ${title}: $($items.Count), first $([Math]::Min(5, $items.Count)):"
        foreach ($d in ($items | Select-Object -First 5)) { Write-Output "    $d" }
    }
}
if ($Stats) {
    Write-Output ''
    Write-Output 'STATS'
    Write-Output ('  by type: ' + (($typeCount.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    $orphans = @($files | Where-Object { -not $linked.Contains((Rel $_)) -and -not $inbound.ContainsKey([IO.Path]::GetFileNameWithoutExtension($_)) } |
        ForEach-Object { Rel $_ })
    Write-Output "  orphans (not in any MEMORY.md, no inbound [[wikilink]]): $($orphans.Count)"
    if ($orphans.Count -le 10) { foreach ($o in $orphans) { Write-Output "    $o" } }
}
exit ($findings.Count ? 1 : 0)
