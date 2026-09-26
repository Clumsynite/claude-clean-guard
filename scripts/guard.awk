# guard.awk: read a shell command for clean-guard's PreToolUse check.
# mode=dirs prints each directory the command targets (cd, pushd, -C, --git-dir).
# mode=check prints one deny reason, or nothing. Setup files come first, each preceded by
# kind=<name>: remotes (scoped remote names), urls (their URLs), urlglobs (scope.url), protect (paths).
# Vars for check: noforce (1 if rules.noForcePush is on), scopeall (1 if no remote scope is set).

function glob2re(g,   r, i, c) {
	r = "^"
	for (i = 1; i <= length(g); i++) {
		c = substr(g, i, 1)
		if (c == "*") r = r ".*"
		else if (c == "?") r = r "."
		else if (index("\\.+()^$|{}", c)) r = r "\\" c
		else r = r c
	}
	return r "$"
}

function unq(t,   c) {
	sub(/^[({]+/, "", t)
	c = substr(t, 1, 1)
	if (c == "'" || c == "\"") t = substr(t, 2)
	c = substr(t, length(t), 1)
	if (c == "'" || c == "\"") t = substr(t, 1, length(t) - 1)
	sub(/[)}]+$/, "", t)
	return t
}

function deny(r) { if (reason == "") reason = r }

# t is a prefix of word at least min characters long (git accepts unique option prefixes).
function pre(t, word, min) { return length(t) >= min && index(word, t) == 1 }
function isnv(t) { return pre(t, "--no-verify", 6) }

function badcfg(v) { return v ~ /^(hook\.|core\.hookspath|include\.|includeif\.)/ }

function protected(p) {
	sub(/^[0-9]*>+/, "", p)
	sub(/^of=/, "", p)
	if (p == "") return 0
	if (p in prot) return 1
	if (p ~ /(^|\/)\.git\/(config|config\.worktree|clean-guard)$/) return 1
	if (p ~ /(^|\/)\.git\/worktrees\/[^\/]+\/config\.worktree$/) return 1
	if (p ~ /(^|\/)\.gitconfig$/ || p ~ /(^|\/)\.config\/git\/config$/) return 1
	return 0
}

function scoped(r,   i) {
	if (scopeall || (r in rem) || (r in url)) return 1
	for (i = 1; i <= nug; i++) if (r ~ ug[i]) return 1
	return 0
}

function dirs(   i) {
	for (i = 1; i < nt; i++) {
		if (tk[i] == "cd" || tk[i] == "pushd" || tk[i] == "-C" || tk[i] == "--git-dir") print tk[i + 1]
	}
	for (i = 1; i <= nt; i++) if (tk[i] ~ /^--git-dir=/) print substr(tk[i], 11)
}

# Index of the command word: skips VAR=value prefixes and sh/bash/exec/command/env wrappers.
function cmdword(   i) {
	for (i = 1; i <= nt; i++) {
		if (tk[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
		if (lc[i] ~ /^(sh|bash|dash|zsh|exec|command|env|sudo|nohup|time)$/) continue
		return i
	}
	return 0
}

# A redirect writes only to its own target; 2>&1 and redirects elsewhere are fine.
function writecheck(   i, t, tgt, hasw, hasp, sedlike) {
	hasw = 0; hasp = 0; sedlike = 0
	for (i = 1; i <= nt; i++) {
		t = tk[i]
		if (index(t, ">")) {
			tgt = t
			sub(/^.*>/, "", tgt)
			if (tgt == "" && i < nt) tgt = tk[i + 1]
			if (substr(tgt, 1, 1) != "&" && protected(tgt)) {
				deny("writing to the clean-guard decision file or a git config file is blocked")
				return
			}
			continue
		}
		if (lc[i] ~ /(^|\/)(mv|rm|cp|tee|truncate|ln|dd|install|unlink)$/) hasw = 1
		if (lc[i] ~ /(^|\/)(sed|perl)$/) sedlike = 1
		else if (sedlike && lc[i] ~ /^-[a-z]*i/) hasw = 1
		if (protected(t)) hasp = 1
	}
	if (hasw && hasp) deny("writing to the clean-guard decision file or a git config file is blocked")
}

function cgcheck(i,   s) {
	s = lc[i + 1]
	if (s == "" || s ~ /^(scan|fix|status|doctor|help|version|-h|--help)$/) return
	if (s == "config" && lc[i + 2] == "get") return
	if (s == "config" && lc[i + 2] == "add" && lc[i + 3] ~ /^allow\.(pattern|path)$/) return
	deny("only the user may run clean-guard " s (s == "config" ? " " lc[i + 2] " " lc[i + 3] : ""))
}

function commitcheck(i,   j, t, skip) {
	skip = 0
	for (j = i + 1; j <= nt; j++) {
		t = tk[j]
		if (skip) { skip = 0; continue }
		if (t == "--") break
		if (t ~ /^--(message|file|template|author|date|reuse-message|reedit-message|fixup|squash|cleanup|trailer|pathspec-from-file)$/) { skip = 1; continue }
		if (isnv(lc[j])) { deny("git commit " t " skips clean-guard's hooks"); return }
		if (t ~ /^-[a-zA-Z]+$/) {
			if (index(t, "n")) { deny("git commit " t " (-n is --no-verify) skips clean-guard's hooks"); return }
			if (t ~ /[mFCct]$/) skip = 1
		}
	}
}

function pushcheck(i,   j, t, l, skip, dd, np, pos, frc) {
	skip = 0; dd = 0; np = 0; frc = ""
	for (j = i + 1; j <= nt; j++) {
		t = tk[j]; l = lc[j]
		if (skip) { skip = 0; continue }
		if (!dd && t == "--") { dd = 1; continue }
		if (!dd && substr(t, 1, 1) == "-") {
			if (isnv(l)) { deny("git push " t " skips clean-guard's pre-push hook"); return }
			if (l ~ /^(-o|--push-option|--repo|--receive-pack|--exec)$/) { skip = 1; continue }
			if (l ~ /^--repo=/) { pos[++np] = substr(t, 8); continue }
			if (l ~ /^--force-with-lease/ || l == "--force-if-includes" || pre(l, "--force", 4) || pre(l, "--mirror", 3) || pre(l, "--delete", 4) || pre(l, "--prune", 4)) frc = t
			else if (t ~ /^-[a-zA-Z]+$/ && (index(t, "f") || index(t, "d"))) frc = t
			continue
		}
		pos[++np] = t
	}
	if (!noforce) return
	for (j = 2; j <= np; j++) if (substr(pos[j], 1, 1) == "+" || substr(pos[j], 1, 1) == ":") frc = pos[j]
	if (frc == "") return
	if (np == 0 || scoped(pos[1]))
		deny("force pushes and ref deletes to a scoped remote are blocked (" frc ")")
}

function configcheck(i,   j, t, l, skip, fileval, write, np, key, sub_) {
	skip = 0; fileval = 0; write = 0; np = 0; key = ""; sub_ = 0
	for (j = i + 1; j <= nt; j++) {
		t = tk[j]; l = lc[j]
		if (skip) {
			skip = 0
			if (fileval && protected(t)) prot_f = 1
			fileval = 0
			continue
		}
		if (l == "-f" || l == "--file") { skip = 1; fileval = 1; continue }
		if (l ~ /^--file=/) { if (protected(substr(t, 8))) prot_f = 1; continue }
		if (l ~ /^(--blob|--type|--default|--comment|--value)$/) { skip = 1; continue }
		if (l == "-e" || l == "--edit") { deny("git config --edit is blocked in a tracked repo"); return }
		if (l ~ /^--(add|unset|unset-all|replace-all|rename-section|remove-section)$/) { write = 1; continue }
		if (substr(l, 1, 1) == "-") continue
		np++
		if (np == 1 && l == "edit") { deny("git config edit is blocked in a tracked repo"); return }
		if (np == 1 && l ~ /^(set|unset|rename-section|remove-section)$/) { write = 1; sub_ = 1; continue }
		if (np == 1 && l ~ /^(get|list|get-color|get-colorbool)$/) { sub_ = 1; continue }
		if (key == "") key = l
		else if (!sub_) write = 1
	}
	if (write && prot_f) { deny("git config -f on the clean-guard decision file or a git config file is blocked"); return }
	if (write && key ~ /^(hook\.|core\.hookspath|include\.|includeif\.|alias\.)/)
		deny("changing " key " could switch clean-guard's hooks off")
}

function gitcheck(g,   i, t, j) {
	i = g + 1
	while (i <= nt) {
		t = tk[i]
		if (t == "-c" || t == "--config-env") {
			if (badcfg(lc[i + 1])) { deny("git " t " " tk[i + 1] " can switch clean-guard's hooks off"); return }
			i += 2; continue
		}
		if (lc[i] ~ /^--config-env=/) {
			if (badcfg(substr(lc[i], 14))) { deny("git " t " can switch clean-guard's hooks off"); return }
			i++; continue
		}
		if (t == "-C" || t == "--git-dir" || t == "--work-tree" || t == "--namespace") { i += 2; continue }
		if (substr(t, 1, 1) == "-") { i++; continue }
		break
	}
	if (i > nt) return
	if (lc[i] == "commit") { commitcheck(i); return }
	if (lc[i] == "push") { pushcheck(i); return }
	if (lc[i] == "config") { configcheck(i); return }
	for (j = i + 1; j <= nt; j++) if (isnv(lc[j])) { deny("git " lc[i] " " tk[j] " skips hooks"); return }
}

function check(   i, c) {
	for (i = 1; i <= nt; i++) if (index(lc[i], "git_config_")) { deny("GIT_CONFIG_* variables can switch clean-guard's hooks off"); return }
	c = cmdword()
	if (c && (tk[c] == "clean-guard" || tk[c] ~ /\/clean-guard(\.sh)?$/ || tk[c] == "clean-guard.sh")) { cgcheck(c); return }
	writecheck()
	if (reason != "") return
	for (i = 1; i <= nt; i++) if (tk[i] == "git" || tk[i] ~ /\/git$/) { gitcheck(i); return }
}

function segment(s,   n, a, i) {
	sub(/^[ \t]+/, "", s)
	sub(/[ \t]+$/, "", s)
	if (s == "") return
	n = split(s, a, /[ \t]+/)
	nt = 0
	for (i = 1; i <= n; i++) {
		tk[++nt] = unq(a[i])
		lc[nt] = tolower(tk[nt])
	}
	prot_f = 0
	if (mode == "dirs") dirs()
	else check()
}

kind == "remotes" { if ($0 != "") rem[$0] = 1; next }
kind == "urls" { if ($0 != "") url[$0] = 1; next }
kind == "urlglobs" { if ($0 != "") ug[++nug] = glob2re($0); next }
kind == "protect" { if ($0 != "") prot[$0] = 1; next }

{
	s = $0
	gsub(/&&|\|\||;|\||&/, "\n", s)
	n = split(s, segs, "\n")
	for (k = 1; k <= n && reason == ""; k++) segment(segs[k])
}

END { if (reason != "") print reason }
