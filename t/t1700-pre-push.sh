#!/usr/bin/env bash
# The working tree's own guard (spec 8.2): a whitelist, carrying no secret,
# with the store-side blacklist behind it.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
SHADOW=$(store_shadow "$id")
HOOK="$P/.git/hooks/pre-push"

ok 'the guard is installed and executable' test -x "$HOOK"

# The whole point of the whitelist form: the hook lives where the shadow
# repository's reader can see it, so it must not name what it is protecting.
leak=$(grep -F -e 'alice@example.com' -e 'Alice Zhang' -e "$UPSTREAM" -e "$SGIT_HOME" "$HOOK" || true)
is 'and it names no real identity, upstream or store path' '' "$leak"

# --- it blocks work committed under another identity ------------------------

printf 'a\n' >>"$P/file.txt"
git -C "$P" add -A
GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL='alice@example.com' \
	git -C "$P" commit -qm 'committed as someone else'
out=$(git -C "$P" push origin main 2>&1) && rc=0 || rc=1
is 'a foreign committer is refused before anything leaves' 1 "$rc"
case "$out" in
*'different identity'*) pass 'and the reason is clear' ;;
*) fail 'and the reason is clear' "$out" ;;
esac
is 'nothing reached the upstream' \
	"$(git -C "$UPWORK" rev-parse main)" "$(git -C "$UPSTREAM" rev-parse main)"

# --- and the store side catches it even when the guard is bypassed ----------

before=$(git -C "$SHADOW" rev-parse refs/heads/main)
out=$(git -C "$P" push --no-verify origin main 2>&1) && rc=0 || rc=1
is '--no-verify does not get it through' 1 "$rc"
is 'the shadow ref stayed put'  "$before" "$(git -C "$SHADOW" rev-parse refs/heads/main)"

git -C "$P" reset -q --hard HEAD~1

# --- no false positive on history that came down from the real side ---------
#
# A branch cut from an old commit carries whatever identities that history
# had. Those commits are already on a remote-tracking ref, so the guard must
# leave them alone -- otherwise ordinary branching would be impossible.
is 'the history really does contain a third party' \
	'Bob Lee' "$(git -C "$P" log --format='%cn' | tail -1)"
git -C "$P" checkout -q -b feature "$(git -C "$P" rev-list --max-parents=0 HEAD)"
printf 'b\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'own work on a branch cut from old history'
ok 'pushing a branch containing that history is allowed' \
	git -C "$P" push -q origin feature
is 'and it arrived' 'own work on a branch cut from old history' \
	"$(git -C "$UPSTREAM" log -1 --format='%s' refs/heads/feature)"

# --- an author who is not the committer is fine -----------------------------
#
# Applying someone else's patch keeps their authorship; only the committer
# says who did the work here.
git -C "$P" checkout -q main
printf 'c\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -q --author='Carol Ng <carol@elsewhere.org>' -m 'a patch from carol'
ok 'a third-party author passes the guard' git -C "$P" push -q origin main
is 'and the upstream keeps that authorship' \
	'Carol Ng' "$(git -C "$UPSTREAM" log -1 --format='%an')"
is 'while the committer is the real identity' \
	'Alice Zhang' "$(git -C "$UPSTREAM" log -1 --format='%cn')"

test_summary
