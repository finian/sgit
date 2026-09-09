#!/usr/bin/env bash
# Managing the real repository's remotes, and the local-only <-> upstream
# switch that comes with them (spec 9.3, 6.3, C4).
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home

P="$TRASH/proj"
sgit init "$P" >/dev/null 2>&1
id=$(id_of "$P")
cfg() { git config -f "$SGIT_HOME/repos/$id/config" --get "$1" 2>/dev/null || true; }

is 'a new project has no remotes' '' "$(sgit -C "$P" remote)"
is 'and no fetch target'          '' "$(cfg upstream.fetchRemote)"

# An empty upstream, so the first push after adopting it is a fast-forward.
git init -q --bare -b main "$TRASH/up.git"
sgit -C "$P" remote add origin "$TRASH/up.git" 2>/dev/null

is 'adding the first remote makes it the fetch target' 'origin' "$(cfg upstream.fetchRemote)"
is 'and the push target'                               'origin' "$(cfg upstream.pushRemote)"
case "$(sgit -C "$P" status)" in
*'mode         upstream'*) pass 'the repository is no longer local-only' ;;
*) fail 'the repository is no longer local-only' "$(sgit -C "$P" status)" ;;
esac

# --- redaction (spec 9) -----------------------------------------------------

out=$(sgit -C "$P" remote -v 2>/dev/null)
case "$out" in
*'<upstream>'*) pass 'URLs are redacted by default' ;;
*) fail 'URLs are redacted by default' "$out" ;;
esac
case "$out" in
*"$TRASH/up.git"*) fail 'and the real URL is not shown' "$out" ;;
*) pass 'and the real URL is not shown' ;;
esac
out=$(sgit -C "$P" --show-upstream remote -v 2>/dev/null)
case "$out" in
*"$TRASH/up.git"*) pass '--show-upstream reveals it' ;;
*) fail '--show-upstream reveals it' "$out" ;;
esac

# --- the mode switch actually works end to end (spec 6.3) -------------------

printf 'hello\n' >"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'work done while local-only'
ok 'a push now reaches the upstream' git -C "$P" push -q origin main
is 'and arrives with the real identity' \
	'Alice Zhang <alice@example.com>' "$(git -C "$TRASH/up.git" log -1 --format='%an <%ae>' main)"
is 'while the working tree keeps the shadow one' \
	'Dolores' "$(git -C "$P" log -1 --format='%an')"

# --- rename, set-url, remove ------------------------------------------------

sgit -C "$P" remote rename origin upstream 2>/dev/null
is 'renaming carries the fetch target along' 'upstream' "$(cfg upstream.fetchRemote)"
is 'and the push target'                     'upstream' "$(cfg upstream.pushRemote)"
is 'the old name is gone'                    'upstream' "$(git -C "$(store_real "$id")" remote)"

sgit -C "$P" remote set-url upstream "$TRASH/other.git" 2>/dev/null
is 'set-url changes the address' "$TRASH/other.git" \
	"$(git -C "$(store_real "$id")" config --get remote.upstream.url)"

out=$(sgit -C "$P" remote remove upstream 2>&1)
is 'removing the target drops back to local-only' '' "$(cfg upstream.fetchRemote)"
case "$out" in
*local-only*) pass 'and says so' ;;
*) fail 'and says so' "$out" ;;
esac
case "$(sgit -C "$P" status)" in
*'mode         local-only'*) pass 'status agrees' ;;
*) fail 'status agrees' "$(sgit -C "$P" status)" ;;
esac

# --- refusals ---------------------------------------------------------------

sgit -C "$P" remote add a "$TRASH/a.git" 2>/dev/null
not_ok 'adding a name twice is refused'     sgit -C "$P" remote add a "$TRASH/b.git"
not_ok 'renaming a missing remote is refused' sgit -C "$P" remote rename nope other
not_ok 'set-url on a missing remote is refused' sgit -C "$P" remote set-url nope "$TRASH/x.git"
not_ok 'set-push to a missing remote is refused' sgit -C "$P" remote set-push nope

sgit -C "$P" remote add b "$TRASH/b.git" 2>/dev/null
sgit -C "$P" remote set-push b 2>/dev/null
is 'the push target can differ from the fetch target' 'b' "$(cfg upstream.pushRemote)"
is 'and the fetch target is untouched'                'a' "$(cfg upstream.fetchRemote)"

test_summary
