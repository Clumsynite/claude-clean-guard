# clean-guard

[![CI](https://github.com/Clumsynite/claude-clean-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/Clumsynite/claude-clean-guard/actions/workflows/ci.yml)
[![Release](https://github.com/Clumsynite/claude-clean-guard/actions/workflows/release.yml/badge.svg)](https://github.com/Clumsynite/claude-clean-guard/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/badge/release-v0.1.0-blue.svg)](https://github.com/Clumsynite/claude-clean-guard/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Keep AI-tool traces out of the branches you ship. clean-guard is a small POSIX sh CLI plus a Claude Code plugin:

- **git hooks** strip attribution trailers (`Co-Authored-By: Claude …`, `🤖 Generated with …`) and block commits and pushes that still carry AI-tool traces on the branches and remotes you choose. They run for every push, from Claude or from your own terminal.
- **a Claude hook** stops the agent bypassing or loosening those hooks (`--no-verify`, hook config overrides, editing the decision file, force pushes to a scoped remote).
- **`clean-guard scan --history`** audits a whole repo: every ref, deleted files, unreachable commits, stash, replace refs, reflog, identities and date anomalies.

## Why

Some code has to read as if an engineer wrote it with no tools in the loop: client work, employer repos, anything pushed to a shared remote. Attribution creeps in from many places (a tool's default commit trailer, a `CLAUDE.md` that got committed, a "generated with" footer, an agent's note in a comment), and once it's pushed, removing it means a history rewrite and a force push. clean-guard catches it before the push.

The decision is **per repo, and within a repo per branch and remote**. A repo can ship one release branch to a client remote under strict rules while every other branch works normally.

## Token cost

About 60 tokens per session for the `/clean-guard:scan` skill's description; its body loads only when you run it. The hooks add nothing in untracked repos and outside git. In a tracked repo, a session starts with a short summary of the rules (about 130 words): no AI traces, comments kept short and about why, and no narration of the change. In a repo with no decision yet, the session gets a short note asking Claude to raise the question with you once.

## Requirements

git **2.54 or newer** (config-based hooks), awk and a POSIX sh. jq is needed only for the Claude hooks; without it they print a warning and stay out of the way, and the git hooks still apply.

## Install

From GitHub:

```
/plugin marketplace add Clumsynite/claude-clean-guard
/plugin install clean-guard@clumsyknight-clean-guard
```

From a local clone:

```
claude plugin marketplace add /path/to/claude-clean-guard
claude plugin install clean-guard@clumsyknight-clean-guard --scope user
```

Each session start copies the scripts to a stable place, `${XDG_DATA_HOME:-~/.local/share}/clean-guard/`, and links `~/.local/bin/clean-guard` to it. Git hooks always point at that copy, so they keep working when the plugin updates. The copy is refreshed only when the version changes.

## Deciding, once per repo

When Claude opens a repo with no decision, it gets the signals (remotes, AI files that are tracked or excluded, and a suggestion from your hints) and **asks you** before recording anything. Then it runs one of:

```
clean-guard init --track --branch release --remote client-remote --strict --reason "ships to the client"  --by user
clean-guard init --untrack --reason "personal project" --by user
```

`--track` writes the decision, installs the `commit-msg` and `pre-push` hooks, and checks that git lists them. `--untrack` records the decision and installs nothing. A second `init` is refused unless you pass `--force`, and Claude is never allowed `--force`.

The decision lives in `$(git rev-parse --git-common-dir)/clean-guard`, inside `.git`: it can't be committed, `git clean` doesn't touch it, and every worktree shares it.

Hints for the suggestion go in `~/.config/clean-guard/config` (see [examples/config](examples/config)):

```
[hint]
	personalRemote = *github.com*your-user/*
	cleanRemote = *git.client.example*
	ignorePath = */scratch/*
```

## Config reference

The decision file is git-config format. Read it with `clean-guard status` or `clean-guard config get KEY`.

```
[guard]
	decision = tracked            # tracked | untracked
	reason = ships to the client
	decidedBy = user              # agent | user
	decidedAt = 2026-01-01
[scope]                           # all empty = every branch and remote
	branch = release              # shell glob, repeatable
	remote = client-remote        # remote name, repeatable
	url = *git.client.example*    # glob matched against the push URL, repeatable
[rules]
	strict = true                 # also block test files, any Co-Authored-By and 2+ line comments; warn on dates, hashes, IPs
	maxCommentLines = 3           # longest run of added comment lines (default 3, or 1 in strict mode; 0 = off)
	stripTrailers = true          # commit-msg removes attribution lines instead of blocking (default true)
	noForcePush = true            # block non-fast-forward pushes and ref deletes in scope (default true)
	noSharedHistoryWith = main    # block a pushed tip that shares any commit with this ref, repeatable
	extra = block add (^|[^0-9])10\.0\.0\.[0-9]+   # "<block|warn> <targets> <ERE>", repeatable
	allowEmail = *@example.com    # authors and committers must match, repeatable
[allow]
	pattern = @anthropic-ai/sdk   # ERE; a matching line is never flagged, repeatable
	path = vendor/*               # glob; files skipped for path, add and comment rules, repeatable
[scan]
	excludePath = package-lock.json   # pathspec excluded from diff scans, repeatable
```

Scope is an OR: a push is checked if its remote is scoped (by name, by the URL of a scoped remote, or by `scope.url`), or if the branch being pushed matches `scope.branch`. The commit-msg hook runs on scoped branches (all branches when `scope.branch` is empty).

Claude may change only one thing itself: adding a narrow `allow.pattern` or `allow.path` for a false positive. Patterns that match almost everything are refused. Every other change is yours (`! clean-guard config set …` in Claude Code). `status` lists every allow entry.

## Rules

Lines are lowercased and matched as POSIX ERE. Targets: `msg` (commit message lines), `path` (changed paths), `add` (added lines), `comment` (added lines that look like comments; Markdown, reST and text files don't count), `ident` (author and committer).

| rule | severity | targets | catches |
|---|---|---|---|
| attr-trailer | block | msg | `Co-Authored-By`, `Generated-By`, `Assisted-By`, `X-AI-*` naming an AI tool; `Claude-Session:`; in strict mode any `Co-Authored-By` |
| gen-line | block | msg, add | "generated with/by/using" an AI tool, 🤖, "created by" an AI tool |
| ai-name | block | msg, add | the words claude, anthropic, chatgpt, openai, copilot, gemini, llm(s), codex, aider, "cursor ai" |
| ai-file | block | path | `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`, `.claude/`, `.cursor/`, `.cursorrules`, `.aider*`, `.aidex/`, `.windsurf*`, `.continue/`, `.github/copilot-instructions.md`, `.mcp.json`, `.clean-guard` |
| notes-file | block | path | `handoff*.md`, `plan.md`, `plans/`, `pickup*.md`, `*-plan.md` |
| test-file | block (strict only) | path | `test/`, `tests/`, `__tests__/`, `e2e/`, `spec/`, `*.test.*`, `*.spec.*`, `test_*.py`, `*_test.go`, `*_test.py` |
| process-words | warn | msg, comment | "as discussed", "this session", "the agent added", "used to be", "previously was" and similar |
| slop-words | warn | msg, comment | narration of the change: "as requested", "for clarity", "it's worth noting"; in comments also "this change", "now handles", "updated to", "note that" |
| comment-wall | warn (block in strict) | comment | more than `rules.maxCommentLines` consecutive added comment lines with text in them (lines holding only `/**`, `*/` and the like don't count) |
| history-refs | warn (strict only) | msg, comment | ISO dates, commit hashes that resolve in the repo, `ticket #`, IPv4 addresses |
| odd-ident | warn | ident | `root@…`, `@localhost`, `.local`/`.lan` emails, emails with no dot in the domain |

Exit codes: 0 clean or warnings only, 1 at least one block, 2 usage, config or git error. A git error inside a hook blocks the commit or push (fail closed).

## Commands

In Claude Code, `/clean-guard:scan` audits the current repo and summarises what to fix without changing anything. With no argument it runs a whole-history audit; `recent` scans unpushed commits, `staged` scans the index, and anything else is passed through as a range. Its one-line description adds about 60 tokens to each session; the rest (about 650) loads only when you run it.

```
clean-guard scan [RANGE] [--staged] [--all] [--json]    # default range: @{upstream}..HEAD
clean-guard scan --history [--refs all|REF...]          # whole-repo audit
clean-guard status                                      # decision, scope, rules, allow entries, hook health
clean-guard doctor [--fix]                              # repair missing or disabled hooks
clean-guard config get|set|add|unset KEY [VALUE]
clean-guard uninstall-repo                              # remove the hooks and decision from this repo
clean-guard uninstall [--force]                         # remove the stable copy (and, with --force, every repo's hooks)
```

Output is one line per finding, at most 5 per rule (`--all` lifts the cap), then a summary. `--json` prints one object per finding.

## Husky and other hook managers

Config-based hooks run **in addition to** the `core.hooksPath` hook, so husky, lint-staged and friends keep working untouched. clean-guard runs first; if it blocks, the push is blocked.

## Uninstall

In each tracked repo, `clean-guard uninstall-repo`. Then `clean-guard uninstall` removes the stable copy and the `~/.local/bin` link, and `claude plugin uninstall clean-guard@clumsyknight-clean-guard` removes the plugin. By hand: `git config --remove-section hook.clean-guard-commit-msg`, `git config --remove-section hook.clean-guard-pre-push`, and delete `.git/clean-guard`.

## Limitations

- The git hooks are the real guard. The Claude hook reads commands as text, so it can't see through a script file (`sh x.sh`), `eval` of a built string, or pushes made through an API or a web UI.
- It checks what enters git. It can't see squash or merge commits made on the server, or clones made before the repo was tracked; `scan --history` is the backstop for those.
- The Claude hook errs on the side of denying: a quoted commit message containing a bare `-n` or `--no-verify` is denied. Run such a command yourself with `!`.
- Server-side enforcement (a `pre-receive` hook on the Git server) isn't included, so pushes from machines without clean-guard aren't checked.

## Development

```
sh tests/run.sh                 # full suite, once per awk found (awk, mawk, gawk)
TEST_SH=dash sh tests/run.sh    # the script under dash
TEST_AWKS=awk sh tests/run.sh   # one awk only, faster
shellcheck -s sh scripts/*.sh tests/run.sh
```

The tests use a throwaway `HOME`, data dir, config and git config, and touch nothing else. CI (`.github/workflows/ci.yml`) runs shellcheck, the manifest checks and the tests on Ubuntu and macOS with a current git.

## Releasing

Releases are built by CI/CD:

1. Bump `version` in `.claude-plugin/plugin.json` and the `release-v<version>` badge at the top of this README (CI fails if they differ), commit, and push to `main`.
2. When CI passes on that push, `.github/workflows/release.yml` creates the tag `clean-guard--v<version>` and a GitHub release with generated notes at the tested commit. If that release already exists, it does nothing.

Users pick up new versions with `/plugin update clean-guard@clumsyknight-clean-guard`.

## License

MIT
