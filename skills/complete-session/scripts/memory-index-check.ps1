#Requires -Version 7
<#
.SYNOPSIS
  Mechanical consistency check of ~/.claude/memory: every file indexed, every index
  line points at a file, every file has valid frontmatter, and every inline
  [[wikilink]] resolves. Read-only; prints findings. Exit code 0 = consistent
  (dead wikilinks are informational and do NOT fail), 1 = structural findings.

.PARAMETER Stats
  Also print a breakdown: memory count by type, and orphan memories (files no other
  memory links to). Feeds the Step 6 "deep reconcile" signal without eyeballing.
#>
[CmdletBinding()]
param(
    [string]$MemoryDir = (Join-Path $HOME '.claude' 'memory'),
    [switch]$Stats
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$indexPath = Join-Path $MemoryDir 'MEMORY.md'
if (-not (Test-Path -LiteralPath $indexPath)) { Write-Output "MEMORY.md missing at $indexPath"; exit 1 }

$files = @(Get-ChildItem -LiteralPath $MemoryDir -Filter '*.md' -File | Where-Object Name -ne 'MEMORY.md')
$indexLines = @(Get-Content -LiteralPath $indexPath)
$linked = [ordered]@{}
foreach ($l in $indexLines) {
    foreach ($m in [regex]::Matches($l, '\]\(([^)]+\.md)\)')) {
        $target = $m.Groups[1].Value
        if ($linked.Contains($target)) { $linked[$target]++ } else { $linked[$target] = 1 }
    }
}

$baseNames = @($files | ForEach-Object BaseName)
$findings = [System.Collections.Generic.List[string]]::new()
$inbound  = @{}   # basename -> count of [[wikilink]] references from other files
$typeCount = [ordered]@{}
foreach ($f in $files) {
    if (-not $linked.Contains($f.Name)) { $findings.Add("not in index : $($f.Name)") }
    $head = Get-Content -LiteralPath $f.FullName -TotalCount 12
    if (-not $head -or $head[0] -ne '---') { $findings.Add("no frontmatter: $($f.Name)"); continue }
    $nameLine = $head | Where-Object { $_ -match '^name:\s*(\S+)' } | Select-Object -First 1
    if (-not $nameLine) { $findings.Add("no name:      $($f.Name)") }
    elseif (($nameLine -replace '^name:\s*', '') -ne $f.BaseName) { $findings.Add("name/file mismatch: $($f.Name) has name: $($nameLine -replace '^name:\s*','')") }
    $typeLine = $head | Where-Object { $_ -match '^\s*type:\s*(user|feedback|project|reference)\s*$' } | Select-Object -First 1
    if (-not $typeLine) { $findings.Add("bad/missing type: $($f.Name)") }
    elseif ($typeLine -match '^\s*type:\s*(\w+)') { $t = $Matches[1]; $typeCount[$t] = 1 + ($typeCount[$t] ?? 0) }
}
foreach ($t in $linked.Keys) {
    if (-not (Test-Path -LiteralPath (Join-Path $MemoryDir $t))) { $findings.Add("dangling link : $t") }
    if ($linked[$t] -gt 1) { $findings.Add("indexed twice : $t") }
}

# ---------- inline [[wikilink]] resolution (informational) ----------
$deadWiki = [System.Collections.Generic.List[string]]::new()
foreach ($f in $files) {
    $body = Get-Content -LiteralPath $f.FullName -Raw
    foreach ($m in [regex]::Matches($body, '\[\[([^\]]+)\]\]')) {
        $t = $m.Groups[1].Value.Trim()
        if ($t -in $baseNames) { $inbound[$t] = 1 + ($inbound[$t] ?? 0) }
        else { $deadWiki.Add("$($f.Name) -> [[$t]]") }
    }
}

Write-Output ("memory files: {0:N0}   index lines with links: {1:N0}   findings: {2}   dead wikilinks: {3}" -f $files.Count, $linked.Count, $findings.Count, $deadWiki.Count)
foreach ($x in $findings) { Write-Output "  $x" }
if ($deadWiki.Count -gt 0) {
    Write-Output "  dead [[wikilink]] targets (forward refs are allowed; listed for awareness):"
    foreach ($d in $deadWiki) { Write-Output "    $d" }
}

if ($Stats) {
    Write-Output ""
    Write-Output "STATS"
    Write-Output ("  by type: {0}" -f (($typeCount.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    $orphans = @($baseNames | Where-Object { -not $inbound.ContainsKey($_) })
    Write-Output ("  orphans (no inbound [[wikilink]]): {0}" -f $orphans.Count)
    foreach ($o in ($orphans | Sort-Object)) { Write-Output "    $o" }
}

exit ($findings.Count -gt 0 ? 1 : 0)
