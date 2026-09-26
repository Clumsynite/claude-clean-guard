---
name: fix
description: Clean AI-tool traces with clean-guard. It cuts attribution lines and AI or notes files out of a branch's commits, fixes comment banners and filler phrases in the files, and leaves only the rewording that needs judgment.
argument-hint: "[history [BRANCH] [--to NEW]]"
disable-model-invocation: true
allowed-tools: Bash(clean-guard fix *), Bash(clean-guard scan *), Bash(clean-guard status), Bash(git diff *), Bash(git log *), Bash(git show *), Bash(git status *)
---

# clean-guard fix

clean-guard does the mechanical cleanup, and you reword only what it can't. Don't hand-edit anything `clean-guard fix`
handles (banners, dividers, filler phrases, generated-with lines, attribution trailers, AI and notes files), and don't
write your own sed, awk or filter-branch passes for them.

## Preview (captured when you invoked this)

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/clean-guard.sh" skill-fix $ARGUMENTS`

## Steps

1. If the preview says this isn't a git repository, say so and stop.
2. Show the user the preview in at most 8 lines: what would change, and anything it left alone because a test has
   the same text.
3. Files (no arguments): run `clean-guard fix`. It edits the working files and untracks AI and notes files (they stay
   on disk). Then show `git diff --stat`.
4. History (`history`): this rewrites commits. Ask the user before running it. Prefer
   `clean-guard fix --history BRANCH --to NEW`, which leaves BRANCH as it is. A rewrite in place is fine only on a
   branch that hasn't been pushed, and the output prints the undo command.
5. Reword by hand only what the "Left for you" report lists: comment walls (more than the allowed lines), narration
   ("this change", "used to", "now handles"), AI names in code or docs, and the lines kept because a test asserts on
   them (change the comment and the test together). Keep each comment to the line limit and say why, not what.
6. Check with `clean-guard scan --worktree --summary` until nothing blocks. Then ask the user to run the tests before
   committing.

## Don't

- Don't force push, delete branches, change clean-guard config or the decision, or bypass the hooks.
- Don't commit unless the user asks.
