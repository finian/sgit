#!/usr/bin/env bash
# Repository locking (spec 6.5). sync-down and the push hook must not run at
# the same time, and a lock left by a dead process must not block forever.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
LOCK="$SGIT_HOME/repos/$id/lock"

# --- a live holder blocks ---------------------------------------------------

mkdir -p "$LOCK"
printf '%s\n' "$$" >"$LOCK/pid"
out=$(SGIT_LOCK_TIMEOUT=1 sgit --id "$id" sync 2>&1) && rc=0 || rc=1
is 'a lock held by a live process blocks the sync' 1 "$rc"
case "$out" in
*'timed out'*) pass 'and the failure says so' ;;
*) fail 'and the failure says so' "$out" ;;
esac
ok 'the holder keeps its lock' test -d "$LOCK"
rm -rf "$LOCK"

# --- a stale holder does not ------------------------------------------------

(exit 0) &
dead=$!
wait "$dead" 2>/dev/null || true
mkdir -p "$LOCK"
printf '%s\n' "$dead" >"$LOCK/pid"
out=$(SGIT_LOCK_TIMEOUT=5 sgit --id "$id" sync 2>&1) && rc=0 || rc=1
is 'a lock left by a dead process is broken' 0 "$rc"
case "$out" in
*stale*) pass 'and the removal is reported' ;;
*) fail 'and the removal is reported' "$out" ;;
esac

# --- the lock is released on the way out ------------------------------------

not_ok 'a successful sync leaves no lock behind' test -d "$LOCK"
sgit --id "$id" sync >/dev/null 2>&1
not_ok 'and neither does the next one' test -d "$LOCK"

# --- concurrent syncs serialise ---------------------------------------------

commit_as "$UPWORK" 'Alice Zhang' 'alice@example.com' 'concurrent'
git -C "$UPWORK" push -q origin main
sgit --id "$id" sync >/dev/null 2>&1 &
a=$!
sgit --id "$id" sync >/dev/null 2>&1 &
b=$!
wait "$a" && ra=0 || ra=1
wait "$b" && rb=0 || rb=1
is 'both concurrent syncs succeed' '0 0' "$ra $rb"
not_ok 'and leave no lock behind' test -d "$LOCK"

SHADOW=$(store_shadow "$id")
is 'the result is correct after concurrency' \
	"$(git -C "$UPSTREAM" rev-list --count main)" \
	"$(git -C "$SHADOW" rev-list --count refs/heads/main)"
ok 'and the shadow repository is intact' git -C "$SHADOW" fsck --no-progress --connectivity-only

test_summary
