#Requires -Version 7
<#
.SYNOPSIS
  Mechanical consistency check of a Claude Code memory dir: every file indexed, every
  index line points at a file, every file has valid frontmatter, and every inline
  [[wikilink]] resolves. Read-only; prints findings. Exit 0 = consistent (dead
  wikilinks are informational and do NOT fail), 1 = structural findings.
  Port of memory-index-check.py.

.PARAMETER MemoryDir
  Defaults to the auto-memory dir for this session's git root
  (~/.claude/projects/<root-slug>/memory; session found via $env:CLAUDE_CODE_SESSION_ID),
  else for the current directory's git root. No memory files at all = pass.

.PARAMETER Stats
  Also print memory count by type and orphan memories (nothing links to them).
#>
[CmdletBinding()]
param(
    [string]$MemoryDir,
    [switch]$Stats
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projects = Join-Path $HOME '.claude' 'projects'
$archiveDirs = 'archive', 'archived', 'unused', 'deprecated'

function Session-Cwd {
    $sid = $env:CLAUDE_CODE_SESSION_ID
    if ($sid) {
        foreach ($t in @(Get-ChildItem -Path (Join-Path $projects '*' "$sid.jsonl") -File -ErrorAction SilentlyContinue)) {
            foreach ($line in [IO.File]::ReadLines($t.FullName)) {
                if ($line -cmatch '"cwd":"((?:[^"\\]|\\.)*)"') { return ConvertFrom-Json ('"' + $Matches[1] + '"') }
            }
        }
    }
    return (Get-Location).ProviderPath
}

function Default-MemoryDir {
    # Auto-memory is keyed by the git root of the MAIN worktree, not the launch dir: a session started in a
    # subdirectory or a linked worktree keeps its transcript under a different slug than its memory.
    $root = Session-Cwd
    $common = & git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -eq 0 -and $common -match '[\\/]\.git$') { $root = $common.Substring(0, $common.Length - 5) }
    return Join-Path $projects ($root -replace '[^A-Za-z0-9]', '-') 'memory'
}

$mem = [IO.Path]::GetFullPath($MemoryDir ? $MemoryDir : (Default-MemoryDir))
$found = @(if (Test-Path -LiteralPath $mem -PathType Container) {
    Get-ChildItem -LiteralPath $mem -Filter '*.md' -File -Recurse | ForEach-Object FullName | Sort-Object
})

if (-not (Test-Path -LiteralPath (Join-Path $mem 'MEMORY.md') -PathType Leaf)) {
    if (-not $found) { Write-Output "memory dir: $mem"; Write-Output 'memory files: 0 (nothing saved in this project yet)'; exit 0 }
    Write-Output "MEMORY.md missing at $(Join-Path $mem 'MEMORY.md')"; exit 1
}

function Rel([string]$p) { [IO.Path]::GetRelativePath($mem, $p) }
function Archived([string]$p) {
    $parts = (Rel $p) -split '[\\/]'
    foreach ($d in $parts[0..($parts.Count - 2)]) { if ($d.ToLower() -in $archiveDirs) { return $true } }
    return $false
}
$allMd = @($found | Where-Object { -not (Archived $_) })
$skipped = $found.Count - $allMd.Count
$files = @($allMd | Where-Object { (Split-Path $_ -Leaf) -ne 'MEMORY.md' })
$indexes = @($allMd | Where-Object { (Split-Path $_ -Leaf) -eq 'MEMORY.md' })

# Links from ALL MEMORY.md files (root + subfolders), resolved relative to the index containing them.
# Any .md link on a line indexes its file, but only the first link per line is that line's entry,
# so "indexed twice" counts entries, not cross-refs.
$linkRe = '\]\(<?(?![a-z][a-z0-9+.-]*:)([^)>#\s]+\.md)(?:#[^)>\s]*)?>?(?:\s+"[^"]*")?\)'
$linked = [Collections.Generic.HashSet[string]]::new()
$entries = @{}
foreach ($idx in $indexes) {
    $text = [regex]::Replace((Get-Content -LiteralPath $idx -Raw -Encoding utf8) ?? '', '(?sm)<!--.*?-->|^```.*?^```', '')
    foreach ($line in ($text -split "`r?`n")) {
        $rs = @(foreach ($m in [regex]::Matches($line, $linkRe)) {
            Rel ([IO.Path]::GetFullPath((Join-Path (Split-Path $idx) $m.Groups[1].Value)))
        })
        foreach ($x in $rs) { $null = $linked.Add($x) }
        if ($rs) { $entries[$rs[0]] = 1 + ($entries[$rs[0]] ?? 0) }
    }
}

$baseNames = @($files | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
$findings = [Collections.Generic.List[string]]::new()
$deadWiki = [Collections.Generic.List[string]]::new()
$inbound = @{}
$typeCount = [ordered]@{}
$typeRe = '^\s*type:\s*["'']?(user|feedback|project|reference)["'']?\s*(#.*)?$'
foreach ($f in $files) {
    $name = Split-Path $f -Leaf
    $base = [IO.Path]::GetFileNameWithoutExtension($f)
    if (-not $linked.Contains((Rel $f))) { $findings.Add("not in index : $(Rel $f)") }
    try { $body = (Get-Content -LiteralPath $f -Raw -Encoding utf8) ?? '' }
    catch { $findings.Add("unreadable   : $(Rel $f) ($($_.Exception.GetType().Name))"); continue }
    $lines = $body -split "`r?`n"
    $end = 0
    if ($lines[0] -eq '---') { for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } } }
    $head = $end ? $lines[0..($end - 1)] : @()
    $stripped = [regex]::Replace($body, '(?s)```.*?```|`[^`\n]*`', '')
    foreach ($m in [regex]::Matches($stripped, '\[\[([^\]|#]+)[^\]]*\]\]')) {
        $t = $m.Groups[1].Value.Trim() -replace '\.md$', ''
        if ($t -cin $baseNames) { $inbound[$t] = 1 + ($inbound[$t] ?? 0) } else { $deadWiki.Add("$name -> [[$t]]") }
    }
    if (-not $head) { $findings.Add("no frontmatter: $name"); continue }
    $nm = $head | ForEach-Object { if ($_ -cmatch '^name:\s*(\S+)') { $Matches[1] } } | Select-Object -First 1
    if (-not $nm) { $findings.Add("no name:      $name") }
    elseif ($nm.Trim('"', "'") -cne $base) { $findings.Add("name/file mismatch: $name has name: $nm") }
    if (-not ($head | Where-Object { $_ -cmatch '^description:\s*\S' })) { $findings.Add("no description: $name") }
    $ty = $head | ForEach-Object { if ($_ -cmatch $typeRe) { $Matches[1] } } | Select-Object -First 1
    if (-not $ty) { $findings.Add("bad/missing type: $name") } else { $typeCount[$ty] = 1 + ($typeCount[$ty] ?? 0) }
}
foreach ($r in ($linked | Sort-Object)) {
    if (-not (Test-Path -LiteralPath (Join-Path $mem $r))) { $findings.Add("dangling link : $r") }
}
foreach ($r in $entries.Keys) { if ($entries[$r] -gt 1) { $findings.Add("indexed twice : $r") } }

Write-Output "memory dir: $mem"
Write-Output "memory files: $($files.Count)   indexed files: $($linked.Count)   findings: $($findings.Count)   dead wikilinks: $($deadWiki.Count)"
if ($skipped) { Write-Output "archived (skipped): $skipped files in $(($archiveDirs | Sort-Object) -join ', ') folders" }
foreach ($x in $findings) { Write-Output "  $x" }
if ($deadWiki.Count) {
    Write-Output '  dead [[wikilink]] targets (forward refs are allowed; listed for awareness):'
    foreach ($d in $deadWiki) { Write-Output "    $d" }
}
if ($Stats) {
    Write-Output ''
    Write-Output 'STATS'
    Write-Output ('  by type: ' + (($typeCount.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    $orphans = @($baseNames | Where-Object { -not $inbound.ContainsKey($_) } | Sort-Object)
    Write-Output "  orphans (no inbound [[wikilink]]): $($orphans.Count)"
    foreach ($o in $orphans) { Write-Output "    $o" }
}
exit ($findings.Count ? 1 : 0)
