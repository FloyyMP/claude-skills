---
name: r6-appid-perf
description: Extract and rank AppID performance from run_summary.log files in build/results/. Supports time-based filters ("today", "yesterday", "last 7 days", "since 2026-09-10") and count-based ("last N runs"). Cross-references pool membership from source. Use when the user asks about AppID performance, which IDs are performing or degraded, or wants to compare a time window.
---

# R6 AppID Performance Analyzer

Reads `build/results/*/debug/run_summary.log` files, aggregates the APPID PERFORMANCE section
across the selected runs, ranks AppIDs by auth_rate, and annotates each with their current
pool membership.

Always run from the project root (`C:\...\r6-custom-tool`), not from `build/`.

---

## Step 0 — Read the current pool from source

Before collecting any logs, grep `LoginAppIDPool` and `OpenAppIDs` from
`src/internal/api/ubisoft.go` to get live membership. The log tables use 8-char hex prefixes;
UUIDs in source must be truncated to match.

```powershell
$src = Get-Content "src\internal\api\ubisoft.go" -Raw

# Extract all uncommented UUID strings
$allUUIDs = [regex]::Matches($src, '(?m)^\s+"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"') |
    ForEach-Object { $_.Groups[1].Value }

# OpenAppIDs block: same pattern but only within the OpenAppIDs var block
# Simplest: find the OpenAppIDs slice literal and extract IDs from it
$openBlock = [regex]::Match($src, '(?s)var OpenAppIDs = \[\]string\{(.*?)\}')
$openIDs = [regex]::Matches($openBlock.Groups[1].Value, '[0-9a-f]{8}') |
    ForEach-Object { $_.Value }

# LoginAppIDPool IDs (all uncommented UUIDs in that block)
$poolBlock = [regex]::Match($src, '(?s)var LoginAppIDPool = \[\]string\{(.*?)\n\}')
$poolIDs = [regex]::Matches($poolBlock.Groups[1].Value, '^\s+"([0-9a-f]{8})', 'Multiline') |
    ForEach-Object { $_.Groups[1].Value }

# Build lookup sets (8-char prefix → label)
$openSet = @{}; foreach ($id in $openIDs) { $openSet[$id] = $true }
$poolSet = @{}; foreach ($id in $poolIDs) { $poolSet[$id] = $true }

function Get-PoolLabel($id) {
    $inPool = $poolSet.ContainsKey($id)
    $inOpen = $openSet.ContainsKey($id)
    if ($inOpen -and $inPool) { return "[OPEN]" }
    if ($inPool)               { return "[POOL]" }
                                 return "[NOT IN POOL]"
}
```

---

## Step 1 — Parse the time filter from the request

| User phrase | Filter mode | What to compute |
|---|---|---|
| "today" / "today's runs" | date | `$start = $end = (Get-Date).ToString("yyyy-MM-dd")` |
| "yesterday" | date | `$start = $end = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")` |
| "last N days" / "past N days" | date-range | `$start = (Get-Date).AddDays(-N).ToString("yyyy-MM-dd")`, `$end = today` |
| "since YYYY-MM-DD" / "from YYYY-MM-DD" | date-range | `$start = that date`, `$end = today` |
| "last N runs" / "N runs" / no qualifier | count | Take N most recent (default 10) |

---

## Step 2 — Collect matching run_summary.log files

Run result directories follow the pattern `build\results\YYYY-MM-DD_HH-MM-SS_XXXXXX[_tag]\`.
The date prefix of the **directory name** (not the log's internal timestamp) is the filter key.
Upfront full-capture runs have `_fullcap` in the dir name (enforced from 2026-09-12 onward).
Post-brute full-capture passes also append `_fullcap`. Brute-only runs have no `_fullcap` suffix.

```powershell
# Collect all run_summary.log paths, sorted newest-first
$allLogs = Get-ChildItem "build\results" -Recurse -Filter "run_summary.log" |
    Where-Object { $_.FullName -match '\\debug\\run_summary\.log$' } |
    Sort-Object { $_.Directory.Parent.Name } -Descending

# Date/range filter — extract YYYY-MM-DD from the run dir name
$logs = $allLogs | Where-Object {
    $runDate = $_.Directory.Parent.Name.Substring(0, 10)
    $runDate -ge $startDate -and $runDate -le $endDate
}

# Count filter
$logs = $allLogs | Select-Object -First $N
```

### Brute/full-capture mixing check

After collecting `$logs`, check whether the selection mixes run types:

```powershell
$fullcapLogs = $logs | Where-Object { $_.Directory.Parent.Name -match '_fullcap' }
$bruteLogs   = $logs | Where-Object { $_.Directory.Parent.Name -notmatch '_fullcap' }

if ($fullcapLogs -and $bruteLogs) {
    # Warn before printing results
    $mixWarn = $true
}
```

Full-capture runs make far more API calls per account (inventory, platforms, 2FA, etc.),
so their AppID `Used` counts are much higher than brute runs. Mixing them skews auth_rate
because high-traffic full-cap AppIDs dominate the aggregate. If the window contains both
types, print a warning at the top of the output and offer to re-run with `_fullcap` only
or brute-only.

**Historical note:** upfront full-capture runs before 2026-09-12 may not have `_fullcap` in
their dir name — they look like brute runs by folder name. Check the `LoginOnly:` field in
the run's RUN CONFIG section (`false` = full capture) if unsure.

---

## Step 3 — Parse the APPID PERFORMANCE section

Column layout (as of 2026-09-05 — 8 columns):
```
  AppID         Used      200  400/401      429      403   NetErr    Other
  -------------------------------------------------------------------------
  a991b6c1        20       17        0        3        0        0        0
```

Row regex (capture groups 1–8 = AppID, Used, 200, 400/401, 429, 403, NetErr, Other):
```
^\s+([0-9a-f]{8})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)
```

Parse loop (PowerShell):
```powershell
$stats = @{}   # AppID -> hashtable of summed columns

foreach ($log in $logs) {
    $content = Get-Content $log.FullName -Raw
    if ($content -match '(?s)=== APPID PERFORMANCE ===\r?\n.*?-{10,}\r?\n(.*?)(?:\r?\n===|\z)') {
        foreach ($line in ($Matches[1] -split '\r?\n')) {
            if ($line -match '^\s+([0-9a-f]{8})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
                $id = $Matches[1]
                if (-not $stats[$id]) { $stats[$id] = @{Used=0; S200=0; S400=0; S429=0; S403=0; NetErr=0; Other=0} }
                $stats[$id].Used   += [int]$Matches[2]
                $stats[$id].S200   += [int]$Matches[3]
                $stats[$id].S400   += [int]$Matches[4]
                $stats[$id].S429   += [int]$Matches[5]
                $stats[$id].S403   += [int]$Matches[6]
                $stats[$id].NetErr += [int]$Matches[7]
                $stats[$id].Other  += [int]$Matches[8]
            }
        }
    }
}
```

---

## Step 4 — Compute auth_rate and rank

```
auth_rate = (sum_200 + sum_400/401) / (sum_Used - sum_429)
```

- If `(sum_Used - sum_429) == 0`, set auth_rate = 0.
- Rank **descending** by auth_rate. Secondary sort: descending by sum_200 (raw successes).

---

## Step 5 — Output

Print any mixing warning first, then the run count and covered date range, then the ranked table.

```
⚠  Mixed brute and full-capture runs (8 brute, 3 full-cap) — auth_rate not comparable across types.
   Re-run with "fullcap only" or "brute only" to isolate.

Runs included: 11  (2026-09-05 → 2026-09-12)

  AppID     Pool        Used     200   400/401     429     403  NetErr   Other  auth_rate
  -----------------------------------------------------------------------------------------
  a991b6c1  [OPEN]      1234     900       200      80       0      20      34     93.0%
  b8aa2f37  [OPEN]       980     750       180     120       0       5      25     88.4%
  1f299cd1  [OPEN]       540     400        80      60       0       3      10     85.2%
  d5fa0769  [OPEN]       320     250        50      20       0       0       0     85.2%
  089d29b5  [POOL]       412       0         0      10     402       0       0      0.0%
  ff30fd80  [NOT IN POOL] 45       0         0       2      43       0       0      0.0%
  ...
```

After the table, flag any of these patterns:

- **DEAD** — `Used > 500` AND `200 == 0` AND `400/401 == 0` AND `(429 / Used) > 0.95`
  → "DEAD pattern — consider removing from pool."
- **RESTRICTED/HIGH-403** — `auth_rate == 0` AND `(403 / Used) > 0.5`
  → "High 403 — likely proxy-exit IP block, not an AppID issue. Do not remove solely for this."
- **NOT IN POOL but active** — `[NOT IN POOL]` AND `Used > 20`
  → "Active but not in pool — discovered AppID? Consider probing before adding."
- **LOW SAMPLE** — `Used < 20` across the whole window
  → "Low sample — not representative."

---

## Notes

- `f68a4bb5` (UbiChallenge AppID) is hardcoded separately; it will not appear in the APPID PERFORMANCE table. Its absence is expected.
- 403 = Ubisoft blocked the proxy IP for this AppID at the exit node — a proxy issue, not an AppID issue. Never remove an AppID solely because of high 403 counts.
- 429 is a **raw count** (not a percentage) since 2026-09-05. Any parse logic expecting `%` is stale.
- auth_rate excludes 429s from the denominator — 429s are retried and don't represent a settled auth outcome.
- `ec=2 "Ubi-AppId header is invalid"` appears as 400/401 for some accounts on OPEN AppIDs — normal behavior, not a problem.
