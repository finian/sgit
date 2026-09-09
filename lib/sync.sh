# shellcheck shell=bash
#
# Downward synchronisation (spec 6.1): bring the real repository up to date
# with its upstream, rewrite whatever is new, and publish the result as the
# shadow repository's refs.

[ -n "${SGIT_SYNC_SH:-}" ] && return 0
SGIT_SYNC_SH=1

SGIT_FETCH_REFSPECS='+refs/heads/*:refs/heads/*
+refs/tags/*:refs/tags/*'

# Fetch from upstream, if there is one. A repository created by `sgit init`
# has none, and stays purely local until `sgit remote add` gives it one.
sync_fetch_upstream() {
	local remote ttl last now
	remote=$(repo_config_get upstream.fetchRemote)
	if [ -z "$remote" ]; then
		sgit_debug "no upstream configured; local-only repository"
		return 0
	fi

	# Every fetch in the shadow repository normally reaches the upstream, so
	# that it sees what a direct fetch would. On a slow or intermittent link
	# that is not always wanted, and sync.downTtl allows a recent result to
	# be reused instead. Zero, the default, keeps the faithful behaviour.
	ttl=$(_config_one sync.downTtl)
	case "${ttl:-0}" in
	'' | 0 | *[!0-9]*) ;;
	*)
		last=$(repo_config_get sync.lastRun)
		now=$(date +%s)
		if [ -n "$last" ] && [ "$((now - last))" -lt "$ttl" ]; then
			sgit_debug "last sync was $((now - last))s ago, within sync.downTtl ($ttl); not contacting the upstream"
			return 0
		fi
		;;
	esac
	if [ -n "${SGIT_INTERACTIVE:-}" ]; then
		# Run by the person who owns the store: git's own diagnostics are
		# theirs to read, and they know where the upstream is already.
		# --quiet drops the "From <url>" summary; --progress puts back the
		# part worth watching, but only on a terminal -- forcing it into a
		# pipe would bury whatever is reading in thousands of lines.
		if [ -t 2 ]; then
			git -C "$SGIT_REAL" fetch --quiet --progress --prune "$remote" \
				'+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' ||
				sgit_die "cannot fetch from the upstream of $SGIT_ID"
		else
			git -C "$SGIT_REAL" fetch --quiet --prune "$remote" \
				'+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' ||
				sgit_die "cannot fetch from the upstream of $SGIT_ID"
		fi
		return 0
	fi

	# Reached through the remote helper or a hook, so anything git says
	# travels to the shadow side -- and what it says when a fetch fails is
	# the address of the upstream. Captured, then scrubbed (spec 6.4).
	sgit_tmpdir_init
	if ! git -C "$SGIT_REAL" fetch --quiet --prune "$remote" \
		'+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' \
		>"$SGIT_TMPDIR/fetch-err" 2>&1; then
		scrub_build_tokens "$SGIT_TMPDIR/tokens"
		scrub_stream "$SGIT_TMPDIR/tokens" <"$SGIT_TMPDIR/fetch-err" >&2
		sgit_die "cannot fetch from the upstream of $SGIT_ID"
	fi
}

# Publish the rewritten commits as shadow refs, and drop shadow refs whose real
# counterpart has gone away.
sync_refs() {
	local tmp sha ref
	sgit_tmpdir_init
	tmp="$SGIT_TMPDIR"

	git -C "$SGIT_REAL" for-each-ref --format='%(objectname) %(refname)' \
		refs/heads refs/tags >"$tmp/real-refs"
	git -C "$SGIT_SHADOW" for-each-ref --format='%(refname)' \
		refs/heads refs/tags >"$tmp/shadow-refs"

	: >"$tmp/ref-batch"
	while read -r sha ref; do
		[ -n "$ref" ] || continue
		map_lookup "$sha"
		[ -n "$MAP_VALUE" ] || sgit_die "ref $ref points at unmapped object $sha"
		printf 'update %s %s\n' "$ref" "$MAP_VALUE" >>"$tmp/ref-batch"
	done <"$tmp/real-refs"

	cut -d' ' -f2 <"$tmp/real-refs" | sort >"$tmp/want"
	sort <"$tmp/shadow-refs" >"$tmp/have"
	while read -r ref; do
		[ -n "$ref" ] || continue
		printf 'delete %s\n' "$ref" >>"$tmp/ref-batch"
	done < <(comm -13 "$tmp/want" "$tmp/have")

	if [ -s "$tmp/ref-batch" ]; then
		git -C "$SGIT_SHADOW" update-ref --stdin <"$tmp/ref-batch" ||
			sgit_die "cannot update shadow refs"
	fi
}

# Keep the default branch aligned, so that cloning the shadow repository checks
# out the same branch the real one would.
sync_head() {
	local head
	head=$(git -C "$SGIT_REAL" symbolic-ref -q HEAD) || return 0
	git -C "$SGIT_SHADOW" symbolic-ref HEAD "$head"
}

sync_down() {
	sgit_identity_resolve "$SGIT_REAL"
	store_lock
	sync_fetch_upstream
	# Prune the walk at everything already rewritten.
	#
	# refs/sgit/rmap/<shadow-sha> lives in the real repository and points at
	# the real commit, so those refs are exactly the mapped part of this
	# history. Sound to prune there because mapping happens in topological
	# order and is committed in one transaction: a mapped commit has mapped
	# ancestors.
	#
	# Pruning on its own is a loss -- resolving those refs costs more than
	# the walk it saves. It pays off because it makes the walk come back
	# empty, and an empty walk is what lets the whole mapping table go
	# unread (see sgit_rewrite). The two only make sense together.
	sgit_rewrite "$SGIT_REAL" "$SGIT_SHADOW" down \
		--branches --tags --not --glob='refs/sgit/rmap/*' 
	# Read before the tag pass overwrites the counters, and reported only
	# when there was work: a fetch that brings nothing is the common case
	# and should stay silent.
	if [ "${SGIT_REWROTE_COUNT:-0}" -gt 0 ]; then
		sgit_note "synced $SGIT_REWROTE_COUNT commit(s);" \
			"$SGIT_REWROTE_CHANGED got a new id"
	fi
	sgit_rewrite_tags "$SGIT_REAL" "$SGIT_SHADOW" down
	sync_refs
	sync_head
	repo_config sync.lastRun "$(date +%s)"
	store_unlock
}
