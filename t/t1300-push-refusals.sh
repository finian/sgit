#!/usr/bin/env bash
# What happens when a push must not go through (spec 6.2, 6.3, 6.4, 8.2).
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

# An upstream that refuses, the way a protected branch or a read-only account
# would -- and whose refusal names the repository and the user, as real ones do.
cat >"$UPSTREAM/hooks/pre-receive" <<HOOK
#!/bin/sh
cat >/dev/null
echo "Permission to $UPSTREAM denied to alice@example.com (Alice Zhang)." >&2
exit 1
HOOK
chmod +x "$UPSTREAM/hooks/pre-receive"

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
REAL=$(store_real "$id")
SHADOW=$(store_shadow "$id")

shadow_before=$(git -C "$SHADOW" rev-parse refs/heads/main)
real_before=$(git -C "$REAL" rev-parse refs/heads/main)

printf 'work\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work that will be refused'
out=$(git -C "$P" push origin main 2>&1) && rc=0 || rc=1

is 'a refusal upstream fails the push' 1 "$rc"
is 'the shadow ref does not move' "$shadow_before" "$(git -C "$SHADOW" rev-parse refs/heads/main)"
is 'and neither does the real one'  "$real_before"   "$(git -C "$REAL" rev-parse refs/heads/main)"

# --- the refusal must not carry the origin back (spec 6.4) ------------------

case "$out" in
*"$UPSTREAM"*) fail 'the upstream path is scrubbed from the refusal' "$out" ;;
*) pass 'the upstream path is scrubbed from the refusal' ;;
esac
case "$out" in
*alice@example.com*) fail 'the real address is scrubbed too' "$out" ;;
*) pass 'the real address is scrubbed too' ;;
esac
case "$out" in
*'Alice Zhang'*) fail 'and so is the real name' "$out" ;;
*) pass 'and so is the real name' ;;
esac
case "$out" in
*'<upstream>'*) pass 'something recognisable is left in its place' ;;
*) fail 'something recognisable is left in its place' "$out" ;;
esac

rm -f "$UPSTREAM/hooks/pre-receive"
ok 'once the upstream relents, the same push works' git -C "$P" push -q origin main

# --- identity blacklist (spec 8.2) ------------------------------------------

before=$(git -C "$SHADOW" rev-parse refs/heads/main)
printf 'more\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -q --author='Alice Zhang <alice@example.com>' -m 'authored under the real name'
out=$(git -C "$P" push origin main 2>&1) && rc=0 || rc=1
is 'a commit carrying the real identity is refused' 1 "$rc"
is 'and the shadow ref stays put' "$before" "$(git -C "$SHADOW" rev-parse refs/heads/main)"
# The refusal reaches the shadow side, so it must not repeat what it objected to.
case "$out" in
*alice@example.com* | *'Alice Zhang'*) fail 'the refusal does not quote the identity' "$out" ;;
*) pass 'the refusal does not quote the identity' ;;
esac

git -C "$P" reset -q --hard HEAD~1
git -C "$UPWORK" fetch -q origin

# --- the mapping table is not writable --------------------------------------

out=$(git -C "$P" push origin HEAD:refs/sgit/map/deadbeef 2>&1) && rc=0 || rc=1
is 'pushing into the mapping table is refused' 1 "$rc"
case "$out" in
*'not writable'*) pass 'and says why' ;;
*) fail 'and says why' "$out" ;;
esac

# --- local-only repositories (spec G5 exception) ----------------------------

L="$TRASH/local"
sgit init "$L" >/dev/null 2>&1
lid=$(id_of "$L")
LREAL=$(store_real "$lid")

printf 'hello\n' >"$L/file.txt"
git -C "$L" add -A
git -C "$L" commit -qm 'first commit with no upstream'
out=$(git -C "$L" push -u origin main 2>&1) && rc=0 || rc=1

is 'a push with no upstream succeeds' 0 "$rc"
case "$out" in
*'no upstream configured'*) pass 'and says the change went no further' ;;
*) fail 'and says the change went no further' "$out" ;;
esac
is 'the real repository received it' \
	'first commit with no upstream' "$(git -C "$LREAL" log -1 --format='%s' main)"
is 'with the real identity restored' \
	'Alice Zhang <alice@example.com>' "$(git -C "$LREAL" log -1 --format='%an <%ae>' main)"
is 'while the working tree keeps the shadow one' \
	'Dolores' "$(git -C "$L" log -1 --format='%an')"
ok 'and the real repository is fully connected' \
	git -C "$LREAL" fsck --no-progress --connectivity-only

test_summary
