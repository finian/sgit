#!/usr/bin/env bash
# Signature and mergetag handling (spec 5.3, 5.5).
#
# Objects are crafted by hand rather than produced with gpg, so the test needs
# no keyring and stays deterministic.
. "$(dirname "$0")/test-lib.sh"

W="$TRASH/w"
work_init "$W"
commit_as "$W" 'Bob Lee' 'bob@elsewhere.org' 'base'
setup_store "$W"

TREE=$(git -C "$REAL" hash-object -w -t tree /dev/null)

craft() { git -C "$REAL" hash-object -w -t commit --stdin; }

signed_alice=$(craft <<OBJ
tree $TREE
author Alice Zhang <alice@example.com> 1700000000 +0800
committer Alice Zhang <alice@example.com> 1700000000 +0800
gpgsig -----BEGIN PGP SIGNATURE-----
 
 iQIzBAABCgAdFiEEfakefakefakefakefakefakefakefake
 -----END PGP SIGNATURE-----

signed by alice
OBJ
)

signed_bob=$(craft <<OBJ
tree $TREE
author Bob Lee <bob@elsewhere.org> 1700000000 +0800
committer Bob Lee <bob@elsewhere.org> 1700000000 +0800
gpgsig -----BEGIN PGP SIGNATURE-----
 
 iQIzBAABCgAdFiEEotherotherotherotherotherotherot
 -----END PGP SIGNATURE-----

signed by bob
OBJ
)

merged=$(craft <<OBJ
tree $TREE
author Alice Zhang <alice@example.com> 1700000000 +0800
committer Alice Zhang <alice@example.com> 1700000000 +0800
mergetag object 0123456789012345678901234567890123456789
 type commit
 tag v9
 tagger Alice Zhang <alice@example.com> 1700000000 +0800
 
 tag message

merge with an embedded tag
OBJ
)

git -C "$REAL" update-ref refs/heads/sig1 "$signed_alice"
git -C "$REAL" update-ref refs/heads/sig2 "$signed_bob"
git -C "$REAL" update-ref refs/heads/merged "$merged"

sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all

body_of() { git -C "$SHADOW" cat-file commit "$1"; }

sa=$(map_of "$signed_alice")
isnt 'a signed commit by the user is rewritten' "$signed_alice" "$sa"
case "$(body_of "$sa")" in
*gpgsig*) fail 'the stale signature is stripped' "gpgsig still present" ;;
*) pass 'the stale signature is stripped' ;;
esac
is 'the rewritten commit carries the shadow identity' \
	'Dolores' "$(field "$SHADOW" "$sa" '%an')"

# A commit that needed no rewriting keeps its id, and therefore its signature
# is still valid and must be preserved (spec 5.5).
sb=$(map_of "$signed_bob")
is 'an untouched signed commit keeps its object id' "$signed_bob" "$sb"
case "$(git -C "$REAL" cat-file commit "$sb")" in
*gpgsig*) pass 'an untouched signature is preserved' ;;
*) fail 'an untouched signature is preserved' "gpgsig was removed" ;;
esac

sm=$(map_of "$merged")
case "$(body_of "$sm")" in
*mergetag*) fail 'the mergetag block is dropped' "mergetag still present" ;;
*) pass 'the mergetag block is dropped' ;;
esac
case "$(body_of "$sm")" in
*'merge with an embedded tag'*) pass 'the commit message survives' ;;
*) fail 'the commit message survives' "$(body_of "$sm")" ;;
esac
is 'the mergetag commit keeps its tree' \
	"$TREE" "$(git -C "$SHADOW" rev-parse "$sm^{tree}")"

test_summary
