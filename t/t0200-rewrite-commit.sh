#!/usr/bin/env bash
# Commit rewriting, parent remapping and the map table (spec 5.2, 5.3, 5.8).
. "$(dirname "$0")/test-lib.sh"

W="$TRASH/w"
work_init "$W"
commit_as "$W" 'Bob Lee'    'bob@elsewhere.org'      'c1 by bob'
commit_as "$W" 'Alice Zhang' 'alice@example.com'     'c2 by alice'
commit_as "$W" 'Bob Lee'    'bob@elsewhere.org'      'c3 by bob'
commit_as "$W" 'A. Zhang'   'a.zhang@work-corp.com'  'c4 by alice at work'
setup_store "$W"

revs=$(git -C "$REAL" rev-list --reverse main)
set -- $revs
c1=$1 c2=$2 c3=$3 c4=$4

sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all

s1=$(map_of "$c1") s2=$(map_of "$c2") s3=$(map_of "$c3") s4=$(map_of "$c4")

# Nothing before the user's first commit needs touching, so it keeps its id.
is   'c1 (before any real identity) keeps its object id' "$c1" "$s1"
isnt 'c2 (authored by the user) gets a new object id'    "$c2" "$s2"
# The connecting insight of spec 5.2: c3 is Bob's, but its parent moved.
isnt 'c3 is rewritten too because its parent moved'      "$c3" "$s3"
isnt 'c4 (glob-matched work address) is rewritten'       "$c4" "$s4"

is 'c2 author is the shadow identity'   'Dolores' "$(field "$SHADOW" "$s2" '%an')"
is 'c2 email is the shadow identity'    "$SGIT_SHADOW_EMAIL" "$(field "$SHADOW" "$s2" '%ae')"
is 'c2 committer is rewritten as well'  'Dolores' "$(field "$SHADOW" "$s2" '%cn')"
is 'c3 keeps the collaborator identity' 'Bob Lee' "$(field "$SHADOW" "$s3" '%an')"
is 'c4 matched by glob is rewritten'    'Dolores' "$(field "$SHADOW" "$s4" '%an')"

is 'timestamps are untouched in v0.1' \
	"$(field "$REAL" "$c2" '%ad')" "$(field "$SHADOW" "$s2" '%ad')"

# G1: the working tree must be identical on both sides.
is 'c2 tree is unchanged' \
	"$(git -C "$REAL" rev-parse "$c2^{tree}")" "$(git -C "$SHADOW" rev-parse "$s2^{tree}")"
is 'c4 tree is unchanged' \
	"$(git -C "$REAL" rev-parse "$c4^{tree}")" "$(git -C "$SHADOW" rev-parse "$s4^{tree}")"

is 'parent pointers are remapped' "$s2" "$(git -C "$SHADOW" rev-parse "$s3^")"
is 'history length is preserved' \
	"$(git -C "$REAL" rev-list --count main)" "$(git -C "$SHADOW" rev-list --count "$s4")"

is 'the reverse map inverts the forward map' "$c2" "$(rmap_of "$s2")"

# Re-running must be a no-op: the map is consulted before any work is done.
out=$(SGIT_DEBUG=1 sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all 2>&1)
case "$out" in
*'rewrote 0 object(s)'*) pass 'a second run rewrites nothing' ;;
*) fail 'a second run rewrites nothing' "$out" ;;
esac
is 'object ids are stable across runs' "$s2" "$(map_of "$c2")"

test_summary
