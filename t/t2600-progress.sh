#!/usr/bin/env bash
# Progress on the slow parts, and what may be said while showing it.
#
# The rewrite runs at tens of milliseconds a commit, so a large repository
# spends minutes in a loop that used to print nothing at all.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home

# A history long enough to be worth reporting on, built with commit-tree so
# that making it does not cost more than the test.
big_upstream() {
	local n="$1" i tree parent=''
	UPWORK="$TRASH/up"
	UPSTREAM="$TRASH/upstream.git"
	work_init "$UPWORK"
	tree=$(git -C "$UPWORK" hash-object -w -t tree /dev/null)
	i=1
	while [ "$i" -le "$n" ]; do
		if [ -z "$parent" ]; then
			parent=$(GIT_AUTHOR_NAME='Alice Zhang' GIT_AUTHOR_EMAIL=alice@example.com \
				GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL=alice@example.com \
				git -C "$UPWORK" commit-tree "$tree" -m "c$i")
		else
			parent=$(GIT_AUTHOR_NAME='Alice Zhang' GIT_AUTHOR_EMAIL=alice@example.com \
				GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL=alice@example.com \
				git -C "$UPWORK" commit-tree "$tree" -p "$parent" -m "c$i")
		fi
		i=$((i + 1))
	done
	git -C "$UPWORK" update-ref refs/heads/main "$parent"
	git clone -q --bare "$UPWORK" "$UPSTREAM"
	git -C "$UPWORK" remote add origin "$UPSTREAM"
}

# Add more commits on top of what is already there.
extend_upstream() {
	local n="$1" i=1 tree parent
	tree=$(git -C "$UPWORK" hash-object -w -t tree /dev/null)
	parent=$(git -C "$UPWORK" rev-parse refs/heads/main)
	while [ "$i" -le "$n" ]; do
		parent=$(GIT_AUTHOR_NAME='Alice Zhang' GIT_AUTHOR_EMAIL=alice@example.com \
			GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL=alice@example.com \
			git -C "$UPWORK" commit-tree "$tree" -p "$parent" -m "more$i")
		i=$((i + 1))
	done
	git -C "$UPWORK" update-ref refs/heads/main "$parent"
	git -C "$UPWORK" push -q origin main
}

big_upstream 240

P="$TRASH/proj"
err=$(sgit clone "$UPSTREAM" "$P" 2>&1 >/dev/null)
out=$(sgit --id "$(id_of "$P")" status 2>/dev/null)

case "$err" in
*'commits 240/240'*) pass 'a long rewrite reports how far it has got' ;;
*) fail 'a long rewrite reports how far it has got' "$err" ;;
esac
case "$err" in
*'(240 new)'*) pass 'and how many it actually rewrote' ;;
*) fail 'and how many it actually rewrote' "$err" ;;
esac

# Progress belongs on stderr. On the helper and hook paths stdout carries the
# pack protocol, and a byte of anything else there corrupts it.
stdout=$(sgit --id "$(id_of "$P")" sync 2>/dev/null)
case "$stdout" in
*commits*) fail 'progress never reaches stdout' "$stdout" ;;
*) pass 'progress never reaches stdout' ;;
esac

# A second sync has nothing to walk at all: the history is pruned at the part
# already rewritten, so there is no counter and nothing is claimed.
err=$(sgit --id "$(id_of "$P")" sync 2>&1 >/dev/null)
case "$err" in
*commits*) fail 'a sync with nothing to do says nothing' "$err" ;;
*) pass 'a sync with nothing to do says nothing' ;;
esac

# And when there is something, the count is of that something -- not of the
# whole history it sits on top of.
extend_upstream 260
err=$(sgit --id "$(id_of "$P")" sync 2>&1 >/dev/null)
case "$err" in
*'commits 260/260'*) pass 'a later sync counts what is new, not the history' ;;
*) fail 'a later sync counts what is new, not the history' "$err" ;;
esac
case "$err" in
*'(260 new)'*) pass 'all of which needed rewriting' ;;
*) fail 'all of which needed rewriting' "$err" ;;
esac

err=$(SGIT_NO_PROGRESS=1 sgit --id "$(id_of "$P")" sync 2>&1 >/dev/null)
case "$err" in
*commits*) fail 'SGIT_NO_PROGRESS silences it' "$err" ;;
*) pass 'SGIT_NO_PROGRESS silences it' ;;
esac

# A handful of commits is not worth a counter. Its own upstream, since the
# one above is already 240 commits long.
SMALLWORK="$TRASH/small-up"
SMALL_UPSTREAM="$TRASH/small-upstream.git"
work_init "$SMALLWORK"
commit_as "$SMALLWORK" 'Alice Zhang' 'alice@example.com' 'one'
git clone -q --bare "$SMALLWORK" "$SMALL_UPSTREAM"
git -C "$SMALLWORK" remote add origin "$SMALL_UPSTREAM"
UPSTREAM="$SMALL_UPSTREAM"

S="$TRASH/small"
err=$(sgit clone "$UPSTREAM" "$S" 2>&1 >/dev/null)
case "$err" in
*commits*) fail 'a small repository gets no counter' "$err" ;;
*) pass 'a small repository gets no counter' ;;
esac

# --- what git itself is allowed to say --------------------------------------
#
# Reported alongside: a fetch that fails prints the address it could not reach.
# Run by the owner of the store that is fine; reached through the shadow
# repository it is the one thing that must not travel.

id=$(id_of "$S")
mv "$UPSTREAM" "$UPSTREAM.away"

out=$(git -C "$S" pull 2>&1) && rc=0 || rc=1
is 'a fetch failure reaches the shadow side as a failure' 1 "$rc"
case "$out" in
*"$UPSTREAM"*) fail 'with the upstream scrubbed out of it' "$out" ;;
*) pass 'with the upstream scrubbed out of it' ;;
esac
case "$out" in
*'<upstream>'*) pass 'leaving something recognisable in its place' ;;
*) fail 'leaving something recognisable in its place' "$out" ;;
esac

out=$(sgit --id "$id" sync 2>&1) && rc=0 || rc=1
is 'the same failure run by the owner also fails' 1 "$rc"
case "$out" in
*"$UPSTREAM"*) pass 'and tells them which address it could not reach' ;;
*) fail 'and tells them which address it could not reach' "$out" ;;
esac

mv "$UPSTREAM.away" "$UPSTREAM"

test_summary
