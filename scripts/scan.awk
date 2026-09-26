# scan.awk: match clean-guard rules against tagged git streams.
# Each input file is preceded by kind=<name>. Setup kinds: rules, allow, allowpath, allowemail, hex, extra.
# Stream kinds: msg (git log %x01%H%n%B), msgfile (a commit message file), path (--name-status),
# diff (-p -U0), ident (%x01%H then "name <email>" lines). A line starting with \001 names the commit.
# mode: scan (default), strip (print msgfile without attribution lines), hexcand (print hex words), extra.
# maxc/wallsev: longest allowed run of added comment lines and the severity of a longer one (0 = off).
# summary=1 adds per-area counts. Diff findings carry the line number in the new file.
# Run with LC_ALL=C so matching and cutting work on bytes the same way in BWK awk, mawk and gawk.

BEGIN {
	if (mode == "") mode = "scan"
	sha = "new"
}

FNR == 1 { sha = "new"; file = ""; inhdr = 0; cut = 0; blanks = 0 }

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

function cont(c) { return c >= "\200" && c < "\300" }

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# The first commit-like hex word in s that is in the hex set, as a position (0 if none).
function hexpos(s, want,   rest, off, w, b, a) {
	rest = s; off = 0
	while (match(rest, /[0-9a-f]+/)) {
		w = substr(rest, RSTART, RLENGTH)
		b = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
		a = substr(rest, RSTART + RLENGTH, 1)
		if (length(w) >= 7 && length(w) <= 40 && w ~ /[0-9]/ && w ~ /[a-f]/ && b !~ /[[:alnum:]_]/ && a !~ /[[:alnum:]_]/) {
			if (want == "cand") { if (!(w in candseen)) { candseen[w] = 1; print w } }
			else if (want == "ok" && (w in hexok)) return off + RSTART
			else if (want == "bad" && (w in hexbad) && length(w) <= 12) { HEXWORD = w; return off + RSTART }
		}
		off += RSTART + RLENGTH - 1
		rest = substr(rest, RSTART + RLENGTH)
	}
	return 0
}

function skippath(f,   i) {
	for (i = 1; i <= npath; i++) if (f ~ apath[i]) return 1
	return 0
}

function allowed(lc,   i) {
	for (i = 1; i <= nallow; i++) if (lc ~ allow[i]) return 1
	return 0
}

function iscomment(t, f,   s) {
	if (tolower(f) ~ /\.(md|markdown|rst|txt)$/) return 0
	s = t
	sub(/^[ \t]+/, "", s)
	if (cpp(s, f)) return 0
	if (s ~ /^(\/\/|#|\/\*|\*|--|<!--|;)/) return 1
	return index(t, " // ") > 0 || index(t, " # ") > 0
}

# A C preprocessor line, which starts with # but isn't a comment.
function cpp(s, f) { return s ~ /^#[ \t]*[a-z]/ && tolower(f) ~ /\.(c|h|cc|cpp|cxx|hh|hpp|m|mm)$/ }

# A whole-line comment that carries text (delimiter-only lines like /**, */ or a bare // don't count).
function wallline(t, f,   s) {
	if (tolower(f) ~ /\.(md|markdown|rst|txt)$/) return 0
	s = t
	sub(/^[ \t]+/, "", s)
	if (s !~ /^(\/\/|#|\/\*|\*|--|<!--|;)/ || s ~ /^#!/ || cpp(s, f)) return 0
	sub(/^(\/\/+!?|#+|\/\*+!?|\*+|--+|<!--|;+)/, "", s)
	sub(/(\*\/|-->)[ \t]*$/, "", s)
	return s ~ /[[:alnum:]]/
}

# Reports a run of consecutive added comment lines longer than maxc (rules.maxCommentLines).
function wallflush(   keep) {
	if (maxc > 0 && wallrun > maxc) {
		keep = curline
		curline = wallstart
		add(wallsev, "comment-wall", "comment", wallfile, wallrun " comment lines (max " maxc "): " trim(walltext), 1)
		curline = keep
	}
	wallrun = 0
}

function isdoc(f,   l) {
	l = tolower(f)
	return l ~ /\.(md|markdown|rst|txt|adoc)$/ && l !~ /(^|\/)(license|licence|copying|notice|ofl)[^\/]*$/
}

# Tracks shell heredocs (text a script writes out, not comments): sets inheredoc for the lines inside one.
function heredoc(t, f,   s) {
	if (tolower(f) !~ /\.(sh|bash)$/) { inheredoc = 0; return }
	if (inheredoc) {
		s = t
		if (hdstrip) sub(/^\t+/, "", s)
		if (s == hdterm) { inheredoc = 0; hdend = 1 }
		return
	}
	hdend = 0
	if (t ~ /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/ && t !~ /<<</ && !iscomment(t, f)) {
		s = t
		sub(/.*<</, "", s)
		hdstrip = (substr(s, 1, 1) == "-")
		sub(/^-?[ \t]*['"]?/, "", s)
		match(s, /^[A-Za-z_][A-Za-z0-9_]*/)
		hdterm = substr(s, 1, RLENGTH)
		hdnext = 1
	}
}

# Top one or two path components, for --summary.
function area(f,   n, a) {
	if (f == "") return "(commits)"
	n = split(f, a, "/")
	if (n >= 3) return a[1] "/" a[2]
	if (n == 2) return a[1]
	return "(root)"
}

function add(sev, id, tg, f, text, pos) {
	nfind++
	fsev[nfind] = sev; fid[nfind] = id; fsha[nfind] = sha; ftg[nfind] = tg
	ffile[nfind] = f; ftext[nfind] = text; fpos[nfind] = pos; fline[nfind] = curline
	if (sev == "block") nblock++
	else nwarn++
}

function check(tg, text, f,   lc, i, p, seen) {
	lc = tolower(text)
	if (allowed(lc)) return
	split("", seen)
	for (i = 1; i <= nrule; i++) {
		if (index(rtg[i], "," tg ",") == 0 || (rid[i] in seen)) continue
		if (rre[i] == "@hexref") {
			p = hexpos(lc, "ok")
			if (p) { seen[rid[i]] = 1; add(rsev[i], rid[i], tg, f, text, p) }
		} else if (match(lc, rre[i])) {
			seen[rid[i]] = 1
			add(rsev[i], rid[i], tg, f, text, RSTART)
		}
	}
}

# Lines the commit-msg hook removes when rules.stripTrailers is on.
function stripme(text,   lc, i) {
	lc = tolower(text)
	if (allowed(lc)) return 0
	for (i = 1; i <= nrule; i++)
		if ((rid[i] == "attr-trailer" || rid[i] == "gen-line") && index(rtg[i], ",msg,") && lc ~ rre[i]) return 1
	return 0
}

function fmt(i,   head, t, w, s, e, p, n) {
	head = toupper(fsev[i]) " " fid[i] " " substr(fsha[i], 1, 7) " " ftg[i]
	if (ffile[i] != "" && ftg[i] != "path") head = head " " ffile[i] (fline[i] > 0 ? ":" fline[i] : "")
	head = head ": "
	t = ftext[i]; p = fpos[i]
	match(t, /^[ \t]*/)
	t = substr(t, RLENGTH + 1); p -= RLENGTH
	if (p < 1) p = 1
	gsub(/\t/, " ", t)
	w = 100 - length(head) - 6
	if (w < 30) w = 30
	n = length(t)
	if (n <= w) return head t
	s = p - 20
	if (s < 1) s = 1
	if (s + w - 1 > n) s = n - w + 1
	while (s > 1 && cont(substr(t, s, 1))) s--
	e = s + w - 1
	if (e > n) e = n
	while (e < n && e > s && cont(substr(t, e + 1, 1))) e--
	return head (s > 1 ? "..." : "") substr(t, s, e - s + 1) (e < n ? "..." : "")
}

function jesc(s,   r, i, c) {
	r = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "\\") r = r "\\\\"
		else if (c == "\"") r = r "\\\""
		else if (c == "\t") r = r "\\t"
		else if (c < " ") r = r " "
		else r = r c
	}
	return r
}

function jline(i) {
	return "{\"severity\":\"" fsev[i] "\",\"rule\":\"" jesc(fid[i]) "\",\"commit\":\"" fsha[i] "\",\"target\":\"" ftg[i] "\",\"file\":\"" jesc(ffile[i]) "\",\"line\":" (fline[i] + 0) ",\"text\":\"" jesc(ftext[i]) "\"}"
}

# ---- setup kinds ----

kind == "rules" {
	if ($0 ~ /^#/ || $0 == "") next
	n = split($0, f, "\t")
	if (n < 5) next
	if (f[4] ~ /(^|,)strict(,|$)/ && !strict) next
	nrule++
	rid[nrule] = f[1]
	rsev[nrule] = (f[4] ~ /strictblock/ && strict) ? "block" : f[2]
	rtg[nrule] = "," f[3] ","
	rre[nrule] = f[5]
	next
}

kind == "extra" {
	if ($0 == "") next
	s = $0
	sev = s; sub(/ .*/, "", sev)
	s = substr(s, length(sev) + 2)
	tg = s; sub(/ .*/, "", tg)
	re = substr(s, length(tg) + 2)
	if ((sev != "block" && sev != "warn") || tg !~ /^(msg|add|comment|doc|path|ident)(,(msg|add|comment|doc|path|ident))*$/ || re == "") {
		print "clean-guard: bad rules.extra entry (want \"<block|warn> <targets> <ERE>\"): " $0 > "/dev/stderr"
		bad = 1
		next
	}
	print "extra\t" sev "\t" tg "\t-\t" tolower(re)
	next
}

kind == "allow" { if ($0 != "") allow[++nallow] = tolower($0); next }
kind == "allowpath" { if ($0 != "") apath[++npath] = glob2re($0); next }
kind == "allowemail" { if ($0 != "") aemail[++nemail] = glob2re(tolower($0)); next }
kind == "hex" {
	n = split($0, f, "\t")
	if (f[2] == "commit") hexok[f[1]] = 1
	else hexbad[f[1]] = 1
	next
}

# ---- modes that don't scan ----

mode == "hexcand" {
	if (substr($0, 1, 1) == "\001") next
	if (kind == "diff" && substr($0, 1, 1) != "+") next
	hexpos(tolower($0), "cand")
	next
}

mode == "strip" && kind == "msgfile" {
	line = $0
	if (!cut && line ~ /^# -+ >8 -+$/) cut = 1
	if (!cut && substr(line, 1, 1) != "#" && stripme(line)) { print line > rmfile; next }
	if (!cut && line ~ /^[ \t]*$/) { blanks++; next }
	while (blanks > 0) { print ""; blanks-- }
	print line
	next
}

# ---- stream kinds ----

kind == "msg" || kind == "msgfile" {
	if (substr($0, 1, 1) == "\001") { sha = substr($0, 2); ncommit++; next }
	if (kind == "msgfile") {
		if (cut) next
		if ($0 ~ /^# -+ >8 -+$/) { cut = 1; next }
		if (substr($0, 1, 1) == "#") next
	}
	if ($0 ~ /^[ \t]*$/) next
	check("msg", $0, "")
	if (history && hexpos(tolower($0), "bad") && !((sha, HEXWORD) in unres)) {
		unres[sha, HEXWORD] = 1
		nunres++
		if (nunres <= 5) unresl[nunres] = substr(sha, 1, 7) ": " HEXWORD
	}
	next
}

kind == "path" {
	if (substr($0, 1, 1) == "\001") { sha = substr($0, 2); next }
	if ($0 == "") next
	n = split($0, f, "\t")
	if (n < 2) next
	for (i = 2; i <= n; i++) if (!skippath(f[i])) check("path", f[i], f[i])
	next
}

kind == "diff" {
	c1 = substr($0, 1, 1)
	if (c1 == "\001") { wallflush(); sha = substr($0, 2); inhdr = 0; next }
	if (substr($0, 1, 5) == "diff ") { wallflush(); inhdr = 1; file = ""; inheredoc = 0; hdnext = 0; next }
	if (inhdr) {
		if (substr($0, 1, 6) == "+++ b/") file = substr($0, 7)
		else if (substr($0, 1, 4) == "+++ ") file = ""
		if (substr($0, 1, 2) != "@@") next
		inhdr = 0
	}
	if (c1 == "@") {
		wallflush()
		nextline = match($0, /\+[0-9]+/) ? substr($0, RSTART + 1, RLENGTH - 1) + 0 : 0
		next
	}
	if (c1 != "+" || file == "" || skippath(file)) next
	curline = nextline++
	text = substr($0, 2)
	if (hdnext) { inheredoc = 1; hdnext = 0 }
	heredoc(text, file)
	if (inheredoc || hdend) {
		hdend = 0
		wallflush()
		check("add", text, file)
		curline = 0
		next
	}
	if (wallline(text, file)) {
		if (wallrun == 0) { wallfile = file; walltext = text; wallstart = curline }
		wallrun++
	} else wallflush()
	check("add", text, file)
	if (iscomment(text, file)) check("comment", text, file)
	else if (isdoc(file)) check("doc", text, file)
	curline = 0
	next
}

kind == "ident" {
	if (substr($0, 1, 1) == "\001") { sha = substr($0, 2); next }
	if ($0 == "" || ($0 in identseen)) next
	identseen[$0] = 1
	check("ident", $0, "")
	if (nemail > 0 && match($0, /<[^>]*>/)) {
		em = tolower(substr($0, RSTART + 1, RLENGTH - 2))
		ok = 0
		for (i = 1; i <= nemail; i++) if (em ~ aemail[i]) ok = 1
		if (!ok) add("block", "allow-email", "ident", "", $0, 1)
	}
	next
}

END {
	if (mode == "extra") { if (bad) exit 2; exit 0 }
	if (mode != "scan") exit 0
	wallflush()
	for (i = 1; i <= nfind; i++) {
		cnt[fid[i]]++
		if (!all && !json && cnt[fid[i]] > 5) { more[fid[i]]++; continue }
		print (json ? jline(i) : fmt(i))
	}
	if (json) { if (nblock > 0) exit 1; exit 0 }
	for (id in more) printf "  (+%d more %s)\n", more[id], id
	if (summary && nfind > 0) {
		fflush()
		for (i = 1; i <= nfind; i++) sc[area(ffile[i]) "\t" fid[i] "\t" fsev[i]]++
		for (k in sc) print "SUMMARY\t" k "\t" sc[k] | "sort"
		close("sort")
	}
	where = ncommit > 0 ? " in " ncommit " commit(s)" : ""
	if (nfind > 0) printf "clean-guard: %d blocking, %d warning(s)%s\n", nblock, nwarn, where
	else if (!quiet) printf "clean-guard: clean%s\n", (ncommit > 0 ? " (" ncommit " commit(s) scanned)" : "")
	if (nblock > 0) print "fix: clean-guard fix (files) or clean-guard fix --history --to NEW (commits) does the mechanical part; reword the rest, or for a false positive add an allow entry (clean-guard config add allow.pattern '<ERE>')"
	if (history && nunres > 0) {
		printf "INFO unresolved short hashes in messages: %d\n", nunres
		for (i = 1; i <= nunres && i <= 5; i++) print "INFO   " unresl[i]
	}
	if (nblock > 0) exit 1
	exit 0
}
