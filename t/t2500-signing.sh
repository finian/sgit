#!/usr/bin/env bash
# Signing on the way up.
#
# Reported as: commits pushed from the shadow repository arrive at the upstream
# unsigned, although commit.gpgsign is on. The upward path assembled objects by
# hand, which is a path git's signing never runs on.
#
# ssh signing is used here because it needs no agent and no passphrase.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home

command -v ssh-keygen >/dev/null 2>&1 &&
	ssh-keygen -q -t ed25519 -N '' -C 'alice' -f "$TRASH/key" 2>/dev/null || {
	printf '  (no usable ssh-keygen; skipping)\n'
	test_summary
	exit 0
}
printf 'alice@example.com %s\n' "$(cat "$TRASH/key.pub")" >"$TRASH/allowed"
git config --global gpg.format ssh
git config --global user.signingkey "$TRASH/key.pub"
git config --global gpg.ssh.allowedSignersFile "$TRASH/allowed"
git config --global commit.gpgsign true

make_upstream
P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
SHADOW=$(store_shadow "$id")
REAL=$(store_real "$id")

# --- the shadow side must never sign ----------------------------------------

is 'signing is off in the shadow working tree' 'false' "$(git -C "$P" config commit.gpgSign)"
printf 'a\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'written in the shadow repository'
is 'so its commit carries no signature' 0 \
	"$(git -C "$P" cat-file commit HEAD | command grep -c gpgsig)"

# --- and the real side signs, because that is what it is configured to do ----

ok 'the push succeeds' git -C "$P" push -q origin main
is 'the upstream commit is signed and verifies' \
	'G' "$(git -C "$UPSTREAM" log -1 --format='%G?' main)"
is 'by the real identity' \
	'alice@example.com' "$(git -C "$UPSTREAM" log -1 --format='%GS' main)"
is 'which is also its author' \
	'Alice Zhang <alice@example.com>' "$(git -C "$UPSTREAM" log -1 --format='%an <%ae>' main)"
is 'and the message is intact' \
	'written in the shadow repository' "$(git -C "$UPSTREAM" log -1 --format='%s' main)"
is 'while the shadow copy stays unsigned' 0 \
	"$(git -C "$P" cat-file commit HEAD | command grep -c gpgsig)"

# --- and none of that disturbs the round trip -------------------------------

before=$(git -C "$P" rev-parse HEAD)
ok 'fetching afterwards works' git -C "$P" pull --ff-only
is 'the shadow object is unchanged' "$before" "$(git -C "$P" rev-parse HEAD)"
is 'and no duplicate appeared' \
	"$(git -C "$UPSTREAM" rev-list --count main)" "$(git -C "$P" rev-list --count HEAD)"

# --- a key that cannot be used fails the push, and nothing moves -------------

git config --global user.signingkey "$TRASH/absent.pub"
sbefore=$(git -C "$SHADOW" rev-parse refs/heads/main)
printf 'b\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'this one cannot be signed'
out=$(git -C "$P" push origin main 2>&1) && rc=0 || rc=1
is 'a push that cannot be signed fails' 1 "$rc"
is 'and the shadow ref does not move' "$sbefore" "$(git -C "$SHADOW" rev-parse refs/heads/main)"
case "$out" in
*'sgit git config commit.gpgsign false'*) pass 'the message says how to proceed' ;;
*) fail 'the message says how to proceed' "$out" ;;
esac

# --- and it can be turned off for one repository alone -----------------------

sgit -C "$P" git config commit.gpgsign false
ok 'the same push then works' git -C "$P" push -q origin main
is 'arriving unsigned' 'N' "$(git -C "$UPSTREAM" log -1 --format='%G?' main)"
is 'while the global setting is untouched' \
	'true' "$(git config --global commit.gpgsign)"

# --- annotated tags, signed the same way ------------------------------------

git config --global user.signingkey "$TRASH/key.pub"
sgit -C "$P" git config commit.gpgsign true
git config --global tag.gpgsign true

# A message with a line beginning with #, which git's default cleanup would
# take for a comment and delete out of someone's release notes.
printf 'release v1\n\n# not a comment\nnotes\n' >"$TRASH/tagmsg"
git -C "$P" tag -a --cleanup=verbatim -F "$TRASH/tagmsg" v1

is 'the tag in the shadow repository is unsigned' 0 \
	"$(git -C "$P" cat-file tag v1 | command grep -c 'BEGIN.*SIGNATURE')"
is 'and tagged by the shadow identity' 'Dolores' \
	"$(git -C "$P" cat-file tag v1 | sed -n 's/^tagger \(.*\) <.*/\1/p')"

ok 'pushing it works' git -C "$P" push -q origin v1
ok 'and the upstream tag verifies' git -C "$UPSTREAM" tag -v v1
is 'signed by the real identity' 'alice@example.com' \
	"$(git -C "$UPSTREAM" tag -v v1 2>&1 >/dev/null | sed -n 's/.*signature for \([^ ]*\).*/\1/p')"
is 'and tagged by it too' 'Alice Zhang' \
	"$(git -C "$UPSTREAM" cat-file tag v1 | sed -n 's/^tagger \(.*\) <.*/\1/p')"
is 'the tagger date is carried over exactly' \
	"$(git -C "$P" cat-file tag v1 | sed -n 's/^tagger .*> //p')" \
	"$(git -C "$UPSTREAM" cat-file tag v1 | sed -n 's/^tagger .*> //p')"

tagbody() {
	git -C "$1" cat-file tag v1 | sed -n '/^$/,$p' | tail -n +2 |
		sed '/BEGIN SSH SIGNATURE/,$d' | od -An -tx1 | tr -d ' \n'
}
is 'the tag message survives byte for byte' \
	"$(od -An -tx1 <"$TRASH/tagmsg" | tr -d ' \n')" "$(tagbody "$UPSTREAM")"

# git tag writes refs/tags/<name> as it goes, and that has to be put back so
# that the ref only moves once the upstream has taken the push.
is 'the real ref ends at the tag that was pushed' \
	"$(git -C "$UPSTREAM" rev-parse refs/tags/v1)" "$(git -C "$REAL" rev-parse refs/tags/v1)"

before=$(git -C "$P" rev-parse refs/tags/v1)
ok 'fetching the signed tag back works' git -C "$P" fetch -q --tags
is 'and produces no second tag object' "$before" "$(git -C "$P" rev-parse refs/tags/v1)"
is 'which is still unsigned on this side' 0 \
	"$(git -C "$P" cat-file tag v1 | command grep -c 'BEGIN.*SIGNATURE')"

# --- a tag that cannot be signed stops the push -----------------------------

git config --global user.signingkey "$TRASH/absent.pub"
git -C "$P" tag -a -m 'release v2' v2
out=$(git -C "$P" push origin v2 2>&1) && rc=0 || rc=1
is 'a tag that cannot be signed fails the push' 1 "$rc"
not_ok 'and does not reach the upstream' \
	git -C "$UPSTREAM" rev-parse --verify --quiet refs/tags/v2
case "$out" in
*'tag.gpgsign false'*) pass 'the message names the setting to change' ;;
*) fail 'the message names the setting to change' "$out" ;;
esac

git config --global user.signingkey "$TRASH/key.pub"
sgit -C "$P" git config tag.gpgsign false
ok 'with tag signing off the push works' git -C "$P" push -q origin v2
not_ok 'and the tag arrives unsigned' git -C "$UPSTREAM" tag -v v2
git config --global --unset tag.gpgsign

test_summary
