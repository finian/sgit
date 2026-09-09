#!/usr/bin/env bash
# Round-trip stability (spec G6): a commit made on the shadow side must reach
# the real side with the real identity, and coming back down must land on the
# very same shadow object rather than a duplicate.
. "$(dirname "$0")/test-lib.sh"

W="$TRASH/w"
work_init "$W"
commit_as "$W" 'Bob Lee'     'bob@elsewhere.org' 'c1 by bob'
commit_as "$W" 'Alice Zhang' 'alice@example.com' 'c2 by alice'
setup_store "$W"

real_head=$(git -C "$REAL" rev-parse main)
sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all
shadow_head=$(map_of "$real_head")
git -C "$SHADOW" update-ref refs/heads/main "$shadow_head"

# A new commit made in the shadow repository, as the shadow identity would
# produce it.
tree=$(git -C "$SHADOW" rev-parse "$shadow_head^{tree}")
new_shadow=$(git -C "$SHADOW" hash-object -w -t commit --stdin <<OBJ
tree $tree
parent $shadow_head
author Dolores <$SGIT_SHADOW_EMAIL> 1700000100 +0000
committer Dolores <$SGIT_SHADOW_EMAIL> 1700000100 +0000

work done in the shadow repository

Signed-off-by: Dolores <$SGIT_SHADOW_EMAIL>
OBJ
)
git -C "$SHADOW" update-ref refs/heads/main "$new_shadow"

sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction up -- refs/heads/main
new_real=$(rmap_of "$new_shadow")

isnt 'the new commit gets a real-side object id' "$new_shadow" "$new_real"
is 'its author is restored to the real identity' \
	'Alice Zhang' "$(field "$REAL" "$new_real" '%an')"
is 'its email is restored'  'alice@example.com' "$(field "$REAL" "$new_real" '%ae')"
is 'its committer is restored' 'Alice Zhang' "$(field "$REAL" "$new_real" '%cn')"
is 'its trailer is restored' \
	'Signed-off-by: Alice Zhang <alice@example.com>' \
	"$(git -C "$REAL" log -1 --format='%B' "$new_real" | grep '^Signed-off-by:')"
is 'its parent is the real head' "$real_head" "$(git -C "$REAL" rev-parse "$new_real^")"
is 'its tree is unchanged' "$tree" "$(git -C "$REAL" rev-parse "$new_real^{tree}")"
is 'the forward map agrees with the reverse map' "$new_shadow" "$(map_of "$new_real")"

# The point of the map: after the real side advances, fetching it back down
# must resolve to the object the shadow side already has.
git -C "$REAL" update-ref refs/heads/main "$new_real"
out=$(SGIT_DEBUG=1 sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all 2>&1)
case "$out" in
*'rewrote 0 object(s)'*) pass 'coming back down rewrites nothing' ;;
*) fail 'coming back down rewrites nothing' "$out" ;;
esac
is 'and resolves to the same shadow object' "$new_shadow" "$(map_of "$new_real")"
is 'the shadow history has not grown' 3 "$(git -C "$SHADOW" rev-list --count "$new_shadow")"
is 'the real history has not grown'   3 "$(git -C "$REAL" rev-list --count "$new_real")"

# A commit carrying a third party's identity must survive the trip untouched.
third=$(git -C "$SHADOW" hash-object -w -t commit --stdin <<OBJ
tree $tree
parent $new_shadow
author Carol Ng <carol@elsewhere.org> 1700000200 +0000
committer Dolores <$SGIT_SHADOW_EMAIL> 1700000200 +0000

a patch from carol, applied by the shadow user
OBJ
)
git -C "$SHADOW" update-ref refs/heads/main "$third"
sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction up -- refs/heads/main
third_real=$(rmap_of "$third")
is "a third party's authorship is preserved upwards" \
	'Carol Ng' "$(field "$REAL" "$third_real" '%an')"
is 'while the committer is restored to the real identity' \
	'Alice Zhang' "$(field "$REAL" "$third_real" '%cn')"

test_summary
