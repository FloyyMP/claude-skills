#!/usr/bin/env bash
# Emit the Step 7 "prove clean" table for one or more repos, every row backed by a
# git command run now. Read-only. Exit 0 = every repo clean, 1 = open items, 2 = usage error.
#
# Per repo: working tree clean, nothing unpushed, push landed (local HEAD == upstream),
# no op in progress, on default branch, no stashes, single worktree, no unmerged branches. The default
# branch is derived per repo, never hardcoded. Rows are ok, OPEN, note (informational,
# never blocks) or n/a.
#
# Usage: [SINCE=<unix seconds>] prove-clean.sh <repo> [<repo> ...]
#   SINCE limits the stash, branch and worktree rows to ones created at or after it
#   (13-digit milliseconds are accepted too). Unset = count everything.
set -uo pipefail

if [[ $# -eq 0 || $1 == -h || $1 == --help ]]; then
    sed -n '2,/^set /{/^#/s/^# \{0,1\}//p}' "$0"
    exit 2
fi

since=${SINCE:-0}
if [[ $since =~ ^[0-9]{13}$ ]]; then since=$((10#$since / 1000))
elif [[ $since != 0 && ! $since =~ ^[0-9]{9,10}$ ]]; then
    echo "ERROR: SINCE must be unix seconds (9-10 digits), got '$SINCE'" >&2
    exit 2
fi

open=0 ok=0 notes=0
row() { # label ok(0/1) detail
    local mark=ok
    if [[ $2 != 0 ]]; then mark=OPEN; open=$((open + 1)); else ok=$((ok + 1)); fi
    printf '  %-24s %-8s %s\n' "$1" "$mark" "$3"
}
note() { notes=$((notes + 1)); printf '  %-24s %-8s %s\n' "$1" note "$2"; } # label detail
count() { grep -c . || true; }

birth() { # unix time $1 was created; mtime where the filesystem has no birth time; far future (= new) if unreadable
    local t
    t=$(stat -c %W "$1" 2>/dev/null) || t=$(stat -f %B "$1" 2>/dev/null)
    [[ $t =~ ^[1-9][0-9]*$ ]] || t=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
    echo "${t:-9999999999}"
}

born() { # unix time branch $1 of $r was created: oldest reflog entry, else (reflog expired/off) its tip commit date
    local t
    t=$(git -C "$r" reflog show --date=unix --format=%gd "$1" -- 2>/dev/null | tail -1 | sed -n 's/.*@{\([0-9]*\)}$/\1/p')
    [[ -n $t ]] || t=$(git -C "$r" log -1 --format=%ct "$1" -- 2>/dev/null)
    echo "${t:-9999999999}"
}

default_branch() { # empty output = unknown -> row is OPEN (fail closed)
    local r=$1 rems rem b
    rems=$(git -C "$r" remote)
    if [[ -z $rems ]]; then # local-only: never the current branch (tautology)
        for b in "$(git -C "$r" config init.defaultBranch)" main master; do
            git -C "$r" show-ref -q --verify "refs/heads/$b" && { echo "$b"; return; }; done
        (( $(git -C "$r" for-each-ref refs/heads | count) <= 1 )) && git -C "$r" symbolic-ref --short HEAD; return
    fi
    rems=$({ grep -x origin <<<"$rems"; grep -vx origin <<<"$rems"; }) # origin first
    # Local refs before any network call. A refs/remotes/<rem>/HEAD whose branch is gone doesn't count.
    for rem in $rems; do
        b=$(git -C "$r" symbolic-ref --short "refs/remotes/$rem/HEAD" 2>/dev/null) && b=${b#"$rem"/} &&
            git -C "$r" show-ref -q --verify "refs/remotes/$rem/$b" && { echo "$b"; return; }
        for b in main master; do
            git -C "$r" show-ref -q --verify "refs/remotes/$rem/$b" && { echo "$b"; return; }; done
    done
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' timeout 8 \
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 -C "$r" ls-remote --symref "${rems%%$'\n'*}" HEAD 2>/dev/null |
        sed -n 's|^ref: refs/heads/\(.*\)\tHEAD$|\1|p'
}

for r in "$@"; do
    echo "repo $r"
    if [[ ! -d $r ]]; then open=$((open + 1)); echo "  ERROR: path not found"; continue; fi
    if [[ $(git -C "$r" rev-parse --is-bare-repository 2>/dev/null) == true ]]; then notes=$((notes + 1)); echo "  bare repo (skipped)"; continue; fi
    if ! git -C "$r" rev-parse --show-toplevel >/dev/null 2>&1; then open=$((open + 1)); echo "  ERROR: not a git repo"; continue; fi

    def=$(default_branch "$r")
    git -C "$r" rev-parse -q --verify HEAD >/dev/null; nohead=$?
    branch=$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || echo '(detached/unborn)')
    dirty=$(git -C "$r" status --porcelain --untracked-files=normal | count) || dirty=-1
    row 'working tree clean' "$((dirty != 0))" "git status --porcelain        ($dirty dirty)"

    if [[ -n $(git -C "$r" remote) ]] && ((nohead)); then
        printf '  %-24s %-8s %s\n' 'nothing unpushed' 'n/a' 'unborn (no commits)'
    elif git -C "$r" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        ahead=$(git -C "$r" rev-list --count '@{u}..HEAD')
        behind=$(git -C "$r" rev-list --count 'HEAD..@{u}')
        row 'nothing unpushed' "$((ahead != 0))" "git rev-list --count @{u}..  ($ahead ahead)"
        if [[ $(git -C "$r" rev-parse HEAD) == $(git -C "$r" rev-parse '@{u}') ]]; then
            row 'push landed (sha match)' 0 'git rev-parse HEAD vs @{u}'
        elif ((ahead == 0)); then
            note 'push landed (sha match)' "behind $behind (pull needed)"
        else
            row 'push landed (sha match)' 1 "git rev-parse HEAD vs @{u}  (ahead $ahead, behind $behind)"
        fi
    elif [[ -n $(git -C "$r" remote) ]]; then # remote but no/gone upstream
        ahead=$(git -C "$r" rev-list --count HEAD --not --remotes 2>/dev/null) || ahead=-1
        row 'nothing unpushed' "$((ahead != 0))" "git rev-list --count HEAD --not --remotes ($ahead, no upstream)"
    else
        printf '  %-24s %-8s %s\n' 'nothing unpushed' 'n/a' '(no remote)'
    fi
    op=; for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        [[ -e $(git -C "$r" rev-parse --path-format=absolute --git-path "$f") ]] && op+="${op:+ }$f"; done
    row 'no op in progress' "$([[ -z $op ]]; echo $?)" "git rev-parse --git-path ...    (${op:-none})"

    [[ -n $def && $branch == "$def" ]]; ondef=$?
    row 'on default branch' "$ondef" "git symbolic-ref --short HEAD ($branch, default ${def:-none})"
    stashes=$(git -C "$r" stash list --format=%ct | awk -v s="$since" '$1 >= s' | count) || stashes=-1
    row 'no stashes' "$((stashes != 0))" "git stash list                ($stashes)"
    wt=0 wtold=0
    while IFS= read -r p; do # a worktree's creation time = its .git file's
        wt=$((wt + 1)); ((wt > 1)) || continue # the first entry is the main worktree
        (($(birth "$p/.git") < since)) && wtold=$((wtold + 1))
    done < <(git -C "$r" worktree list --porcelain | sed -n 's/^worktree //p')
    if ((wt <= 1)); then row 'single worktree' 0 "git worktree list             ($wt)"
    elif ((wtold == wt - 1)); then note 'single worktree' "git worktree list             ($wt, all linked ones predate SINCE)"
    else row 'single worktree' 1 "git worktree list             ($wt$( ((wtold)) && echo ", $wtold predate SINCE"))"; fi
    if ((nohead)); then
        printf '  %-24s %-8s %s\n' 'no unmerged branches' 'n/a' 'unborn (no commits)'
    elif [[ -z $def ]]; then
        row 'no unmerged branches' 1 'git branch --no-merged ?  (default branch unknown, not checked)'
    elif ! list=$(git -C "$r" for-each-ref --no-merged="$def" --format='%(refname)' refs/heads 2>&1); then
        row 'no unmerged branches' 1 "git branch --no-merged $def  (error: ${list%%$'\n'*})"
    else
        unmerged=$(while read -r b; do [[ -n $b ]] && born "$b"; done <<<"$list" | awk -v s="$since" '$1 >= s' | count)
        row 'no unmerged branches' "$((unmerged != 0))" "git branch --no-merged $def  ($unmerged)"
    fi
done

echo
echo "checks ok: $ok, open: $open, notes: $notes"
if ((open == 0)); then echo 'ALL CLEAN'; exit 0; fi
echo "OPEN ITEMS: $open"
exit 1
