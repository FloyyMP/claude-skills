<#
.SYNOPSIS
    Dump raw ASCII strings from a PE binary for Claude to analyze.
.PARAMETER ExePath
    Full path to the .exe file.
.PARAMETER MinLen
    Minimum string length (default 6).
#>
param(
    [Parameter(Mandatory=$true)][string]$ExePath,
    [int]$MinLen = 6
)

$ExePath = (Resolve-Path $ExePath -ErrorAction Stop).Path
$bytes   = [System.IO.File]::ReadAllBytes($ExePath)

# PE header
$peOff = [System.BitConverter]::ToInt32($bytes, 0x3C)
$mach  = [System.BitConverter]::ToUInt16($bytes, $peOff + 4)
$arch  = switch ($mach) { 0x14c {"x86"} 0x8664 {"x64"} default {"0x$("{0:X4}" -f $mach)"} }
$sizeMB = [Math]::Round($bytes.Length / 1MB, 2)

Write-Host "=BINARY_INFO arch=$arch size=${sizeMB}MB path=$ExePath"

# PyInstaller detection
$pyiFound = $false
$scanStart = [Math]::Max(0, $bytes.Length - 8192)
for ($i = $scanStart; $i -lt $bytes.Length - 2; $i++) {
    if ($bytes[$i] -eq 0x4D -and $bytes[$i+1] -eq 0x45 -and $bytes[$i+2] -eq 0x49) {
        $pyiFound = $true; break
    }
}
if ($pyiFound) { Write-Host "=RUNTIME PyInstaller" }

# Extract ASCII strings >= MinLen
$cur = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $bytes.Length; $i++) {
    $b = $bytes[$i]
    if ($b -ge 32 -and $b -le 126) { [void]$cur.Append([char]$b) }
    else {
        if ($cur.Length -ge $MinLen) { Write-Host $cur.ToString() }
        [void]$cur.Clear()
    }
}
if ($cur.Length -ge $MinLen) { Write-Host $cur.ToString() }
