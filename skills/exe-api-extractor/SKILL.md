---
name: exe-api-extractor
description: >
  Analyzes Windows PE executables (.exe, .dll) to extract backend API information:
  endpoints, hardcoded credentials, auth tokens, request/response fields, custom headers,
  developer identity, dependencies, TLS fingerprinting profiles, and internal function names.
  Writes a structured Markdown report to a .md file next to the input binary.

  Use this skill whenever the user asks to "analyze", "check out", "inspect", "reverse",
  "look at", or "find backend info / endpoints / credentials" in a binary or executable file.
  Also trigger for phrases like "what does this exe connect to", "what APIs does this use",
  "any hardcoded keys in this binary", or when the user drops a .exe path into the conversation.
---

# exe-api-extractor

Analyze a PE binary by running the extraction script, then reading the written report.

---

## Step 1 — Run the extractor

```powershell
& "C:\Users\Administrator\.claude\skills\exe-api-extractor\scripts\extract.ps1" -ExePath "<full path to .exe>"
```

The script reads the binary, extracts strings, and writes a structured Markdown report to
`<basename>-analysis.md` in the same directory as the binary. Its stdout output is a 3-line
summary: report path, runtime/arch/size, and counts of findings.

This is the only tool call needed. **Do not run dump.ps1 or do manual grep passes.**

---

## Step 2 — Read the report

Read the `.md` file the script just wrote. The path is the first line of the stdout summary.

---

## Step 3 — Reason over the report

The script captures most signals automatically. Apply your own judgment on top:

### URLs: trim noise
The URL extractor has heuristics but can still include false positives from concatenated Go
strings. Drop any URL whose domain is a framework/tooling domain (`golang.org`, `w3.org`,
`schema.org`, `mozilla.org`, `iana.org`, `github.com/bogdanfinn/*/wiki`).

When a URL has trailing CamelCase noise (Go symbol glued on), reason about where the real path
ends — path segments are lowercase with `/`, `-`, `_`, digits.

### Hardcoded credentials
If the report shows a `Basic` auth token, the token is already decoded. Verify the
`client_id:client_secret` split makes sense.

Also check the raw report for: long alphanumeric strings near key names, Bearer tokens, HMAC
secrets — the script only catches `Basic` tokens automatically.

### Auth flow
Look at the endpoint list and any JSON fields to reconstruct how auth works (OAuth2 flow,
session cookie, device code, etc.). Note how many request steps are needed.

### TLS fingerprinting
If the report lists TLS profiles, the binary spoofs browser TLS handshakes using
`bogdanfinn/tls-client`. Note the specific profiles used.

### Go symbol table
`main.*` functions in the report tell you what the program actually does. Custom package
functions reveal internal architecture. Ignore anything that starts with a stdlib package.

---

## Step 4 — Report to the user

Tell the user:
1. What the binary does (one sentence)
2. The API endpoints found (clean, no noise)
3. Any hardcoded credentials (with decoded values)
4. Notable techniques (TLS spoofing, proxy rotation, captcha bypass, etc.)
5. Where the `.md` was saved

**Never include developer identity (build machine username) or source paths in the report.**

---

## Fallback: manual grep passes

Use `dump.ps1` only if `extract.ps1` misses something specific. Pipe it to a file:

```powershell
& "C:\Users\Administrator\.claude\skills\exe-api-extractor\scripts\dump.ps1" -ExePath "<path>" | Out-File "$env:TEMP\strings_dump.txt" -Encoding utf8
```

Then grep `$env:TEMP\strings_dump.txt` for the specific pattern you need.
