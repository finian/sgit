#!/usr/bin/env bash
# `sgit git` -- reach the real repository without knowing where it is.
#
# The mirror is an ordinary git repository; only its path is awkward, being
# built from a random id and buried in the store.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
REAL=$(store_real "$id")
SHADOW=$(store_shadow "$id")

# --- it reaches the real repository, not the shadow one ---------------------

is 'it operates on the real mirror' \
	"$(git -C "$REAL" rev-parse main)" "$(sgit -C "$P" git rev-parse main)"
isnt 'which is not the shadow repository' \
	"$(git -C "$SHADOW" rev-parse main)" "$(sgit -C "$P" git rev-parse main)"
is 'so it shows the real identities' \
	'Alice Zhang' "$(sgit -C "$P" git log --format='%an' main | sed -n 2p)"
is 'where the working tree shows the shadow one' \
	'Dolores' "$(git -C "$P" log --format='%an' | sed -n 2p)"

# --- the case it exists for -------------------------------------------------

sgit -C "$P" git config user.email 'you@work.example'
sgit -C "$P" git config user.name 'You At Work'
is 'a repository-local identity can be set without knowing the path' \
	'you@work.example' "$(git -C "$REAL" config user.email)"

printf 'x\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'after setting a per-repository identity'
ok 'and a push picks it up' git -C "$P" push -q origin main
is 'restoring that identity upstream' \
	'You At Work <you@work.example>' "$(git -C "$UPSTREAM" log -1 --format='%an <%ae>')"
is 'while the shadow copy is unchanged' 'Dolores' "$(git -C "$P" log -1 --format='%an')"

# --- everything after `git` belongs to git ----------------------------------

is 'git options are passed through' \
	'you@work.example' "$(sgit -C "$P" git config --get user.email)"
is 'including ones that look like sgit options' \
	'true' "$(sgit -C "$P" git rev-parse --is-bare-repository)"
is 'and format strings' \
	'You At Work' "$(sgit -C "$P" git log -1 --format='%an' main)"

# --- git's exit status is the command's -------------------------------------

ok     'a successful command succeeds' sgit -C "$P" git rev-parse --verify main
not_ok 'and a failing one fails'       sgit -C "$P" git cat-file -e "$(printf '0%.0s' $(seq 40))"

# --- how the repository is located ------------------------------------------

is 'it works from inside the working tree' \
	'true' "$(cd "$P" && sgit git rev-parse --is-bare-repository)"
is 'and by id from anywhere' \
	'true' "$(cd "$TRASH" && sgit --id "$id" git rev-parse --is-bare-repository)"
not_ok 'but not from nowhere in particular' \
	sh -c "cd '$TRASH' && sgit git rev-parse --is-bare-repository"

# --- what is not about a repository at all ----------------------------------
#
# `config --global` writes the account's own ~/.gitconfig; requiring a shadow
# working tree to be found first only stands in the way. It stands in the way
# at the worst moment in the separate-user deployment, where this command is
# how that account's identity and credentials get set -- before any repository
# exists.

( cd "$TRASH" && sgit git config --global sgit.test.outside yes ) 2>/dev/null
is 'config --global works from nowhere in particular' \
	'yes' "$(git config --global --get sgit.test.outside)"

( cd "$TRASH" && sgit git config --file "$TRASH/loose.cfg" a.b c ) 2>/dev/null
is 'and so does config --file' 'c' "$(git config -f "$TRASH/loose.cfg" --get a.b)"

# The scopes must not blur into one another: a global write from inside a
# working tree is still global, and an unscoped one is still the real
# repository's own.
( cd "$P" && sgit git config --global sgit.test.inside yes )
is 'a global write from inside the tree is still global' \
	'yes' "$(git config --global --get sgit.test.inside)"
is 'and did not land in the real repository' \
	'' "$(git -C "$REAL" config --local --get sgit.test.inside || true)"

( cd "$P" && sgit git config sgit.test.local yes )
is 'an unscoped write still lands in the real repository' \
	'yes' "$(git -C "$REAL" config --local --get sgit.test.local)"
is 'and not in the global file' \
	'' "$(git config --global --get sgit.test.local || true)"

# Everything else still needs to know which repository it is talking about.
not_ok 'anything else from nowhere in particular still fails' \
	sh -c "cd '$TRASH' && sgit git config --list --local"


test_summary
