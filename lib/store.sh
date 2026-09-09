# shellcheck shell=bash
#
# The sgit store (spec 4.1): one directory per shadowed repository, holding the
# real mirror, the rewritten shadow repository, and the configuration that ties
# them together. Everything secret lives here and nowhere else.

[ -n "${SGIT_STORE_SH:-}" ] && return 0
SGIT_STORE_SH=1

# The store holds every secret sgit has: the upstream URL, the real
# identities, and the ability to push with the user's credentials. Nothing
# outside the owner has any business reading it.
store_ensure_home() {
	mkdir -p "$SGIT_HOME/repos"
	chmod 700 "$SGIT_HOME" 2>/dev/null || true
	chmod 700 "$SGIT_HOME/repos" 2>/dev/null || true
}

# Resolve the paths for one repository id into globals.
store_use() {
	SGIT_ID="$1"
	SGIT_REPO_DIR="$SGIT_HOME/repos/$SGIT_ID"
	SGIT_REAL="$SGIT_REPO_DIR/real.git"
	SGIT_SHADOW="$SGIT_REPO_DIR/shadow.git"
	SGIT_REPO_CONFIG="$SGIT_REPO_DIR/config"
}

store_require() {
	store_use "$1"
	[ -d "$SGIT_REPO_DIR" ] || sgit_die "no such shadow repository: $1"
}

# A repository id must not be derived from the upstream URL: it is visible in
# the shadow repository's remote URL, so a hash of the URL could be confirmed
# by brute force against a guessed candidate (spec 4.3).
store_new_id() {
	local id=""
	if command -v openssl >/dev/null 2>&1; then
		id=$(openssl rand -hex 8 2>/dev/null) || id=""
	fi
	if [ -z "$id" ]; then
		id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n') ||
			sgit_die "cannot generate a repository id"
	fi
	case "$id" in
	[0-9a-f][0-9a-f]*) ;;
	*) sgit_die "generated a malformed repository id" ;;
	esac
	printf '%s' "$id"
}

repo_config() { git config -f "$SGIT_REPO_CONFIG" "$@"; }
repo_config_get() { git config -f "$SGIT_REPO_CONFIG" --get "$1" 2>/dev/null || true; }

# --- locking (spec 6.5) -----------------------------------------------------
#
# One lock per repository, taken by sync-down and by the pre-receive hook.
# mkdir is the portable atomic primitive here; macOS ships no flock(1).

store_lock() {
	local lock="$SGIT_REPO_DIR/lock" waited=0 timeout pid
	timeout=$(repo_config_get sync.lockTimeout)
	timeout="${timeout:-${SGIT_LOCK_TIMEOUT:-120}}"

	while ! mkdir "$lock" 2>/dev/null; do
		pid=$(cat "$lock/pid" 2>/dev/null || true)
		if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
			sgit_warn "removing a stale lock left by process $pid"
			rm -rf "$lock"
			continue
		fi
		if [ "$waited" -ge "$timeout" ]; then
			sgit_die "timed out after ${timeout}s waiting for the lock on $SGIT_ID"
		fi
		sleep 1
		waited=$((waited + 1))
	done

	printf '%s\n' "$$" >"$lock/pid"
	SGIT_HELD_LOCK="$lock"
	sgit_cleanup_add "$lock"
}

store_unlock() {
	if [ -n "${SGIT_HELD_LOCK:-}" ]; then
		rm -rf "$SGIT_HELD_LOCK"
		sgit_cleanup_drop "$SGIT_HELD_LOCK"
		SGIT_HELD_LOCK=""
	fi
}

# --- creation ---------------------------------------------------------------

# The shadow repository shares the real object database through alternates:
# trees and blobs are identical on both sides, so only commit and tag objects
# are ever written anew. That link is one-directional, which the pre-receive
# hook has to compensate for when pushing upwards (spec 6.2 step 3).
store_init_shadow() {
	local transport="$1"

	git init -q --bare "$SGIT_SHADOW"
	printf '%s\n' "$SGIT_REAL/objects" >"$SGIT_SHADOW/objects/info/alternates"

	# Reaching the real objects physically must not mean a client can ask for
	# one by name and receive the unrewritten original (spec 7.3).
	git -C "$SGIT_SHADOW" config uploadpack.allowAnySHA1InWant false
	git -C "$SGIT_SHADOW" config uploadpack.allowTipSHA1InWant false
	git -C "$SGIT_SHADOW" config uploadpack.allowReachableSHA1InWant false

	# The map refs are named after real-side object ids. Advertising them
	# would hand a client a commit id from the real repository, and for a
	# public upstream a single commit id is enough to identify it. Hide them
	# from both services; with allowTipSHA1InWant off they cannot be asked
	# for by name either.
	git -C "$SGIT_SHADOW" config transfer.hideRefs "$SGIT_MAP_REF"
	git -C "$SGIT_SHADOW" config --add transfer.hideRefs "$SGIT_RMAP_REF"

	store_install_hooks

	if [ "$transport" = gateway ]; then
		# Only the shadow repository is ever exported. real.git carries no
		# marker, so git-daemon refuses it even though it sits under the
		# same base path (spec 7.2).
		git -C "$SGIT_SHADOW" config daemon.receivepack true
		: >"$SGIT_SHADOW/git-daemon-export-ok"
	fi
}

# The upward path runs inside the shadow repository's pre-receive hook, so that
# the shadow ref only moves once the real side has accepted the change. The
# hook is a thin shim; the logic lives in `sgit pre-receive`.
#
# git relays whatever this hook writes back to whoever pushed -- the shadow
# side, which must not learn where the store is (spec 6.4). Two things would
# otherwise name it, both before sgit can say anything about itself: a shell
# reports a failed exec by printing the path it tried, so the shim tests the
# path and speaks for itself instead; and a library that will not load makes
# the shell print that file's path, which SGIT_HOOK_BOUNDARY turns into the
# same anonymous refusal. Neither detail is lost, it only stays on the store
# side -- `sgit doctor` runs the hooks from there and reports what happened.
#
# The gateway's access hook needs none of this: git-daemon discards whatever a
# hook prints and substitutes a message of its own, so nothing it says can
# reach a client.
store_install_hooks() {
	local hook="$SGIT_SHADOW/hooks/pre-receive"
	mkdir -p "$SGIT_SHADOW/hooks"
	cat >"$hook" <<HOOK
#!/bin/sh
[ -x "$SGIT_ROOT/bin/sgit" ] || {
	echo 'sgit: the hook on the store side could not start' >&2
	echo 'sgit: run "sgit doctor" where the store is' >&2
	exit 1
}
SGIT_HOOK_BOUNDARY=1
export SGIT_HOOK_BOUNDARY
exec "$SGIT_ROOT/bin/sgit" --id "$SGIT_ID" pre-receive
HOOK
	chmod +x "$hook"
}

store_write_config() {
	local transport="$1" workdir="$2"
	mkdir -p "$SGIT_REPO_DIR"
	: >"$SGIT_REPO_CONFIG"
	repo_config sgit.transport "$transport"
	repo_config sgit.created "$(date +%s)"
	[ -z "$workdir" ] || repo_config sgit.workdir "$workdir"
}

store_list_ids() {
	[ -d "$SGIT_HOME/repos" ] || return 0
	local d
	for d in "$SGIT_HOME/repos"/*; do
		[ -d "$d/real.git" ] || continue
		printf '%s\n' "${d##*/}"
	done
}

# What has become of the working tree this repository was created with.
#
#   ok       it is there and still belongs to this repository
#   missing  a path was recorded but nothing is at it any more
#   foreign  something is there, but it is not this shadow working tree
#   none     none was recorded -- created with --no-workdir, so it may well
#            exist on another machine where sgit cannot see it
#
# -> STORE_WD, STORE_WD_STATE
store_workdir_state() {
	local marker
	STORE_WD=$(repo_config_get sgit.workdir)

	if [ -z "$STORE_WD" ]; then
		STORE_WD_STATE=none
		return 0
	fi
	if [ ! -d "$STORE_WD/.git" ]; then
		STORE_WD_STATE=missing
		return 0
	fi
	marker=$(cat "$STORE_WD/.git/sgit" 2>/dev/null || true)
	if [ "$marker" = "$SGIT_ID" ]; then
		STORE_WD_STATE=ok
	else
		STORE_WD_STATE=foreign
	fi
	return 0
}

# The upstream URL is a secret; commands print a placeholder unless the user
# explicitly asks for it (spec 9).
store_upstream_url() {
	local remote
	remote=$(repo_config_get upstream.fetchRemote)
	[ -n "$remote" ] || return 0
	git -C "$SGIT_REAL" config --get "remote.$remote.url" 2>/dev/null || true
}

store_redact() {
	if [ -n "${SGIT_SHOW_UPSTREAM:-}" ]; then
		printf '%s' "$1"
	else
		printf '<upstream>'
	fi
}

# Refuse repositories whose origin cannot be hidden (spec N2, N7).
#
# A submodule URL lives in .gitmodules, inside the tree, and the tree may not
# be rewritten without breaking the guarantee that both working trees match.
# Failing at clone time is the honest outcome; silently shadowing such a
# repository would leave the origin in plain sight.
store_reject_unsupported() {
	local sha ref tmp
	sgit_tmpdir_init
	tmp="$SGIT_TMPDIR"
	git -C "$SGIT_REAL" for-each-ref --format='%(objectname) %(refname)' refs/heads >"$tmp/heads"
	while read -r sha ref; do
		[ -n "$ref" ] || continue
		if git -C "$SGIT_REAL" cat-file -e "$sha:.gitmodules" 2>/dev/null; then
			sgit_die "$ref contains submodules; their URLs live in the tree and cannot be hidden (see the spec, N2)"
		fi
		if git -C "$SGIT_REAL" cat-file -p "$sha:.gitattributes" 2>/dev/null |
			grep -q 'filter=lfs'; then
			sgit_die "$ref uses git-lfs, which is not supported in v0.1 (see the spec, N7)"
		fi
	done <"$tmp/heads"
}
