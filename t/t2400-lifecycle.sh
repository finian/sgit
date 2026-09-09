#!/usr/bin/env bash
# Losing a working tree, getting it back, and getting rid of a store entry.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
SHADOW=$(store_shadow "$id")

printf 'pushed\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work that was pushed'
git -C "$P" push -q origin main
printf 'kept back\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work that was never pushed'

# --- a working tree that is gone is said to be gone -------------------------

rm -rf "$P"
out=$(sgit list 2>&1)
case "$out" in
*'(gone'*) pass 'list says the working tree is gone' ;;
*) fail 'list says the working tree is gone' "$out" ;;
esac
case "$out" in
*"sgit restore $id"*) pass 'and names the command that brings it back' ;;
*) fail 'and names the command that brings it back' "$out" ;;
esac
out=$(sgit doctor 2>&1)
case "$out" in
*'is gone'*) pass 'doctor warns about it too' ;;
*) fail 'doctor warns about it too' "$out" ;;
esac

# --- and can be brought back ------------------------------------------------

ok 'restore recreates it' sgit restore "$id"
ok 'at the recorded path'  test -d "$P/.git"
is 'holding the shadow identity' 'Dolores' "$(git -C "$P" log -1 --format='%an')"
is 'and the remote it had'  "sgit::$id" "$(git -C "$P" remote get-url origin)"
ok 'with the guard hook back in place' test -x "$P/.git/hooks/pre-push"
is 'work that was pushed comes back' \
	'work that was pushed' "$(git -C "$P" log -1 --format='%s')"
# The shadow repository never saw the last commit, so nothing can produce it.
is 'work that was never pushed does not' \
	'' "$(git -C "$P" log --format='%s' | command grep 'never pushed' || true)"
leak=$(command grep -rIl -e "$SGIT_HOME" -e "$UPSTREAM" -e 'alice@example.com' "$P/.git" 2>/dev/null || true)
is 'and it leaks nothing, as a fresh clone would not' '' "$leak"

not_ok 'restoring over something that exists is refused' sgit restore "$id"
not_ok 'restoring an unknown id is refused' sgit restore 0123456789abcdef

# --- a directory that is no longer ours -------------------------------------

mv "$P/.git/sgit" "$P/.git/sgit.gone"
out=$(sgit list 2>&1)
case "$out" in
*'not a shadow working tree'*) pass 'a replaced directory is reported as such' ;;
*) fail 'a replaced directory is reported as such' "$out" ;;
esac
mv "$P/.git/sgit.gone" "$P/.git/sgit"

# --- removing a store entry -------------------------------------------------

before=$(ls "$SGIT_HOME/repos" | wc -l | tr -d ' ')
out=$(sgit remove "$id" 2>&1) && rc=0 || rc=1
is 'removing without --yes fails when nobody can be asked' 1 "$rc"
is 'and nothing is deleted' "$before" "$(ls "$SGIT_HOME/repos" | wc -l | tr -d ' ')"
case "$out" in
*'cloned again'*) pass 'the warning says the upstream still has the history' ;;
*) fail 'the warning says the upstream still has the history' "$out" ;;
esac
case "$out" in
*'different object ids'*) pass 'and that the mapping goes with it' ;;
*) fail 'and that the mapping goes with it' "$out" ;;
esac

ok 'removing with --yes works' sgit remove "$id" --yes
not_ok 'the store entry is gone' test -d "$SGIT_HOME/repos/$id"
ok 'the working tree is left alone' test -d "$P/.git"
is 'as an ordinary repository' 'work that was pushed' "$(git -C "$P" log -1 --format='%s')"
out=$(sgit list 2>&1)
case "$out" in
*"$id"*) fail 'and it is no longer listed' "$out" ;;
*) pass 'and it is no longer listed' ;;
esac

# --- a repository whose only copy this is -----------------------------------

L="$TRASH/solo"
sgit init "$L" >/dev/null 2>&1
lid=$(id_of "$L")
out=$(sgit remove "$lid" 2>&1) || true
case "$out" in
*'only one there is'*) pass 'a local-only repository is called out as irreplaceable' ;;
*) fail 'a local-only repository is called out as irreplaceable' "$out" ;;
esac
ok 'it survives an unconfirmed removal' test -d "$SGIT_HOME/repos/$lid"
ok 'and goes when confirmed' sgit remove "$lid" --yes
not_ok 'leaving no store entry' test -d "$SGIT_HOME/repos/$lid"

test_summary
