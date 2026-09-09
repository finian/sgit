# shellcheck shell=bash
#
# Management of the real repository's remotes (spec 9.3).
#
# These commands act on R, not on R'. The shadow working tree has exactly one
# remote -- the gateway -- and that never changes; what changes here is where
# the real repository fetches from and pushes to.
#
# In v0.1 a repository may carry any number of remotes but only the two named
# by upstream.fetchRemote and upstream.pushRemote take part in synchronisation.

[ -n "${SGIT_REMOTE_SH:-}" ] && return 0
SGIT_REMOTE_SH=1

remote_exists() {
	git -C "$SGIT_REAL" config --get "remote.$1.url" >/dev/null 2>&1
}

remote_require() {
	remote_exists "$1" || sgit_die "no such remote: $1"
}

remote_list() {
	local name fetch push mark url
	fetch=$(repo_config_get upstream.fetchRemote)
	push=$(repo_config_get upstream.pushRemote)
	while read -r name; do
		[ -n "$name" ] || continue
		mark=''
		[ "$name" = "$fetch" ] && mark='fetch'
		[ "$name" = "$push" ] && mark="${mark:+$mark,}push"
		if [ "${SGIT_REMOTE_VERBOSE:-no}" = yes ]; then
			url=$(git -C "$SGIT_REAL" config --get "remote.$name.url" || true)
			printf '%-12s %-10s %s\n' "$name" "${mark:--}" "$(store_redact "$url")"
		else
			printf '%-12s %s\n' "$name" "${mark:--}"
		fi
	done <<NAMES
$(git -C "$SGIT_REAL" remote)
NAMES
}

# real.git is a mirror, so a remote fetches straight into refs/heads and
# refs/tags rather than into a remote-tracking namespace. Anything outside
# those two is deliberately not mirrored (spec 11).
remote_set_refspecs() {
	local name="$1"
	# Two values, so the key has to be cleared first: writing a multi-valued
	# key with a plain `git config` fails, and under set -e that failure
	# would silently skip whatever the caller does next.
	git -C "$SGIT_REAL" config --unset-all "remote.$name.fetch" 2>/dev/null || true
	git -C "$SGIT_REAL" config --add "remote.$name.fetch" '+refs/heads/*:refs/heads/*'
	git -C "$SGIT_REAL" config --add "remote.$name.fetch" '+refs/tags/*:refs/tags/*'
}

remote_add() {
	local name="$1" url="$2"
	remote_exists "$name" && sgit_die "remote $name already exists"
	git -C "$SGIT_REAL" remote add "$name" "$url" ||
		sgit_die "cannot add remote $name"
	remote_set_refspecs "$name"

	if [ -z "$(repo_config_get upstream.fetchRemote)" ]; then
		# The repository was local-only; the first remote it is given
		# becomes its upstream and the G5 exception stops applying.
		repo_config upstream.fetchRemote "$name"
		repo_config upstream.pushRemote "$name"
		sgit_warn "$SGIT_ID is no longer local-only: pushes now go to $name"
		sgit_warn "run 'sgit sync' to bring down whatever the upstream already has"
	fi
}

remote_set_url() {
	local name="$1" url="$2"
	remote_require "$name"
	git -C "$SGIT_REAL" remote set-url "$name" "$url" ||
		sgit_die "cannot change the URL of $name"
}

remote_rename() {
	local old="$1" new="$2"
	remote_require "$old"
	# git warns about the mirror-style refspecs it will not rewrite, and about
	# branches outside refs/remotes/; both are expected here and would only
	# confuse. Its own diagnostics are shown when it actually fails.
	git -C "$SGIT_REAL" remote rename "$old" "$new" >/dev/null 2>&1 ||
		sgit_die "cannot rename $old to $new"
	remote_set_refspecs "$new"
	[ "$(repo_config_get upstream.fetchRemote)" != "$old" ] ||
		repo_config upstream.fetchRemote "$new"
	[ "$(repo_config_get upstream.pushRemote)" != "$old" ] ||
		repo_config upstream.pushRemote "$new"
}

remote_remove() {
	local name="$1" fell_back=no
	remote_require "$name"
	git -C "$SGIT_REAL" remote remove "$name" >/dev/null 2>&1 ||
		sgit_die "cannot remove $name"

	if [ "$(repo_config_get upstream.fetchRemote)" = "$name" ]; then
		repo_config --unset upstream.fetchRemote || true
		fell_back=yes
	fi
	if [ "$(repo_config_get upstream.pushRemote)" = "$name" ]; then
		repo_config --unset upstream.pushRemote || true
		fell_back=yes
	fi
	if [ "$fell_back" = yes ]; then
		sgit_warn "$name was the synchronisation target; $SGIT_ID is local-only again"
		sgit_warn "pushes from the shadow repository now stop at the real one"
	fi
}

remote_set_target() {
	local which="$1" name="$2"
	remote_require "$name"
	case "$which" in
	fetch) repo_config upstream.fetchRemote "$name" ;;
	push) repo_config upstream.pushRemote "$name" ;;
	esac
}
