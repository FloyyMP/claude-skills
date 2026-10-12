---
name: review-session
version: 1.0.0
description: "Review everything changed in the current Claude Code session (all commits since the session started, plus uncommitted edits) for repo standards and code smells. For a commit-and-push-straight-to-the-branch flow with no PRs or tickets. Use when the user runs /review-session or asks to review this session's work; pass a ref to review since that point instead."
---

Standards review of the work done in this Claude Code session. The flow it assumes: every change is committed and pushed straight to the current branch, with no PRs, no feature branches and no issue tracker. So there is no PR to diff against, and the remote is always level with HEAD. The session itself is the unit of review.

## 1. Pin the fixed point

If the user passed a ref (SHA, tag, `HEAD~5`), that is the fixed point. Otherwise derive it from the session start, which is the first timestamp in this session's transcript:

```bash
t=$(ls ~/.claude/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl 2>/dev/null | head -1)
start=$(grep -m1 -o '"timestamp":"[^"]*"' "$t" | cut -d'"' -f4)
oldest=$(git log --since="$start" --reverse --format=%H | head -1)
if [ -n "$oldest" ]; then
  # parent of the session's first commit; empty tree if that commit is the root
  fp=$(git rev-parse -q --verify "$oldest^" || echo 4b825dc642cb6eb9a060e54bf8d69288fbe0bba4)
else
  fp=HEAD  # no commits this session: review uncommitted edits only
fi
git diff --stat "$fp"; git log --oneline "$fp"..HEAD; git status --short
```

`git diff <fp>` (no `HEAD`) compares against the working tree, so it covers commits and uncommitted edits at once. Untracked files (`??` in `git status`) aren't in any diff. Hand those to the reviewer as whole files. If the transcript can't be found or `$CLAUDE_CODE_SESSION_ID` is unset, say so and use `HEAD~1`. If the diff is empty, stop and report "nothing changed this session". Don't spawn a reviewer on nothing.

## 2. Collect the standards sources

The repo's `CLAUDE.md` / `AGENTS.md` (root plus any in directories the diff touches), the user's global `~/.claude/CLAUDE.md`, and `CODING_STANDARDS.md` / `CONTRIBUTING.md` if present. Many instructions in a `CLAUDE.md` are about how to work, not how code should look. Only the code-facing ones apply.

On top of those, the review always carries this **smell baseline** (Fowler, _Refactoring_ ch. 3). A documented repo standard overrides it, and each smell is a judgement call ("possible Feature Envy"), never a hard violation:

- **Mysterious Name**: a name that doesn't reveal what the thing does or holds. → rename; if no honest name comes, the design is murky.
- **Duplicated Code**: the same logic shape in more than one hunk or file. → extract the shared shape.
- **Feature Envy**: a method that reaches into another object's data more than its own. → move it onto that data.
- **Data Clumps**: the same few fields or params always travelling together. → bundle them into one type.
- **Primitive Obsession**: a primitive standing in for a domain concept. → give the concept a small type.
- **Repeated Switches**: the same `switch`/`if`-cascade on the same type recurring. → polymorphism, or one shared map.
- **Shotgun Surgery**: one logical change forcing scattered edits across many files. → gather what changes together.
- **Divergent Change**: one module edited for several unrelated reasons. → split it.
- **Speculative Generality**: abstraction, parameters or hooks for needs that don't exist yet. → inline until a real need shows.
- **Message Chains**: long `a.b().c().d()` navigation. → hide the walk behind one method.
- **Middle Man**: a class or function that mostly delegates. → call the real target directly.
- **Refused Bequest**: a subclass that ignores most of what it inherits. → composition instead.

## 3. Run the review in one sub-agent

Keep the diff out of the main context. Give the sub-agent:

- the diff and log commands from step 1, with the resolved `fp`;
- the standards-source paths from step 2 and the smell baseline pasted in full (it has no other access to it);
- the brief: "Report, per file/hunk: (a) every place the diff breaks a documented standard, citing file + rule; (b) any baseline smell, named, with the hunk quoted; (c) real bugs you notice in the changed lines. Mark hard violations vs judgement calls. Skip anything a linter, typechecker or formatter enforces, and skip issues on lines the session didn't touch. Security: only critical issues (RCE, auth bypass, data loss, secrets committed to the repo). Skip everything else. Under 400 words."

## 4. Report

Show the findings under `## Standards`, then one line with the finding count and the worst issue (if any). Don't apply fixes unless the user asks.
