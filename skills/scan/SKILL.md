---
name: scan
description: Audit the current repo for AI-tool traces with clean-guard (whole history by default) and report what to fix. Read-only.
argument-hint: "[history | recent | staged | <range>]"
disable-model-invocation: true
allowed-tools: Bash(clean-guard scan *), Bash(clean-guard status), Bash(git log *), Bash(git show *)
---

# clean-guard scan

Audit this repo for AI-tool traces and tell the user what they'd need to fix. This is read-only.

## Scan output (captured when you invoked this)

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/clean-guard.sh" skill-scan $ARGUMENTS`

## Steps

1. If the output says this isn't a git repository, say so and stop.
2. Summarise in at most 12 lines:
   - **Verdict** first: clean, warnings only, or blocking findings (from the exit code).
   - **Blocking findings** grouped by rule, with counts and up to 3 examples each (short commit, file, and the matched text).
     If the history scan reports unreachable commits, say which findings come only from those. Unreachable commits
     are never pushed, so they matter only if this repo's objects are shared.
   - **Warnings** in one line per rule. Say plainly when one looks like a false positive (for example "agent" meaning a
     software agent).
   - **Info** lines (identities, timezones, dates, replace refs, stash) only when they look odd.
3. For each blocking rule, give the fix in one line. Use a reworded commit or an interactive rebase for messages,
   `git rm` plus a history rewrite for committed AI or notes files, and a narrow `allow.pattern` for a real false
   positive.
4. If the decision is `none`, end with one line: this repo has no clean-guard decision, and the user can record one with
   `clean-guard init --track …` or `clean-guard init --untrack …`.

## Don't

- Don't rewrite history, force push, delete files, or change clean-guard config or the decision. Only report. If the
  user then asks for a fix, confirm before any history rewrite or force push.
- Don't run the whole scan again. Use `clean-guard scan --all <range>` or `git show <commit>` only to look closer at a
  specific finding.
