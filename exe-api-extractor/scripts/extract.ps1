<#
.SYNOPSIS
    Extract backend API information from a Windows PE binary.
.PARAMETER ExePath
    Full path to the .exe file to analyze.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ExePath
)

$ExePath = (Resolve-Path $ExePath -ErrorAction Stop).Path
$dir     = Split-Path $ExePath -Parent
$base    = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
$outPath = Join-Path $dir "$base-analysis.md"

# ---- READ BYTES + EXTRACT STRINGS ----
$bytes = [System.IO.File]::ReadAllBytes($ExePath)

$strings = New-Object System.Collections.Generic.List[string]
$cur     = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $bytes.Length; $i++) {
    $b = $bytes[$i]
    if ($b -ge 32 -and $b -le 126) { [void]$cur.Append([char]$b) }
    else {
        if ($cur.Length -ge 5) { $strings.Add($cur.ToString()) }
        [void]$cur.Clear()
    }
}
if ($cur.Length -ge 5) { $strings.Add($cur.ToString()) }

# ---- PE HEADER ----
$peOff  = [System.BitConverter]::ToInt32($bytes, 0x3C)
$mach   = [System.BitConverter]::ToUInt16($bytes, $peOff + 4)
$arch   = switch ($mach) { 0x14c { "x86 (32-bit)" } 0x8664 { "x64 (64-bit)" } default { "Unknown (0x$("{0:X4}" -f $mach))" } }
$sizeMB = [Math]::Round($bytes.Length / 1MB, 2)

# ---- RUNTIME DETECTION ----
$runtime = "Unknown"

# Go: embedded symbol table always contains these packages
if ($strings | Where-Object { $_ -match '^(runtime\.|encoding/json|net/http\.|crypto/tls)' } | Select-Object -First 1) {
    $runtime = "Go"
}
# PyInstaller: MEI magic bytes near end of file
$pyiFound = $false
$scanStart = [Math]::Max(0, $bytes.Length - 8192)
for ($i = $scanStart; $i -lt $bytes.Length - 3; $i++) {
    if ($bytes[$i] -eq 0x4D -and $bytes[$i+1] -eq 0x45 -and $bytes[$i+2] -eq 0x49) {
        $pyiFound = $true; break
    }
}
if ($pyiFound) { $runtime = "Python (PyInstaller)" }

# .NET
if ($runtime -eq "Unknown" -and ($strings | Where-Object { $_ -match 'mscoree\.dll|_CorExeMain' } | Select-Object -First 1)) {
    $runtime = ".NET / C#"
}
# Electron
if ($runtime -eq "Unknown" -and ($strings | Where-Object { $_ -match '\belectron\b' } | Select-Object -First 1)) {
    $runtime = "Electron (Node.js)"
}

# Noise filter: standard library / framework internals to ignore
$noise = 'crypto/|tls:|x509:|http2:|runtime\.|reflect\.|encoding/|asn1:|ecdsa:|chacha|GCM|FIPS|golang\.org|go\.dev|hkdf|hmac|ed25519|ml-dsa|mlkem|sync\.|math/|strconv|bufio|compress|context|errors|unicode|atomic|vendor/'

# ---- DEVELOPER / SOURCE PATHS ----

# Module cache paths reveal developer username and third-party deps
$srcPaths = $strings | Where-Object {
    $_ -match '\.(go|py|rs|cs|js|ts)$' -and $_ -match 'Users/[^/]+/(go/pkg/mod|\.cargo|AppData)'
} | Sort-Object -Unique

$devUser = $null
foreach ($p in $srcPaths) {
    if ($p -match 'Users/([^/]+)/') { $devUser = $Matches[1]; break }
}

# Project-internal source files: short relative paths, NOT stdlib/system paths
$projFiles = $strings | Where-Object {
    $_ -match '\.(go|py|rs|cs)$' -and
    $_ -notmatch '(C:/Program Files|C:/Windows|/usr/lib|/usr/local|pkg/mod/|C:/Users/)' -and
    $_.Length -lt 80
} | Sort-Object -Unique

# ---- API ENDPOINTS (URLs) ----
# Extract URLs from within all strings (URLs often live inside large concatenated blobs)
$urlNoise = 'golang\.org|go\.dev|w3\.org|jquery|bootstrap|schema\.org|openssl\.org|pkg/crypto|about:|example\.com|mozilla\.org|whatwg\.org|iana\.org|http://www\.w3'
$urls = $strings | ForEach-Object {
    [regex]::Matches($_, 'https?://[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z]{2,}[^\s"<>(){},\|\\^`\[\]]*')
} | ForEach-Object {
    $url = $_.Value.TrimEnd('.,;)/')
    # Rule 1: trim CamelCase run-on glued to end of path (e.g. /me + MapIter.Value → /me)
    #   Match: preceded by lowercase/digit, lookahead is UpperCase+2lower+Uppercase (CamelCase word)
    $url = [regex]::Replace($url, '(?<=[a-z0-9])(?=[A-Z][a-z]{2,}[A-Z])[A-Za-z.]+$', '')
    # Rule 2: trim Go package.Type.Method chains at the end (e.g. ".Buffer.WriteTo:" → removed)
    #   Only strips the .Type chain itself; leaves any preceding lowercase run untouched
    $url = [regex]::Replace($url, '\.[A-Z][a-zA-Z]+(\.[A-Z][a-zA-Z]+)*[.:]?$', '')
    # Rule 3: strip any trailing Go stdlib package name glued to the last path segment
    #   e.g. /tokenbytes (after rule 2 removed .Buffer.WriteTo) → /token
    $stdPkgs = 'bytes|strings|errors|strconv|runtime|unicode|unsafe|atomic|io|os|fmt|sync|net|log|math|sort|rand|flag|path|exec|heap|ring|list|big|bits|utf8|utf16|tls|http|gzip'
    $url = [regex]::Replace($url, "(?<=[a-zA-Z0-9_-])($stdPkgs)$", '')
    $url = $url.TrimEnd("/.,;:'")
    # Filter: skip URLs whose hostname has fewer than 3 parts (e.g. http://www.css)
    $hostname = ($url -replace '^https?://([^/]+).*', '$1') -replace ':\d+$', ''
    if (($hostname.Split('.').Count -lt 3) -and ($hostname -match '^www\.')) { return }
    $url
} | Where-Object { $_ -and $_.Length -gt 12 -and $_ -notmatch $urlNoise } | Sort-Object -Unique

# ---- BASIC AUTH CREDENTIALS ----
# Extract "Basic <b64>" tokens from within any string (often inside larger blobs)
$decodedCreds = @()
$strings | ForEach-Object {
    [regex]::Matches($_, 'Basic [A-Za-z0-9+/=]{24,}') | ForEach-Object {
        $raw   = $_.Value
        $token = $raw -replace '^Basic ', ''
        try {
            $dec = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token))
            if ($dec -match '^[\x20-\x7E]+$') {
                $decodedCreds += [PSCustomObject]@{ Raw = "Basic $token"; Decoded = $dec }
            }
        } catch {}
    }
}
$decodedCreds = $decodedCreds | Group-Object Raw | ForEach-Object { $_.Group[0] }  # dedupe

# ---- JSON STRUCT TAGS ----
$jsonTags = $strings | Where-Object { $_ -match '^json:"[^"]{2,}"' } | Sort-Object -Unique

# ---- USER-AGENT STRINGS ----
# Extract UA patterns from within any string
$userAgents = $strings | ForEach-Object {
    [regex]::Matches($_, '[A-Za-z][A-Za-z0-9_-]{2,}/\d+\.\d+[^\r\n]{5,}?(Android|iOS|okhttp|AppleWebKit|Chrome|Firefox|Safari|Windows NT|Dalvik|Mobile)')
} | ForEach-Object { $_.Value.Trim() } |
  Where-Object { $_ -and $_.Length -lt 200 -and $_ -notmatch $noise } |
  Sort-Object -Unique | Select-Object -First 8

# ---- CUSTOM HTTP HEADERS ----
$customHeaders = $strings | Where-Object {
    $_ -match '^x-[a-z][a-z0-9-]{3,}:' -and $_.Length -lt 80
} | Sort-Object -Unique

# ---- OUTPUT / STATUS FORMAT STRINGS ----
$statusFmts = $strings | Where-Object {
    $_ -match '%(d|s|f|\.?\d+[dsf])' -and $_.Length -lt 80 -and
    $_ -match '(HIT|BAD|MISS|FREE|LOCK|DENY|RETRY|CHECK|FAIL|VALID|INVALID|CPM|PROXY|COMBO|CHECKED|HITS|FOUND|PREMIUM|SUCCESS|BANNED|GOOD|INVALID|ERROR|WARN|Total|Count)' -and
    $_ -notmatch $noise
} | Sort-Object -Unique

# ---- GO SYMBOL TABLE ----
$mainFuncs = @()
$pkgFuncs  = @()
if ($runtime -eq "Go") {
    # Exclude all Go standard library packages and well-known imported packages
    $stdlibPkgs = 'reflect\.|runtime\.|encoding/|net/|crypto/|tls\.|sync\.|math/|time\.|fmt\.|os\.|io/|bufio\.|sort\.|slices\.|iter\.|maps\.|slices\.|cmp\.|builtin\.|strconv\.|bytes\.|strings\.|context\.|errors\.|unicode/|atomic\.|compress/|path\.|vendor/|golang\.org/|internal/|go:|hash/|container/|log/|mime/|debug/|database/|database/|text/|html/|image/|archive/|testing\.|flag\.'
    $allGoFuncs = $strings | Where-Object {
        $_ -match '^(main\.|[a-z][a-z0-9_-]+/[a-z][a-z0-9_-]+\.)' -and
        $_ -notmatch $stdlibPkgs
    } | Sort-Object -Unique

    $mainFuncs = $allGoFuncs | Where-Object { $_ -match '^main\.' }
    $pkgFuncs  = $allGoFuncs | Where-Object { $_ -notmatch '^main\.' }
}

# ---- DEPENDENCIES (Go mod cache paths) ----
$deps = @()
if ($runtime -eq "Go") {
    $deps = $strings |
        ForEach-Object { if ($_ -match '/pkg/mod/(.+?)@') { $Matches[1] } } |
        Where-Object { $_ } | Sort-Object -Unique
}

# ---- TLS FINGERPRINT PROFILES (bogdanfinn stack) ----
$tlsProfiles = $strings | Where-Object { $_ -match 'profiles\.(Chrome|Firefox|Safari|Okhttp|iOS|Android)_' } |
    ForEach-Object { if ($_ -match 'profiles\.([A-Za-z0-9_]+)') { $Matches[1] } } | Sort-Object -Unique

# ---- BUILD MARKDOWN REPORT ----
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$L  = [System.Collections.Generic.List[string]]::new()

$L.Add("# Binary Analysis: $([System.IO.Path]::GetFileName($ExePath))")
$L.Add("")
$L.Add("> Auto-generated by **exe-api-extractor** on $ts")
$L.Add("")

# Binary info table
$L.Add("## Binary Info")
$L.Add("")
$L.Add("| Field | Value |")
$L.Add("|-------|-------|")
$L.Add("| File | ``$([System.IO.Path]::GetFileName($ExePath))`` |")
$L.Add("| Size | $sizeMB MB |")
$L.Add("| Architecture | $arch |")
$L.Add("| Runtime | $runtime |")
if ($devUser) { $L.Add("| Developer (build machine user) | ``$devUser`` |") }
$L.Add("")

# Developer info
if ($srcPaths.Count -gt 0 -or $projFiles.Count -gt 0) {
    $L.Add("## Developer Info")
    $L.Add("")
    if ($projFiles.Count -gt 0) {
        $L.Add("**Project source files:**")
        $L.Add("")
        $projFiles | ForEach-Object { $L.Add("- ``$_``") }
        $L.Add("")
    }
    if ($srcPaths.Count -gt 0) {
        $L.Add("**Build machine paths (module cache):**")
        $L.Add("")
        $L.Add('```')
        $srcPaths | Select-Object -First 12 | ForEach-Object { $L.Add($_) }
        if ($srcPaths.Count -gt 12) { $L.Add("... ($($srcPaths.Count - 12) more)") }
        $L.Add('```')
        $L.Add("")
    }
}

# API endpoints
if ($urls.Count -gt 0) {
    $L.Add("## API Endpoints")
    $L.Add("")
    $urls | ForEach-Object { $L.Add("- ``$_``") }
    $L.Add("")
}

# Credentials
if ($decodedCreds.Count -gt 0) {
    $L.Add("## Hardcoded Credentials")
    $L.Add("")
    foreach ($cred in $decodedCreds) {
        $L.Add("**Basic Auth:**")
        $L.Add("")
        $L.Add('```')
        $L.Add($cred.Raw)
        $L.Add('```')
        $L.Add("")
        $parts = $cred.Decoded -split ":", 2
        if ($parts.Count -eq 2) {
            $L.Add("| Field | Value |")
            $L.Add("|-------|-------|")
            $L.Add("| client\_id / username | ``$($parts[0])`` |")
            $L.Add("| client\_secret / password | ``$($parts[1])`` |")
        } else {
            $L.Add("Decoded: ``$($cred.Decoded)``")
        }
        $L.Add("")
    }
}

# User-Agent
if ($userAgents.Count -gt 0) {
    $L.Add("## Spoofed Identity / User-Agent")
    $L.Add("")
    $userAgents | ForEach-Object { $L.Add("- ``$_``") }
    $L.Add("")
}

# Custom headers
if ($customHeaders.Count -gt 0) {
    $L.Add("## Custom HTTP Headers")
    $L.Add("")
    $customHeaders | ForEach-Object { $L.Add("- ``$_``") }
    $L.Add("")
}

# TLS fingerprinting
if ($tlsProfiles.Count -gt 0) {
    $L.Add("## TLS Fingerprint Spoofing")
    $L.Add("")
    $L.Add("Uses ``bogdanfinn/tls-client`` — mimics browser TLS handshakes to evade bot detection:")
    $L.Add("")
    $tlsProfiles | ForEach-Object { $L.Add("- $_") }
    $L.Add("")
}

# JSON response/request fields
if ($jsonTags.Count -gt 0) {
    $L.Add("## JSON Fields (Request / Response)")
    $L.Add("")
    $jsonTags | ForEach-Object { $L.Add("- ``$_``") }
    $L.Add("")
}

# Output format strings
if ($statusFmts.Count -gt 0) {
    $L.Add("## TUI / Output Format Strings")
    $L.Add("")
    $statusFmts | ForEach-Object { $L.Add("- ``$_``") }
    $L.Add("")
}

# Go functions
if ($mainFuncs.Count -gt 0 -or $pkgFuncs.Count -gt 0) {
    $L.Add("## Go Symbol Table")
    $L.Add("")
    if ($mainFuncs.Count -gt 0) {
        $L.Add("### main package")
        $L.Add("")
        $mainFuncs | ForEach-Object { $L.Add("- ``$_``") }
        $L.Add("")
    }
    if ($pkgFuncs.Count -gt 0) {
        $L.Add("### internal packages")
        $L.Add("")
        $pkgFuncs | ForEach-Object { $L.Add("- ``$_``") }
        $L.Add("")
    }
}

# Dependencies
if ($deps.Count -gt 0) {
    $L.Add("## Dependencies")
    $L.Add("")
    $L.Add("| Package |")
    $L.Add("|---------|")
    $deps | ForEach-Object { $L.Add("| ``$_`` |") }
    $L.Add("")
}

$L.Add("---")
$L.Add("*Generated by exe-api-extractor*")

$report = $L -join "`n"
[System.IO.File]::WriteAllText($outPath, $report, [System.Text.Encoding]::UTF8)

Write-Host "Report written to: $outPath"
Write-Host ""
Write-Host $report
