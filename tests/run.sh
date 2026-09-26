#!/bin/sh
# Self-contained tests for clean-guard. Uses a throwaway HOME, data, config and git config;
# touches nothing else. Usage: sh tests/run.sh
# Set TEST_SH=dash (or bash) to run the script under another /bin/sh. The awk-dependent tests run once
# for each of awk, mawk and gawk found on PATH (TEST_AWKS="awk" limits that).

HERE=$(cd "$(dirname "$0")/.." && pwd -P)
CG="$HERE/scripts/clean-guard.sh"
SH=${TEST_SH:-sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/clean-guard-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT INT TERM

unset CLEAN_GUARD_AWK CLEAN_GUARD_HOME CLEAN_GUARD_CONFIG
export HOME="$WORK/home"
export XDG_DATA_HOME="$WORK/data"
export XDG_CONFIG_HOME="$WORK/config"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Dev GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME=Dev GIT_COMMITTER_EMAIL=dev@example.com
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf '[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[advice]\n\tdetachedHead = false\n' > "$GIT_CONFIG_GLOBAL"
DATA="$XDG_DATA_HOME/clean-guard"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# check NAME OUTPUT PATTERN - OUTPUT must match the grep -E PATTERN.
check() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else no "$1" "$2"; fi; }
# lacks NAME OUTPUT PATTERN - OUTPUT must not match.
lacks() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then no "$1" "$2"; else ok "$1"; fi; }
# rc NAME WANT GOT [OUTPUT]
rc() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "exit $3, want $2${4:+
$4}"; fi; }

cg() { $SH "$CG" "$@"; }

# newrepo DIR - a fresh repo with one commit, cd'd into.
newrepo() {
	mkdir -p "$1" && cd "$1" || exit 1
	git init -q
	echo base > base.txt
	git add base.txt
	git commit -q -m "Initial commit"
}

# The decision file of the current repo.
df() { printf '%s/clean-guard' "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"; }

# ---------------------------------------------------------------- M0: git support

tg=$WORK/gitprobe
git init -q "$tg"
git -C "$tg" config hook.probe.event pre-push
git -C "$tg" config hook.probe.command true
if git -C "$tg" hook list pre-push 2>/dev/null | grep -qx probe; then
	ok "git supports config-based hooks ($(git --version))"
else
	no "git supports config-based hooks" "clean-guard needs git 2.54+; this is $(git --version)"
fi

# ---------------------------------------------------------------- M1: scan engine, per awk

# mcase NAME WANT MESSAGE - commit MESSAGE; WANT is +rule (must be reported) or -rule (must not).
mcase() {
	git commit -q --allow-empty -m "$3"
	out=$(cg scan 'HEAD^!' 2>&1)
	want=${2#?}
	case $2 in
	+*) check "$AWKNAME msg $1" "$out" " $want [0-9a-f]{7} msg" ;;
	-*) lacks "$AWKNAME msg $1" "$out" " $want [0-9a-f]{7} msg" ;;
	esac
}

# fcase NAME WANT PATH [LINE] - add a file (with LINE as its content) and commit it.
fcase() {
	mkdir -p "$(dirname "$3")"
	printf '%s\n' "${4:-content}" > "$3"
	git add -- "$3"
	git commit -q -m "Add file"
	out=$(cg scan 'HEAD^!' 2>&1)
	want=${2#?}
	case $2 in
	+*) check "$AWKNAME $1" "$out" " $want [0-9a-f]{7} " ;;
	-*) lacks "$AWKNAME $1" "$out" " $want [0-9a-f]{7} " ;;
	esac
}

scan_tests() {
	newrepo "$WORK/scan-$AWKNAME"

	mcase "trailer hit" +attr-trailer "Fix login

Co-Authored-By: Claude <noreply@anthropic.com>"
	mcase "trailer other tool" +attr-trailer "Fix

Co-authored-by: GitHub Copilot <copilot@github.com>"
	mcase "trailer session" +attr-trailer "Fix

Claude-Session: abc"
	mcase "human co-author is fine" -attr-trailer "Fix

Co-Authored-By: Jane Roe <jane@example.com>"
	mcase "gen-line hit" +gen-line "Fix

Generated with Claude Code"
	mcase "gen-line emoji" +gen-line "$(printf 'Fix\n\n\360\237\244\226 done')"
	mcase "gen-line created by" +gen-line "Created by ChatGPT"
	mcase "gen-line near-miss" -gen-line "Generated with the protobuf compiler"
	mcase "ai-name hit" +ai-name "Claude wrote the parser"
	mcase "ai-name openai" +ai-name "Switch the OpenAI client"
	mcase "ai-name near-miss claudette" -ai-name "Rename claudette helper"
	mcase "ai-name near-miss llmnr" -ai-name "Resolve names over LLMNR"
	mcase "ai-name near-miss cursor" -ai-name "Close the DB cursor early"
	mcase "process-words hit" +process-words "Fix as discussed"
	mcase "process-words used to be" +process-words "It used to be slow"
	mcase "process-words near-miss store" -process-words "Buffer used to store frames"
	mcase "process-words near-miss previously" -process-words "Restore the previously selected item"
	mcase "process-words near-miss handoff" -process-words "Handle call handoff between cells"
	mcase "process-words near-miss agent" -process-words "Restart the ha-agent service"
	mcase "history-refs off unless strict" -history-refs "Fix bug from 2026-01-02"
	out=$(cg scan 'HEAD^!')
	lacks "$AWKNAME warn is not block" "$out" "BLOCK"

	fcase "ai-file CLAUDE.md" +ai-file CLAUDE.md
	fcase "ai-file .claude dir" +ai-file sub/.claude/settings.json
	fcase "ai-file .aider" +ai-file .aider.conf.yml
	fcase "ai-file copilot" +ai-file .github/copilot-instructions.md
	fcase "ai-file .clean-guard" +ai-file .clean-guard
	fcase "ai-file near-miss" -ai-file docs/claude-desktop-notes.txt
	fcase "notes-file plan" +notes-file docs/PLAN.md
	fcase "notes-file handoff" +notes-file handoff-2.md
	fcase "notes-file plans dir" +notes-file plans/x.md
	fcase "notes-file near-miss" -notes-file docs/planning-guide.md
	fcase "test-file off unless strict" -test-file tests/a_test.go
	fcase "add line ai-name" +ai-name src/a.js "// written by Claude"
	fcase "add line near-miss" -ai-name src/b.js "const claudette = 1"
	fcase "comment process-words" +process-words src/c.js "// as discussed with the team"
	fcase "markdown heading is not a comment" -comment-banner docs/d.md "## Setup"

	git commit -q --allow-empty -m "Plain" --author "Root <root@box.local>"
	out=$(cg scan 'HEAD^!')
	check "$AWKNAME odd-ident" "$out" "WARN odd-ident"

	# comment walls and slop words
	fcase "comment wall of 4 warns" +comment-wall src/w1.js "$(printf '// one\n// two\n// three\n// four\nrun()')"
	fcase "3 comment lines are fine" -comment-wall src/w2.js "$(printf '// one\n// two\n// three\nrun()')"
	fcase "delimiter lines don't count" -comment-wall src/w3.ts "$(printf '/**\n * One line of doc.\n */\nexport const x = 1')"
	fcase "C preprocessor lines aren't comments" -comment-wall src/w4.c "$(printf '#include <a.h>\n#include <b.h>\n#include <c.h>\n#define X 1\nint x;')"
	fcase "Markdown headings aren't comments" -comment-wall docs/w5.md "$(printf '# a\n# b\n# c\n# d')"
	fcase "trailing code comments aren't a wall" -comment-wall src/w6.js "$(printf 'a() // x\nb() // y\nc() // z\nd() // w')"
	fcase "slop: this change" +slop-words src/s1.js "// This change fixes the retry"
	fcase "slop: now handles" +slop-words src/s2.js "// Now handles empty input"
	fcase "slop: updated to" +slop-words src/s3.py "# Updated to use the new client"
	fcase "slop near-miss handles" -slop-words src/s4.js "// Handles empty input"
	fcase "slop near-miss updated total" -slop-words src/s5.js "// Returns the updated total"
	mcase "slop in a message" +slop-words "Fix the login check as requested"
	fcase "banner divider" +comment-banner src/b1.js "// ---- Section ----"
	fcase "banner heading" +comment-banner scripts/b2.sh "## Setup"
	fcase "banner near-miss modeline" -comment-banner src/b3.py "# -*- coding: utf-8 -*-"
	fcase "banner near-miss jsdoc" -comment-banner src/b4.ts "/** One line. */"
	fcase "doc wording" +slop-words docs/d1.md "The cache is deliberately small."
	fcase "doc history" +process-words docs/d2.md "We tried a bigger cache first."
	fcase "doc near-miss" -slop-words docs/d3.md "Run the installer, then restart the service."
	fcase "heredoc text is not a comment" -comment-banner scripts/h1.sh "$(printf 'cat > out.md <<'"'"'EOF'"'"'\n## What this is\n# a\n# b\nEOF\nrun')"
	fcase "heredoc text is not a comment wall" -comment-wall scripts/h2.sh "$(printf 'cat <<-END\n\t# a\n\t# b\n\t# c\n\t# d\n\tEND\nrun')"
	fcase "comments after a heredoc still count" +comment-wall scripts/h3.sh "$(printf 'cat <<EOF\nx\nEOF\n# a\n# b\n# c\n# d\nrun')"
	fcase "a heredoc named in a comment doesn't hide code" +comment-wall scripts/h4.sh "$(printf '# usage: cat <<EOF\n# a\n# b\n# c\nrun')"
	fcase "section sign in a code comment is fine" -slop-words src/rfc.ts "// RFC 4226 section 5.3 (§5.3) truncation"
	fcase "license files are skipped" -slop-words LICENSE.txt "§1 The notices travel with the files."

	# strict mode
	git config -f "$(df)" guard.decision tracked
	git config -f "$(df)" rules.strict true
	mcase "strict any co-author" +attr-trailer "Fix

Co-Authored-By: Jane Roe <jane@example.com>"
	mcase "strict date" +history-refs "Fix bug from 2026-01-02"
	mcase "strict ip" +history-refs "Point at 10.1.2.3 now"
	short=$(git rev-parse --short=9 HEAD~2)
	mcase "strict hexref" +history-refs "Revert $short"
	mcase "strict hex near-miss" -history-refs "Colour deadbeefcafe0"
	fcase "strict test-file" +test-file tests/b_test.go
	fcase "strict spec" +test-file src/x.spec.ts
	fcase "strict near-miss" -test-file src/testing.go
	fcase "strict: 2 comment lines block" +comment-wall src/w7.js "$(printf '// one\n// two\nrun()')"
	out=$(cg scan 'HEAD^!')
	check "$AWKNAME strict comment wall is a block" "$out" "BLOCK comment-wall"
	fcase "strict: 1 comment line is fine" -comment-wall src/w8.js "$(printf '// one\nrun()')"
	git config -f "$(df)" rules.maxCommentLines 0
	fcase "maxCommentLines 0 turns it off" -comment-wall src/w9.js "$(printf '// a\n// b\n// c\n// d\n// e\nrun()')"
	git config -f "$(df)" --unset rules.maxCommentLines
	git config -f "$(df)" --unset rules.strict

	# allow entries, extras, excludes
	git config -f "$(df)" allow.pattern '@anthropic-ai/sdk'
	fcase "allow.pattern" -ai-name src/e.js "import x from '@anthropic-ai/sdk' // anthropic client"
	git config -f "$(df)" allow.path 'vendor/*'
	fcase "allow.path" -ai-name vendor/lib/f.js "claude"
	git config -f "$(df)" rules.extra 'block add (^|[^0-9])10\.9\.[0-9]+\.[0-9]+'
	fcase "rules.extra" +extra src/g.conf "host = 10.9.8.7"
	git config -f "$(df)" scan.excludePath 'gen/*'
	fcase "scan.excludePath" -ai-name gen/h.txt "claude"
	git config -f "$(df)" rules.extra 'nonsense'
	out=$(cg scan 'HEAD^!' 2>&1)
	rc "$AWKNAME bad rules.extra exits 2" 2 $? "$out"
	git config -f "$(df)" --unset-all rules.extra

	# multi-valued decision
	git config -f "$(df)" --add guard.decision untracked
	out=$(cg scan 'HEAD^!' 2>&1)
	rc "$AWKNAME two guard.decision values exit 2" 2 $? "$out"
	rm -f "$(df)"

	# exit codes, subdirectory, cap, json, renames, non-ASCII paths, git failure
	git commit -q --allow-empty -m "Claude one"
	cg scan 'HEAD^!' > /dev/null 2>&1
	rc "$AWKNAME block exits 1" 1 $?
	git commit -q --allow-empty -m "Plain two"
	cg scan 'HEAD^!' > /dev/null 2>&1
	rc "$AWKNAME clean exits 0" 0 $?
	mkdir -p deep/er
	(cd deep/er && cg scan HEAD~2..HEAD > "$WORK/sub.out" 2>&1)
	check "$AWKNAME scan from a subdirectory sees the whole repo" "$(cat "$WORK/sub.out")" "ai-name"
	i=0
	while [ $i -lt 7 ]; do git commit -q --allow-empty -m "Claude $i"; i=$((i + 1)); done
	out=$(cg scan HEAD~7..HEAD)
	check "$AWKNAME cap at 5 per rule" "$out" "\(\+2 more ai-name\)"
	out=$(cg scan --all HEAD~7..HEAD)
	lacks "$AWKNAME --all removes the cap" "$out" "more ai-name"
	out=$(cg scan --json HEAD~7..HEAD)
	if printf '%s\n' "$out" | jq -e . > /dev/null 2>&1 && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 7 ]; then
		ok "$AWKNAME --json lines parse"
	else
		no "$AWKNAME --json lines parse" "$out"
	fi
	git mv base.txt "$(printf 'pl\303\244n-plan.md')"
	git commit -q -m "Rename"
	out=$(cg scan 'HEAD^!')
	check "$AWKNAME non-ASCII rename matched" "$out" "notes-file [0-9a-f]{7} path: pl.*-plan\.md"
	out=$(cg scan nosuchref..HEAD 2>&1)
	rc "$AWKNAME git failure exits 2" 2 $? "$out"
	check "$AWKNAME git failure is reported" "$out" "git failed"
	long="x$(printf '%0200d' 0) Claude $(printf '%0200d' 0)"
	git commit -q --allow-empty -m "$long"
	out=$(cg scan 'HEAD^!' | head -n 1)
	check "$AWKNAME long line is cut around the match" "$out" "\.\.\.0+ Claude 0+\.\.\.$"
	if [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" -le 110 ]; then ok "$AWKNAME cut to about 100 bytes"; else no "$AWKNAME cut to about 100 bytes" "$out"; fi
	cd "$WORK" || exit 1
}

for a in ${TEST_AWKS:-awk mawk gawk}; do
	command -v "$a" > /dev/null 2>&1 || continue
	export CLEAN_GUARD_AWK="$a"
	AWKNAME=$a
	scan_tests
done
unset CLEAN_GUARD_AWK

# ---------------------------------------------------------------- M2: init, config, status, doctor, install-copy

newrepo "$WORK/m2"
out=$(cg init --track --remote client --reason "ships to client" --by user 2>&1)
rc "init --track" 0 $? "$out"
check "init installs the stable copy" "$(cat "$DATA/VERSION" 2>&1)" "^0\.2\.0$"
check "init lists both hooks" "$(git hook list pre-push; git hook list commit-msg)" "clean-guard-pre-push"
check "decision file lives in the git dir" "$(git config -f .git/clean-guard --get guard.decision)" "^tracked$"
check "registry has the repo" "$(cat "$DATA/repos")" "/m2/\.git$"
out=$(cg init --untrack --reason again 2>&1)
rc "init twice exits 2" 2 $? "$out"
out=$(cg status)
rc "status healthy" 0 $? "$out"
check "status shows scope" "$out" "remotes client"
git worktree add -q "$WORK/m2-wt" 2>/dev/null
printf '[guard]\n\tdecision = untracked\n' > "$WORK/m2-wt/.clean-guard"
out=$(cd "$WORK/m2-wt" && cg status)
check "linked worktree reads the main decision file" "$out" "^decision: tracked"

out=$(cg config add allow.pattern '.' 2>&1)
rc "config rejects a match-all allow.pattern" 2 $? "$out"
out=$(cg config add allow.path '*' 2>&1)
rc "config rejects a match-all allow.path" 2 $? "$out"
cg config add allow.pattern '@anthropic-ai/sdk' > /dev/null 2>&1
rc "config accepts a narrow allow.pattern" 0 $?
check "status lists allow entries" "$(cg status)" "allow.pattern: @anthropic-ai/sdk"

git config hook.clean-guard-pre-push.enabled false
out=$(cg status)
rc "status exits 1 when a hook is disabled" 1 $? "$out"
out=$(cg doctor --fix 2>&1)
rc "doctor --fix repairs it" 0 $? "$out"
cg status > /dev/null
rc "status healthy after doctor" 0 $?

# husky-style hooksPath hook still runs next to ours
git init -q --bare "$WORK/m2-remote.git"
git remote add client "$WORK/m2-remote.git"
mkdir -p hp
printf '#!/bin/sh\ntouch "%s/husky-ran"\n' "$WORK" > hp/pre-push
chmod +x hp/pre-push
git config core.hooksPath hp
out=$(git push -q client main 2>&1)
rc "clean push goes through" 0 $? "$out"
if [ -f "$WORK/husky-ran" ]; then ok "hooksPath hook still runs"; else no "hooksPath hook still runs"; fi
git config --unset core.hooksPath

# install-copy
before=$(cat "$DATA/clean-guard.sh")
printf '# local marker\n' >> "$DATA/scan.awk"
cg install-copy > /dev/null 2>&1
check "install-copy skips an equal VERSION" "$(tail -n 1 "$DATA/scan.awk")" "local marker"
printf '0.0.1\n' > "$DATA/VERSION"
cg install-copy > /dev/null 2>&1
lacks "install-copy replaces a different VERSION" "$(tail -n 1 "$DATA/scan.awk")" "local marker"
mkdir -p "$WORK/broken"
cp -R "$HERE/scripts" "$HERE/rules" "$HERE/.claude-plugin" "$WORK/broken/"
printf 'if then fi (\n' >> "$WORK/broken/scripts/clean-guard.sh"
out=$($SH "$WORK/broken/scripts/clean-guard.sh" install-copy --force 2>&1)
rc "install-copy refuses a script that fails sh -n" 2 $? "$out"
if [ "$(cat "$DATA/clean-guard.sh")" = "$before" ]; then ok "old copy left intact"; else no "old copy left intact"; fi
out=$("$HOME/.local/bin/clean-guard" status 2>&1)
check "CLI works through the symlink" "$out" "^decision: tracked"
mkdir -p "$WORK/home2/.local/bin"
printf 'mine\n' > "$WORK/home2/.local/bin/clean-guard"
out=$(HOME="$WORK/home2" XDG_DATA_HOME="$WORK/data2" cg install-copy 2>&1)
check "install-copy never replaces a non-symlink" "$(cat "$WORK/home2/.local/bin/clean-guard")" "^mine$"
check "install-copy warns about the non-symlink" "$out" "not a symlink"

# old git: init undoes itself
mkdir -p "$WORK/fakegit"
realgit=$(command -v git)
# shellcheck disable=SC2016 # the fake git's own $1 and $@
printf '#!/bin/sh\n[ "$1" = hook ] && exit 129\nexec "%s" "$@"\n' "$realgit" > "$WORK/fakegit/git"
chmod +x "$WORK/fakegit/git"
newrepo "$WORK/m2-old"
out=$(PATH="$WORK/fakegit:$PATH" cg init --track --reason x 2>&1)
rc "init on git without config hooks exits 2" 2 $? "$out"
check "init names the git requirement" "$out" "needs git 2\.54"
if [ ! -f .git/clean-guard ] && ! git config --get-regexp '^hook\.' > /dev/null; then ok "init left nothing behind"; else no "init left nothing behind"; fi

# untrack, uninstall-repo, uninstall
cd "$WORK/m2" || exit 1
out=$(cg init --untrack --force --reason "personal" 2>&1)
rc "init --untrack --force" 0 $? "$out"
git config --get-regexp '^hook\.clean-guard' > /dev/null
rc "untrack removes our hooks" 1 $?
cg init --track --force --reason again > /dev/null 2>&1
cg uninstall-repo > /dev/null 2>&1
git config --get-regexp '^hook\.clean-guard' > /dev/null
rc "uninstall-repo leaves no hook keys" 1 $?
if [ ! -f .git/clean-guard ]; then ok "uninstall-repo removes the decision"; else no "uninstall-repo removes the decision"; fi
cg init --track --reason again > /dev/null 2>&1
out=$(cg uninstall 2>&1)
rc "uninstall refuses while repos have hooks" 2 $? "$out"
out=$(cg uninstall --force 2>&1)
rc "uninstall --force" 0 $? "$out"
if [ ! -d "$DATA" ] && [ ! -e "$HOME/.local/bin/clean-guard" ] && ! git config --get-regexp '^hook\.clean-guard' > /dev/null; then
	ok "uninstall removes the data dir, symlink and repo hooks"
else
	no "uninstall removes the data dir, symlink and repo hooks"
fi
cd "$WORK" || exit 1

# ---------------------------------------------------------------- M3: git hooks

newrepo "$WORK/m3"
git init -q --bare "$WORK/m3-client.git"
git init -q --bare "$WORK/m3-other.git"
git remote add client "$WORK/m3-client.git"
git remote add other "$WORK/m3-other.git"
git checkout -q --orphan release
git rm -q -rf . > /dev/null
echo app > app.txt
git add app.txt
git commit -q -m "Start release line"
git push -q client release
cg init --track --branch release --remote client --no-shared-history-with main --reason "ships to client" --by user > /dev/null 2>&1
rc "m3 init" 0 $?

# commit-msg
echo one >> app.txt
out=$(git commit -q -am "Tune the retry loop

Co-Authored-By: Claude <noreply@anthropic.com>
$(printf '\360\237\244\226') Generated with Claude Code" 2>&1)
rc "commit with a trailer succeeds" 0 $? "$out"
check "trailer removal is reported" "$out" "removed: Co-Authored-By"
msg=$(git log -1 --format=%B)
lacks "trailer stripped" "$msg" "Co-Authored-By|Generated"
check "subject kept" "$msg" "^Tune the retry loop$"
echo "// Claude helper" > helper.js
git add helper.js
out=$(git commit -q -m "Add helper" 2>&1)
rc "commit adding an AI name is blocked" 1 $? "$out"
check "block is explained" "$out" "BLOCK ai-name new add helper.js"
git reset -q
rm -f helper.js
out=$(git commit -q --allow-empty -m "Plain" --author "Root <root@box.local>" 2>&1)
rc "warn-only ident doesn't block" 0 $? "$out"
git checkout -q -b feature main
out=$(git commit -q --allow-empty -m "Claude notes on a feature branch" 2>&1)
rc "commit-msg ignores out-of-scope branches" 0 $? "$out"

# pre-push
git checkout -q release
out=$(git push -q client release 2>&1)
rc "clean push to the scoped remote" 0 $? "$out"
git commit -q --no-verify --allow-empty -m "Claude wrote this"
out=$(git push -q client release 2>&1)
rc "push with a finding is blocked" 1 $? "$out"
check "push block names the rule" "$out" "BLOCK ai-name"
out=$(git push -q "$WORK/m3-client.git" release 2>&1)
rc "push by URL is in scope" 1 $? "$out"
out=$(git push -q other feature 2>&1)
rc "out-of-scope push is allowed" 0 $? "$out"
git reset -q --hard HEAD~1
git commit -q --amend --allow-empty -m "Plain, rewritten" 2>/dev/null
out=$(git push -q -f client release 2>&1)
rc "force push is blocked" 1 $? "$out"
check "force push reason" "$out" "non-fast-forward"
out=$(git push -q client :release 2>&1)
rc "deleting a scoped branch is blocked" 1 $? "$out"
git reset -q --hard client/release 2>/dev/null || git reset -q --hard "$(git ls-remote client refs/heads/release | cut -f 1)"
git branch -q bad main
out=$(git push -q client bad 2>&1)
rc "shared history with main is blocked" 1 $? "$out"
check "shared history reason" "$out" "shares history with main"
git branch -q r2 release
git branch -q r3 release
git checkout -q r3
git commit -q --no-verify --allow-empty -m "Claude in r3"
git checkout -q release
out=$(git push -q client release r2 r3 2>&1)
rc "every pushed ref is checked" 1 $? "$out"
check "third ref's finding reported" "$out" "Claude in r3"
git tag -a -m "Tag" v1 r3
out=$(git push -q client v1 2>&1)
rc "tag push is checked" 1 $? "$out"
git config -f "$(df)" rules.allowEmail '*@example.com'
git commit -q --no-verify --allow-empty -m "Plain" --author "Other <other@elsewhere.org>"
out=$(git push -q client release 2>&1)
rc "allowEmail blocks outside identities" 1 $? "$out"
check "allowEmail reason" "$out" "allow-email"
git reset -q --hard HEAD~1
git config -f "$(df)" --unset rules.allowEmail
git clone -q "$WORK/m3-client.git" "$WORK/m3-clone" 2>/dev/null
(cd "$WORK/m3-clone" && git checkout -q release && git commit -q --allow-empty -m "Elsewhere" && git push -q origin release) > /dev/null 2>&1
git commit -q --allow-empty -m "Local"
out=$(git push -q client release 2>&1)
rc "unknown remote tip is blocked" 1 $? "$out"
check "unknown tip reason" "$out" "fetch first"
mv "$(df)" "$WORK/df.saved"
out=$(git push -q client release 2>&1)
rc "missing decision file fails closed" 1 $? "$out"
check "fail-closed message" "$out" "clean-guard doctor"
mv "$WORK/df.saved" "$(df)"
cd "$WORK" || exit 1

# ---------------------------------------------------------------- M4: scan --history

newrepo "$WORK/m4"
GIT_AUTHOR_DATE="2026-01-10T10:00:00+0530" GIT_COMMITTER_DATE="2026-01-10T10:00:00+0530" \
	git commit -q --allow-empty -m "Parent"
GIT_AUTHOR_DATE="2026-01-01T10:00:00+0000" GIT_COMMITTER_DATE="2026-01-01T10:00:00+0000" \
	git commit -q --allow-empty -m "Backdated child, see 1234abcd9"
GIT_AUTHOR_DATE="2026-01-01T10:00:00+0000" git commit -q --allow-empty -m "Late commit"
git commit -q --allow-empty -m "By root" --author "Root <root@box.local>"
echo s > s.txt
git add s.txt
git stash -q
git replace "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD~2)"
out=$(cg scan --history 2>&1)
rc "history with info only exits 0" 0 $? "$out"
check "history: dated before a parent" "$out" "INFO dated before a parent: 2"
check "history: timezones" "$out" "INFO timezones:.*\+0530.*|INFO timezones:.*\+0000.*\+0530"
check "history: author/committer gap" "$out" "INFO author and committer dates over a day apart"
check "history: identity summary" "$out" "INFO identity: .*Root <root@box.local>"
check "history: odd identity warned" "$out" "WARN odd-ident"
check "history: replace ref" "$out" "INFO ref: refs/replace/"
check "history: stash" "$out" "INFO ref: refs/stash"
check "history: reflog" "$out" "INFO reflog: present"
check "history: unresolved short hash" "$out" "INFO unresolved short hashes in messages: 1"
git checkout -q -b dropped
git commit -q --allow-empty -m "Fix

Co-Authored-By: Claude <noreply@anthropic.com>"
git checkout -q main
git branch -q -D dropped
out=$(cg scan --history 2>&1)
rc "history with an unreachable trailer commit exits 1" 1 $? "$out"
check "history: unreachable commit counted" "$out" "INFO unreachable commits: 1"
check "history: unreachable message scanned" "$out" "BLOCK attr-trailer"
git commit -q --allow-empty -m "Add CLAUDE notes"
git rm -q --cached base.txt > /dev/null
echo x > CLAUDE.md
git add CLAUDE.md
git commit -q -m "Add file"
git rm -q CLAUDE.md
git commit -q -m "Remove file"
out=$(cg scan --history --refs main 2>&1)
check "history: a deleted AI file still counts" "$out" "BLOCK ai-file [0-9a-f]{7} path: CLAUDE.md"
cd "$WORK" || exit 1

# ---------------------------------------------------------------- M5: Claude hooks

# ss CWD - run the SessionStart hook for CWD, print its stdout.
ss() { jq -nc --arg c "$1" '{hook_event_name: "SessionStart", source: "startup", cwd: $c}' | cg claude session-start 2>/dev/null; }
# pt CWD TOOL VALUE - run the PreToolUse hook; VALUE is the command (Bash) or file_path (Edit/Write).
pt() {
	case $2 in
	Bash | Monitor) jq -nc --arg c "$1" --arg t "$2" --arg v "$3" '{hook_event_name: "PreToolUse", cwd: $c, tool_name: $t, tool_input: {command: $v}}' ;;
	*) jq -nc --arg c "$1" --arg t "$2" --arg v "$3" --arg s "${4:-x}" '{hook_event_name: "PreToolUse", cwd: $c, tool_name: $t, tool_input: {file_path: $v, content: $s}}' ;;
	esac | cg claude pre-tool 2>/dev/null
}
denies() {
	out=$(pt "$1" "$2" "$3" "${5:-}")
	if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1; then ok "denies: $4"; else no "denies: $4" "$out"; fi
}
allows() {
	out=$(pt "$1" "$2" "$3" "${5:-}")
	if [ -z "$out" ]; then ok "allows: $4"; else no "allows: $4" "$out"; fi
}

R5=$WORK/m5
newrepo "$R5"
git init -q --bare "$WORK/m5-client.git"
git remote add client "$WORK/m5-client.git"
git remote add other "$WORK/m5-other.git"
out=$(ss "$R5")
check "session-start: no decision asks the user" "$out" "no decision yet"
check "session-start: output is hook JSON" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" "^SessionStart$"
check "session-start: says never init without an answer" "$out" "Never run init without their answer"
check "session-start: no hint means unclear" "$out" "suggestion: unclear"
mkdir -p "$XDG_CONFIG_HOME/clean-guard"
printf '[hint]\n\tcleanRemote = *m5-client.git\n' > "$XDG_CONFIG_HOME/clean-guard/config"
check "session-start: hint.cleanRemote suggests track" "$(ss "$R5")" "suggestion: track"
printf '[hint]\n\tcleanRemote = *m5-client.git\n\tignorePath = %s\n' "$R5" > "$XDG_CONFIG_HOME/clean-guard/config"
check "session-start: hint.ignorePath is silent" "[$(ss "$R5")]" "^\[\]$"
rm -f "$XDG_CONFIG_HOME/clean-guard/config"
mkdir -p "$WORK/plain"
check "session-start: non-git is silent" "[$(ss "$WORK/plain")]" "^\[\]$"
newrepo "$WORK/m5-untracked"
cg init --untrack --reason personal > /dev/null 2>&1
check "session-start: untracked is silent" "[$(ss "$WORK/m5-untracked")]" "^\[\]$"
cd "$R5" || exit 1
cg init --track --branch release --remote client --reason "ships to client" --by user > /dev/null 2>&1
out=$(ss "$R5")
check "session-start: tracked gives the rules" "$out" "this repo is tracked \(ships to client\)"
check "session-start: tracked names the scope" "$out" "branches release; remotes client"
check "session-start: tracked states the comment rule" "$out" "comments are at most 3 lines and say why, not what"
check "session-start: tracked warns against narration" "$out" "no narration of the change"

U=$WORK/m5-untracked
denies "$R5" Bash "git commit --no-verify -m x" "commit --no-verify"
denies "$R5" Bash "git commit -n -m x" "commit -n"
denies "$R5" Bash "git commit -anm x" "commit -anm"
denies "$R5" Bash "git commit --no-verif -m x" "commit --no-verif (prefix)"
denies "$R5" Bash "git push --no-veri client release" "push --no-veri (prefix)"
denies "$R5" Bash "git -c hook.clean-guard-pre-push.command=true push client release" "-c hook."
denies "$R5" Bash "git -c HOOK.clean-guard-commit-msg.enabled=false commit -m x" "-c HOOK. (case)"
denies "$R5" Bash "git -c core.hooksPath=/dev/null commit -m x" "-c core.hooksPath"
denies "$R5" Bash "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.x.command GIT_CONFIG_VALUE_0=true git commit -m x" "GIT_CONFIG_COUNT"
denies "$R5" Bash "git --config-env=hook.x.command=V push client release" "--config-env"
denies "$R5" Bash "git config hook.clean-guard-pre-push.enabled false" "git config hook."
denies "$R5" Bash "git config --unset core.hooksPath" "git config --unset core.hooksPath"
denies "$R5" Bash "git config alias.p 'push --no-verify'" "git config alias."
denies "$R5" Bash "git config include.path /tmp/x" "git config include.path"
denies "$R5" Bash "git config -f .git/clean-guard guard.decision untracked" "git config -f decision file"
denies "$R5" Bash "clean-guard config set scope.branch nothing" "clean-guard config set"
denies "$R5" Bash "clean-guard config add guard.decision untracked" "clean-guard config add guard."
denies "$R5" Bash "clean-guard config unset allow.pattern" "clean-guard config unset"
denies "$R5" Bash "clean-guard init --force --untrack --reason x" "clean-guard init --force"
denies "$R5" Bash "sh ~/.local/share/clean-guard/clean-guard.sh uninstall-repo" "uninstall-repo via sh"
denies "$R5" Bash "git push -f client release" "push -f"
denies "$R5" Bash "git push --force-with-lease client release" "push --force-with-lease"
denies "$R5" Bash "git push client +release" "push +refspec"
denies "$R5" Bash "git push client :release" "push :ref (delete)"
denies "$R5" Bash "git push --delete client release" "push --delete"
denies "$R5" Bash "git push --mirror client" "push --mirror"
denies "$R5" Bash "git push -f" "push -f with no remote"
denies "$R5" Bash "git push -f $WORK/m5-client.git release" "push -f by URL"
denies "$R5" Bash "echo '[guard]' > .git/clean-guard" "redirect into the decision file"
denies "$R5" Bash "sed -i '' s/tracked/untracked/ .git/clean-guard" "sed -i on the decision file"
denies "$R5" Bash "rm .git/clean-guard" "rm the decision file"
denies "$R5" Bash "cp /tmp/x ~/.gitconfig" "cp over ~/.gitconfig"
denies "$R5" Bash "printf x | tee -a .git/config" "tee into .git/config"
denies "$R5" Monitor "git commit --no-verify -m x" "Monitor tool"
denies "$R5" Edit "$R5/.git/clean-guard" "Edit of the decision file"
denies "$R5" Write "$R5/.git/config" "Write of .git/config"
denies "$U" Bash "cd $R5 && git commit --no-verify -m x" "cd into a tracked repo from an untracked cwd"
denies "$U" Bash "git -C $R5 push --no-verify client release" "git -C a tracked repo"
denies "$U" Edit "$R5/.git/clean-guard" "Edit of a tracked decision file from an untracked cwd"
denies "$U" Write "$HOME/.gitconfig" "Write of ~/.gitconfig adding hook settings" "[hook \"clean-guard-pre-push\"] enabled = false"
allows "$R5" Bash "git push -n client release" "push -n (dry run)"
allows "$R5" Bash "git commit --amend --no-edit" "commit --amend --no-edit"
allows "$R5" Bash "git commit --signoff -m \"re-enable login\"" "commit --signoff -m re-enable"
allows "$R5" Bash "git commit -m x src/main-window.ts" "commit with a dashed file name"
allows "$R5" Bash "git log -n 5 && git commit -m x" "log -n then commit"
allows "$R5" Bash "git config user.name X" "git config user.name"
allows "$R5" Bash "git config --get-regexp '^hook\\.'" "reading hook config"
allows "$R5" Bash "clean-guard scan" "clean-guard scan"
allows "$R5" Bash "clean-guard status && clean-guard doctor --fix" "clean-guard status/doctor"
allows "$R5" Bash "clean-guard config add allow.pattern '@anthropic-ai/sdk'" "clean-guard config add allow.pattern"
allows "$R5" Bash "git push -f other feature" "force push to an unscoped remote"
allows "$R5" Bash "cat .git/clean-guard" "reading the decision file"
allows "$R5" Bash "ls .git/clean-guard 2>&1" "reading the decision file with 2>&1"
allows "$R5" Bash "cat .git/config > /tmp/cfg-copy" "copying git config elsewhere by redirect"
denies "$R5" Bash "echo x>>.git/config" "attached append into .git/config"
denies "$R5" Bash "cmd 2> .git/clean-guard" "stderr redirect into the decision file"
allows "$R5" Edit "$R5/src/app.js" "Edit of a normal file"
allows "$U" Bash "git commit --no-verify -m x" "untracked repo is not guarded"
allows "$WORK/plain" Bash "git push --force" "non-git cwd"
out=$(jq -nc --arg c "$R5" '{cwd: $c, tool_name: "Bash", tool_input: {command: "git commit --no-verify"}}' |
	CLEAN_GUARD_JQ=/nonexistent/jq cg claude pre-tool 2> "$WORK/jq.err")
rc "missing jq exits 0" 0 $?
check "missing jq warns on stderr" "$(cat "$WORK/jq.err")" "jq not found"
check "missing jq prints nothing on stdout" "[$out]" "^\[\]$"
if [ -z "${CI:-}" ]; then
	start=$(date +%s)
	i=0
	while [ $i -lt 20 ]; do pt "$R5" Bash "git push -f client release" > /dev/null; i=$((i + 1)); done
	secs=$(($(date +%s) - start))
	if [ "$secs" -le 3 ]; then ok "pre-tool is fast (20 runs in ${secs}s)"; else no "pre-tool is fast" "20 runs took ${secs}s"; fi
fi
cd "$WORK" || exit 1

# ---------------------------------------------------------------- scan --tree and --summary

newrepo "$WORK/tree"
mkdir -p src/api docs
printf '// one\n// two\n// three\n// four\nold()\n' > src/api/gone.js
git add src/api/gone.js
git commit -q -m "Add old file"
git rm -q src/api/gone.js
mkdir -p src/api
printf 'const a = 1\nconst b = 2\n// one\n// two\n// three\n// four\nrun()\n' > src/api/now.js
printf 'This is deliberately simple.\n' > docs/guide.md
git add src/api/now.js docs/guide.md
git commit -q -m "Add current files"
out=$(cg scan --tree)
check "tree: current comment wall with its line" "$out" "WARN comment-wall [0-9a-f]{7} comment src/api/now.js:3: 4 comment lines"
lacks "tree: a deleted file is not reported" "$out" "gone\.js"
check "tree: doc wording with its line" "$out" "slop-words [0-9a-f]{7} doc docs/guide.md:1"
out=$(cg scan --tree HEAD~1)
check "tree at an older ref" "$out" "src/api/gone.js:1"
out=$(cg scan HEAD~2..HEAD)
check "history range still sees the deleted file" "$out" "gone\.js"
out=$(cg scan --tree --summary)
check "summary has per-area rows" "$out" "$(printf 'SUMMARY\tsrc/api\tcomment-wall\twarn\t1')"
check "summary counts docs" "$out" "$(printf 'SUMMARY\tdocs\tslop-words\twarn\t1')"
out=$(cg scan --tree --json)
check "json carries the line" "$out" '"file":"src/api/now.js","line":3,'
git config -f "$(df)" guard.decision untracked
git config -f "$(df)" rules.extra 'warn doc (^|[^[:alnum:]_])lab-node-[0-9]+'
printf 'Deploy to lab-node-7 first.\n' > docs/lab.md
git add docs/lab.md
git commit -q -m "Add lab doc"
out=$(cg scan --tree 2>&1)
check "rules.extra accepts the doc target" "$out" "extra [0-9a-f]{7} doc docs/lab.md:1"
out=$(cg skill-scan tree)
check "skill-scan tree" "$out" "^## clean-guard scan --tree --summary$"
cd "$WORK" || exit 1

# ---------------------------------------------------------------- fix and scan --worktree

fix_tests() {
	A=$AWKNAME
	newrepo "$WORK/fix-$A"
	mkdir -p pkg docs
	cat > pkg/a.go << 'EOF'
package pkg

// ---------------------------------------------------------------------------
// Fencing
// ---------------------------------------------------------------------------

// Deliberately skip the cache. The epoch is genuinely new.
// deliberately zero: the rest stay unset
// ==== Setup ====
// ### Why it lives here
func A() string {
	s := `
// ---- raw string ----
`
	return s // this is genuinely inline
}

var q = "a // b" + x // honestly odd

/*****************************************
 * ---- Block ----
 *****************************************/

// ------------->
// Generated with Claude Code
// It is (deliberately crossed) and kept deliberately
// ASSERTED IS DELIBERATELY KEPT HERE
EOF
	printf 'package pkg\nfunc TestA(t *testing.T) { want("ASSERTED IS DELIBERATELY KEPT HERE") }\n' > pkg/a_test.go
	cat > run.sh << 'EOF'
#!/bin/sh
# ## Setup
cat <<EOT
# ---- heredoc text ----
EOT
#####################
# It's worth noting that this runs twice.
EOF
	printf '#!/usr/bin/env bash\n# ---- section ----\necho hi\n' > tool
	# shellcheck disable=SC2016 # Markdown fences, not command substitution
	printf 'This is deliberately simple, **deliberately** so.\n\n```\ndeliberately in code\n```\n' > docs/guide.md
	printf '// ---- crlf ----\r\nint x;\r\n' > crlf.c
	printf 'x = 1 # deliberately\n# ---- tail ----' > nonl.py
	echo notes > CLAUDE.md
	git add .
	git commit -q -m "Add files"
	out=$(cg fix --dry-run)
	rc "$A fix --dry-run exits 0" 0 $?
	check "$A fix --dry-run lists a file" "$out" "^  pkg/a.go: .*banner"
	check "$A fix --dry-run names the AI file" "$out" "would untrack AI and notes files.*CLAUDE.md"
	check "$A fix --dry-run changes nothing" "[$(git status --short)]" "^\[\]$"
	out=$(cg fix)
	check "$A fix reports what changed" "$out" "clean-guard fix: changed [0-9]+ file\(s\): .*banner"
	check "$A fix reports the protected line" "$out" "pkg/a.go:27 \(a test has \"ASSERTED IS DELIBERATELY KEPT HERE\"\)"
	check "$A fix ends with what's left" "$out" "^## Left for you: clean-guard scan --worktree --summary$"
	a=$(cat pkg/a.go)
	lacks "$A fix removes pure dividers" "$a" "^// -+$"
	check "$A fix keeps the divided heading" "$a" "^// Fencing$"
	check "$A fix drops a capitalised filler word and capitalises" "$a" "^// Skip the cache. The epoch is new\.$"
	check "$A fix keeps lowercase when the phrase was lowercase" "$a" "^// zero: the rest stay unset$"
	check "$A fix cuts a divider to its text" "$a" "^// Setup$"
	check "$A fix strips a heading marker" "$a" "^// Why it lives here$"
	check "$A fix leaves raw strings" "$a" "^// ---- raw string ----$"
	check "$A fix cleans a trailing comment" "$a" "return s // this is inline$"
	check "$A fix leaves a trailing comment after unbalanced quotes" "$a" "honestly odd"
	check "$A fix reduces a block banner" "$a" "^/\*$"
	check "$A fix keeps block text" "$a" "^ \* Block$"
	check "$A fix closes the block" "$a" "^ \*/$"
	check "$A fix leaves an ASCII arrow" "$a" "^// ------------->$"
	lacks "$A fix removes a generated-with comment" "$a" "Generated with"
	check "$A fix tidies around brackets" "$a" "^// It is \(crossed\) and kept$"
	check "$A fix keeps a line a test asserts on" "$a" "ASSERTED IS DELIBERATELY KEPT HERE"
	r=$(cat run.sh)
	check "$A fix: shell heading" "$r" "^# Setup$"
	check "$A fix leaves heredoc text" "$r" "^# ---- heredoc text ----$"
	lacks "$A fix removes a hash divider" "$r" "^#####"
	check "$A fix drops worth noting" "$r" "^# This runs twice\.$"
	check "$A fix reads a shebang" "$(cat tool)" "^# section$"
	d=$(cat docs/guide.md)
	check "$A fix: doc filler" "$d" "^This is simple, \*\*deliberately\*\* so\.$"
	check "$A fix leaves code fences" "$d" "^deliberately in code$"
	check "$A fix keeps CRLF" "$(od -c crlf.c | head -n 1)" "c   r   l   f  \\\\r  \\\\n"
	check "$A fix keeps a missing final newline" "$(tail -c 6 nonl.py)" "# tail$"
	check "$A fix: trailing hash comment" "$(head -n 1 nonl.py)" "^x = 1 # deliberately$"
	check "$A fix untracks the AI file" "$(git status --short CLAUDE.md)" "^D  CLAUDE.md"
	check "$A fix keeps the AI file on disk" "$(cat CLAUDE.md)" "^notes$"
	check "$A fix excludes the AI file" "$(cat .git/info/exclude)" "^/CLAUDE.md$"
	git add -A
	git commit -q -m "Tidy"
	out=$(cg fix)
	check "$A fix twice changes nothing" "$out" "nothing to change in the files"
	printf '// Claude wrote this\n' >> pkg/a.go
	out=$(cg scan --worktree)
	rc "$A scan --worktree sees an unstaged edit" 1 $? "$out"
	check "$A scan --worktree names the file" "$out" "BLOCK ai-name [0-9a-f]{7} add pkg/a.go:"
	out=$(cg fix)
	rc "$A fix exits 1 while blocks are left" 1 $? "$out"
	git stash -q
	cd "$WORK" || exit 1

	newrepo "$WORK/fixh-$A"
	git commit -q --allow-empty -m "Fix login

Co-Authored-By: Claude <noreply@anthropic.com>"
	echo p > plan.md
	mkdir -p .claude
	echo s > .claude/settings.json
	echo code > app.js
	git add plan.md .claude app.js
	git commit -q -m "Add plan and app"
	git rm -q plan.md
	git commit -q -m "Drop plan"
	git commit -q --allow-empty -m "Empty on purpose

Generated with Claude Code"
	c=$(printf 'Tail\n\nCo-Authored-By: Claude <noreply@anthropic.com>' | git commit-tree "HEAD^{tree}" -p HEAD)
	git reset -q "$c"
	old=$(git rev-parse HEAD)
	out=$(cg fix --history --dry-run)
	rc "$A fix --history --dry-run exits 0" 0 $?
	check "$A fix --history --dry-run counts" "$out" "would rewrite main: 6 commit\(s\) read, 3 message\(s\) cleaned \(3 attribution line\(s\) cut\), 2 AI or notes path\(s\) dropped from 2 commit\(s\), 1 commit\(s\) left empty and dropped"
	check "$A fix --history --dry-run leaves the branch" "$(git rev-parse HEAD)" "^$old$"
	out=$(cg fix --history --to clean)
	check "$A fix --history --to reports" "$out" "rewrote main into clean"
	check "$A fix --history --to leaves the source" "$(git rev-parse main)" "^$old$"
	msgs=$(git log --format='%B' clean)
	lacks "$A fix --history cuts trailers" "$msgs" "Co-Authored-By|Generated with"
	check "$A fix --history keeps the subject" "$msgs" "^Fix login$"
	check "$A fix --history keeps a commit that was empty" "$msgs" "^Empty on purpose$"
	check "$A fix --history drops a commit left empty" "$(git log --format=%s clean | tr '\n' ' ')" "^Tail Empty on purpose Add plan and app Fix login Initial commit $"
	check "$A fix --history drops the paths" "[$(git log --format= --name-only clean | grep -E 'plan|claude')]" "^\[\]$"
	check "$A fix --history keeps other files" "$(git show clean:app.js)" "^code$"
	check "$A fix --history keeps dates" "$(git log -1 --format=%at clean)" "^$(git log -1 --format=%at main)$"
	out=$(cg fix --history --to clean 2>&1)
	rc "$A fix --history --to an existing branch exits 2" 2 $? "$out"
	check "$A fix --history --to an existing branch says so" "$out" "branch clean already exists"
	echo edit >> app.js
	out=$(cg fix --history)
	check "$A fix --history in place gives the same commits" "$(git rev-parse main)" "^$(git rev-parse clean)$"
	check "$A fix --history in place prints the undo" "$out" "to undo: git update-ref refs/heads/main $old"
	check "$A fix --history keeps unstaged edits" "$(git status --short app.js)" "^ M app.js"
	check "$A fix --history keeps a dropped file on disk" "$(cat .claude/settings.json)" "^s$"
	check "$A fix --history excludes it" "$(cat .git/info/exclude)" "^/.claude/settings.json$"
	check "$A fix --history leaves no temp ref" "[$(git for-each-ref refs/clean-guard)]" "^\[\]$"
	out=$(cg fix --history)
	check "$A fix --history twice finds nothing" "$out" "no attribution lines or AI files in the 5 commit\(s\) of main"
	out=$(cg fix --to x 2>&1)
	rc "$A fix --to without --history exits 2" 2 $? "$out"
	cd "$WORK" || exit 1
}

for a in ${TEST_AWKS:-awk mawk gawk}; do
	command -v "$a" > /dev/null 2>&1 || continue
	export CLEAN_GUARD_AWK="$a"
	AWKNAME=$a
	fix_tests
done
unset CLEAN_GUARD_AWK
allows "$R5" Bash "clean-guard fix --history --to clean" "clean-guard fix"
check "install-copy includes fix.awk" "$(ls "$DATA")" "fix.awk"

# ---------------------------------------------------------------- /clean-guard:scan skill

out=$(cd "$WORK/plain" && cg skill-scan)
rc "skill-scan outside git exits 0" 0 $? "$out"
check "skill-scan outside git says so" "$out" "Not inside a git repository"
newrepo "$WORK/sk"
git commit -q --allow-empty -m "Claude wrote this"
out=$(cg skill-scan)
rc "skill-scan exits 0 even with blocks" 0 $? "$out"
check "skill-scan shows the decision" "$out" "^decision: none"
check "skill-scan defaults to a history scan" "$out" "^## clean-guard scan --history --summary$"
check "skill-scan reports the scan exit code" "$out" "^exit code: 1 "
out=$(cg skill-scan recent)
check "skill-scan recent scans unpushed commits" "$out" "^## clean-guard scan $"
out=$(cg skill-scan staged)
check "skill-scan staged scans the index" "$out" "^## clean-guard scan --staged$"
out=$(cg skill-scan 'HEAD~1..HEAD')
check "skill-scan passes a range through" "$out" "BLOCK ai-name"
printf '// ---- x ----\n' > a.js
git add a.js
git commit -q -m "Add a.js"
out=$(cg skill-fix)
rc "skill-fix exits 0" 0 $? "$out"
check "skill-fix previews the files" "$out" "^## clean-guard fix --dry-run$"
check "skill-fix shows what would change" "$out" "would change 1 file"
check "skill-fix changes nothing" "$(cat a.js)" "^// ---- x ----$"
out=$(cg skill-fix history --to clean)
check "skill-fix history previews a rewrite" "$out" "^## clean-guard fix --history --to clean --dry-run$"
lacks "skill-fix history creates no branch" "$(git branch)" "clean"
out=$(cd "$WORK/plain" && cg skill-fix)
check "skill-fix outside git says so" "$out" "Not inside a git repository"
cd "$WORK" || exit 1

# ---------------------------------------------------------------- summary

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
