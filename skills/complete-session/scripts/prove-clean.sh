#!/usr/bin/env bash
# Emit the Step 7 "prove clean" table for one or more repos, every row backed by a
# git command run now. Read-only. Exit 0 = every repo clean, 1 = open items.
#
# Per repo: working tree clean, nothing unpushed, push landed (local HEAD == upstream),
# on default branch, no stashes, single worktree, no unmerged branches. The default
# branch is derived per repo, never hardcoded.
#
# Usage: prove-clean.sh <repo> [<repo> ...]
set -uo pipefail

if [[ $# -eq 0 || $1 == -h || $1 == --help ]]; then
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

open=0
row() { # label ok(0/1) detail
    local mark=ok
    if [[ $2 != 0 ]]; then mark=OPEN; open=$((open + 1)); fi
    printf '  %-24s %-8s %s\n' "$1" "$mark" "$3"
}
count() { grep -c . || true; }

default_branch() { # empty output = unknown -> row is OPEN (fail closed)
    local r=$1 rem b
    rem=$(git -C "$r" config "branch.$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null).remote" || git -C "$r" remote | head -1)
    if [[ -z $rem ]]; then # local-only: never the current branch (tautology)
        for b in "$(git -C "$r" config init.defaultBranch)" main master; do
            git -C "$r" show-ref -q --verify "refs/heads/$b" && { echo "$b"; return; }; done
        (( $(git -C "$r" for-each-ref refs/heads | count) <= 1 )) && git -C "$r" symbolic-ref --short HEAD; return
    fi
    b=$(git -C "$r" symbolic-ref --short "refs/remotes/$rem/HEAD" 2>/dev/null) && { echo "${b#"$rem"/}"; return; }
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' timeout 15 \
        git -C "$r" ls-remote --symref "$rem" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)\tHEAD$|\1|p'
}

for r in "$@"; do
    echo "repo $r"
    if [[ ! -d $r ]]; then open=$((open + 1)); echo "  ERROR: path not found"; continue; fi
    if ! git -C "$r" rev-parse --show-toplevel >/dev/null 2>&1; then open=$((open + 1)); echo "  ERROR: not a git repo"; continue; fi

    def=$(default_branch "$r")
    branch=$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || echo '(detached/unborn)')
    dirty=$(git -C "$r" status --porcelain | count) || dirty=-1
    row 'working tree clean' "$((dirty != 0))" "git status --porcelain        ($dirty dirty)"

    if git -C "$r" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        ahead=$(git -C "$r" rev-list --count '@{u}..HEAD')
        row 'nothing unpushed' "$((ahead != 0))" "git rev-list --count @{u}..  ($ahead ahead)"
        [[ $(git -C "$r" rev-parse HEAD) == $(git -C "$r" rev-parse '@{u}') ]]; landed=$?
        row 'push landed (sha match)' "$landed" 'git rev-parse HEAD vs @{u}'
    elif [[ -n $(git -C "$r" remote) ]] && git -C "$r" rev-parse -q --verify HEAD >/dev/null; then # remote but no/gone upstream
        ahead=$(git -C "$r" rev-list --count HEAD --not --remotes 2>/dev/null) || ahead=-1
        row 'nothing unpushed' "$((ahead != 0))" "git rev-list --count HEAD --not --remotes ($ahead, no upstream)"
    else
        printf '  %-24s %-8s %s\n' 'nothing unpushed' 'n/a' '(no remote)'
    fi
    op=; for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        [[ -e $(git -C "$r" rev-parse --path-format=absolute --git-path "$f") ]] && op+="$f "; done
    row 'no op in progress' "$([[ -z $op ]]; echo $?)" "git rev-parse --git-path …    (${op:-none})"

    [[ -n $def && $branch == "$def" ]]; ondef=$?
    row 'on default branch' "$ondef" "git symbolic-ref --short HEAD ($branch, default ${def:-none})"
    stashes=$(git -C "$r" stash list --format=%ct | awk -v s="${SINCE:-0}" '$1 >= s' | count) || stashes=-1
    row 'no stashes' "$((stashes != 0))" "git stash list                ($stashes)"
    wt=$(git -C "$r" worktree list | count)
    row 'single worktree' "$((wt > 1))" "git worktree list             ($wt)"
    unmerged=0
    [[ -n $def ]] && unmerged=$(git -C "$r" for-each-ref --no-merged="$def" --format='%(refname)' refs/heads 2>/dev/null |
        while read -r b; do git -C "$r" reflog show --date=unix --format=%gd "$b" -- | tail -1 | sed -n 's/.*@{\([0-9]*\)}$/\1/p' | grep . || echo 9999999999; done |
        awk -v s="${SINCE:-0}" '$1 >= s' | count)
    row 'no unmerged branches' "$((unmerged != 0))" "git branch --no-merged ${def:-?}  ($unmerged)"
done

echo
if ((open == 0)); then echo 'ALL CLEAN'; exit 0; fi
echo "OPEN ITEMS: $open"
exit 1
