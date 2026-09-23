#!/usr/bin/env bash
# sgit init: a new project with no upstream (spec G5 exception, C3).
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home

P="$TRASH/fresh"
sgit init "$P" >/dev/null 2>&1 || fail 'init succeeds' 'init exited non-zero'
id=$(id_of "$P")
REAL=$(store_real "$id")
SHADOW=$(store_shadow "$id")

ok 'a real repository is created' test -d "$REAL"
is 'it is bare' 'true' "$(git -C "$REAL" config core.bare)"
is 'it has no remote' '' "$(git -C "$REAL" remote)"
is 'the default branch is set' 'refs/heads/main' "$(git -C "$REAL" symbolic-ref HEAD)"

is 'no fetch upstream is recorded' '' \
	"$(git config -f "$SGIT_HOME/repos/$id/config" --get upstream.fetchRemote || true)"
is 'no push upstream is recorded' '' \
	"$(git config -f "$SGIT_HOME/repos/$id/config" --get upstream.pushRemote || true)"

is 'the working tree points at the gateway' "sgit::$id" "$(git -C "$P" remote get-url origin)"
is 'with the shadow identity' 'dolores@users.noreply.github.com' "$(git -C "$P" config user.email)"
is 'and an unborn default branch' 'refs/heads/main' "$(git -C "$P" symbolic-ref HEAD)"

status=$(sgit -C "$P" status 2>&1)
case "$status" in
*'mode         local-only'*) pass 'status reports local-only' ;;
*) fail 'status reports local-only' "$status" ;;
esac

listing=$(sgit list 2>&1)
case "$listing" in
*local-only*) pass 'list reports local-only' ;;
*) fail 'list reports local-only' "$listing" ;;
esac

# Syncing a repository with no upstream must be a quiet no-op rather than an
# error: there is simply nothing to fetch from.
ok 'sync on a local-only repository succeeds' sgit --id "$id" sync

printf 'hello\n' >"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'first commit'
is 'a commit in the new project uses the shadow identity' \
	'Dolores' "$(git -C "$P" log -1 --format='%an')"

leak=$(grep -rIl -e "$SGIT_HOME" -e 'alice@example.com' -e 'Alice Zhang' "$P/.git" 2>/dev/null || true)
is 'the new project leaks nothing either' '' "$leak"

# init reaches the same place from nothing, and answers the same question.
out=$(sgit init --no-workdir --print-id 2>/dev/null)
case "$out" in
????????????????) pass 'init --print-id writes the id to stdout' ;;
*) fail 'init --print-id writes the id to stdout' "$out" ;;
esac
ok 'and it names a repository that is there' test -d "$(store_real "$out")"


# A relative directory is recorded absolutely: sgit list, remote and the rest
# run from anywhere, and a relative path would name a different place from
# each of them -- or nothing, which list reports as a lost working tree.
mkdir -p "$TRASH/rel"
# $TRASH may carry a doubled slash from $TMPDIR; the recorded path will not.
REL=$(cd "$TRASH/rel" && pwd)
( cd "$TRASH/rel" && sgit init sub/../proj ) >/dev/null 2>&1 || fail 'init with a relative path' 'exited non-zero'
rid=$(id_of "$REL/proj")
is 'a relative working tree path is recorded absolutely' "$REL/proj" \
	"$(git config -f "$SGIT_HOME/repos/$rid/config" --get sgit.workdir)"
( cd "$REL/proj" && sgit remote add origin "$REL/nowhere.git" ) >/dev/null 2>&1
listing=$( cd "$REL/proj" && sgit list 2>&1 )
case "$listing" in
*"$rid"*gone*) fail 'list from inside the tree still finds it' "$listing" ;;
*"$REL/proj"*) pass 'list from inside the tree still finds it' ;;
*) fail 'list from inside the tree still finds it' "$listing" ;;
esac

# Stores written before that fix hold a relative path; list says how to repair
# it rather than offering a restore that would build a second tree.
git config -f "$SGIT_HOME/repos/$rid/config" sgit.workdir proj
listing=$(sgit list 2>&1)
case "$listing" in
*"$rid"*'relative path'*) pass 'list flags a relative path from an older init' ;;
*) fail 'list flags a relative path from an older init' "$listing" ;;
esac
sgit --id "$rid" config --repo sgit.workdir "$REL/proj" 2>/dev/null
listing=$(sgit list 2>&1)
case "$listing" in
*"$rid"*gone* | *"$rid"*relative*) fail 'config sgit.workdir repairs it' "$listing" ;;
*"$REL/proj"*) pass 'config sgit.workdir repairs it' ;;
*) fail 'config sgit.workdir repairs it' "$listing" ;;
esac

test_summary
