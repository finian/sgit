# shellcheck shell=bash
#
# The upward path (spec 6.2), running as the shadow repository's pre-receive
# hook.
#
# The hook's exit code decides whether the shadow ref moves, which is what
# makes the two sides agree: the change is rewritten, sent upstream, and only
# if the upstream accepts it does the shadow side advance. Permission errors,
# branch protection and non-fast-forward rejections therefore reach the shadow
# repository unchanged, without any of it being reimplemented here.

[ -n "${SGIT_PUSH_SH:-}" ] && return 0
SGIT_PUSH_SH=1

SGIT_ZERO=0000000000000000000000000000000000000000

# pre-receive is all or nothing, so any objection rejects the whole push.
# The message reaches the client, so it must not name what it objected to when
# the objection is an identity.
push_reject() {
	printf 'sgit: %s\n' "$*" >&2
	exit 1
}

shadow_git() { git -C "$SGIT_SHADOW" "$@"; }
real_git() { git -C "$SGIT_REAL" "$@"; }

# --- 1. validation ----------------------------------------------------------

push_validate() {
	local tmp="$1" old new ref cur forced
	: >"$tmp/plan"
	: >"$tmp/news"

	while read -r old new ref; do
		[ -n "$ref" ] || continue

		case "$ref" in
		refs/sgit/*)
			push_reject "$ref: the mapping table is not writable" ;;
		refs/heads/* | refs/tags/*) ;;
		*)
			push_reject "$ref: only branches and tags can be pushed" ;;
		esac

		# receive-pack compares old against the advertised value only after
		# this hook has run. Checking here as well closes the window in
		# which the upstream would already have been updated by the time
		# the local update turns out to be stale.
		cur=$(shadow_git rev-parse --verify --quiet "$ref" || printf '%s' "$SGIT_ZERO")
		[ "$cur" = "$old" ] ||
			push_reject "$ref moved since it was advertised; fetch and try again"

		forced=no
		if [ "$old" != "$SGIT_ZERO" ] && [ "$new" != "$SGIT_ZERO" ]; then
			shadow_git merge-base --is-ancestor "$old" "$new" 2>/dev/null ||
				forced=yes
		fi

		printf '%s %s %s %s\n' "$old" "$new" "$ref" "$forced" >>"$tmp/plan"
		[ "$new" = "$SGIT_ZERO" ] || printf '%s\n' "$new" >>"$tmp/news"
	done <"$tmp/commands"
}

# Everything reachable from the pushed tips that the shadow repository does not
# already know. --all covers the map refs too, so anything that came down from
# the real side is excluded without a second lookup.
push_new_commits() {
	local tmp="$1"
	if [ -s "$tmp/news" ]; then
		# shellcheck disable=SC2046
		shadow_git rev-list --topo-order --reverse $(cat "$tmp/news") --not --all
	fi
}

# --- 2. identity blacklist (spec 8.2) ---------------------------------------

push_scan_object() {
	local sha="$1" type="$2" raw line key val
	raw=$(shadow_git cat-file "$type" "$sha")
	while IFS= read -r line; do
		case "$line" in
		'author '* | 'committer '* | 'tagger '*)
			val="${line#* }"
			if ident_split "$val" && ident_is_real "$IDENT_NAME" "$IDENT_EMAIL"; then
				sgit_debug "$sha: real identity in '${line%% *}'"
				push_reject "$sha carries an identity that must not leave the shadow repository; check user.name and user.email"
			fi
			;;
		*': '*)
			key="${line%%: *}"
			val="${line#*: }"
			if ident_is_trailer_token "$key" && ident_split "$val" &&
				ident_is_real "$IDENT_NAME" "$IDENT_EMAIL"; then
				sgit_debug "$sha: real identity in the '$key' trailer"
				push_reject "$sha carries an identity in a '$key' trailer that must not leave the shadow repository"
			fi
			;;
		esac
	done <<OBJECT
$raw
OBJECT
}

# The authoritative check. The working tree's own pre-push hook makes the same
# objection earlier, but it can be removed or bypassed with --no-verify, and it
# cannot hold the list of real identities without leaking it (spec 8.2).
push_check_identities() {
	local tmp="$1" sha old new ref forced

	push_new_commits "$tmp" >"$tmp/newcommits"
	while read -r sha; do
		[ -n "$sha" ] || continue
		push_scan_object "$sha" commit
	done <"$tmp/newcommits"

	while read -r old new ref forced; do
		case "$ref" in refs/tags/*) ;; *) continue ;; esac
		[ "$new" != "$SGIT_ZERO" ] || continue
		[ "$(shadow_git cat-file -t "$new")" = tag ] || continue
		push_scan_object "$new" tag
	done <"$tmp/plan"
}

# --- 3. object transfer (spec 6.2 step 3) -----------------------------------

# The alternates link only points one way: the shadow repository can read the
# real object database, not the reverse. New trees and blobs pushed here exist
# nowhere else, so the rewritten real commits would otherwise reference trees
# that do not exist -- a corruption only fsck would find.
push_transfer_objects() {
	local tmp="$1"
	[ -s "$tmp/news" ] || return 0

	# pack-objects --revs reads revisions, not rev-list options, so the
	# exclusion set is spelled out. Excluding the branch and tag tips is
	# enough and stays cheap: anything reachable from them is already on the
	# real side, either because it was rewritten down or pushed up before.
	{
		cat "$tmp/news"
		shadow_git for-each-ref --format='^%(objectname)' refs/heads refs/tags
	} | shadow_git pack-objects --stdout --revs --quiet >"$tmp/pack" 2>"$tmp/pack-err" ||
		sgit_die "cannot pack the pushed objects: $(cat "$tmp/pack-err")"

	# An empty push (everything already known) produces a header-only pack.
	[ -s "$tmp/pack" ] || return 0
	real_git index-pack --stdin <"$tmp/pack" >/dev/null 2>"$tmp/idx-err" ||
		sgit_die "cannot import the pushed objects into the real repository: $(cat "$tmp/idx-err")"
}

# --- 4. reverse rewrite -----------------------------------------------------

push_rewrite() {
	local tmp="$1" old new ref forced

	SGIT_DIRECTION=up
	SGIT_REWRITE_COMMIT_REFS=no
	map_load "$SGIT_REAL" "$SGIT_RMAP_REF" no

	if [ -s "$tmp/news" ]; then
		# shellcheck disable=SC2046
		sgit_rewrite "$SGIT_REAL" "$SGIT_SHADOW" up $(cat "$tmp/news") --not --all
	fi

	# A pushed annotated tag is an object of its own and is not reachable
	# through rev-list, which walks commits.
	while read -r old new ref forced; do
		case "$ref" in refs/tags/*) ;; *) continue ;; esac
		[ "$new" != "$SGIT_ZERO" ] || continue
		[ "$(shadow_git cat-file -t "$new")" = tag ] || continue
		map_lookup "$new"
		[ -z "$MAP_VALUE" ] || continue
		_rewrite_one "$SGIT_SHADOW" "$SGIT_REAL" "$new" tag
		printf 'update %s/%s %s\n' "$SGIT_RMAP_REF" "$new" "$REWROTE_SHA" \
			>>"$SGIT_TMPDIR/rmap.batch"
		printf 'update %s/%s %s\n' "$SGIT_MAP_REF" "$REWROTE_SHA" "$new" \
			>>"$SGIT_TMPDIR/map.batch"
	done <"$tmp/plan"
}

# --- 5. upstream ------------------------------------------------------------

push_upstream() {
	local tmp="$1" remote old new ref forced realnew out

	: >"$tmp/refspecs"
	: >"$tmp/realrefs"
	while read -r old new ref forced; do
		if [ "$new" = "$SGIT_ZERO" ]; then
			printf ':%s\n' "$ref" >>"$tmp/refspecs"
			printf '%s %s\n' "$ref" "$SGIT_ZERO" >>"$tmp/realrefs"
			continue
		fi
		map_lookup "$new"
		realnew="$MAP_VALUE"
		[ -n "$realnew" ] || sgit_die "internal error: $new was not rewritten"
		if [ "$forced" = yes ]; then
			printf '+%s:%s\n' "$realnew" "$ref" >>"$tmp/refspecs"
		else
			printf '%s:%s\n' "$realnew" "$ref" >>"$tmp/refspecs"
		fi
		printf '%s %s\n' "$ref" "$realnew" >>"$tmp/realrefs"
	done <"$tmp/plan"

	remote=$(repo_config_get upstream.pushRemote)
	if [ -z "$remote" ]; then
		# Local-only (spec G5 exception): the real repository is the final
		# destination, so there is nothing further to push to.
		printf 'sgit: no upstream configured; the change reached the real repository only\n' >&2
		return 0
	fi

	# --atomic keeps both sides consistent when several refs move at once:
	# a partial upstream failure would otherwise leave the real repository
	# ahead of the shadow one with no way to express that locally.
	# shellcheck disable=SC2046
	if real_git push --atomic --quiet "$remote" $(cat "$tmp/refspecs") 2>"$tmp/err"; then
		return 0
	fi
	# Only a remote that cannot do atomic pushes justifies the weaker mode.
	# A plain rejection also mentions "atomic push failed", so matching the
	# word alone would silently drop the all-or-nothing guarantee.
	if grep -q 'does not support --atomic push' "$tmp/err"; then
		sgit_warn "the upstream does not support atomic pushes; falling back"
		# shellcheck disable=SC2046
		if real_git push --quiet "$remote" $(cat "$tmp/refspecs") 2>"$tmp/err"; then
			return 0
		fi
	fi

	# Upstream diagnostics name the repository; relaying them verbatim would
	# undo the whole point (spec 6.4).
	scrub_stream "$tmp/tokens" <"$tmp/err" >&2
	push_reject "the upstream refused the push"
}

# --- 6. commit --------------------------------------------------------------

push_commit() {
	local tmp="$1" ref val
	: >"$tmp/realbatch"
	while read -r ref val; do
		[ -n "$ref" ] || continue
		if [ "$val" = "$SGIT_ZERO" ]; then
			printf 'delete %s\n' "$ref" >>"$tmp/realbatch"
		else
			printf 'update %s %s\n' "$ref" "$val" >>"$tmp/realbatch"
		fi
	done <"$tmp/realrefs"

	if [ -s "$tmp/realbatch" ]; then
		real_git update-ref --stdin <"$tmp/realbatch" ||
			sgit_die "cannot update the real refs"
	fi
	# Only now, once the upstream has accepted: a map ref written earlier
	# would point at a quarantined object that a rejection discards.
	sgit_rewrite_flush_refs "$SGIT_REAL" "$SGIT_SHADOW"
}

# --- entry point ------------------------------------------------------------

push_pre_receive() {
	local tmp quarantine

	sgit_tmpdir_init
	tmp="$SGIT_TMPDIR"
	cat >"$tmp/commands"

	# The pushed objects live in receive-pack's quarantine and are reachable
	# only through the environment it exported. That same environment would
	# hijack every command aimed at the real repository (C11), so it is
	# cleared and the quarantine re-attached as a read-only alternate --
	# which changes where objects are found, not where writes land.
	quarantine="${GIT_QUARANTINE_PATH:-}"
	sgit_clear_git_env
	# GIT_QUARANTINE_PATH is not part of --local-env-vars, and any receive-pack
	# that inherits it refuses to update refs ("ref updates forbidden inside
	# quarantine environment"). That bites whenever the upstream is a local
	# repository, since its receive-pack is a child of this process.
	unset GIT_QUARANTINE_PATH
	if [ -n "$quarantine" ]; then
		GIT_ALTERNATE_OBJECT_DIRECTORIES="$quarantine"
		export GIT_ALTERNATE_OBJECT_DIRECTORIES
	fi

	sgit_config_load
	sgit_identity_resolve "$SGIT_REAL"
	sgit_signing_resolve "$SGIT_REAL"
	store_lock
	scrub_build_tokens "$tmp/tokens"

	push_validate "$tmp"
	push_check_identities "$tmp"
	push_transfer_objects "$tmp"
	push_rewrite "$tmp"
	push_upstream "$tmp"
	push_commit "$tmp"

	store_unlock
}
