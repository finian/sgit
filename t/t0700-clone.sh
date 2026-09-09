#!/usr/bin/env bash
# sgit clone: store creation, full sync-down, and a leak-free working tree
# (spec 4.1, 4.2, 6.1, 9.1).
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1 || fail 'clone succeeds' 'clone exited non-zero'
id=$(id_of "$P")
REAL=$(store_real "$id")
SHADOW=$(store_shadow "$id")

ok 'the store holds a real mirror'   test -d "$REAL"
ok 'the store holds a shadow repo'   test -d "$SHADOW"
is 'the shadow shares the real object database through alternates' \
	"$REAL/objects" "$(cat "$SHADOW/objects/info/alternates")"
is 'arbitrary object requests are refused' \
	'false' "$(git -C "$SHADOW" config uploadpack.allowAnySHA1InWant)"
not_ok 'the helper transport exports nothing to git-daemon' \
	test -f "$SHADOW/git-daemon-export-ok"

# --- the working tree -------------------------------------------------------

is 'history length matches the upstream' \
	"$(git -C "$UPSTREAM" rev-list --count main)" "$(git -C "$P" rev-list --count HEAD)"
is 'the user commit is rewritten'        'Dolores' "$(git -C "$P" log --format='%an' | sed -n 2p)"
is 'the work address is rewritten too'   'Dolores' "$(git -C "$P" log --format='%an' | sed -n 1p)"
is 'a collaborator is left alone'        'Bob Lee' "$(git -C "$P" log --format='%an' | sed -n 3p)"
is 'the tree is identical to the upstream' \
	"$(git -C "$UPSTREAM" rev-parse 'main^{tree}')" "$(git -C "$P" rev-parse 'HEAD^{tree}')"

is 'the remote hides the origin'   "sgit::$id" "$(git -C "$P" remote get-url origin)"
is 'the identity is the shadow one' 'Dolores' "$(git -C "$P" config user.name)"
is 'signing is disabled'            'false'   "$(git -C "$P" config commit.gpgSign)"
is 'the working tree knows its id'  "$id"     "$(cat "$P/.git/sgit")"

# The clone reflog records where the objects came from, which is a store path.
not_ok 'the clone reflog is scrubbed' test -e "$P/.git/logs"

# --- the invariant ----------------------------------------------------------

leak=$(grep -rIl -e "$SGIT_HOME" -e "$UPSTREAM" -e 'alice@example.com' -e 'Alice Zhang' \
	"$P/.git" 2>/dev/null || true)
is 'no store path, upstream or real identity in the git metadata' '' "$leak"

# --- working in the shadow repository ---------------------------------------

printf 'more\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work in the shadow repository'
is 'a new commit takes the shadow identity' 'Dolores' "$(git -C "$P" log -1 --format='%an')"
ok  'the reflog comes back on its own'      test -f "$P/.git/logs/HEAD"

# --- incremental sync -------------------------------------------------------

out=$(SGIT_DEBUG=1 sgit --id "$id" sync 2>&1)
case "$out" in
*'rewrote 0 object(s) down'*) pass 'a sync with no upstream change rewrites nothing' ;;
*) fail 'a sync with no upstream change rewrites nothing' "$out" ;;
esac

commit_as "$UPWORK" 'Alice Zhang' 'alice@example.com' 'fourth by alice'
git -C "$UPWORK" push -q origin main
sgit --id "$id" sync >/dev/null 2>&1
head=$(git -C "$SHADOW" rev-parse refs/heads/main)
is 'the new upstream commit arrives rewritten' \
	'Dolores' "$(git -C "$SHADOW" log -1 --format='%an' "$head")"
is 'and the shadow history grew by one' 4 "$(git -C "$SHADOW" rev-list --count "$head")"

# --- sync.downTtl lets a recent result be reused ----------------------------

git config -f "$SGIT_HOME/config" sync.downTtl 3600
mv "$UPSTREAM" "$UPSTREAM.away"
ok 'within the TTL a sync does not need the upstream at all' sgit --id "$id" sync
mv "$UPSTREAM.away" "$UPSTREAM"
git config -f "$SGIT_HOME/config" --unset sync.downTtl
mv "$UPSTREAM" "$UPSTREAM.away"
not_ok 'and without it the unreachable upstream fails the sync' sgit --id "$id" sync
mv "$UPSTREAM.away" "$UPSTREAM"

# --- ref deletion propagates ------------------------------------------------

git -C "$UPWORK" branch -q side
git -C "$UPWORK" push -q origin side
sgit --id "$id" sync >/dev/null 2>&1
ok 'a new upstream branch appears' \
	git -C "$SHADOW" rev-parse --verify --quiet refs/heads/side
git -C "$UPWORK" push -q origin --delete side
sgit --id "$id" sync >/dev/null 2>&1
not_ok 'a deleted upstream branch disappears' \
	git -C "$SHADOW" rev-parse --verify --quiet refs/heads/side

# --- the warning about the directory name -----------------------------------
#
# A working tree called after the upstream names the real repository even
# though nothing inside it does. What decides the warning is the name itself,
# not who chose it: sgit defaulting to the upstream's name and the user asking
# for that same name leak equally, and a name the user picked instead is
# theirs to judge -- warning about it anyway trains them to ignore the warning.

err=$(sgit clone "$UPSTREAM" "$TRASH/private-notes" 2>&1 >/dev/null)
case "$err" in
*'directory name'*) fail 'a directory the user named draws no warning' "$err" ;;
*) pass 'a directory the user named draws no warning' ;;
esac

err=$(cd "$TRASH" && sgit clone "$UPSTREAM" 2>&1 >/dev/null)
case "$err" in
*'directory name'*) pass 'the name defaulted from the upstream is warned about' ;;
*) fail 'the name defaulted from the upstream is warned about' "$err" ;;
esac

err=$(sgit clone "$UPSTREAM" "$TRASH/nested/upstream" 2>&1 >/dev/null)
case "$err" in
*'directory name'*) pass 'so is the same name asked for explicitly' ;;
*) fail 'so is the same name asked for explicitly' "$err" ;;
esac

err=$(sgit clone --no-workdir "$UPSTREAM" 2>&1 >/dev/null)
case "$err" in
*'directory name'*) fail 'with no working tree there is no name to warn about' "$err" ;;
*) pass 'with no working tree there is no name to warn about' ;;
esac


# --- the id, for a caller rather than a reader ------------------------------
#
# Everything clone says goes to stderr, so --print-id can hand the id to a
# script on stdout with nothing around it. The separate-account wrapper needs
# exactly this: it makes the store on one side of a user boundary and the
# working tree on the other, and has to name the repository to the second half.

out=$(sgit clone --no-workdir --print-id "$UPSTREAM" 2>/dev/null)
case "$out" in
????????????????) pass '--print-id writes the id, and only the id, to stdout' ;;
*) fail '--print-id writes the id, and only the id, to stdout' "$out" ;;
esac
ok 'and it names a repository that is there' test -d "$(store_real "$out")"

quiet=$(sgit clone --no-workdir "$UPSTREAM" 2>/dev/null)
is 'without it stdout stays empty' '' "$quiet"


test_summary
