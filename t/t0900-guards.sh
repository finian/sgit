#!/usr/bin/env bash
# Refusals and rollback (spec 11): a failed creation must leave nothing behind.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home

count_repos() { ls "$SGIT_HOME/repos" 2>/dev/null | wc -l | tr -d ' '; }

# --- submodules (spec N2) ---------------------------------------------------

W="$TRASH/withsub"
work_init "$W"
printf '[submodule "x"]\n\tpath = x\n\turl = https://github.com/acme/private.git\n' >"$W/.gitmodules"
git -C "$W" add -A
git -C "$W" commit -qm 'add a submodule'
git clone -q --bare "$W" "$TRASH/withsub.git"

before=$(count_repos)
out=$(sgit clone "$TRASH/withsub.git" "$TRASH/sub" 2>&1) && rc=0 || rc=1
is 'a repository with submodules is refused' 1 "$rc"
case "$out" in
*submodule*) pass 'and the reason names submodules' ;;
*) fail 'and the reason names submodules' "$out" ;;
esac
is 'the half-built store is rolled back' "$before" "$(count_repos)"
not_ok 'and so is the working tree' test -e "$TRASH/sub"

# --- git-lfs (spec N7) ------------------------------------------------------

L="$TRASH/withlfs"
work_init "$L"
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >"$L/.gitattributes"
git -C "$L" add -A
git -C "$L" commit -qm 'use lfs'
git clone -q --bare "$L" "$TRASH/withlfs.git"

out=$(sgit clone "$TRASH/withlfs.git" "$TRASH/lfs" 2>&1) && rc=0 || rc=1
is 'a repository using git-lfs is refused' 1 "$rc"
case "$out" in
*lfs*) pass 'and the reason names lfs' ;;
*) fail 'and the reason names lfs' "$out" ;;
esac

# --- transport validation (spec 7.2.2) --------------------------------------

# With nothing configured the gateway binds to loopback, and loopback is a
# usable answer: it is the same-machine, separate-user arrangement, where the
# client really is here.
sgit init --transport gateway "$TRASH/gw" >/dev/null 2>&1
case "$(git -C "$TRASH/gw" remote get-url origin)" in
git://127.0.0.1:*) pass 'an unconfigured gateway transport advertises loopback' ;;
*) fail 'an unconfigured gateway transport advertises loopback' \
	"$(git -C "$TRASH/gw" remote get-url origin)" ;;
esac

# A wildcard is the one bind address nothing can dial, and it is caught before
# anything is created.
git config -f "$SGIT_HOME/config" gateway.listen 0.0.0.0
before=$(count_repos)
out=$(sgit init --transport gateway "$TRASH/gw-bad" 2>&1) && rc=0 || rc=1
is 'a wildcard bind address is refused' 1 "$rc"
case "$out" in
*gateway.advertise*) pass 'and the reason names gateway.advertise' ;;
*) fail 'and the reason names gateway.advertise' "$out" ;;
esac
is 'nothing was created' "$before" "$(count_repos)"
not_ok 'not even a working tree' test -e "$TRASH/gw-bad"
git config -f "$SGIT_HOME/config" --unset gateway.listen

out=$(sgit init --transport nonsense "$TRASH/bad" 2>&1) && rc=0 || rc=1
is 'an unknown transport is refused' 1 "$rc"

git config -f "$SGIT_HOME/config" gateway.advertise '192.168.64.1'
git config -f "$SGIT_HOME/config" gateway.port 9418
sgit init --transport gateway "$TRASH/gw2" >/dev/null 2>&1
id=$(id_of "$TRASH/gw2")
is 'a configured gateway produces a dialable URL' \
	"git://192.168.64.1:9418/$id/shadow.git" "$(git -C "$TRASH/gw2" remote get-url origin)"
ok 'and the shadow repository becomes exportable' \
	test -f "$(store_shadow "$id")/git-daemon-export-ok"
not_ok 'while the real mirror never is' \
	test -f "$(store_real "$id")/git-daemon-export-ok"

# --- the default transport (spec 10.1) --------------------------------------

sgit init "$TRASH/plain" >/dev/null 2>&1
plain=$(id_of "$TRASH/plain")
is 'without configuration a repository gets the helper' 'helper' \
	"$(git config -f "$SGIT_HOME/repos/$plain/config" --get sgit.transport)"

git config -f "$SGIT_HOME/config" sgit.defaultTransport gateway
sgit init "$TRASH/gw3" >/dev/null 2>&1
gid=$(id_of "$TRASH/gw3")
is 'sgit.defaultTransport decides what a new one gets' 'gateway' \
	"$(git config -f "$SGIT_HOME/repos/$gid/config" --get sgit.transport)"
case "$(git -C "$TRASH/gw3" remote get-url origin)" in
git://*) pass 'and the remote URL follows' ;;
*) fail 'and the remote URL follows' "$(git -C "$TRASH/gw3" remote get-url origin)" ;;
esac

sgit init --transport helper "$TRASH/gw4" >/dev/null 2>&1
is 'an explicit --transport still wins' 'helper' \
	"$(git config -f "$SGIT_HOME/repos/$(id_of "$TRASH/gw4")/config" --get sgit.transport)"

# Each repository keeps what it was created with; the default is only a
# template, which is why it is not called sgit.transport.
is 'an existing repository is unaffected' 'helper' \
	"$(git config -f "$SGIT_HOME/repos/$plain/config" --get sgit.transport)"

git config -f "$SGIT_HOME/config" sgit.defaultTransport nonsense
before=$(count_repos)
not_ok 'an unusable default is refused' sgit init "$TRASH/gw5"
is 'before anything is created' "$before" "$(count_repos)"
git config -f "$SGIT_HOME/config" --unset sgit.defaultTransport

out=$(sgit config --global sgit.transport helper 2>&1)
case "$out" in
*sgit.defaultTransport*) pass 'writing sgit.transport globally points at the right key' ;;
*) fail 'writing sgit.transport globally points at the right key' "$out" ;;
esac
out=$(sgit -C "$TRASH/gw3" config --repo sgit.defaultTransport gateway 2>&1)
case "$out" in
*'no effect'*) pass 'and writing the default per repository is flagged' ;;
*) fail 'and writing the default per repository is flagged' "$out" ;;
esac

# The URL names a host, a port and a random id, and nothing else.
url=$(git -C "$TRASH/gw2" remote get-url origin)
case "$url" in
*"$SGIT_HOME"*) fail 'the URL does not embed the store path' "$url" ;;
*) pass 'the URL does not embed the store path' ;;
esac

test_summary
