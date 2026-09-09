#!/usr/bin/env bash
# Annotated tag rewriting (spec 5.4, 5.5).
. "$(dirname "$0")/test-lib.sh"

W="$TRASH/w"
work_init "$W"
commit_as "$W" 'Bob Lee'     'bob@elsewhere.org'  'c1 by bob'
commit_as "$W" 'Alice Zhang' 'alice@example.com'  'c2 by alice'

tag_as() { # repo name email tag target
	GIT_COMMITTER_NAME="$2" GIT_COMMITTER_EMAIL="$3" \
		GIT_COMMITTER_DATE='2024-01-01T00:00:00 +0800' \
		git -C "$1" tag -a "$4" -m "release $4" "$5"
}
tag_as "$W" 'Alice Zhang' 'alice@example.com' v2 'HEAD'
tag_as "$W" 'Bob Lee' 'bob@elsewhere.org' v1 'HEAD~'
git -C "$W" tag light HEAD

setup_store "$W"
c1=$(git -C "$REAL" rev-parse 'main~')
t1=$(git -C "$REAL" rev-parse refs/tags/v1)
t2=$(git -C "$REAL" rev-parse refs/tags/v2)

is 'v1 is an annotated tag' 'tag' "$(git -C "$REAL" cat-file -t "$t1")"
is 'light is a lightweight tag' 'commit' "$(git -C "$REAL" cat-file -t refs/tags/light)"

sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down --tags -- --all

s1=$(map_of "$t1")
s2=$(map_of "$t2")

# v1 tags a commit that needed no rewriting and was tagged by a collaborator,
# so the tag object itself is unchanged.
is 'a tag with nothing to change keeps its object id' "$t1" "$s1"
is 'it still points at the same commit' "$c1" "$(git -C "$SHADOW" rev-parse "$s1^{commit}")"

isnt 'a tag by the user gets a new object id' "$t2" "$s2"
tagger_of() { git -C "$1" cat-file tag "$2" | sed -n 's/^tagger //p'; }
is 'the tagger becomes the shadow identity' \
	"Dolores <$SGIT_SHADOW_EMAIL>" \
	"$(tagger_of "$SHADOW" "$s2" | sed 's/> .*/>/')"
is 'a collaborator tagger is left alone' \
	'Bob Lee <bob@elsewhere.org>' "$(tagger_of "$SHADOW" "$s1" | sed 's/> .*/>/')"
is 'the tag points at the rewritten commit' \
	"$(map_of "$(git -C "$REAL" rev-parse "$t2^{commit}")")" \
	"$(git -C "$SHADOW" rev-parse "$s2^{commit}")"
is 'the tag message survives' 'release v2' \
	"$(git -C "$SHADOW" cat-file tag "$s2" | sed -n '$p')"

# A signed tag carries its signature in the message body, not in a header, so
# it needs a separate removal path from a commit's gpgsig.
TREE=$(git -C "$REAL" rev-parse 'main^{tree}')
signed_tag=$(git -C "$REAL" hash-object -w -t tag --stdin <<OBJ
object $(git -C "$REAL" rev-parse main)
type commit
tag v3
tagger Alice Zhang <alice@example.com> 1700000000 +0800

release v3
-----BEGIN PGP SIGNATURE-----

iQIzBAABCgAdFiEEfakefakefakefakefakefake
-----END PGP SIGNATURE-----
OBJ
)
git -C "$REAL" update-ref refs/tags/v3 "$signed_tag"
sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down --tags -- --all
s3=$(map_of "$signed_tag")
body=$(git -C "$SHADOW" cat-file tag "$s3")
case "$body" in
*'BEGIN PGP SIGNATURE'*) fail 'a tag signature is stripped' "$body" ;;
*) pass 'a tag signature is stripped' ;;
esac
case "$body" in
*'release v3'*) pass 'the signed tag message survives' ;;
*) fail 'the signed tag message survives' "$body" ;;
esac

test_summary
