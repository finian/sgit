#!/usr/bin/env bash
# The object stream (spec 15): two long-lived git processes in place of two per
# commit.
#
# Everything here is about producing byte-for-byte what the process-per-object
# path produced. The stream reads an object by counting bytes a line at a time,
# because bash 3.2 cannot read an exact number of them, so the cases that
# matter are the ones where lines and object boundaries do not coincide.
. "$(dirname "$0")/test-lib.sh"

W="$TRASH/w"
work_init "$W"
tree=$(git -C "$W" hash-object -w -t tree /dev/null)
me='Alice Zhang <alice@example.com>'

# Built by hand rather than with `git commit`, which would normalise away the
# very things being tested.
plant() {
	git -C "$W" hash-object -w -t commit --stdin
}

c1=$(printf 'tree %s\nauthor %s 1700000000 +0800\ncommitter %s 1700000000 +0800\n\nno newline at the end' \
	"$tree" "$me" "$me" | plant)
c2=$(printf 'tree %s\nparent %s\nauthor %s 1700000001 +0800\ncommitter %s 1700000001 +0800\n\nblank lines\n\n\nand a trailing one\n' \
	"$tree" "$c1" "$me" "$me" | plant)
big=$(head -c 9000 /dev/zero | tr '\0' x)
c3=$(printf 'tree %s\nparent %s\nauthor 张三 <alice@example.com> 1700000002 +0800\ncommitter 张三 <alice@example.com> 1700000002 +0800\n\n%s\n' \
	"$tree" "$c2" "$big" | plant)
# Somebody else's commit, so that the path for objects that come out unchanged
# is exercised too.
c4=$(printf 'tree %s\nparent %s\nauthor Bob Lee <bob@elsewhere.org> 1700000003 +0800\ncommitter Bob Lee <bob@elsewhere.org> 1700000003 +0800\n\nbob\n' \
	"$tree" "$c3" | plant)
git -C "$W" update-ref refs/heads/main "$c4"

# --- the two paths must agree -----------------------------------------------

loose_count() {
	find "$SHADOW/objects" -type f \
		-not -path '*/info/*' -not -path '*/pack/*' | wc -l | tr -d ' '
}

# setup_store sets REAL and SHADOW, so this cannot run in a subshell.
setup_store "$W"
sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all
streamed=$(git -C "$SHADOW" rev-list --reverse --all)
loose_streamed=$(loose_count)

setup_store "$W"
SGIT_NO_STREAM=1 sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all
fallback=$(git -C "$SHADOW" rev-list --reverse --all)
loose_fallback=$(loose_count)

is 'the streamed rewrite produces what the process-per-object one does' \
	"$fallback" "$streamed"
is 'and writes no more objects than it did' "$loose_fallback" "$loose_streamed"
ok 'and produced something' test -n "$streamed"

# --- and the awkward objects survive it -------------------------------------

setup_store "$W"
sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all

# A reader that counts bytes a line at a time gets these wrong by exactly one
# newline, in one direction or the other, so count them.
newlines() { git -C "$1" cat-file commit "$2" | tr -dc '\n' | wc -c | tr -d ' '; }
lastbyte() { git -C "$1" cat-file commit "$2" | tail -c 1 | od -An -c | tr -d ' '; }

s1=$(map_of "$c1")
is 'a commit with no trailing newline still has none' \
	"$(lastbyte "$REAL" "$c1")" "$(lastbyte "$SHADOW" "$s1")"
isnt 'and that last byte really is not a newline' '\\n' "$(lastbyte "$SHADOW" "$s1")"
is 'and it gained no line' \
	"$(newlines "$REAL" "$c1")" "$(newlines "$SHADOW" "$s1")"
is 'and its message is intact' 'no newline at the end' \
	"$(git -C "$SHADOW" log -1 --format=%s "$s1")"

s2=$(map_of "$c2")
is 'blank lines inside a message are neither dropped nor doubled' \
	"$(newlines "$REAL" "$c2")" "$(newlines "$SHADOW" "$s2")"

s3=$(map_of "$c3")
is 'a message larger than a pipe buffer comes through whole' \
	9000 "$(git -C "$SHADOW" log -1 --format=%B "$s3" | tr -d '\n' | wc -c | tr -d ' ')"
is 'and a non-ASCII author is rewritten, not mangled' \
	'Dolores' "$(field "$SHADOW" "$s3" '%an')"

s4=$(map_of "$c4")
isnt 'a third party commit moves because its ancestors did' "$c4" "$s4"
is 'but keeps its author' 'Bob Lee' "$(field "$SHADOW" "$s4" '%an')"

# --- the source of the object ids -------------------------------------------
#
# An object the rewrite leaves alone is not copied into the shadow repository:
# it is read through the alternates link. That is settled once per walk now
# rather than asked per object, so it is worth asserting that it still holds.
ok 'an unchanged object is reachable from the shadow side' \
	git -C "$SHADOW" cat-file -e "$(git -C "$REAL" rev-parse "$c1^{tree}")"

test_summary
