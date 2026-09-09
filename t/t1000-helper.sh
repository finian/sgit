#!/usr/bin/env bash
# The sgit:: remote helper (spec 7.1): fetching from the shadow working tree
# triggers a refresh and then hands the connection to git's own service.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
SHADOW=$(store_shadow "$id")
REAL=$(store_real "$id")

# --- the refs a client is allowed to see ------------------------------------

refs=$(git -C "$P" ls-remote origin)
case "$refs" in
*refs/heads/main*) pass 'the shadow branches are advertised' ;;
*) fail 'the shadow branches are advertised' "$refs" ;;
esac
# The map refs are named after real-side object ids, and for a public upstream
# a single commit id identifies the repository.
case "$refs" in
*refs/sgit/*) fail 'the map refs are hidden from clients' "$refs" ;;
*) pass 'the map refs are hidden from clients' ;;
esac
realsha=$(git -C "$REAL" rev-parse main)
not_ok 'a hidden map ref cannot be fetched by name' \
	git -C "$P" fetch origin "refs/sgit/map/$realsha"

# --- fetching ---------------------------------------------------------------

commit_as "$UPWORK" 'Alice Zhang' 'alice@example.com' 'fourth by alice'
git -C "$UPWORK" push -q origin main

ok 'git pull works through the helper' git -C "$P" pull --ff-only
is 'the new commit arrived rewritten' 'Dolores' "$(git -C "$P" log -1 --format='%an')"
is 'and the message is intact' 'fourth by alice' "$(git -C "$P" log -1 --format='%s')"
is 'history length matches the upstream' \
	"$(git -C "$UPSTREAM" rev-list --count main)" "$(git -C "$P" rev-list --count HEAD)"

# A tag created upstream must reach the shadow side through a plain fetch.
GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL='alice@example.com' \
	git -C "$UPWORK" tag -a v1 -m 'release v1'
git -C "$UPWORK" push -q origin v1
ok 'fetching brings tags across' git -C "$P" fetch --tags
is 'and the tagger is the shadow identity' \
	"Dolores" "$(git -C "$P" cat-file tag v1 | sed -n 's/^tagger \(.*\) <.*/\1/p')"

# --- stdio discipline (spec 6.6) --------------------------------------------
#
# The helper's stdout is the pack protocol. Anything the refresh prints must go
# to stderr; if a single diagnostic reached stdout the fetch below would fail
# with a protocol error.
ok 'a refresh that prints diagnostics does not corrupt the stream' \
	env SGIT_DEBUG=1 git -C "$P" fetch --tags

# --- upstream failures propagate --------------------------------------------

mv "$UPSTREAM" "$UPSTREAM.moved"
not_ok 'an unreachable upstream makes the fetch fail' git -C "$P" fetch
mv "$UPSTREAM.moved" "$UPSTREAM"
ok 'and it recovers once the upstream is back' git -C "$P" fetch

# --- the helper serves the push side too ------------------------------------

before=$(git -C "$SHADOW" rev-parse refs/heads/main)
printf 'local\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work in the shadow repository'
ok 'a push goes through the helper as well' git -C "$P" push -q origin main
isnt 'and the shadow ref moves' "$before" "$(git -C "$SHADOW" rev-parse refs/heads/main)"
is 'the upstream received it under the real identity' \
	'Alice Zhang' "$(git -C "$UPSTREAM" log -1 --format='%an' main)"

test_summary
