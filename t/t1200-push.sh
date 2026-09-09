#!/usr/bin/env bash
# The upward path (spec 6.2): a push from the shadow side reaches the upstream
# carrying the real identity, and coming back down produces no duplicate.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
REAL=$(store_real "$id")
SHADOW=$(store_shadow "$id")

# A brand new file, so the push carries blobs and trees that exist nowhere but
# the shadow side. This is what the object transfer step exists for: without
# it the rewritten real commit would point at a tree the real repository has
# never seen, and only fsck would notice.
printf 'written in the shadow repository\n' >"$P/new-file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'add a new file'
shadow_head=$(git -C "$P" rev-parse HEAD)

ok 'the push succeeds' git -C "$P" push -q origin main

is 'the upstream sees the real author' \
	'Alice Zhang <alice@example.com>' "$(git -C "$UPSTREAM" log -1 --format='%an <%ae>')"
is 'and the real committer' \
	'Alice Zhang <alice@example.com>' "$(git -C "$UPSTREAM" log -1 --format='%cn <%ce>')"
is 'with the message intact' 'add a new file' "$(git -C "$UPSTREAM" log -1 --format='%s')"
is 'the shadow side still shows the shadow identity' \
	'Dolores' "$(git -C "$P" log -1 --format='%an')"
is 'the two sides carry the same tree' \
	"$(git -C "$UPSTREAM" rev-parse 'main^{tree}')" "$(git -C "$P" rev-parse 'HEAD^{tree}')"
is 'the new file arrived upstream' \
	'written in the shadow repository' "$(git -C "$UPSTREAM" show main:new-file.txt)"

# The object transfer is what makes this pass.
ok 'the real repository is fully connected' \
	git -C "$REAL" fsck --no-progress --connectivity-only
ok 'and so is the shadow repository' \
	git -C "$SHADOW" fsck --no-progress --connectivity-only

# --- round trip (spec G6) ---------------------------------------------------

ok 'fetching afterwards works' git -C "$P" pull --ff-only
is 'and produces no duplicate' "$shadow_head" "$(git -C "$P" rev-parse HEAD)"
is 'the history lengths match' \
	"$(git -C "$UPSTREAM" rev-list --count main)" "$(git -C "$P" rev-list --count HEAD)"

# --- branches and tags ------------------------------------------------------

git -C "$P" checkout -q -b feature
printf 'on a branch\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work on a branch'
ok 'a new branch can be pushed' git -C "$P" push -q origin feature
is 'the upstream has the branch' 'work on a branch' \
	"$(git -C "$UPSTREAM" log -1 --format='%s' refs/heads/feature)"
is 'with the real identity' 'Alice Zhang' \
	"$(git -C "$UPSTREAM" log -1 --format='%an' refs/heads/feature)"

git -C "$P" tag -a v1 -m 'release v1'
ok 'an annotated tag can be pushed' git -C "$P" push -q origin v1
is 'and its tagger is restored upstream' 'Alice Zhang' \
	"$(git -C "$UPSTREAM" cat-file tag v1 | sed -n 's/^tagger \(.*\) <.*/\1/p')"

ok 'a branch can be deleted' git -C "$P" push -q origin --delete feature
not_ok 'and it is gone upstream' \
	git -C "$UPSTREAM" rev-parse --verify --quiet refs/heads/feature
not_ok 'and gone from the shadow repository too' \
	git -C "$SHADOW" rev-parse --verify --quiet refs/heads/feature

# --- forcing ----------------------------------------------------------------

git -C "$P" checkout -q main
git -C "$P" commit -q --amend -m 'amended in the shadow repository'
not_ok 'a non-fast-forward push without --force is refused' git -C "$P" push -q origin main
is 'and the upstream is untouched' 'add a new file' "$(git -C "$UPSTREAM" log -1 --format='%s')"

ok 'the same push with --force succeeds' git -C "$P" push -q --force origin main
is 'and the upstream took the rewrite' \
	'amended in the shadow repository' "$(git -C "$UPSTREAM" log -1 --format='%s')"
is 'still with the real identity' 'Alice Zhang' "$(git -C "$UPSTREAM" log -1 --format='%an')"

test_summary
