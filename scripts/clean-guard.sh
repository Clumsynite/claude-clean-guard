#!/bin/sh
# clean-guard: keep AI-tool traces out of the branches you ship.
# POSIX sh; needs git (2.54+ for the hooks) and awk. jq is needed only by the Claude hook entry points.
# Run `clean-guard help` for usage.
# shellcheck disable=SC2016 # awk and jq programs: their $vars aren't the shell's

set -u

NL='
'
ZERO=0000000000000000000000000000000000000000
AWK=${CLEAN_GUARD_AWK:-awk}
JQ=${CLEAN_GUARD_JQ:-jq}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/clean-guard
BIN=$HOME/.local/bin/clean-guard
T=

err() { printf 'clean-guard: %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 2
}

cleanup() { if [ -n "$T" ]; then rm -rf "$T"; fi; }
mktmp() {
	[ -n "$T" ] && return 0
	T=$(mktemp -d "${TMPDIR:-/tmp}/clean-guard.XXXXXX") || die "mktemp failed"
	trap cleanup EXIT
	trap 'cleanup; exit 2' HUP INT TERM
}

self_dir() {
	p=$0
	while [ -L "$p" ]; do
		l=$(readlink "$p") || break
		case $l in
		/*) p=$l ;;
		*) p=$(dirname "$p")/$l ;;
		esac
	done
	(cd "$(dirname "$p")" && pwd -P)
}

CG_HOME=${CLEAN_GUARD_HOME:-$(self_dir)}
SCAN_AWK=$CG_HOME/scan.awk
GUARD_AWK=$CG_HOME/guard.awk
if [ -f "$CG_HOME/rules/default.tsv" ]; then
	RULES=$CG_HOME/rules/default.tsv
else
	RULES=$CG_HOME/../rules/default.tsv
fi

plugin_version() { sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1; }

# glob_match VALUE FILE: VALUE matches one of the shell globs in FILE (one per line).
glob_match() {
	[ -f "$2" ] || return 1
	while IFS= read -r g; do
		[ -n "$g" ] || continue
		# shellcheck disable=SC2254
		case $1 in $g) return 0 ;; esac
	done < "$2"
	return 1
}

# ---------------------------------------------------------------- repo and decision file

# Sets CD (absolute common git dir) and DF (the decision file). Returns 1 outside a repo.
repo_init() {
	c=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
	CD=$(cd "$c" && pwd -P) || return 1
	DF=$CD/clean-guard
}
need_repo() { repo_init || die "not inside a git repository"; }

dget() { git config -f "$DF" --get "$1" 2>/dev/null; }
dall() { git config -f "$DF" --get-all "$1" 2>/dev/null; }
dbool() {
	v=$(git config -f "$DF" --type=bool --get "$1" 2>/dev/null) || v=$2
	[ "$v" = true ]
}

# Sets DEC to none, tracked or untracked. Exits 2 on a malformed decision file.
load_decision() {
	DEC=none
	[ -f "$DF" ] || return 0
	[ -r "$DF" ] || die "cannot read $DF"
	n=$(dall guard.decision | wc -l | tr -d ' ')
	[ "$n" -le 1 ] || die "guard.decision has $n values in $DF; ask the user to fix it"
	v=$(dget guard.decision)
	case $v in
	tracked | untracked) DEC=$v ;;
	'') DEC=none ;;
	*) die "unknown guard.decision '$v' in $DF" ;;
	esac
}

# ---------------------------------------------------------------- scanning

# Writes the rule and allow files for this repo into $T and sets STRICT and EXCL.
prep_rules() {
	mktmp
	cp "$RULES" "$T/rules.tsv" || die "missing rules file $RULES"
	: > "$T/allow.txt"
	: > "$T/allowpath.txt"
	: > "$T/allowemail.txt"
	: > "$T/hex.txt"
	STRICT=0
	EXCL=
	MAXC=3
	WALLSEV=warn
	[ -f "$DF" ] || return 0
	if dbool rules.strict false; then STRICT=1 MAXC=1 WALLSEV=block; fi
	v=$(dget rules.maxCommentLines)
	case $v in '') ;; *[!0-9]*) die "rules.maxCommentLines must be a number (0 turns the check off)" ;; *) MAXC=$v ;; esac
	dall rules.extra > "$T/extra.txt"
	LC_ALL=C "$AWK" -v mode=extra -f "$SCAN_AWK" kind=extra "$T/extra.txt" >> "$T/rules.tsv" || die "fix rules.extra in $DF"
	dall allow.pattern > "$T/allow.txt"
	dall allow.path > "$T/allowpath.txt"
	dall rules.allowEmail > "$T/allowemail.txt"
	EXCL=$(dall scan.excludePath | sed 's/^/:(exclude,top)/')
}

# gitout FILE ARGS...: run git ARGS with stdout to FILE; a git failure exits 2 (which blocks a hook).
gitout() {
	f=$1
	shift
	if ! git --no-replace-objects -c core.quotePath=false "$@" > "$f" 2> "$T/git.err" < /dev/null; then
		err "git failed: git $*"
		sed 's/^/  /' "$T/git.err" >&2
		exit 2
	fi
}

# streams_range ARGS...: the four streams for a git log range. PFILTER is the --name-status filter.
streams_range() {
	gitout "$T/msg" log --no-color --format='%x01%H%n%B' "$@"
	gitout "$T/ident" log --no-color --format='%x01%H%n%an <%ae>%n%cn <%ce>' "$@"
	set -f
	IFS=$NL
	# shellcheck disable=SC2086
	gitout "$T/path" log --no-color --format='%x01%H' --name-status $PFILTER "$@" -- ':/' $EXCL
	# shellcheck disable=SC2086
	gitout "$T/diff" log --no-color --format='%x01%H' -p -U0 --no-ext-diff --no-textconv \
		--diff-merges=remerge --full-history "$@" -- ':/' $EXCL
	unset IFS
	set +f
}

streams_staged() {
	: > "$T/msg"
	: > "$T/ident"
	set -f
	IFS=$NL
	# shellcheck disable=SC2086
	gitout "$T/path" diff --cached --no-color --name-status --diff-filter=ACMR -- ':/' $EXCL
	# shellcheck disable=SC2086
	gitout "$T/diff" diff --cached --no-color -U0 --no-ext-diff --no-textconv -- ':/' $EXCL
	unset IFS
	set +f
}

streams_empty() { : > "$T/msg"; : > "$T/ident"; : > "$T/path"; : > "$T/diff"; }

# streams_tree REF: every file at REF as added lines (a diff from the empty tree), so rules apply to the
# code as it stands rather than to history.
streams_tree() {
	c=$(git rev-parse -q --verify "${1:-HEAD}^{commit}") || die "unknown ref ${1:-HEAD}"
	empty=$(git hash-object -t tree /dev/null) || die "git hash-object failed"
	: > "$T/msg"
	: > "$T/ident"
	set -f
	IFS=$NL
	# shellcheck disable=SC2086
	gitout "$T/tpath" diff --no-color --name-status "$empty" "$c" -- ':/' $EXCL
	# shellcheck disable=SC2086
	gitout "$T/tdiff" diff --no-color -U0 --no-ext-diff --no-textconv "$empty" "$c" -- ':/' $EXCL
	unset IFS
	set +f
	{ printf '\001%s\n' "$c"; cat "$T/tpath"; } > "$T/path"
	{ printf '\001%s\n' "$c"; cat "$T/tdiff"; } > "$T/diff"
}

# Resolves hex words in the streams to commits, in one git call, for @hexref and --history.
prep_hex() {
	LC_ALL=C "$AWK" -v mode=hexcand -f "$SCAN_AWK" kind=msg "$T/msg" kind=diff "$T/diff" > "$T/cand"
	[ -s "$T/cand" ] || return 0
	sed 's/$/^{commit}/' "$T/cand" > "$T/candq"
	git cat-file --batch-check='%(objecttype)' < "$T/candq" > "$T/candr" 2>/dev/null || die "git cat-file failed"
	paste "$T/cand" "$T/candr" > "$T/hex.txt"
}

# Runs the matcher; returns 0 (clean or warnings), 1 (blocks) or exits 2.
run_matcher() {
	LC_ALL=C "$AWK" -v mode=scan -v strict="$STRICT" -v all="${ALL:-0}" -v json="${JSON:-0}" \
		-v quiet="${QUIET:-0}" -v history="${HIST:-0}" -v summary="${SUMMARY:-0}" -v maxc="$MAXC" -v wallsev="$WALLSEV" -f "$SCAN_AWK" \
		kind=rules "$T/rules.tsv" kind=allow "$T/allow.txt" kind=allowpath "$T/allowpath.txt" \
		kind=allowemail "$T/allowemail.txt" kind=hex "$T/hex.txt" \
		kind="${MSGKIND:-msg}" "$T/msg" kind=path "$T/path" kind=diff "$T/diff" kind=ident "$T/ident"
	rc=$?
	[ "$rc" -le 1 ] || die "matcher failed (awk exit $rc)"
	return "$rc"
}

# scan_range ARGS...: scan a git log range with the repo's rules (prep_rules first).
scan_range() {
	PFILTER=--diff-filter=ACMR
	streams_range "$@"
	if [ "$STRICT" = 1 ]; then prep_hex; fi
	run_matcher
}

history_info() {
	git rev-parse -q --verify HEAD > /dev/null || return 0
	if [ -s "$T/unreach" ]; then
		printf 'INFO unreachable commits: %s (their messages were scanned above; remove with git reflog expire --expire=now --all && git gc --prune=now)\n' \
			"$(wc -l < "$T/unreach" | tr -d ' ')"
	fi
	git for-each-ref --format='%(refname)' refs/replace refs/stash > "$T/oddrefs" 2>/dev/null
	while IFS= read -r r; do printf 'INFO ref: %s\n' "$r"; done < "$T/oddrefs"
	if [ -d "$CD/logs" ]; then
		printf 'INFO reflog: present for %s ref(s)\n' "$(find "$CD/logs" -type f | wc -l | tr -d ' ')"
	fi
	gitout "$T/ids" log --all --format='%an <%ae>%n%cn <%ce>'
	sort "$T/ids" | uniq -c | sort -rn | sed 's/^ *\([0-9]*\) /INFO identity: \1x /'
	gitout "$T/dates" log --all --format='%H %ct %P'
	"$AWK" 'NR == FNR { ct[$1] = $2; next }
		{ for (i = 3; i <= NF; i++) if (($i in ct) && $2 < ct[$i]) { n++; if (n <= 5) l[n] = substr($1, 1, 7) } }
		END { if (n) { printf "INFO dated before a parent: %d commit(s)", n; for (i = 1; i <= n && i <= 5; i++) printf " %s", l[i]; print "" } }' \
		"$T/dates" "$T/dates"
	gitout "$T/tz" log --all --format='%ai'
	"$AWK" '{ c[$3]++ } END { for (z in c) n++; if (n > 1) { printf "INFO timezones:"; for (z in c) printf " %s x%d", z, c[z]; print "" } }' "$T/tz"
	gitout "$T/ac" log --all --format='%h %at %ct'
	"$AWK" '{ d = $3 - $2; if (d < 0) d = -d; if (d > 86400) { n++; if (n <= 5) l[n] = $1 } }
		END { if (n) { printf "INFO author and committer dates over a day apart: %d commit(s)", n; for (i = 1; i <= n && i <= 5; i++) printf " %s", l[i]; print "" } }' "$T/ac"
}

cmd_scan() {
	ALL=0 JSON=0 QUIET=0 HIST=0 STAGED=0 TREE=0 SUMMARY=0
	RANGE=
	REFS=
	inrefs=0
	for a in "$@"; do
		case $a in
		--all) ALL=1 ;;
		--json) JSON=1 ;;
		--staged) STAGED=1 ;;
		--history) HIST=1 ;;
		--tree) TREE=1 ;;
		--summary) SUMMARY=1 ;;
		--quiet) QUIET=1 ;;
		--refs) inrefs=1 ;;
		-h | --help) usage; exit 0 ;;
		-*) die "unknown scan option $a" ;;
		*) if [ "$inrefs" = 1 ]; then REFS=$REFS$a$NL; else RANGE=$RANGE$a$NL; fi ;;
		esac
	done
	need_repo
	load_decision
	if top=$(git rev-parse --show-toplevel 2>/dev/null); then cd "$top" || exit 2; fi
	prep_rules
	if [ "$STAGED" = 1 ]; then
		streams_staged
	elif [ "$TREE" = 1 ]; then
		ref=${RANGE%%"$NL"*}
		streams_tree "${ref:-HEAD}"
	elif [ "$HIST" = 1 ]; then
		PFILTER=
		case $REFS in '' | "all$NL") set -- --all ;; *)
			set -f
			IFS=$NL
			# shellcheck disable=SC2086
			set -- $REFS
			unset IFS
			set +f
			;;
		esac
		if git rev-parse -q --verify HEAD > /dev/null || [ "$1" != --all ]; then
			streams_range "$@"
		else
			streams_empty
		fi
		git fsck --unreachable --no-reflogs > "$T/fsck" 2>/dev/null
		"$AWK" '$2 == "commit" { print $3 }' "$T/fsck" > "$T/unreach"
		if [ -s "$T/unreach" ]; then
			git --no-replace-objects log --no-color --no-walk --format='%x01%H%n%B' --stdin < "$T/unreach" >> "$T/msg" 2>/dev/null ||
				err "could not read unreachable commits"
		fi
	else
		if [ -n "$RANGE" ]; then
			set -f
			IFS=$NL
			# shellcheck disable=SC2086
			set -- $RANGE
			unset IFS
			set +f
		elif git rev-parse -q --verify '@{upstream}' > /dev/null 2>&1; then
			set -- '@{upstream}..HEAD'
		else
			set -- HEAD --not --remotes
		fi
		if git rev-parse -q --verify HEAD > /dev/null; then
			PFILTER=--diff-filter=ACMR
			streams_range "$@"
		else
			streams_empty
		fi
	fi
	if [ "$STRICT" = 1 ] || [ "$HIST" = 1 ]; then prep_hex; fi
	run_matcher
	rc=$?
	if [ "$HIST" = 1 ] && [ "$JSON" = 0 ]; then history_info; fi
	exit "$rc"
}

# ---------------------------------------------------------------- stable copy and hooks

cmd_install_copy() {
	force=0 quiet=0
	for a in "$@"; do
		case $a in
		--force) force=1 ;;
		--quiet) quiet=1 ;;
		*) die "unknown install-copy option $a" ;;
		esac
	done
	case $DATA in *\'*) die "the data dir path $DATA contains a quote; set XDG_DATA_HOME elsewhere" ;; esac
	here=$(cd "$DATA" 2>/dev/null && pwd -P)
	if [ "$here" != "$CG_HOME" ]; then
		pj=$CG_HOME/../.claude-plugin/plugin.json
		ver=dev
		if [ -f "$pj" ]; then ver=$(plugin_version "$pj"); fi
		need=$force
		if [ "$(cat "$DATA/VERSION" 2>/dev/null)" != "$ver" ]; then need=1; fi
		for f in clean-guard.sh scan.awk guard.awk rules/default.tsv; do [ -f "$DATA/$f" ] || need=1; done
		if [ "$need" = 1 ]; then
			mkdir -p "$DATA/rules" || die "cannot create $DATA"
			tmp=.tmp.$$
			if ! { cp "$CG_HOME/clean-guard.sh" "$DATA/clean-guard.sh$tmp" &&
				cp "$CG_HOME/scan.awk" "$DATA/scan.awk$tmp" &&
				cp "$CG_HOME/guard.awk" "$DATA/guard.awk$tmp" &&
				cp "$RULES" "$DATA/rules/default.tsv$tmp" &&
				printf '%s\n' "$ver" > "$DATA/VERSION$tmp"; }; then
				die "copy into $DATA failed"
			fi
			if ! sh -n "$DATA/clean-guard.sh$tmp" 2>/dev/null; then
				rm -f "$DATA/clean-guard.sh$tmp" "$DATA/scan.awk$tmp" "$DATA/guard.awk$tmp" "$DATA/rules/default.tsv$tmp" "$DATA/VERSION$tmp"
				die "the new clean-guard.sh fails sh -n; kept the old copy in $DATA"
			fi
			chmod +x "$DATA/clean-guard.sh$tmp"
			for f in clean-guard.sh scan.awk guard.awk rules/default.tsv VERSION; do
				mv -f "$DATA/$f$tmp" "$DATA/$f" || die "cannot update $DATA/$f"
			done
			[ "$quiet" = 1 ] || printf 'clean-guard: stable copy %s installed in %s\n' "$ver" "$DATA"
		fi
	fi
	mkdir -p "$(dirname "$BIN")" 2>/dev/null
	if [ -L "$BIN" ] || [ ! -e "$BIN" ]; then
		ln -sf "$DATA/clean-guard.sh" "$BIN" 2>/dev/null || err "could not link $BIN"
	else
		err "$BIN exists and is not a symlink; left it alone"
	fi
	return 0
}

hook_cmd() { printf "sh '%s/clean-guard.sh' hook %s" "$DATA" "$1"; }

hooks_remove() {
	for ev in commit-msg pre-push; do
		git config --local --remove-section "hook.clean-guard-$ev" 2>/dev/null
	done
	return 0
}

# Installs both config hooks and checks git runs them; undoes them and returns 1 if not.
hooks_install() {
	for ev in commit-msg pre-push; do
		if ! git config --local --get-all "hook.clean-guard-$ev.event" 2>/dev/null | grep -qx "$ev"; then
			git config --local --add "hook.clean-guard-$ev.event" "$ev" || return 1
		fi
		git config --local "hook.clean-guard-$ev.command" "$(hook_cmd "$ev")" || return 1
	done
	for ev in commit-msg pre-push; do
		if ! git hook list "$ev" 2>/dev/null | grep -qx "clean-guard-$ev"; then
			hooks_remove
			return 1
		fi
	done
	return 0
}

# Prints one line per problem with the hooks; returns the number of problems (0 = healthy).
hook_problems() {
	np=0
	for ev in commit-msg pre-push; do
		name=clean-guard-$ev
		if [ "$(git config --local --get "hook.$name.command" 2>/dev/null)" != "$(hook_cmd "$ev")" ]; then
			echo "hook $name: command missing or stale"
			np=$((np + 1))
		fi
		if ! git config --local --get-all "hook.$name.event" 2>/dev/null | grep -qx "$ev"; then
			echo "hook $name: event $ev not set"
			np=$((np + 1))
		fi
		if git config --type=bool --get-all "hook.$name.enabled" 2>/dev/null | grep -qx false; then
			echo "hook $name: disabled by hook.$name.enabled=false ($(git config --show-origin --get-all "hook.$name.enabled" | head -n 1 | cut -f 1))"
			np=$((np + 1))
		fi
		if ! git hook list "$ev" 2>/dev/null | grep -qx "$name"; then
			echo "hook $name: not listed by git hook list $ev"
			np=$((np + 1))
		fi
	done
	if [ ! -f "$DATA/clean-guard.sh" ]; then
		echo "stable copy missing: $DATA/clean-guard.sh"
		np=$((np + 1))
	fi
	return "$np"
}

registry_add() {
	mkdir -p "$DATA" 2>/dev/null || return 0
	grep -Fqx -- "$CD" "$DATA/repos" 2>/dev/null || printf '%s\n' "$CD" >> "$DATA/repos"
}
registry_drop() {
	[ -f "$DATA/repos" ] || return 0
	grep -Fvx -- "$1" "$DATA/repos" > "$DATA/repos.tmp.$$"
	mv -f "$DATA/repos.tmp.$$" "$DATA/repos"
}

# ---------------------------------------------------------------- init, config, status, doctor

cmd_init() {
	mode='' reason='' by=agent force=0 strict=0
	mktmp
	: > "$T/branches"
	: > "$T/remotes"
	: > "$T/urls"
	: > "$T/nosh"
	while [ $# -gt 0 ]; do
		case $1 in
		--track) mode=tracked ;;
		--untrack) mode=untracked ;;
		--strict) strict=1 ;;
		--force) force=1 ;;
		--branch | --remote | --url | --no-shared-history-with | --reason | --by)
			[ $# -ge 2 ] || die "$1 needs a value"
			case $1 in
			--branch) printf '%s\n' "$2" >> "$T/branches" ;;
			--remote) printf '%s\n' "$2" >> "$T/remotes" ;;
			--url) printf '%s\n' "$2" >> "$T/urls" ;;
			--no-shared-history-with) printf '%s\n' "$2" >> "$T/nosh" ;;
			--reason) reason=$2 ;;
			--by) by=$2 ;;
			esac
			shift
			;;
		*) die "unknown init option $1 (see clean-guard help)" ;;
		esac
		shift
	done
	[ -n "$mode" ] || die "init needs --track or --untrack"
	[ -n "$reason" ] || die "init needs --reason TEXT"
	case $by in agent | user) ;; *) die "--by must be agent or user" ;; esac
	need_repo
	load_decision
	if [ "$DEC" != none ] && [ "$force" = 0 ]; then
		die "this repo already has a decision ($DEC: $(dget guard.reason)); to change it, the user runs clean-guard init --force …"
	fi
	new=$DF.new.$$
	rm -f "$new"
	if ! { git config -f "$new" guard.decision "$mode" &&
		git config -f "$new" guard.reason "$reason" &&
		git config -f "$new" guard.decidedBy "$by" &&
		git config -f "$new" guard.decidedAt "$(date +%Y-%m-%d)"; }; then
		die "cannot write $new"
	fi
	if [ "$mode" = tracked ]; then
		while IFS= read -r v; do git config -f "$new" --add scope.branch "$v"; done < "$T/branches"
		while IFS= read -r v; do git config -f "$new" --add scope.remote "$v"; done < "$T/remotes"
		while IFS= read -r v; do git config -f "$new" --add scope.url "$v"; done < "$T/urls"
		while IFS= read -r v; do git config -f "$new" --add rules.noSharedHistoryWith "$v"; done < "$T/nosh"
		if [ "$strict" = 1 ]; then git config -f "$new" rules.strict true; fi
	fi
	mv -f "$new" "$DF" || die "cannot write $DF"
	if [ "$mode" = untracked ]; then
		hooks_remove
		registry_drop "$CD"
		echo "clean-guard: recorded untracked ($reason). No hooks installed."
		return 0
	fi
	cmd_install_copy --quiet
	if ! hooks_install; then
		rm -f "$DF"
		die "needs git 2.54+ (config-based hooks); this git is $(git --version | sed 's/^git version //'). Nothing was changed."
	fi
	registry_add
	DEC=tracked
	echo "clean-guard: recorded tracked ($reason); commit-msg and pre-push hooks installed."
	cmd_status_body
}

cmd_config() {
	[ $# -ge 2 ] || die "usage: clean-guard config get|set|add|unset KEY [VALUE]"
	verb=$1 key=$2
	shift 2
	need_repo
	[ -f "$DF" ] || die "no decision yet; run clean-guard init first"
	case $verb in
	get) git config -f "$DF" --get-all "$key" ;;
	set | add)
		[ $# -eq 1 ] || die "config $verb needs one VALUE"
		case $key in
		guard.decision) case $1 in tracked | untracked) ;; *) die "guard.decision must be tracked or untracked" ;; esac ;;
		allow.pattern)
			if printf '%s\n%s\n%s\n' "" x a | "$AWK" -v p="$1" 'BEGIN { p = tolower(p) } $0 ~ p { hit = 1 } END { exit !hit }'; then
				die "allow.pattern '$1' matches almost everything; use a narrower pattern"
			fi
			;;
		allow.path)
			for s in a a/b x/y/z.txt; do
				# shellcheck disable=SC2254
				case $s in $1) die "allow.path '$1' matches almost everything; use a narrower glob" ;; esac
			done
			;;
		esac
		if [ "$verb" = set ]; then git config -f "$DF" "$key" "$1"; else git config -f "$DF" --add "$key" "$1"; fi
		;;
	unset) git config -f "$DF" --unset-all "$key" ;;
	*) die "config verb must be get, set, add or unset" ;;
	esac
}

list_or() { v=$(dall "$1" | paste -s -d ' ' -); printf '%s' "${v:-$2}"; }

cmd_status_body() {
	printf 'decision: %s (by %s, %s): %s\n' "$DEC" "$(dget guard.decidedBy)" "$(dget guard.decidedAt)" "$(dget guard.reason)"
	[ "$DEC" = tracked ] || return 0
	printf 'scope: branches %s; remotes %s; urls %s\n' "$(list_or scope.branch all)" "$(list_or scope.remote all)" "$(list_or scope.url -)"
	s=false
	if dbool rules.strict false; then s=true; fi
	st=false
	if dbool rules.stripTrailers true; then st=true; fi
	nf=false
	if dbool rules.noForcePush true; then nf=true; fi
	printf 'rules: strict=%s stripTrailers=%s noForcePush=%s noSharedHistoryWith=%s allowEmail=%s\n' \
		"$s" "$st" "$nf" "$(list_or rules.noSharedHistoryWith -)" "$(list_or rules.allowEmail -)"
	dall rules.extra | sed 's/^/rules.extra: /'
	dall allow.pattern | sed 's/^/allow.pattern: /'
	dall allow.path | sed 's/^/allow.path: /'
	if probs=$(hook_problems); then
		printf 'hooks: ok (config-based; %s, version %s)\n' "$DATA" "$(cat "$DATA/VERSION" 2>/dev/null)"
		return 0
	fi
	printf '%s\n' "$probs" | sed 's/^/hooks: PROBLEM: /'
	echo "hooks: run clean-guard doctor --fix"
	return 1
}

cmd_status() {
	need_repo
	load_decision
	if [ "$DEC" = none ]; then
		echo "decision: none (run clean-guard init --track|--untrack --reason TEXT)"
		return 0
	fi
	cmd_status_body
}

cmd_doctor() {
	fix=0 quiet=0
	for a in "$@"; do
		case $a in
		--fix) fix=1 ;;
		--quiet) quiet=1 ;;
		*) die "unknown doctor option $a" ;;
		esac
	done
	need_repo
	load_decision
	if [ "$DEC" != tracked ]; then
		[ "$quiet" = 1 ] || echo "clean-guard: repo is not tracked ($DEC); nothing to check"
		return 0
	fi
	if probs=$(hook_problems); then
		[ "$quiet" = 1 ] || echo "clean-guard: hooks ok"
		return 0
	fi
	if [ "$fix" = 0 ]; then
		printf '%s\n' "$probs"
		echo "run clean-guard doctor --fix"
		return 1
	fi
	cmd_install_copy --quiet
	for ev in commit-msg pre-push; do
		git config --local --unset-all "hook.clean-guard-$ev.enabled" 2>/dev/null
	done
	hooks_install || die "could not reinstall the hooks (git 2.54+ needed)"
	registry_add
	if probs=$(hook_problems); then
		[ "$quiet" = 1 ] || echo "clean-guard: hooks repaired"
		return 0
	fi
	printf '%s\n' "$probs"
	echo "clean-guard: some problems need the user (for example a global hook.clean-guard-*.enabled=false)"
	return 1
}

cmd_uninstall_repo() {
	need_repo
	hooks_remove
	rm -f "$DF"
	registry_drop "$CD"
	echo "clean-guard: removed the hooks and the decision from $CD"
}

cmd_uninstall() {
	force=0
	[ "${1:-}" = --force ] && force=1
	left=
	if [ -f "$DATA/repos" ]; then
		while IFS= read -r c; do
			[ -d "$c" ] || continue
			if git --git-dir="$c" config --get-regexp '^hook\.clean-guard' > /dev/null 2>&1; then left=$left$c$NL; fi
		done < "$DATA/repos"
	fi
	if [ -n "$left" ] && [ "$force" = 0 ]; then
		printf 'clean-guard: these repos still have clean-guard hooks:\n%s' "$left" >&2
		die "run clean-guard uninstall-repo in each, or clean-guard uninstall --force"
	fi
	printf '%s' "$left" | while IFS= read -r c; do
		for ev in commit-msg pre-push; do git --git-dir="$c" config --remove-section "hook.clean-guard-$ev" 2>/dev/null; done
		rm -f "$c/clean-guard"
	done
	if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$DATA/clean-guard.sh" ]; then rm -f "$BIN"; fi
	rm -rf "$DATA"
	echo "clean-guard: uninstalled (removed $DATA)"
}

# ---------------------------------------------------------------- git hooks

# For git hooks: fail closed if the decision file is gone; true if the repo is tracked.
hook_decision() {
	if [ ! -f "$DF" ]; then
		err "hooks are installed but $DF is missing; run clean-guard doctor, or clean-guard uninstall-repo to remove the hooks"
		exit 1
	fi
	load_decision
	[ "$DEC" = tracked ]
}

hook_commit_msg() {
	f=${1:-}
	[ -f "$f" ] || die "commit-msg hook: no message file"
	need_repo
	hook_decision || exit 0
	mktmp
	dall scope.branch > "$T/sb"
	if [ -s "$T/sb" ]; then
		br=$(git symbolic-ref --short -q HEAD) || exit 0
		glob_match "$br" "$T/sb" || exit 0
	fi
	prep_rules
	if dbool rules.stripTrailers true; then
		: > "$T/removed"
		LC_ALL=C "$AWK" -v mode=strip -v strict="$STRICT" -v rmfile="$T/removed" -f "$SCAN_AWK" \
			kind=rules "$T/rules.tsv" kind=allow "$T/allow.txt" kind=msgfile "$f" > "$T/stripped" || die "strip failed"
		if [ -s "$T/removed" ]; then
			cp "$T/stripped" "$f" || die "cannot rewrite $f"
			sed 's/^/clean-guard: removed: /' "$T/removed" >&2
		fi
	fi
	cp "$f" "$T/msg"
	if top=$(git rev-parse --show-toplevel 2>/dev/null); then cd "$top" || exit 2; fi
	MSGKIND=msgfile
	set -f
	IFS=$NL
	# shellcheck disable=SC2086
	gitout "$T/path" diff --cached --no-color --name-status --diff-filter=ACMR -- ':/' $EXCL
	# shellcheck disable=SC2086
	gitout "$T/diff" diff --cached --no-color -U0 --no-ext-diff --no-textconv -- ':/' $EXCL
	unset IFS
	set +f
	{
		git var GIT_AUTHOR_IDENT
		git var GIT_COMMITTER_IDENT
	} 2>/dev/null | sed 's/ [^ ]* [^ ]*$//' > "$T/ident"
	if [ "$STRICT" = 1 ]; then prep_hex; fi
	QUIET=1
	run_matcher >&2
	exit $?
}

hook_pre_push() {
	remote=${1:-} url=${2:-}
	need_repo
	mktmp
	cat > "$T/refs"
	hook_decision || exit 0
	dall scope.branch > "$T/sb"
	dall scope.remote > "$T/sr"
	dall scope.url > "$T/su"
	: > "$T/surls"
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		git remote get-url --all "$r" 2>/dev/null
		git remote get-url --push --all "$r" 2>/dev/null
	done < "$T/sr" > "$T/surls"
	rin=0
	if [ ! -s "$T/sb" ] && [ ! -s "$T/sr" ] && [ ! -s "$T/su" ]; then
		rin=1
	elif grep -Fqx -- "$remote" "$T/sr" || grep -Fqx -- "$url" "$T/surls" || glob_match "$url" "$T/su"; then
		rin=1
	fi
	isremote=0
	if git remote | grep -Fqx -- "$remote"; then isremote=1; fi
	nfp=0
	if dbool rules.noForcePush true; then nfp=1; fi
	prep_rules
	dall rules.noSharedHistoryWith > "$T/nosh"
	: > "$T/out"
	blocked=0
	while read -r lref lsha rref rsha; do
		[ -n "${lref:-}" ] || continue
		inscope=$rin
		if [ "$inscope" = 0 ]; then
			for b in "${rref#refs/heads/}" "${lref#refs/heads/}"; do
				case $b in refs/*) continue ;; esac
				if glob_match "$b" "$T/sb"; then inscope=1; fi
			done
		fi
		[ "$inscope" = 1 ] || continue
		if [ "$lsha" = "$ZERO" ]; then
			if [ "$nfp" = 1 ]; then
				echo "BLOCK deleting $rref on $remote (rules.noForcePush)" >> "$T/out"
				blocked=1
			fi
			continue
		fi
		if [ "$rsha" = "$ZERO" ]; then
			if [ "$isremote" = 1 ]; then set -- "$lsha" --not "--remotes=$remote"; else set -- "$lsha" --not --remotes; fi
		elif ! git cat-file -e "$rsha^{commit}" 2>/dev/null; then
			if [ "$nfp" = 1 ]; then
				echo "BLOCK $rref: remote tip ${rsha%"${rsha#???????}"} unknown locally; fetch first (rules.noForcePush)" >> "$T/out"
				blocked=1
				continue
			fi
			echo "WARN $rref: remote tip unknown locally; scanning everything not on a remote" >> "$T/out"
			set -- "$lsha" --not --remotes
		else
			if [ "$nfp" = 1 ] && ! git merge-base --is-ancestor "$rsha" "$lsha" 2>/dev/null; then
				echo "BLOCK $rref: non-fast-forward push (rules.noForcePush)" >> "$T/out"
				blocked=1
			fi
			set -- "$rsha..$lsha"
		fi
		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			git rev-parse -q --verify "$ref^{commit}" > /dev/null 2>&1 || continue
			if git merge-base "$lsha" "$ref" > /dev/null 2>&1; then
				echo "BLOCK $rref shares history with $ref (rules.noSharedHistoryWith)" >> "$T/out"
				blocked=1
			fi
		done < "$T/nosh"
		QUIET=1
		scan_range "$@" >> "$T/out" < /dev/null
		rc=$?
		if [ "$rc" = 1 ]; then blocked=1; fi
	done < "$T/refs"
	if [ -s "$T/out" ]; then head -n 20 "$T/out" >&2; fi
	if [ "$blocked" = 1 ]; then
		err "push blocked; see above (clean-guard scan shows the full list)"
		exit 1
	fi
	exit 0
}

# ---------------------------------------------------------------- Claude hooks (always exit 0)

user_config() { printf '%s' "${CLEAN_GUARD_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/clean-guard/config}"; }

no_decision_context() {
	ucfg=$(user_config)
	mktmp
	git config -f "$ucfg" --get-all hint.cleanRemote > "$T/hclean" 2>/dev/null
	git config -f "$ucfg" --get-all hint.personalRemote > "$T/hpers" 2>/dev/null
	remotes='' sug=unclear why="no remote matched your hints"
	nrem=0 npers=0
	for r in $(git remote); do
		u=$(git remote get-url "$r" 2>/dev/null | sed 's#://[^/@]*@#://#')
		remotes="$remotes${remotes:+, }$r=$(printf '%.80s' "$u")"
		nrem=$((nrem + 1))
		if glob_match "$u" "$T/hclean"; then
			sug=track why="remote $r matches hint.cleanRemote"
		elif glob_match "$u" "$T/hpers"; then
			npers=$((npers + 1))
		fi
	done
	if [ "$sug" = unclear ] && [ "$nrem" -gt 0 ] && [ "$npers" = "$nrem" ]; then
		sug=untrack why="every remote matches hint.personalRemote"
	fi
	[ "$nrem" -gt 0 ] || why="no remotes"
	ai=$(git ls-files -- CLAUDE.md AGENTS.md GEMINI.md .claude .cursorrules .cursor .mcp.json .github/copilot-instructions.md 2>/dev/null |
		sed 's#/.*#/#' | sort -u | head -n 5 | paste -s -d ' ' -)
	loc=
	for f in CLAUDE.local.md CLAUDE.md AGENTS.md .claude; do
		if [ -e "$f" ] && git check-ignore -q "$f" 2>/dev/null; then loc="$loc${loc:+ }$f"; fi
	done
	printf '%s' "clean-guard: this repo has no decision yet on whether commits here must carry no trace of AI tools (client or employer code, or anything pushed to a shared or client remote). Signals: remotes ${remotes:-none}; tracked AI files: ${ai:-none}${ai:+ (a hint the repo accepts AI tooling)}; excluded local notes: ${loc:-none}; suggestion: $sug ($why). Before your first commit or push here, ask the user one question with your suggestion and the scope you'd use. After they answer, run \`clean-guard init --track [--branch G] [--remote R] [--strict] --reason \"...\" --by user\` or \`clean-guard init --untrack --reason \"...\" --by user\`. Never run init without their answer."
}

tracked_context() {
	s=
	if dbool rules.strict false; then s=" Strict mode: also no test files, and no dates, hashes, ticket numbers or IP addresses in messages or comments."; fi
	al=$(dall allow.pattern | paste -s -d ' ' -)
	mc=$(dget rules.maxCommentLines)
	if [ -z "$mc" ]; then if [ -n "$s" ]; then mc=1; else mc=3; fi; fi
	cl="at most $mc lines"
	[ "$mc" = 1 ] && cl="one line"
	printf '%s' "clean-guard: this repo is tracked ($(dget guard.reason)). Scope: branches $(list_or scope.branch all); remotes $(list_or scope.remote all). On these, commits must carry no trace of AI tools: no attribution trailers or \"generated with\" lines, no AI tool names in messages or added code, no AI, plan or handoff files.$s Code must read as if an engineer wrote it: comments are $cl and say why, not what; no narration of the change or this session (\"now handles\", \"this change\", \"as requested\", \"used to\") in code, comments or messages. Allow entries: ${al:-none}. Run \`clean-guard scan --staged\` before committing on these branches. Never bypass or loosen the hooks (--no-verify, hook config, the decision file). To change the decision or scope, ask the user to run it with !."
}

claude_session_start() {
	if ! command -v "$JQ" > /dev/null 2>&1; then
		err "jq not found; the Claude-side guard is off (git hooks still apply)"
		return 0
	fi
	in=$(cat)
	(cmd_install_copy --quiet) > /dev/null 2>&1
	cwd=$(printf '%s' "$in" | "$JQ" -r '.cwd // empty' 2>/dev/null)
	[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || return 0
	repo_init || return 0
	ucfg=$(user_config)
	mktmp
	git config -f "$ucfg" --get-all hint.ignorePath > "$T/ign" 2>/dev/null
	if glob_match "$cwd" "$T/ign" || glob_match "$(pwd -P)" "$T/ign"; then return 0; fi
	load_decision
	case $DEC in
	untracked) return 0 ;;
	tracked)
		(cmd_doctor --fix --quiet) > /dev/null 2>&1
		ctx=$(tracked_context)
		;;
	*) ctx=$(no_decision_context) ;;
	esac
	"$JQ" -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
}

deny() {
	"$JQ" -n --arg r "clean-guard: $1. Fix the findings instead, or if this really is intended, ask the user to run it themselves with !" \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

claude_pre_tool() {
	if ! command -v "$JQ" > /dev/null 2>&1; then
		err "jq not found; the Claude-side guard is off (git hooks still apply)"
		return 0
	fi
	mktmp
	cat > "$T/in"
	"$JQ" -r '(.tool_name // ""), (.cwd // ""), (.tool_input.file_path // .tool_input.notebook_path // ""),
		((.tool_input.content // .tool_input.new_string // .tool_input.new_source // ([.tool_input.edits[]?.new_string] | join(" "))) | tostring | test("hook|clean-guard"; "i"))' \
		"$T/in" > "$T/meta" 2>/dev/null || return 0
	{
		IFS= read -r tool
		IFS= read -r cwd
		IFS= read -r fpath
		IFS= read -r hooky
	} < "$T/meta"
	: > "$T/cmd"
	case $tool in
	Bash | Monitor) "$JQ" -r '.tool_input.command // .tool_input.script // empty' "$T/in" > "$T/cmd" 2>/dev/null ;;
	Edit | Write | MultiEdit | NotebookEdit)
		case $fpath in
		*/.git/config | */.git/config.worktree | */.gitconfig | */.config/git/config)
			if [ "$hooky" = true ]; then
				deny "editing git config to add or change hook settings is blocked"
				return 0
			fi
			;;
		esac
		;;
	*) return 0 ;;
	esac
	if [ -s "$T/cmd" ] && ! grep -qiE 'git|clean-guard' "$T/cmd"; then return 0; fi
	if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || return 0; fi
	{
		pwd
		if [ -s "$T/cmd" ]; then LC_ALL=C "$AWK" -v mode=dirs -f "$GUARD_AWK" "$T/cmd"; fi
		if [ -n "$fpath" ]; then dirname "$fpath"; fi
	} > "$T/dirs"
	: > "$T/seen"
	: > "$T/remotes"
	: > "$T/urls"
	: > "$T/urlglobs"
	: > "$T/protect"
	tracked=0 noforce=0 scopeall=0
	while IFS= read -r d; do
		# shellcheck disable=SC2016,SC2088 # literal $HOME and ~/ prefixes, expanded by hand
		case $d in
		'~') d=$HOME ;;
		'~/'*) d=$HOME/${d#'~/'} ;;
		'$HOME' | '${HOME}') d=$HOME ;;
		'$HOME/'*) d=$HOME/${d#'$HOME/'} ;;
		'${HOME}/'*) d=$HOME/${d#'${HOME}/'} ;;
		/*) ;;
		*) d=$PWD/$d ;;
		esac
		[ -d "$d" ] || continue
		c=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) || continue
		case $c in /*) ;; *) c=$d/$c ;; esac
		c=$(cd "$c" 2>/dev/null && pwd -P) || continue
		grep -Fqx -- "$c" "$T/seen" && continue
		printf '%s\n' "$c" >> "$T/seen"
		df=$c/clean-guard
		[ -f "$df" ] || continue
		# One git call per repo: read the whole decision file.
		git config -f "$df" --list > "$T/dfl" 2>/dev/null || continue
		dec='' nfv=true sr='' su=''
		while IFS= read -r kv; do
			case $kv in
			guard.decision=*) dec=${kv#*=} ;;
			rules.noforcepush=*) nfv=${kv#*=} ;;
			scope.remote=*) sr="$sr${kv#*=}$NL" ;;
			scope.url=*) su="$su${kv#*=}$NL" ;;
			esac
		done < "$T/dfl"
		[ "$dec" = tracked ] || continue
		tracked=1
		printf '%s\n%s\n%s\n' "$df" "$c/config" "$c/config.worktree" >> "$T/protect"
		case $nfv in false | no | off | 0) ;; *) noforce=1 ;; esac
		if [ -z "$sr$su" ]; then scopeall=1; fi
		printf '%s' "$sr" >> "$T/remotes"
		printf '%s' "$su" >> "$T/urlglobs"
		if [ -n "$sr" ]; then
			git --git-dir="$c" config --get-regexp '^remote\..*\.(push)?url$' > "$T/rurls" 2>/dev/null
			while read -r k u; do
				r=${k#remote.}
				r=${r%.*}
				if printf '%s' "$sr" | grep -Fqx -- "$r"; then printf '%s\n' "$u" >> "$T/urls"; fi
			done < "$T/rurls"
		fi
	done < "$T/dirs"
	[ "$tracked" = 1 ] || return 0
	case $tool in
	Edit | Write | MultiEdit | NotebookEdit)
		if grep -Fqx -- "$fpath" "$T/protect"; then
			deny "editing the clean-guard decision file or git config is blocked in a tracked repo"
			return 0
		fi
		case $fpath in
		*/.git/config | */.git/config.worktree | */.git/clean-guard | */.gitconfig | */.config/git/config)
			deny "editing the clean-guard decision file or git config is blocked in a tracked repo"
			;;
		esac
		return 0
		;;
	esac
	r=$(LC_ALL=C "$AWK" -v mode=check -v noforce="$noforce" -v scopeall="$scopeall" -f "$GUARD_AWK" \
		kind=remotes "$T/remotes" kind=urls "$T/urls" kind=urlglobs "$T/urlglobs" kind=protect "$T/protect" \
		kind=cmd "$T/cmd" 2>/dev/null)
	if [ -n "$r" ]; then deny "$r"; fi
	return 0
}

# ---------------------------------------------------------------- /clean-guard:scan skill

# Report for the skill: decision, then findings. Always exits 0 so the output reaches the session.
cmd_skill_scan() {
	if ! repo_init; then
		echo "Not inside a git repository."
		return 0
	fi
	echo "## Decision"
	(cmd_status) 2>&1
	case ${1:-} in
	'' | history) set -- --history --summary ;;
	recent) set -- ;;
	staged) set -- --staged ;;
	tree)
		shift
		set -- --tree --summary "$@"
		;;
	esac
	echo
	echo "## clean-guard scan $*"
	(cmd_scan "$@") 2>&1
	rc=$?
	echo
	echo "exit code: $rc (0 clean or warnings only, 1 blocking findings, 2 error)"
	return 0
}

# ---------------------------------------------------------------- main

usage() {
	cat << 'EOF'
clean-guard: keep AI-tool traces out of the branches you ship

  clean-guard init --track [--branch GLOB]... [--remote NAME]... [--url GLOB]... [--strict]
                   [--no-shared-history-with REF]... --reason TEXT [--by agent|user] [--force]
  clean-guard init --untrack --reason TEXT [--by agent|user] [--force]
  clean-guard scan [RANGE] [--staged] [--all] [--json] [--summary]
  clean-guard scan --tree [REF] [--all] [--json] [--summary]       (files as they stand at REF)
  clean-guard scan --history [--refs all|REF...] [--all] [--json] [--summary]
  clean-guard status | doctor [--fix] [--quiet]
  clean-guard config get|set|add|unset KEY [VALUE]
  clean-guard install-copy [--force] | uninstall-repo | uninstall [--force] | version

Exit codes: 0 clean or warnings only, 1 blocking findings, 2 usage, config or git error.
EOF
}

cmd=${1:-help}
[ $# -gt 0 ] && shift
case $cmd in
scan) cmd_scan "$@" ;;
init) cmd_init "$@" ;;
config) cmd_config "$@" ;;
status) cmd_status ;;
doctor) cmd_doctor "$@" ;;
install-copy) cmd_install_copy "$@" ;;
uninstall-repo) cmd_uninstall_repo ;;
uninstall) cmd_uninstall "$@" ;;
skill-scan)
	cmd_skill_scan "$@"
	exit 0
	;;
hook)
	ev=${1:-}
	[ $# -gt 0 ] && shift
	case $ev in
	commit-msg) hook_commit_msg "$@" ;;
	pre-push) hook_pre_push "$@" ;;
	*) die "unknown hook event '$ev'" ;;
	esac
	;;
claude)
	sub=${1:-}
	case $sub in
	session-start) (claude_session_start) ;;
	pre-tool) (claude_pre_tool) ;;
	*) err "unknown claude subcommand '$sub'" ;;
	esac
	exit 0
	;;
version)
	if [ -f "$CG_HOME/VERSION" ]; then cat "$CG_HOME/VERSION"; else plugin_version "$CG_HOME/../.claude-plugin/plugin.json"; fi
	;;
help | -h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
