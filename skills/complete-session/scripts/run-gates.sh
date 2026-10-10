#!/usr/bin/env bash
# Detect a repo's languages and run each one's verification gate, every step bounded by a
# hard timeout so a hung check can never stall the close. Prints a verdict per step.
# Exit 0 = every step that ran passed and at least one was a test step, 1 = a failure,
#      2 = a timeout or an exhausted --total-timeout (unverified),
#      3 = nothing runnable (no recognized gate, toolchain/deps missing, placeholder/watch/malformed, no test step ran).
#
# Steps can write caches, lockfiles, a .venv and build output (uv, pytest, cargo, dotnet); a working-tree diff is reported.
#   Python (pyproject.toml, at the root or one level down):
#     ruff, only if configured ([tool.ruff] / ruff.toml / .ruff.toml): ruff check --no-fix . ; ruff format --check .
#     tests: uv.lock -> uv run --frozen pytest ; else .venv python -m pytest ; else not runnable
#     (plain `uv run` creates uv.lock and can rebuild or delete a hand-made .venv)
#     (pytest exit 5 = "no tests collected" is reported, not failed)
#   Python (no root pyproject.toml; requirements.txt or *.py, plus tests/): syntax-check the .py files ;
#     pytest -q if the .venv python (else python/python3) can import it
#   Go     (every go.mod): gofmt -l (skips vendor/, testdata/) must print nothing ; go vet ./... ; go test [-race] ./...
#   Node   (package.json, at the root or one level down): the project's own typecheck / lint / test / build scripts, whichever exist
#   Rust   (Cargo.toml): cargo test --quiet
#   .NET   (*.sln, else *.csproj): dotnet build --nologo -v q
#   A manifest that is found but not gated is listed as "SKIP <path>: <reason>".
#
# Usage: run-gates.sh --repo <root> [--timeout SEC (300)] [--total-timeout SEC (540)] [--tail N (30)] [--no-build]
#   --no-build skips the Node build script (it would clobber the output dir of a running dev server).
set -uo pipefail

repo='' timeout_sec=300 total_sec=540 tail_lines=30 no_build=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo) repo=${2-}; shift 2 || break ;;  # a trailing flag with no value would loop forever
        --timeout) timeout_sec=${2-}; shift 2 || break ;;
        --total-timeout) total_sec=${2-}; shift 2 || break ;;
        --tail) tail_lines=${2-}; shift 2 || break ;;
        --no-build) no_build=1; shift ;;
        -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; echo 'RESULT: not runnable (nothing was verified)'; exit 3 ;;
    esac
done
[[ -d $repo ]] || { echo "not a directory: ${repo:-<none>} (use --repo)"; echo 'RESULT: not runnable (nothing was verified)'; exit 3; }
[[ $timeout_sec =~ ^[1-9][0-9]*$ ]] || { echo "--timeout must be whole seconds > 0"; echo 'RESULT: not runnable (nothing was verified)'; exit 3; }
[[ $total_sec =~ ^[1-9][0-9]*$ ]] || { echo "--total-timeout must be whole seconds > 0"; echo 'RESULT: not runnable (nothing was verified)'; exit 3; }
export NO_COLOR=1 CI=1 PYTHONDONTWRITEBYTECODE=1
unset FORCE_COLOR CLICOLOR_FORCE # Claude Code's Bash sets FORCE_COLOR; keep logs plain
t_all=$SECONDS

# Repo-relative manifests at the root and one level down, never inside vendor/ or node_modules/.
find_manifests() { (cd "$repo" && find . -maxdepth 2 -not -path '*/vendor/*' -not -path '*/node_modules/*' "$@" | sort); }
# The venv python of dir $1, relative to it (Linux or Windows layout); prints nothing if there is none.
venv_py() { local c; for c in .venv/bin/python .venv/Scripts/python.exe; do [[ -x $repo/$1/$c ]] && { echo "$c"; return; }; done; }
# Compiles without writing .pyc files (compileall would litter a repo that has no .gitignore).
pycheck='import sys; [compile(open(f, "rb").read(), f, "exec") for f in sys.argv[1:]]'

# Each step: "label|rule|dir|command"; rule = exit0 | emptyout | pytest | test | notrun
# (pytest and test steps are what make a pass count: lint/build/syntax-only results exit 3)
steps=() langs=() skips=()
while IFS= read -r pp; do
    d=$(dirname "$pp") sfx=''
    [[ $d == . ]] || sfx=" ($d)"
    langs+=("python${sfx:+:$d}")
    if grep -q '^[[:space:]]*\[tool\.ruff' "$repo/$pp" 2>/dev/null || [[ -f $repo/$d/ruff.toml || -f $repo/$d/.ruff.toml ]]; then
        ruff='uvx ruff'
        [[ -f $repo/$d/uv.lock ]] && grep -q '^name = "ruff"$' "$repo/$d/uv.lock" && ruff='uv run --frozen ruff'
        steps+=("ruff check$sfx|exit0|$d|$ruff check --no-fix ." "ruff format --check$sfx|exit0|$d|$ruff format --check .")
    fi
    venv=$(venv_py "$d")
    if [[ -f $repo/$d/uv.lock ]]; then
        steps+=("pytest$sfx|pytest|$d|uv run --frozen pytest -p no:cacheprovider")
    elif [[ -n $venv ]]; then
        steps+=("pytest$sfx|pytest|$d|$venv -m pytest -p no:cacheprovider")
    else
        steps+=("pytest$sfx|notrun|.|no uv.lock and no .venv: use the test command the repo's CLAUDE.md/README names")
    fi
done < <(find_manifests -name pyproject.toml)
if [[ ! -f $repo/pyproject.toml ]] && [[ -f $repo/requirements.txt || -n $(find "$repo" -maxdepth 1 -name '*.py' -print -quit) ]]; then
    if [[ -d $repo/tests ]]; then
        langs+=(python)
        py=$(venv_py .)
        if [[ -z $py ]]; then
            for c in python python3; do command -v "$c" >/dev/null && "$c" -c pass 2>/dev/null && { py=$c; break; }; done
        fi
        if [[ -z $py ]]; then
            steps+=('py syntax|notrun|.|python not installed' 'pytest|notrun|.|python not installed')
        else
            steps+=("py syntax|exit0|.|git -c core.quotepath=off ls-files -co --exclude-standard -z -- '*.py' | xargs -0 $py -c '$pycheck'")
            if (cd "$repo" && "$py" -c 'import pytest') >/dev/null 2>&1; then steps+=("pytest|pytest|.|$py -m pytest -q -p no:cacheprovider")
            else steps+=("pytest|notrun|.|pytest is not importable by $py"); fi
        fi
    else
        skips+=('SKIP requirements.txt / *.py: no tests/ dir, so no Python gate')
    fi
fi
while IFS= read -r mod; do
    d=$(dirname "$mod")
    langs+=("go:$d")
    if ! command -v go >/dev/null; then steps+=("go ($d)|notrun|.|go toolchain not installed"); continue; fi
    race=''
    [[ $(cd "$repo/$d" && go env CGO_ENABLED 2>/dev/null) == 1 ]] && race=' -race'
    steps+=("gofmt ($d)|emptyout|$d|find . -name '*.go' -not -path '*/vendor/*' -not -path '*/testdata/*' -exec gofmt -l {} +"
            "go vet ($d)|exit0|$d|go vet ./..." "go test$race ($d)|test|$d|go test$race ./...")
done < <(cd "$repo" && find . -name go.mod -not -path '*/vendor/*' -not -path '*/node_modules/*' | sort)
while IFS= read -r cm; do # a root Cargo.toml already covers its workspace members
    d=$(dirname "$cm")
    langs+=("rust:$d")
    if ! command -v cargo >/dev/null; then steps+=("cargo ($d)|notrun|.|cargo toolchain not installed"); continue; fi
    steps+=("cargo test ($d)|test|$d|cargo test --quiet")
done < <(if [[ -f $repo/Cargo.toml ]]; then echo ./Cargo.toml; else find_manifests -name Cargo.toml; fi)
dn=$(find_manifests \( -name '*.sln' -o -name '*.slnx' \))
[[ -n $dn ]] || dn=$(find_manifests -name '*.csproj')
while IFS= read -r proj; do
    [[ -n $proj ]] || continue
    langs+=("dotnet:$(dirname "$proj")")
    if ! command -v dotnet >/dev/null; then steps+=("dotnet (${proj#./})|notrun|.|dotnet toolchain not installed"); continue; fi
    steps+=("dotnet build (${proj#./})|test|.|dotnet build --nologo -v q \"$proj\"") # the build is .NET's gate
done <<<"$dn"
while IFS= read -r pj; do
    d=$(dirname "$pj") sfx='' n=${#steps[@]}
    [[ $d == . ]] || sfx=" ($d)"
    langs+=("node${sfx:+:$d}")
    if ! command -v node >/dev/null; then steps+=("node$sfx|notrun|.|node toolchain not installed"); continue; fi
    pm=npm
    for l in "$repo/$d" "$repo"; do
        [[ -f $l/pnpm-lock.yaml ]] && pm=pnpm
        [[ -f $l/yarn.lock ]] && pm=yarn
        [[ $pm != npm ]] && break
    done
    for s in typecheck lint test build; do
        # cwd + relative require, not a path argument: Git Bash leaves a path with spaces/brackets unconverted for node.exe
        body=$(cd "$repo/$d" && node -p 'const s = require(require("path").resolve("package.json"))?.scripts; typeof s?.[process.argv[1]] == "string" ? s[process.argv[1]] : ""' "$s" 2>/dev/null) ||
            { steps+=("node$sfx|notrun|.|malformed ${pj#./} (not valid JSON)"); break; }
        [[ -z $body ]] && continue
        if [[ $s == build ]] && ((no_build)); then skips+=("SKIP ${pj#./} build script: --no-build"); continue; fi
        rule=exit0
        # typecheck/build verify a Node repo with no test script (Next.js sites); lint alone doesn't
        [[ $s == test || $s == typecheck || $s == build ]] && rule=test
        if [[ $body == *'no test specified'* ]]; then steps+=("$pm run $s$sfx|notrun|.|placeholder script (npm init default)")
        elif [[ $body =~ (^|[[:space:]])(--watch|-w|watch)([[:space:]]|$) ]]; then steps+=("$pm run $s$sfx|notrun|.|watch mode would never exit: $body")
        else steps+=("$pm run $s$sfx|$rule|$d|$pm run $s"); fi
    done
    ((${#steps[@]} > n)) || steps+=("node$sfx|notrun|.|no gate steps found")
done < <(find_manifests -name package.json)
while IFS= read -r m; do
    t=${m//[^\/]/}
    ((${#t} >= 3)) && skips+=("SKIP ${m#./}: more than one level down")
done < <(cd "$repo" && find . -maxdepth 4 \( -name vendor -o -name node_modules -o -name .git -o -name .venv -o -name .next -o -name target -o -name dist -o -name build \) -prune -o \( -name package.json -o -name pyproject.toml \) -print)
[[ ${#langs[@]} -gt 0 ]] || {
    ((${#skips[@]})) && printf '  %s\n' "${skips[@]}"
    echo "no recognized gate (no pyproject.toml / go.mod / package.json / Cargo.toml / .sln / .csproj, no requirements.txt + tests/) in $repo"
    echo 'RESULT: not runnable (nothing was verified)'; exit 3
}

echo "GATE (${langs[*]}) for $repo  (timeout ${timeout_sec}s/step, ${total_sec}s total)"
((${#skips[@]})) && printf '  %s\n' "${skips[@]}"
any_fail=0 any_timeout=0 any_pass=0 any_notrun=0 any_test=0
# Anchored to the first lines: a real failure can print "record 7: not found" anywhere later.
nr_re="^error: Failed to spawn|^(bash|sh|/usr/bin/env): ([0-9]+: |line [0-9]+: )?[^[:space:]]+: (command )?not found\$|is not recognized as an internal or external command|No module named '?(pytest|ruff|mypy)'?\$"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
before=$(git -C "$repo" status --porcelain 2>/dev/null)
for step in "${steps[@]}"; do
    IFS='|' read -r label rule dir cmd <<<"$step"
    if [[ $rule == notrun ]]; then
        any_notrun=1; printf '  %-26s %s\n' "$label" "NOT RUNNABLE: $cmd"; continue
    fi
    left=$((total_sec - (SECONDS - t_all)))
    if ((left <= 0)); then
        any_timeout=1; printf '  %-26s %s\n' "$label" "SKIPPED (total ${total_sec}s budget exhausted; unverified)"; continue
    fi
    step_sec=$timeout_sec
    ((left < step_sec)) && step_sec=$left
    rm -f "$log"; log=$(mktemp) # per step: a daemon left by an earlier step keeps its fd and must not write into this log
    t0=$SECONDS
    # exec: timeout(1) leads its own process group, so the kill below also reaps orphans it left behind
    (cd "$repo/$dir" && exec timeout --kill-after=10 "$step_sec" bash -c "$cmd") >"$log" 2>&1 </dev/null &
    pid=$!
    wait "$pid"
    code=$?
    kill -KILL -- "-$pid" 2>/dev/null
    show=1
    if [[ ( $code -eq 124 || $code -eq 137 ) && $((SECONDS - t0)) -ge $step_sec ]]; then
        any_timeout=1; verdict="TIMEOUT after ${step_sec}s (unverified)"
    elif [[ $code -ne 0 ]] && { [[ $code -eq 126 || $code -eq 127 ]] || grep -qE "$nr_re" < <(head -n 10 "$log" | tr -d '\r'); }; then
        any_notrun=1; verdict="NOT RUNNABLE (exit $code: tool or dependency missing)"
    elif [[ $rule == pytest && $code -eq 5 ]]; then
        any_notrun=1; verdict='no tests collected (nothing verified)'; show=0
    elif [[ $code -eq 0 && ( $rule != emptyout || ! -s $log ) ]]; then
        any_pass=1; verdict=pass; show=0
        [[ $rule == test || $rule == pytest ]] && any_test=1
    else
        any_fail=1; verdict="FAIL (exit $code)"
    fi
    printf '  %-26s %s\n' "$label" "$verdict"
    ((show)) && grep -v '^[[:space:]]*$' "$log" | tail -n "$tail_lines" | sed 's/^/      | /'
done
after=$(git -C "$repo" status --porcelain 2>/dev/null)
[[ $before != "$after" ]] && echo "  WARN: the gate changed the working tree:" && diff <(echo "$before") <(echo "$after") | sed -n 's/^> /      /p'
echo
if ((any_fail)); then echo 'RESULT: FAIL'; exit 1; fi
if ((any_timeout)); then echo 'RESULT: unverified (a step timed out or the total budget ran out)'; exit 2; fi
if ((!any_pass)); then echo 'RESULT: not runnable (nothing was verified)'; exit 3; fi
if ((!any_test)); then echo 'RESULT: not runnable (no test, typecheck or build step ran: lint/syntax checks alone do not verify behaviour)'; exit 3; fi
if ((any_notrun)); then echo 'RESULT: pass (partial: some steps could not run, see above)'; exit 0; fi
echo 'RESULT: pass'
