# fix.awk: the mechanical rewrites behind clean-guard fix. Load it before scan.awk
# (awk -f fix.awk -f scan.awk), which supplies the rule loading and the shared helpers.
# mode=aipaths: kind=paths lists paths; print the ones the ai-file and notes-file rules match.
# mode=fixtree: kind=list lists text files; outdir=DIR. Writes each changed file to DIR/<n> (no final newline)
#   and prints "F<TAB>n<TAB>path<TAB>banners<TAB>dividers<TAB>words<TAB>genlines", plus
#   "K<TAB>path:line<TAB>literal" for a change left out because a test file has that literal.
# mode=fixfe: kind=fe is a git fast-export --no-data stream; prints it with attribution lines cut from
#   messages, AI and notes paths dropped, and commits left empty by that dropped. target= names the ref
#   to write; stats= receives the counts.
# Run with LC_ALL=C: data lengths in the stream are bytes.

BEGIN {
	DROP = "\001drop"
	nph = split("please note that|note that|it's worth noting that|it is worth noting that|it's worth noting|it is worth noting|as mentioned above|as mentioned earlier|as mentioned before|for clarity|crucially|deliberately|genuinely|honestly", ph, "|")
	# note that: comments only (the doc rules don't flag it), and only where it opens a clause.
	phc[1] = phc[2] = 1
	phs[1] = phs[2] = phs[5] = phs[6] = 1
	TESTRE = "(^|/)(__tests__|test|tests|e2e|spec)/|(^|/)[^/]*[._](test|spec)\\.[^/]+$|(^|/)test_[^/]*\\.py$"
}

kind == "list" { if ($0 != "") flist[++nflist] = $0; next }
kind == "paths" { if (mode == "aipaths" && $0 != "" && aipath($0)) print; next }
kind == "fe" { feline($0); next }

function rulehit(id, tg, lc,   i) {
	for (i = 1; i <= nrule; i++)
		if (rid[i] == id && index(rtg[i], "," tg ",") && lc ~ rre[i]) return 1
	return 0
}

function aipath(p,   lc) {
	lc = tolower(p)
	if (skippath(p) || allowed(lc)) return 0
	return rulehit("ai-file", "path", lc) || rulehit("notes-file", "path", lc)
}

# ---- files as they stand ----

# Comment syntax by file name: "//" line comments, "/*" block comments, "#", "--", ";". "" = leave alone.
function syntax(f,   b, e) {
	b = tolower(f)
	sub(/.*\//, "", b)
	if (b ~ /^(makefile|gnumakefile|dockerfile|containerfile|gemfile|rakefile|vagrantfile|justfile|\.gitignore|\.dockerignore|\.gitattributes|\.editorconfig)$/ || b ~ /\.dockerfile$/) return "#"
	if (b !~ /\./) return ""
	e = b
	sub(/.*\./, "", e)
	if (e ~ /^(c|h|cc|cpp|cxx|hh|hpp|hxx|m|mm|go|js|jsx|mjs|cjs|ts|tsx|mts|cts|java|kt|kts|scala|swift|rs|cs|dart|groovy|gradle|proto|zig|sol|scss|less|jsonc)$/) return "//*"
	if (e == "css") return "/*"
	if (e == "php") return "//*#"
	if (e ~ /^(sh|bash|zsh|ksh|py|pyi|rb|pl|pm|r|yaml|yml|toml|conf|cfg|mk|cmake|tf|tfvars|hcl|nix|ps1|awk|sed|properties|service|ex|exs|jl|tcl|coffee)$/) return "#"
	if (e ~ /^(sql|lua|hs|elm)$/) return "--"
	if (e ~ /^(lisp|clj|cljs|cljc|el|scm|asm|s)$/) return ";"
	if (e == "ini") return ";#"
	return ""
}

# Multi-line string delimiters, so comment-like lines inside a string are left alone.
function rawkind(f,   l) {
	l = tolower(f)
	if (l ~ /\.(go|js|jsx|mjs|cjs|ts|tsx|mts|cts)$/) return "bt"
	if (l ~ /\.pyi?$/) return "py"
	return ""
}

# Flips inraw when a code line opens or closes a multi-line string.
function rawflip(t, rk,   c, n) {
	c = t
	if (rk == "bt") {
		gsub(/\\`/, "", c)
		n = gsub(/`/, "", c)
	} else if (rk == "py") n = gsub(/"""|'''/, "", c)
	else return
	if (n % 2) inraw = !inraw
}

# Syntax from a script's #! line, for files with no known extension. Sets SHEBANG to its interpreter kind.
function shebang(p,   l) {
	SHEBANG = ""
	if ((getline l < p) <= 0) { close(p); return "" }
	close(p)
	if (l !~ /^#!/) return ""
	if (l ~ /[\/ ](sh|bash|zsh|ksh|dash|ash)([ \t]|$)/) SHEBANG = "sh"
	else if (l ~ /[\/ ]python[0-9.]*([ \t]|$)/) SHEBANG = "py"
	else if (l ~ /[\/ ](ruby|perl)([ \t]|$)/) SHEBANG = "other"
	return SHEBANG == "" ? "" : "#"
}

# Position of a trailing comment opener mk (with blanks around it) after code whose quotes balance, or 0.
function tcpos(line, mk,   p, code, c) {
	p = index(line, " " mk " ")
	if (!p) p = index(line, "\t" mk " ")
	if (!p) return 0
	code = substr(line, 1, p)
	if (index(code, "`") || code ~ /^[ \t]*$/) return 0
	c = code
	gsub(/\\./, "", c)
	if (gsub(/"/, "", c) % 2) return 0
	if (mk == "#" && gsub(/'/, "", c) % 2) return 0
	return p + 1
}

# Filler phrases in a trailing comment; the code before it is never touched.
function trailing(line, syn,   mk, p, body, nb, w) {
	mk = index(syn, "//") ? "//" : (index(syn, "#") ? "#" : "")
	if (mk == "" || !(p = tcpos(line, mk))) return line
	body = substr(line, p + length(mk))
	w = LFW
	nb = fixwords(body, 1)
	if (nb == body || nb !~ /[[:alnum:]]/) { LFW = w; return line }
	return substr(line, 1, p + length(mk) - 1) nb
}

# The line-comment opener at the start of t (leading blanks already removed), or "".
function lcpfx(t, syn) {
	if (index(syn, "//") && match(t, /^\/\/+!?/)) return substr(t, 1, RLENGTH)
	if (index(syn, "#") && t ~ /^#/ && t !~ /^#!/) return "#"
	if (index(syn, "--") && t ~ /^--/) return "--"
	if (index(syn, ";") && match(t, /^;+/)) return substr(t, 1, RLENGTH)
	return ""
}

# Strips a banner's decoration. BAN: 0 not a banner, 1 rewritten to its text, 2 nothing left (drop),
# 3 left alone (decoration around something that isn't plain text, such as an ASCII diagram).
function unbanner(b, hit,   s) {
	BAN = 0
	if (!hit) return b
	s = b
	sub(/^[ \t]+/, "", s)
	if (s ~ /^#+[ \t]+[^ \t]/) {
		sub(/^#+[ \t]+/, "", s)
		BAN = 1
		return " " s
	}
	sub(/^[-=*_#~]+/, "", s)
	sub(/[ \t]+$/, "", s)
	sub(/[ \t]*[-=*_#~][-=*_#~]+$/, "", s)
	sub(/^[ \t]+/, "", s)
	if (s == "") { BAN = 2; return "" }
	if (s ~ /^[[:alnum:]"'`(]/ && s !~ /[-=*_#~][-=*_#~][-=*_#~][-=*_#~]/) { BAN = 1; return " " s }
	BAN = 3
	return b
}

# Position of phrase p in lc at or after start, as a whole phrase; 0 if none.
function phrasepos(lc, p, start,   off, q, b, a) {
	off = start - 1
	while ((q = index(substr(lc, off + 1), p)) > 0) {
		b = off + q > 1 ? substr(lc, off + q - 1, 1) : ""
		a = substr(lc, off + q + length(p), 1)
		if (b !~ /[[:alnum:]_'"`*-]/ && a !~ /[[:alnum:]_'"`*-]/) return off + q
		off += q
	}
	return 0
}

# Drops filler phrases from comment or doc text s; LFW counts them.
function fixwords(s, cmt,   i, pos, pre, post, st, from) {
	for (i = 1; i <= nph; i++) {
		if (phc[i] && !cmt) continue
		from = 1
		while ((pos = phrasepos(tolower(s), ph[i], from)) > 0) {
			pre = substr(s, 1, pos - 1)
			post = substr(s, pos + length(ph[i]))
			st = pre ~ /^[ \t]*$/ || pre ~ /[.!?:;][ \t]+$/
			if (phs[i] && !st && pre !~ /[,(][ \t]*$/) { from = pos + length(ph[i]); continue }
			sub(/^,/, "", post)
			if (pre == "" || pre ~ /[([]$/ || (pre ~ /[ \t]$/ && post ~ /^[ \t]/)) sub(/^[ \t]+/, "", post)
			else if (post ~ /^[.;:!?)]/) { sub(/[ \t]+$/, "", pre); sub(/,$/, "", pre) }
			if (post ~ /^[ \t]*$/) { sub(/[ \t]+$/, "", pre); post = "" }
			if (st && substr(s, pos, 1) ~ /[A-Z]/ && post ~ /^[a-z]/) post = toupper(substr(post, 1, 1)) substr(post, 2)
			s = pre post
			LFW++
			from = length(pre) + 1
		}
	}
	return s
}

# One comment line split as indent, opener and body.
function fixc(ind, pfx, body, line,   nb, before, w) {
	if (rulehit("gen-line", "add", tolower(line))) { LGEN++; return DROP }
	nb = unbanner(body, rulehit("comment-banner", "comment", tolower(line)))
	if (BAN == 2) { LBD++; return DROP }
	if (BAN == 1) LBR++
	before = nb
	w = LFW
	nb = fixwords(nb, 1)
	if (nb != before && nb !~ /[[:alnum:]]/) { nb = before; LFW = w }
	if (BAN != 1 && nb == body) return line
	return ind pfx nb
}

# First literal from a test file that old contains and new lacks, or "".
function protect(old, new,   p, key, m, j, ids, L) {
	for (p = 1; p <= length(old) - 3; p++) {
		key = substr(old, p, 4)
		if (!(key in lk)) continue
		m = split(lk[key], ids, " ")
		for (j = 1; j <= m; j++) {
			L = lit[ids[j]]
			if (substr(old, p, length(L)) == L && !index(new, L)) return L
		}
	}
	return ""
}

# Collects quoted string literals from test files that could be comment text (several words, or long),
# since a test may assert on a comment.
function loadlits(   i, p, ln, rest, s) {
	for (i = 1; i <= nflist; i++) {
		p = flist[i]
		if (p !~ TESTRE) continue
		while ((getline ln < p) > 0) {
			rest = ln
			while (match(rest, /"([^"\\]|\\.)*"|'([^'\\]|\\.)*'/)) {
				s = substr(rest, RSTART + 1, RLENGTH - 2)
				rest = substr(rest, RSTART + RLENGTH)
				gsub(/\\"/, "\"", s)
				gsub(/\\'/, "'", s)
				gsub(/\\\\/, "\\", s)
				if ((s !~ /[^ ] +[^ ]/ && length(s) < 12) || s !~ /[[:alpha:]]/ || (s in litseen)) continue
				litseen[s] = 1
				lit[++nlit] = s
				lk[substr(s, 1, 4)] = lk[substr(s, 1, 4)] " " nlit
			}
		}
		close(p)
	}
}

# The fixed form of one line of p, or DROP. Tracks block comments, strings and heredocs across lines.
function fixone(line, p, syn, rk, doc,   t, ind, pfx, rest, cl, inner, after, s) {
	if (allowed(tolower(line))) return line
	if (doc) {
		if (line ~ /^[ \t]*(```|~~~)/) { infence = !infence; return line }
		if (infence) return line
		if (rulehit("gen-line", "add", tolower(line))) { LGEN++; return DROP }
		return fixwords(line, 0)
	}
	if (hdnext) { inheredoc = 1; hdnext = 0 }
	heredoc(line, hdname)
	if (inheredoc || hdend) { hdend = 0; return line }
	if (inraw) { rawflip(line, rk); return line }
	match(line, /^[ \t]*/)
	ind = substr(line, 1, RLENGTH)
	t = substr(line, RLENGTH + 1)
	if (inblk) {
		if ((cl = index(line, "*/")) > 0) {
			inblk = 0
			if (substr(line, cl + 2) !~ /^[ \t]*$/) return line
			if (rulehit("comment-banner", "comment", tolower(line))) {
				s = substr(line, 1, cl - 1)
				gsub(/[-=*_#~ \t]/, "", s)
				if (s == "") { LBR++; return ind "*/" }
				return line
			}
			s = substr(line, 1, cl - 1)
			rest = fixwords(s, 1)
			return rest == s ? line : rest "*/"
		}
		if (t ~ /^\*/) return fixc(ind, "*", substr(t, 2), line)
		return fixc(ind, "", t, line)
	}
	if (index(syn, "/*") && t ~ /^\/\*/) {
		rest = substr(t, 3)
		if ((cl = index(rest, "*/")) > 0) {
			inner = substr(rest, 1, cl - 1)
			after = substr(rest, cl + 2)
			if (after !~ /^[ \t]*$/) { rawflip(after, rk); return line }
			if (rulehit("gen-line", "add", tolower(line))) { LGEN++; return DROP }
			if (rulehit("comment-banner", "comment", tolower(line))) {
				s = unbanner(inner, 1)
				if (BAN == 2 || inner ~ /^[-=*_#~ \t]*$/) { LBD++; return DROP }
				if (BAN == 1) { LBR++; return ind "/*" s " */" }
				return line
			}
			s = fixwords(inner, 1)
			return s == inner ? line : ind "/*" s "*/" after
		}
		inblk = 1
		if (rulehit("comment-banner", "comment", tolower(line))) {
			s = unbanner(rest, 1)
			if (BAN == 2 || rest ~ /^[-=*_#~ \t]*$/) { LBR++; return ind "/*" }
			if (BAN == 1) { LBR++; return ind "/*" s }
			return line
		}
		s = fixwords(rest, 1)
		return s == rest ? line : ind "/*" s
	}
	pfx = lcpfx(t, syn)
	if (pfx != "") return fixc(ind, pfx, substr(t, length(pfx) + 1), line)
	rawflip(line, rk)
	return inraw ? line : trailing(line, syn)
}

function fixfile(p, n,   syn, rk, doc, r, ln, line, cr, out, k, nb, buf, changed, dropped, lastblank, br, bd, fw, gen, i, o) {
	syn = syntax(p)
	doc = isdoc(p)
	rk = rawkind(p)
	hdname = p
	if (syn == "" && !doc) {
		if ((syn = shebang(p)) == "") return
		if (SHEBANG == "py") rk = "py"
		if (SHEBANG == "sh") hdname = "script.sh"
	}
	inblk = inraw = infence = inheredoc = hdnext = hdend = 0
	nb = changed = dropped = br = bd = fw = gen = 0
	lastblank = 1
	while ((r = (getline line < p)) > 0) {
		ln++
		cr = ""
		if (line ~ /\r$/) { cr = "\r"; line = substr(line, 1, length(line) - 1) }
		LBR = LBD = LFW = LGEN = 0
		out = fixone(line, p, syn, rk, doc)
		if (out != line) {
			k = protect(line, out == DROP ? "" : out)
			if (k != "") {
				print "K\t" p ":" ln "\t" k
				out = line
			} else {
				changed++
				br += LBR; bd += LBD; fw += LFW; gen += LGEN
			}
		}
		if (out == DROP) { dropped = 1; continue }
		if (dropped && lastblank && out ~ /^[ \t]*$/) { dropped = 0; continue }
		dropped = 0
		buf[++nb] = out cr
		lastblank = out ~ /^[ \t]*$/
	}
	close(p)
	if (r < 0) { print "clean-guard: cannot read " p > "/dev/stderr"; return }
	if (!changed) return
	o = outdir "/" n
	for (i = 1; i <= nb; i++) printf "%s%s", buf[i], (i < nb ? "\n" : "") > o
	if (nb == 0) printf "" > o
	close(o)
	print "F\t" n "\t" p "\t" br "\t" bd "\t" fw "\t" gen
}

# ---- history (git fast-export stream) ----

function res(m) {
	while (m in alias) m = alias[m]
	return m
}

# The path of an M or D file change, unquoted.
function fcpath(s,   p) {
	if (s ~ /^M /) { p = s; sub(/^M [^ ]+ [^ ]+ /, "", p) }
	else p = substr(s, 3)
	if (p ~ /^".*"$/) {
		p = substr(p, 2, length(p) - 2)
		gsub(/\\"/, "\"", p)
		gsub(/\\\\/, "\\", p)
	}
	return p
}

function fixmsg(raw,   n, L, i, k, keep, cut, out) {
	n = split(raw, L, "\n")
	if (substr(raw, length(raw)) == "\n") n--
	k = cut = 0
	for (i = 1; i <= n; i++) {
		if (stripme(L[i])) { cut++; continue }
		keep[++k] = L[i]
	}
	if (!cut) return raw
	while (k > 0 && keep[k] ~ /^[ \t]*$/) k--
	if (k == 0) return raw
	out = ""
	for (i = 1; i <= k; i++) out = out keep[i] "\n"
	nmsgs++
	ncut += cut
	return out
}

function fecommit(   msg, i) {
	if (!incommit) return
	incommit = 0
	ncommits++
	lastmk = mk
	msg = fixmsg(raw)
	if (ndrop) npathc++
	if (nall > 0 && nfc == 0 && nmg == 0) { alias[mk] = from; nempty++; return }
	print "commit " target
	if (mk != "") print "mark " mk
	for (i = 1; i <= nh; i++) print hdr[i]
	print "data " length(msg)
	printf "%s", msg
	if (from != "") print "from " from
	for (i = 1; i <= nmg; i++) if (mg[i] != "") print "merge " mg[i]
	for (i = 1; i <= nfc; i++) print fc[i]
	print ""
}

function feline(s,   r, p) {
	if (want > 0) {
		r = want - got
		if (length(s) + 1 <= r) {
			raw = raw s "\n"
			got += length(s) + 1
			if (got == want) want = 0
			return
		}
		# The message ends inside this line: it had no final newline.
		raw = raw substr(s, 1, r)
		want = 0
		feline(substr(s, r + 1))
		return
	}
	if (s ~ /^commit /) {
		fecommit()
		incommit = 1
		mk = from = raw = ""
		nh = nmg = nfc = nall = ndrop = 0
		return
	}
	if (incommit) {
		if (s == "") { fecommit(); return }
		if (s ~ /^mark :/) { mk = substr(s, 6); return }
		if (s ~ /^(author|committer|encoding) /) { hdr[++nh] = s; return }
		if (s ~ /^data [0-9]+$/) { want = substr(s, 6) + 0; got = 0; raw = ""; return }
		if (s ~ /^from /) { from = res(substr(s, 6)); return }
		if (s ~ /^merge /) { mg[++nmg] = res(substr(s, 7)); return }
		nall++
		if (s ~ /^[MD] /) {
			p = fcpath(s)
			if (aipath(p)) {
				ndrop++
				if (!(p in dpath)) { dpath[p] = 1; dpaths[++ndp] = p }
				return
			}
		}
		fc[++nfc] = s
		return
	}
	if (s ~ /^reset /) { print "reset " target; return }
	if (s ~ /^from /) { r = res(substr(s, 6)); if (r != "") print "from " r; return }
	print s
}

function feend(   r, i) {
	fecommit()
	if (lastmk in alias) {
		r = res(lastmk)
		if (r == "") { print "clean-guard: every commit would be dropped" > "/dev/stderr"; exit 2 }
		print "reset " target
		print "from " r
		print ""
	}
	printf "commits %d\nmessages %d\nlines %d\npathcommits %d\nempty %d\n", ncommits, nmsgs, ncut, npathc, nempty > stats
	for (i = 1; i <= ndp; i++) print "path " dpaths[i] > stats
	close(stats)
}

END {
	if (mode == "fixtree") {
		loadlits()
		for (FI = 1; FI <= nflist; FI++) fixfile(flist[FI], FI)
	} else if (mode == "fixfe") feend()
}
