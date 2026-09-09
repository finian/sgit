# shellcheck shell=bash
#
# Origin-identifying strings (spec 6.4).
#
# Anything the upstream says about itself -- and anything sgit writes about the
# store -- has to be recognisable before it can be kept out of the shadow side.
# This module produces that token list; stream scrubbing of upstream error
# output is built on it in the push path.

[ -n "${SGIT_SCRUB_SH:-}" ] && return 0
SGIT_SCRUB_SH=1

# Every form of an upstream URL that could identify it, longest first so that
# a later replacement cannot eat a prefix of an earlier one.
#   https://github.com/acme/secret.git
#     -> the URL, the URL without .git, host, owner/repo, owner, repo
scrub_url_tokens() {
	local url="$1" bare rest host path owner repo
	[ -n "$url" ] || return 0

	printf '%s\n' "$url"
	bare="${url%.git}"
	[ "$bare" = "$url" ] || printf '%s\n' "$bare"

	case "$url" in
	*://*)
		rest="${url#*://}"
		rest="${rest#*@}"
		host="${rest%%/*}"
		host="${host%%:*}"
		path="${rest#*/}"
		;;
	*@*:*)
		rest="${url#*@}"
		host="${rest%%:*}"
		path="${rest#*:}"
		;;
	*)
		return 0
		;;
	esac

	path="${path%.git}"
	path="${path#/}"
	owner="${path%%/*}"
	repo="${path##*/}"

	[ -z "$path" ] || printf '%s\n' "$path"
	[ -z "$host" ] || printf '%s\n' "$host"
	[ -z "$repo" ] || printf '%s\n' "$repo"
	[ -z "$owner" ] || [ "$owner" = "$path" ] || printf '%s\n' "$owner"
}

# The forms of a URL that could only have come from that URL.
#
# Scrubbing an outbound message wants every form, because over-scrubbing costs
# nothing there. Searching the shadow working tree for a leak is the opposite:
# a false positive accuses the tool of a leak it did not commit, and there are
# two that fire constantly.
#
# A bare host matches the shadow address this tool itself suggests --
# "dolores@users.noreply.github.com" contains "github.com" -- so every clone
# from GitHub would report its own configuration as a leak.
#
# A bare repository name is worse: a project's name runs through its own files
# and therefore through .git/index, and file contents are out of scope by
# design (see the boundary in the README). Reporting it would be reporting
# something that cannot be fixed.
#
# What is left is unambiguous: the URL, the URL without .git, and owner/repo.
scrub_url_tokens_exact() {
	local url="$1" bare rest path
	[ -n "$url" ] || return 0

	printf '%s\n' "$url"
	bare="${url%.git}"
	[ "$bare" = "$url" ] || printf '%s\n' "$bare"

	case "$url" in
	*://*)
		rest="${url#*://}"
		rest="${rest#*@}"
		path="${rest#*/}"
		;;
	*@*:*)
		rest="${url#*@}"
		path="${rest#*:}"
		;;
	*)
		# A filesystem path is already unambiguous on its own.
		return 0
		;;
	esac

	path="${path%.git}"
	path="${path#/}"
	case "$path" in
	*/*) printf '%s\n' "$path" ;;
	esac
}

# Rewrite upstream diagnostics so that nothing identifying reaches the shadow
# side (spec 6.4). Upstream errors almost always name the repository --
# "remote: Permission to acme/secret.git denied to alice" -- so relaying them
# verbatim would undo everything else.
#
# Replacement is literal, not regular-expression based: tokens contain dots,
# slashes and @ signs, and escaping them for sed is a source of silent misses.
# Tokens are applied longest first so that the full URL is consumed before its
# host. Whatever still looks like a URL afterwards is redacted wholesale.
scrub_stream() {
	local tokens="$1"
	awk -v tokfile="$tokens" -v repl='<upstream>' '
	BEGIN {
		while ((getline t < tokfile) > 0)
			if (length(t) > 0)
				tok[++n] = t
	}
	{
		line = $0
		for (i = 1; i <= n; i++) {
			while ((p = index(line, tok[i])) > 0)
				line = substr(line, 1, p - 1) repl \
					substr(line, p + length(tok[i]))
		}
		if (line ~ /https?:\/\// || line ~ /ssh:\/\// || line ~ /git:\/\// ||
		    line ~ /[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:/)
			line = "[redacted by sgit]"
		print line
	}'
}

# Write the token file used by scrub_stream, longest token first.
scrub_build_tokens() {
	local out="$1" pat
	{
		scrub_url_tokens "$(store_upstream_url)"
		printf '%s\n' "${SGIT_REAL_NAME:-}" "${SGIT_REAL_EMAIL:-}"
		while IFS= read -r pat; do
			[ -n "$pat" ] || continue
			case "$pat" in
			*'*'* | *'?'* | *'['*) continue ;;
			esac
			printf '%s\n' "$pat"
		done <<PATTERNS
${SGIT_REAL_EMAILS:-}
${SGIT_REAL_NAMES:-}
PATTERNS
	} | grep -v '^$' | awk '{ print length($0) "\t" $0 }' | sort -rn |
		cut -f2- | awk '!seen[$0]++' >"$out"
}
