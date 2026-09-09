#!/usr/bin/env bash
#
# Host-side verification for the gateway (spec 14, items 16-21).
#
# The automated suite covers the gateway over loopback, which exercises every
# code path except the one thing that cannot be tested from inside a guest:
# binding to the address a virtual machine actually dials. Run this on the
# host, then follow the printed instructions inside the guest.
#
# Nothing here is destructive. It creates a scratch store under /tmp and
# removes it on exit.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PATH="$ROOT/bin:$PATH"
export PATH

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
ok() { printf '   [ok]   %s\n' "$*"; }
bad() { printf '   [FAIL] %s\n' "$*"; FAILED=1; }
FAILED=0

if [ "$(sysctl -n hw.model 2>/dev/null)" = 'VirtualMac2,1' ]; then
	printf 'This script must run on the HOST, not inside the guest.\n' >&2
	printf 'Inside the guest there is no vmnet bridge to bind to.\n' >&2
	exit 1
fi

say 'Step 1 -- network shape (spec 7.2.1)'
note 'Interfaces with an IPv4 address:'
for i in $(ifconfig -l 2>/dev/null); do
	a=$(ifconfig "$i" 2>/dev/null | awk '/[ \t]inet /{print $2; exit}')
	[ -n "$a" ] && printf '     %-12s %s\n' "$i" "$a"
done
DEF_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
note "Default route leaves through: ${DEF_IF:-unknown}"

# Pick the vmnet bridge, not any bridge. macOS ships bridge0 as the user's own
# Ethernet bridge and it normally carries no address at all; vmnet numbers its
# own from bridge100 up.
BRIDGE=""
BADDR=""
for i in $(ifconfig -l 2>/dev/null); do
	case "$i" in bridge*) ;; *) continue ;; esac
	a=$(ifconfig "$i" 2>/dev/null | awk '/[ \t]inet /{print $2; exit}')
	[ -n "$a" ] || continue
	case "$i" in
	bridge[1-9][0-9][0-9])
		BRIDGE="$i"
		BADDR="$a"
		break
		;;
	esac
	if [ -z "$BRIDGE" ]; then
		BRIDGE="$i"
		BADDR="$a"
	fi
done
if [ -z "$BADDR" ]; then
	bad 'no bridge interface with an IPv4 address was found.'
	note 'Apple vmnet creates bridge100 when the first virtual machine starts'
	note 'and removes it with the last one. Start the VM, then run this again.'
	note '(bridge0 without an address is macOS own Ethernet bridge, not vmnet.)'
	exit 1
fi
ok "vmnet bridge $BRIDGE holds $BADDR"
if [ "$BRIDGE" = "$DEF_IF" ]; then
	bad "$BRIDGE also carries the default route -- this looks bridged, not NAT."
	note 'The whole local network could reach the gateway. Use SSH instead of git://.'
	exit 1
fi
ok 'the bridge is not the default-route interface, so the LAN cannot route to it'

say 'Step 2 -- a scratch store'
SGIT_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sgit-hostcheck.XXXXXX")
SGIT_GLOBAL_CONFIG="$SGIT_HOME/config"
export SGIT_HOME SGIT_GLOBAL_CONFIG
trap 'sgit gateway stop >/dev/null 2>&1; rm -rf "$SGIT_HOME" "$WORK"' EXIT
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sgit-hostwork.XXXXXX")
PORT=29418

cat >"$SGIT_GLOBAL_CONFIG" <<CFG
[shadow]
	name = Dolores
	email = dolores@users.noreply.github.com
[real]
	email = alice@example.com
	name = Alice Zhang
[gateway]
	listen = $BRIDGE
	advertise = $BADDR
	port = $PORT
CFG
note "store: $SGIT_HOME"
note "gateway.listen is the interface name, so it survives an address change"

git init -q -b main "$WORK/up"
git -C "$WORK/up" config user.name Nobody
git -C "$WORK/up" config user.email nobody@example.invalid
printf 'hello\n' >"$WORK/up/file.txt"
git -C "$WORK/up" add -A
GIT_AUTHOR_NAME='Alice Zhang' GIT_AUTHOR_EMAIL=alice@example.com \
	GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL=alice@example.com \
	git -C "$WORK/up" commit -qm 'a commit by the real identity'
git clone -q --bare "$WORK/up" "$WORK/upstream.git"
if ! out=$(sgit clone --transport gateway --no-workdir "$WORK/upstream.git" 2>&1); then
	bad 'sgit clone failed:'
	printf '%s\n' "$out" | sed 's/^/          /'
	exit 1
fi
ID=$(ls "$SGIT_HOME/repos" | head -1)
ok "shadow repository $ID created"

say 'Step 3 -- refusals before the allowlist is narrowed (spec 7.2.1)'
if sgit gateway start >/dev/null 2>&1; then
	bad 'the gateway started while gateway.allowFrom was still the default'
	sgit gateway stop >/dev/null 2>&1
else
	ok 'binding a non-loopback address with the default allowFrom is refused'
fi
git config -f "$SGIT_GLOBAL_CONFIG" gateway.allowFrom "${BADDR%.*}.*"
note "gateway.allowFrom narrowed to ${BADDR%.*}.*"
note 'For a real deployment, narrow this to the single guest address; find it'
note 'on this host with: cat /var/db/dhcpd_leases'

say 'Step 4 -- start and verify the binding'
if ! sgit gateway start; then
	bad 'the gateway did not start'
	[ -s "$SGIT_HOME/gateway.log" ] && sed 's/^/          /' "$SGIT_HOME/gateway.log"
	exit 1
fi
ok 'the gateway started'
# The address is the field just before the (LISTEN) marker; the number of
# columns before it varies between lsof versions.
LISTEN=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk '/\(LISTEN\)/{print $(NF-1); exit}')
note "listening socket: ${LISTEN:-unknown}"
case "$LISTEN" in
"$BADDR:$PORT") ok 'bound to the bridge address, not the wildcard' ;;
\*:*) bad 'bound to the wildcard -- every interface can reach it' ;;
*) bad "unexpected listening address: $LISTEN" ;;
esac

LANADDR=$(ifconfig "${DEF_IF:-en0}" 2>/dev/null | awk '/[ \t]inet /{print $2; exit}')
if [ -n "$LANADDR" ]; then
	note "this host on the LAN is $LANADDR"
	note "from another machine on the LAN, this must FAIL:  nc -vz $LANADDR $PORT"
fi

say 'Step 5 -- what the gateway serves'
if git ls-remote "git://$BADDR:$PORT/$ID/real.git" >/dev/null 2>&1; then
	bad 'the real mirror is reachable'
else
	ok 'the real mirror is refused (no git-daemon-export-ok)'
fi
REFS=$(git ls-remote "git://$BADDR:$PORT/$ID/shadow.git" 2>&1)
case "$REFS" in
*refs/sgit/*) bad 'the map refs are advertised' ;;
*refs/heads/*) ok 'the shadow branches are served and the map refs are hidden' ;;
*) bad "unexpected: $REFS" ;;
esac

say 'Step 6 -- run these INSIDE the guest'
printf '\n'
sgit gateway url "$ID"
printf '\n'
note 'Then, still inside the guest, check that nothing identifying came along:'
note "  grep -rIl -e alice@example.com -e 'Alice Zhang' -e $WORK .git ; echo done"
note '  git log --format="%an <%ae>"      # must show Dolores only'
note '  git ls-remote origin              # must not list refs/sgit/*'
note 'Make a commit and push it, then back on the host:'
note "  git -C $WORK/upstream.git log -1 --format='%an <%ae>'   # must show Alice Zhang"
printf '\n'
note 'Press return when you are done; the scratch store is then removed.'
read -r _ || true

if [ "$FAILED" = 0 ]; then
	printf '\nall host-side checks passed\n'
else
	printf '\nsome host-side checks FAILED\n'
fi
exit "$FAILED"
