#!/usr/bin/env bash
# Detect a repo's languages and run each one's verification gate, every step bounded by a
# hard timeout so a hung check can never stall the close. Prints a verdict per step.
# Exit 0 = every step that ran passed, 1 = a failure, 2 = a timeout (unverified),
#      3 = nothing runnable (no recognized gate, toolchain/deps missing, placeholder/watch scripts).
#
#   Python (pyproject.toml) - never mutates the user's environment:
#     ruff, only if configured ([tool.ruff] / ruff.toml / .ruff.toml): ruff check --no-fix . ; ruff format --check .
#     tests: uv.lock -> uv run --frozen pytest ; else .venv/bin/python -m pytest ; else not runnable
#     (plain `uv run` creates uv.lock and can rebuild or delete a hand-made .venv)
#     (pytest exit 5 = "no tests collected" is reported, not failed)
#   Go     (every go.mod): gofmt -l (skips vendor/, testdata/) must print nothing ; go vet ./... ; go test [-race] ./...
#   Node   (package.json): the project's own typecheck / lint / test / build scripts, whichever exist
#
# Usage: run-gates.sh --repo <root> [--timeout SEC (300)] [--tail N (30)]
set -uo pipefail

repo='' timeout_sec=300 tail_lines=30
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo) repo=${2-}; shift 2 || break ;;  # a trailing flag with no value would loop forever
        --timeout) timeout_sec=${2-}; shift 2 || break ;;
        --tail) tail_lines=${2-}; shift 2 || break ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; echo 'RESULT: not runnable (nothing was verified)'; exit 3 ;;
    esac
done
[[ -d $repo ]] || { echo "not a directory: ${repo:-<none>} (use --repo)"; echo 'RESULT: not runnable (nothing was verified)'; exit 3; }
[[ $timeout_sec =~ ^[1-9][0-9]*$ ]] || { echo "--timeout must be whole seconds > 0"; echo 'RESULT: not runnable (nothing was verified)'; exit 3; }
export NO_COLOR=1 CI=1 PYTHONDONTWRITEBYTECODE=1
unset FORCE_COLOR CLICOLOR_FORCE # Claude Code's Bash sets FORCE_COLOR; keep logs plain

# Each step: "label|rule|dir|command"; rule = exit0 | emptyout | pytest | notrun
steps=() langs=()
if [[ -f $repo/pyproject.toml ]]; then
    langs+=(python)
    if grep -qi ruff "$repo/pyproject.toml" "$repo/.pre-commit-config.yaml" 2>/dev/null || [[ -f $repo/ruff.toml || -f $repo/.ruff.toml ]]; then
        ruff='uvx ruff'
        [[ -f $repo/uv.lock ]] && grep -q '^name = "ruff"$' "$repo/uv.lock" && ruff='uv run --frozen ruff'
        steps+=("ruff check|exit0|.|$ruff check --no-fix ." "ruff format --check|exit0|.|$ruff format --check .")
    fi
    if [[ -f $repo/uv.lock ]]; then
        steps+=('pytest|pytest|.|uv run --frozen pytest -p no:cacheprovider')
    elif [[ -x $repo/.venv/bin/python ]]; then
        steps+=('pytest|pytest|.|.venv/bin/python -m pytest -p no:cacheprovider')
    else
        steps+=("pytest|notrun|.|no uv.lock and no .venv: use the test command the repo's CLAUDE.md/README names")
    fi
fi
while IFS= read -r mod; do
    d=$(dirname "$mod")
    langs+=("go:$d")
    if ! command -v go >/dev/null; then steps+=("go ($d)|notrun|.|go toolchain not installed"); continue; fi
    race=''
    [[ $(cd "$repo/$d" && go env CGO_ENABLED 2>/dev/null) == 1 ]] && race=' -race'
    steps+=("gofmt ($d)|emptyout|$d|find . -name '*.go' -not -path '*/vendor/*' -not -path '*/testdata/*' -exec gofmt -l {} +"
            "go vet ($d)|exit0|$d|go vet ./..." "go test$race ($d)|exit0|$d|go test$race ./...")
done < <(cd "$repo" && find . -name go.mod -not -path '*/vendor/*' -not -path '*/node_modules/*' | sort)
if [[ -f $repo/package.json ]]; then
    langs+=(node)
    pm=npm
    [[ -f $repo/pnpm-lock.yaml ]] && pm=pnpm
    [[ -f $repo/yarn.lock ]] && pm=yarn
    for s in typecheck lint test build; do
        body=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("scripts") or {}).get(sys.argv[2], ""))' "$repo/package.json" "$s")
        [[ -z $body ]] && continue
        if [[ $body == *'no test specified'* ]]; then steps+=("$pm run $s|notrun|.|placeholder script (npm init default)")
        elif [[ $body =~ (^|[[:space:]])(--watch|-w|watch)([[:space:]]|$) ]]; then steps+=("$pm run $s|notrun|.|watch mode would never exit: $body")
        else steps+=("$pm run $s|exit0|.|$pm run $s"); fi
    done
fi
[[ ${#langs[@]} -gt 0 ]] || { echo "no recognized gate (no pyproject.toml / go.mod / package.json) in $repo"; echo 'RESULT: not runnable (nothing was verified)'; exit 3; }

echo "GATE (${langs[*]}) for $repo  (timeout ${timeout_sec}s/step)"
any_fail=0 any_timeout=0 any_pass=0 any_notrun=0
log=$(mktemp)
trap 'rm -f "$log"' EXIT
before=$(git -C "$repo" status --porcelain 2>/dev/null)
for step in "${steps[@]}"; do
    IFS='|' read -r label rule dir cmd <<<"$step"
    if [[ $rule == notrun ]]; then
        any_notrun=1; printf '  %-26s %s\n' "$label" "NOT RUNNABLE: $cmd"; continue
    fi
    t0=$SECONDS
    # exec: timeout(1) leads its own process group, so the kill below also reaps orphans it left behind
    (cd "$repo/$dir" && exec timeout --kill-after=10 "$timeout_sec" bash -c "$cmd") >"$log" 2>&1 </dev/null &
    pid=$!
    wait "$pid"
    code=$?
    kill -KILL -- "-$pid" 2>/dev/null
    show=1
    if [[ ( $code -eq 124 || $code -eq 137 ) && $((SECONDS - t0)) -ge $timeout_sec ]]; then
        any_timeout=1; verdict="TIMEOUT after ${timeout_sec}s (unverified)"
    elif [[ $code -eq 126 || $code -eq 127 ]] || grep -qE '^error: Failed to spawn|: command not found$|: not found$' "$log"; then
        any_notrun=1; verdict="NOT RUNNABLE (exit $code: tool or dependency missing)"
    elif [[ $rule == pytest && $code -eq 5 ]]; then
        any_notrun=1; verdict='no tests collected (nothing verified)'; show=0
    elif [[ $code -eq 0 && ( $rule != emptyout || ! -s $log ) ]]; then
        any_pass=1; verdict=pass; show=0
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
if ((any_timeout)); then echo 'RESULT: unverified (a step timed out)'; exit 2; fi
if ((any_notrun && !any_pass)); then echo 'RESULT: not runnable (nothing was verified)'; exit 3; fi
if ((any_notrun)); then echo 'RESULT: pass (partial: some steps could not run, see above)'; exit 0; fi
echo 'RESULT: pass'
