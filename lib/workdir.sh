# shellcheck shell=bash
#
# Creation and hardening of the shadow working tree (spec 4.2, 8).
#
# The invariant this module exists to enforce: nothing in the shadow working
# tree may name the store, the upstream, or the user's real identity. That is
# checked, not assumed -- workdir_verify fails the whole operation if any trace
# survives.

[ -n "${SGIT_WORKDIR_SH:-}" ] && return 0
SGIT_WORKDIR_SH=1

# -> WORKDIR_URL
workdir_remote_url() {
	local transport
	transport=$(repo_config_get sgit.transport)
	case "${transport:-helper}" in
	helper)
		# Leaks the least of any form: no host, no port, no path.
		WORKDIR_URL="sgit::$SGIT_ID"
		;;
	gateway)
		gateway_resolve_advertise
		WORKDIR_URL="git://$GATEWAY_ADVERTISE/$SGIT_ID/shadow.git"
		;;
	*) sgit_die "unknown transport: $transport" ;;
	esac
}

# The shadow working tree's own guard (spec 8.2).
#
# It is a whitelist: every commit being pushed must carry the identity this
# repository is configured with. The opposite test -- a list of identities to
# reject -- would mean storing the real ones here, which is precisely what the
# shadow working tree must never contain. That check belongs on the store side,
# in pre-receive, where the list already lives.
#
# The text is self-contained POSIX shell and reads the expected identity from
# the repository at run time, so it works in a virtual machine with no sgit
# installed and stays correct if the identity is ever changed.
workdir_pre_push_hook_text() {
	cat <<'HOOK'
#!/bin/sh
# Installed by sgit. Refuses to push work committed under an identity other
# than this repository's own -- the last chance to catch a commit made with
# --author or with GIT_COMMITTER_* overriding the repository configuration.

name=$(git config user.name)
email=$(git config user.email)
if [ -z "$name" ] || [ -z "$email" ]; then
	echo "sgit: user.name and user.email are not set in this repository" >&2
	exit 1
fi

zero=0000000000000000000000000000000000000000
status=0

while read -r _local_ref local_sha _remote_ref _remote_sha; do
	case "$local_sha" in
	'' | "$zero") continue ;;
	esac

	# Commits already present on a remote came from the other side and may
	# legitimately carry anyone's identity; only local work is examined.
	bad=$(git log --format='%h%x09%cn <%ce>' "$local_sha" --not --remotes |
		awk -F'	' -v want="$name <$email>" '$2 != want')

	if [ -n "$bad" ]; then
		echo "sgit: these commits were made under a different identity:" >&2
		echo "$bad" | sed 's/^/  /' >&2
		echo "sgit: this repository commits as $name <$email>" >&2
		echo "sgit: rewrite them before pushing, for example" >&2
		echo "sgit:   git rebase --exec 'git commit --amend --no-edit --reset-author' <base>" >&2
		status=1
	fi
done

exit $status
HOOK
}

workdir_install_hooks() {
	local dir="$1"
	mkdir -p "$dir/.git/hooks"
	workdir_pre_push_hook_text >"$dir/.git/hooks/pre-push"
	chmod +x "$dir/.git/hooks/pre-push"
}

workdir_populate() {
	local dir="$1" head branch

	if [ -n "$(git -C "$SGIT_SHADOW" for-each-ref refs/heads)" ]; then
		# --no-local forces the real transport instead of the local copy
		# optimisation, so the clone is complete even though the shadow
		# repository reaches most of its objects through alternates.
		# Progress is worth having on a large repository, and a clone names
		# only its destination -- nothing about the upstream. Spelled out
		# rather than built from ${VAR:+...}: the negative form of that
		# expands to the variable's own value, which lands as an argument.
		if [ -n "${SGIT_INTERACTIVE:-}" ] && [ -t 2 ]; then
			# git shows progress on a terminal by itself; forcing it
			# anywhere else is what fills a log with thousands of lines.
			git clone --no-local "$SGIT_SHADOW" "$dir" ||
				sgit_die "cannot create the shadow working tree at $dir"
		else
			git clone --no-local --quiet "$SGIT_SHADOW" "$dir" ||
				sgit_die "cannot create the shadow working tree at $dir"
		fi
	else
		head=$(git -C "$SGIT_SHADOW" symbolic-ref -q HEAD || printf 'refs/heads/main')
		branch="${head#refs/heads/}"
		git init -q -b "$branch" "$dir" ||
			sgit_die "cannot create the shadow working tree at $dir"
	fi
}

workdir_configure() {
	local dir="$1"

	workdir_remote_url
	if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
		git -C "$dir" remote set-url origin "$WORKDIR_URL"
	else
		git -C "$dir" remote add origin "$WORKDIR_URL"
	fi
	# Remembered so that a later `gateway fix-workdir-urls` can tell a URL it
	# wrote from one the user set themselves. The shape of the URL cannot
	# answer that: a tunnel keeps the path and changes only host and port,
	# which is exactly what a changed gateway address looks like.
	#
	# It lives with the working tree rather than in the store because the
	# store may be on another machine from the tree, and then it is not the
	# store's history that is being asked about. Same file either side.
	printf '%s\n' "$WORKDIR_URL" >"$dir/.git/sgit-url"

	git -C "$dir" config user.name "$SGIT_SHADOW_NAME"
	git -C "$dir" config user.email "$SGIT_SHADOW_EMAIL"
	# A signature made here would carry a key fingerprint, which identifies
	# the user as surely as the address would (spec 5.5).
	git -C "$dir" config commit.gpgSign false
	git -C "$dir" config tag.gpgSign false

	printf '%s\n' "$SGIT_ID" >"$dir/.git/sgit"
	workdir_install_hooks "$dir"
}

# Remove the traces the population step leaves behind. A clone records where it
# came from in the reflog, and that is a store path.
workdir_scrub() {
	local dir="$1"
	rm -rf "$dir/.git/logs"
	rm -f "$dir/.git/FETCH_HEAD"
}

# Everything that must not appear in the shadow working tree's metadata.
_workdir_secrets() {
	local url pat
	printf '%s\n' "$SGIT_HOME" "$SGIT_REPO_DIR" "$SGIT_REAL" "$SGIT_SHADOW"
	url=$(store_upstream_url)
	scrub_url_tokens_exact "$url"
	printf '%s\n' "${SGIT_REAL_NAME:-}" "${SGIT_REAL_EMAIL:-}"
	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		# Patterns cannot be searched for literally; the canonical values
		# above cover the addresses that actually appear in objects.
		case "$pat" in
		*'*'* | *'?'* | *'['*) continue ;;
		esac
		printf '%s\n' "$pat"
	done <<PATTERNS
${SGIT_REAL_EMAILS:-}
${SGIT_REAL_NAMES:-}
PATTERNS
}

# Fail loudly if any secret reached the shadow working tree's metadata.
#
# Only git's own metadata is examined. File contents are out of scope by
# design: the shadow tree must stay byte-identical to the real one, so an
# identity written into AUTHORS or a URL in a CI config cannot be removed
# (spec N1).
workdir_verify() {
	local dir="$1" tmp hits f
	sgit_tmpdir_init
	tmp="$SGIT_TMPDIR"

	# Built in a pipeline, so a failure inside it would go unnoticed and the
	# check would quietly run against a shorter list than it should.
	_workdir_secrets >"$tmp/secrets.raw" ||
		sgit_die "cannot work out what to check the working tree for"
	grep -v '^$' <"$tmp/secrets.raw" | sort -u >"$tmp/secrets"
	[ -s "$tmp/secrets" ] || return 0

	# Only what git writes *about* the repository, never what it stores *of*
	# it. The index in particular is a mirror of the tracked paths, so
	# searching it means searching the project's own file names -- content,
	# and out of scope by design.
	: >"$tmp/files"
	for f in config HEAD ORIG_HEAD FETCH_HEAD packed-refs description sgit \
		sgit-url COMMIT_EDITMSG shallow; do
		[ -f "$dir/.git/$f" ] && printf '%s\n' "$dir/.git/$f" >>"$tmp/files"
	done
	find "$dir/.git/info" "$dir/.git/logs" -type f >>"$tmp/files" 2>/dev/null || true
	find "$dir/.git/hooks" -type f ! -name '*.sample' >>"$tmp/files" 2>/dev/null || true
	[ -s "$tmp/files" ] || return 0

	# -I as a second guard: nothing binary should be on that list anyway.
	hits=$(grep -I -F -f "$tmp/secrets" -l -- $(cat "$tmp/files") 2>/dev/null || true)
	if [ -n "$hits" ]; then
		sgit_warn "the shadow working tree still names the store or the upstream:"
		printf '%s\n' "$hits" >&2
		sgit_die "refusing to leave a leaking shadow working tree behind"
	fi
}

workdir_finish() {
	local dir="$1"
	workdir_configure "$dir"
	workdir_scrub "$dir"
	workdir_verify "$dir"
}
