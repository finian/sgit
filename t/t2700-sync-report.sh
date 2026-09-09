#!/usr/bin/env bash
# What a downward sync says it did.
#
# The number that matters to a user is how many commits came out of the sync
# with an id other than the one upstream has, because that is the extent of
# what an agent working in the shadow repository can no longer correlate.
# A commit counts as replaced whenever its id moved -- including one whose own
# text was left alone and only moved because an ancestor did.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
err=$(sgit clone "$UPSTREAM" "$P" 2>&1 >/dev/null)

# make_upstream: bob (hidden by nothing), alice (the real identity), a.zhang
# at work-corp (a listed extra address). Bob's commit is first, so it has no
# rewritten ancestor and keeps its id; the other two do not.
case "$err" in
*'synced 3 commit(s); 2 got a new id'*)
	pass 'a clone reports how many commits it replaced' ;;
*) fail 'a clone reports how many commits it replaced' "$err" ;;
esac

id=$(id_of "$P")
REAL=$(store_real "$id")
n=0
for sha in $(git -C "$REAL" rev-list --branches); do
	[ "$(git -C "$REAL" rev-parse --verify --quiet \
		"refs/sgit/rmap/$sha" 2>/dev/null)" = "$sha" ] || n=$((n + 1))
done
is 'and the number is the one the map actually holds' 2 "$n"

# --- a commit that only moved because its parent did ------------------------
#
# Bob is nobody sgit hides, and this commit's text comes through untouched --
# but its parent is now a rewritten commit, so its id has to change, and that
# is exactly what the user is being told about.
commit_as "$UPWORK" 'Bob Lee' 'bob@elsewhere.org' 'fourth by bob'
git -C "$UPWORK" push -q origin main

err=$(git -C "$P" pull 2>&1 >/dev/null)
case "$err" in
*'synced 1 commit(s); 1 got a new id'*)
	pass 'a pull counts a commit that moved only because its parent did' ;;
*) fail 'a pull counts a commit that moved only because its parent did' "$err" ;;
esac
is 'and it kept its author' 'Bob Lee' "$(field "$P" HEAD '%an')"

# --- nothing to say ---------------------------------------------------------
#
# Most fetches bring nothing. Reporting a zero on every one of them would put
# a line of sgit's own into output that is otherwise git's.
err=$(git -C "$P" pull 2>&1 >/dev/null)
case "$err" in
*synced*) fail 'a fetch that brings nothing stays quiet' "$err" ;;
*) pass 'a fetch that brings nothing stays quiet' ;;
esac

# --- the upward direction is not reported -----------------------------------
#
# `git push` runs a downward sync first, and a push that says "synced 1
# commit" about the commit being pushed would read as though sgit had done
# something to it.
commit_as "$P" 'Dolores' 'dolores@users.noreply.github.com' 'from the shadow'
err=$(git -C "$P" push -q origin main 2>&1 >/dev/null)
case "$err" in
*synced*) fail 'a push does not report a sync of its own commits' "$err" ;;
*) pass 'a push does not report a sync of its own commits' ;;
esac

test_summary
