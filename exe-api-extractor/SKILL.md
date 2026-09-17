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

Extract backend intelligence from a binary by dumping its strings and reasoning over them.
No fixed regex pipeline — read the raw output and apply judgment.

---

## Step 1 — Dump strings

```powershell
& "C:\Users\Administrator\.claude\skills\exe-api-extractor\scripts\dump.ps1" -ExePath "<path>" | Out-File "$env:TEMP\strings_dump.txt" -Encoding utf8
```

Then read `$env:TEMP\strings_dump.txt`. The first two lines starting with `=` are metadata:
- `=BINARY_INFO arch=... size=...MB path=...`
- `=RUNTIME PyInstaller` (only present if PyInstaller detected)

Everything else is a raw string extracted from the binary.

---

## Step 2 — Reason over the strings

Work through the dump with your own judgment. There is no fixed pipeline. Use the signals
below as a starting point, but follow what you actually see.

### Runtime identification

- **Go**: look for `runtime.`, `encoding/json`, `net/http.`, `go/pkg/mod/` paths
- **Python/PyInstaller**: `=RUNTIME PyInstaller` header, or strings like `_MEIPASS`, `.pyc`
- **.NET**: `mscoree.dll`, `_CorExeMain`, MSIL tokens — strings will be sparse (UTF-16 binary)
- **Electron**: `electron`, `node_modules`, `asar`

### API endpoints

URLs appear literally in the binary. They are often **embedded inside larger concatenated strings** —
a URL may be glued directly to a Go runtime error message or symbol name with no separator.

When you see a URL with trailing garbage (e.g. `https://api.example.com/v1/tokenBytes.Buffer.WriteTo:`),
reason about where the real URL ends: path segments are lowercase with `/`, `-`, `_`, digits.
Anything that looks like a Go symbol (`MapIter`, `bytes.Buffer`, `WriteTo`, `ScanState`) or
a Go runtime error string is noise to drop.

Filter out framework/tooling URLs: `golang.org`, `go.dev`, `w3.org`, `schema.org`, `jquery`,
`bootstrap`, `mozilla.org`, `iana.org`, `github.com/bogdanfinn/*/wiki` (these are docs links).

### Hardcoded credentials

`Basic ` followed by a Base64 string → OAuth2 client credentials. Always decode:
```powershell
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("<token>"))
```
Decoded format is usually `client_id:client_secret`.

Also look for: API keys (long alphanumeric strings near key names), Bearer tokens, HMAC secrets.

### User-Agent strings

Product/version tokens like `Crunchyroll/3.56.0 Android/10 okhttp/4.9.1`.
These appear in larger blobs — extract just the recognizable UA substring.

### JSON fields

`json:"field_name"` struct tags reveal exact request/response field names the binary parses.

### TLS fingerprinting

`bogdanfinn/tls-client` profiles appear as `Chrome_103`, `Firefox_120`, `Safari_IOS_16_0`, etc.
If these are present, note that the binary spoofs browser TLS fingerprints to evade detection.

### Go symbol table

Function names follow `package.FunctionName` or `main.FunctionName` format. The symbol table
tells you what the program actually does. Ignore standard library symbols (`runtime/`, `os/exec`,
`regexp/syntax`, `encoding/`, etc.) — focus on `main.*` and custom package names.

### Dependencies

`/pkg/mod/<module>@<version>/` paths in the dump reveal all third-party libraries.

---

## Step 3 — Write the report

Save the report as `<basename>-analysis.md` in the same directory as the binary.

Use this structure (omit sections with no findings):

```markdown
# Binary Analysis: <filename>

> Analyzed <date>

## Binary Info
| Field | Value |
|-------|-------|
| File | ... |
| Size | ... |
| Architecture | ... |
| Runtime | ... |

## API Endpoints
- `https://...`

## Hardcoded Credentials
**Basic Auth token:** `Basic <b64>`
Decoded: `client_id:client_secret`

## Auth Mechanism
Brief description of how auth works (OAuth2, API key, session cookie, etc.)

## Spoofed Identity / User-Agent
- `...`

## TLS Fingerprint Spoofing
Uses bogdanfinn/tls-client — profiles: Chrome_103, ...

## JSON Fields (Request / Response)
- `json:"field"`

## TUI / Output Format Strings
- `HITS: %d / %d`

## Key Functions
- `main.CheckEmail` — ...

## Dependencies
| Package |
|---------|
| `github.com/...` |
```

---

## Step 4 — Report to the user

Tell the user:
1. What the binary does (one sentence)
2. The API endpoints found (clean, no noise)
3. Any hardcoded credentials (with decoded values)
4. Notable techniques (TLS spoofing, reCAPTCHA bypass, proxy rotation, etc.)
5. Where the `.md` was saved
