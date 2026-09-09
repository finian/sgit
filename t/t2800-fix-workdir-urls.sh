#!/usr/bin/env bash
# sgit gateway fix-workdir-urls: pointing working trees at a moved gateway.
#
# The URL a shadow working tree holds is written once, when the tree is made.
# Changing gateway.listen, gateway.port or gateway.advertise changes what sgit
# would write today and nothing else, so every tree made before the change
# keeps dialling an address the daemon has left.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

git config -f "$SGIT_HOME/config" gateway.listen 127.0.0.1

A="$TRASH/a"
T="$TRASH/tunnelled"
H="$TRASH/helper-side"
sgit clone --transport gateway "$UPSTREAM" "$A" >/dev/null 2>&1
sgit clone --transport gateway "$UPSTREAM" "$T" >/dev/null 2>&1
sgit clone --transport helper "$UPSTREAM" "$H" >/dev/null 2>&1
sgit clone --transport gateway --no-workdir "$UPSTREAM" >/dev/null 2>&1
id_a=$(id_of "$A")
id_t=$(id_of "$T")

is 'a working tree records the URL it was given' \
	"git://127.0.0.1:9418/$id_a/shadow.git" "$(cat "$A/.git/sgit-url")"

# This one the user has pointed somewhere else on purpose. Note what it looks
# like: same path, different host and port -- which is also exactly what a
# gateway that moved looks like. Only the record tells them apart.
git -C "$T" remote set-url origin "git://tunnel.example:2222/$id_t/shadow.git"

git config -f "$SGIT_HOME/config" gateway.advertise 192.168.64.1

# --- what it says it would do -----------------------------------------------

out=$(sgit gateway fix-workdir-urls --dry-run 2>&1)
case "$out" in
*'dry run: nothing is written'*) pass 'a dry run says so' ;;
*) fail 'a dry run says so' "$out" ;;
esac
is 'and changes nothing' \
	"git://127.0.0.1:9418/$id_a/shadow.git" "$(git -C "$A" remote get-url origin)"

# --- and then does it -------------------------------------------------------

out=$(sgit gateway fix-workdir-urls 2>&1)
is 'the stale tree is corrected' \
	"git://192.168.64.1:9418/$id_a/shadow.git" "$(git -C "$A" remote get-url origin)"
is 'and its record moves with it' \
	"git://192.168.64.1:9418/$id_a/shadow.git" "$(cat "$A/.git/sgit-url")"
is 'a tree pointed elsewhere on purpose is left alone' \
	"git://tunnel.example:2222/$id_t/shadow.git" "$(git -C "$T" remote get-url origin)"
case "$out" in
*'set by hand -- left alone'*) pass 'and the report says why' ;;
*) fail 'and the report says why' "$out" ;;
esac
is 'a helper-transport tree is untouched, having no address to lose' \
	"sgit::$(id_of "$H")" "$(git -C "$H" remote get-url origin)"
case "$out" in
*'run --script where it lives'*) pass 'a tree on another machine is named, not skipped in silence' ;;
*) fail 'a tree on another machine is named, not skipped in silence' "$out" ;;
esac

out=$(sgit gateway fix-workdir-urls 2>&1)
case "$out" in
*'0 updated,'*) pass 'running it again finds nothing to do' ;;
*) fail 'running it again finds nothing to do' "$out" ;;
esac

# --- the script for trees this machine cannot see ---------------------------

script="$TRASH/fix.sh"
sgit gateway fix-workdir-urls --script >"$script" 2>/dev/null

# It is going to be read and run by someone on the other side of the boundary
# this whole tool exists to draw.
for secret in "$SGIT_HOME" "$UPSTREAM" alice@example.com 'Alice Zhang'; do
	if grep -qF "$secret" "$script"; then
		fail "the script does not name $secret" "$(grep -nF "$secret" "$script")"
	else
		pass "the script does not name $secret"
	fi
done
ok 'and it is valid shell' sh -n "$script"

# Four trees, as a guest would have them: one sgit wrote and the gateway moved
# under, one the user repointed, one belonging to no repository here, and one
# from before sgit recorded what it wrote.
VM="$TRASH/vm"
mkdir -p "$VM"
guest() {
	git init -q "$VM/$1"
	printf '%s\n' "$2" >"$VM/$1/.git/sgit"
	[ -z "$4" ] || printf '%s\n' "$4" >"$VM/$1/.git/sgit-url"
	git -C "$VM/$1" remote add origin "$3"
}
old_a="git://127.0.0.1:9418/$id_a/shadow.git"
new_a="git://192.168.64.1:9418/$id_a/shadow.git"
guest stale     "$id_a" "$old_a" "$old_a"
guest byhand    "$id_a" "git://tunnel.example:2222/$id_a/shadow.git" "$old_a"
guest stranger  0000000000000000 "git://elsewhere/0000000000000000/shadow.git" ''
guest norecord  "$id_a" "$old_a" ''

out=$( cd "$VM" && sh "$script" -n 2>&1 )
is 'the script changes nothing under -n' "$old_a" "$(git -C "$VM/stale" remote get-url origin)"

out=$( cd "$VM" && sh "$script" 2>&1 )
is 'it finds a tree below the directory it was given' \
	"$new_a" "$(git -C "$VM/stale" remote get-url origin)"
is 'it leaves a hand-set URL alone' \
	"git://tunnel.example:2222/$id_a/shadow.git" "$(git -C "$VM/byhand" remote get-url origin)"
is 'it ignores a tree from another store' \
	'git://elsewhere/0000000000000000/shadow.git' "$(git -C "$VM/stranger" remote get-url origin)"
is 'with no record it falls back to the shape of the URL' \
	"$new_a" "$(git -C "$VM/norecord" remote get-url origin)"
is 'and starts recording what it wrote' "$new_a" "$(cat "$VM/norecord/.git/sgit-url")"

# --- the bootstrap hands out the same record --------------------------------
#
# A tree created from `sgit gateway url` is the cross-machine case, so it is
# the one that most needs the record; without it the script can only go by the
# shape of the URL.
boot=$(sgit gateway url "$id_a" 2>/dev/null)
case "$boot" in
*"printf '%s\\n' '$new_a' > .git/sgit-url"*)
	pass 'the bootstrap records the URL it hands out' ;;
*) fail 'the bootstrap records the URL it hands out' "$boot" ;;
esac
case "$boot" in
*fix_one* | *MARKERS*)
	fail 'and expands no command of its own' "$boot" ;;
*) pass 'and expands no command of its own' ;;
esac

test_summary
