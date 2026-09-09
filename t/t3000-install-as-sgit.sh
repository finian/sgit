#!/usr/bin/env bash
# The separate-account installer.
#
# What can be checked without root is the part worth checking: the files it
# generates, and that every command it would run carries the one flag whose
# absence quietly defeats the arrangement.
. "$(dirname "$0")/test-lib.sh"

INSTALL="$SGIT_SRC_ROOT/bin/install-as-sgit"

ok 'the installer is valid shell' sh -n "$INSTALL"
ok 'and is executable' test -x "$INSTALL"

plan=$("$INSTALL" --dry-run --yes \
	--name 'Quiet Fox' --email fox@example.invalid \
	--real-name 'Alice Zhang' --real-email alice@example.com 2>&1)

# --- the flag the whole thing turns on --------------------------------------
#
# Without -H, sudo leaves HOME as yours, sgit reads your git identity and puts
# the store in your own home -- which is precisely where this arrangement
# exists to keep it out of. It is one flag, it is easy to drop, and dropping it
# fails silently, so it is asserted rather than trusted.
bare=$(printf '%s\n' "$plan" | grep 'sudo' | grep -- '-u ' | grep -v -- '-H' || true)
if [ -z "$bare" ]; then
	pass 'every command it runs as the service account passes -H'
else
	fail 'every command it runs as the service account passes -H' "$bare"
fi

case "$plan" in
*'sudo -H -u sgit'*) pass 'and it does run things as that account' ;;
*) fail 'and it does run things as that account' "$plan" ;;
esac

# --- what a dry run must not do ---------------------------------------------

case "$plan" in
*'would run'*) pass 'a dry run says what it would do' ;;
*) fail 'a dry run says what it would do' "$plan" ;;
esac
not_ok 'and creates nothing' test -e /usr/local/lib/sgit/bin/sgit.dryrun
case "$plan" in
*'chmod 700'*) pass 'the store home is owner-only' ;;
*) fail 'the store home is owner-only' "$plan" ;;
esac

# Run twice, land in the same place: `cp -R bin dst/` nests the second time.
case "$plan" in
*'/bin/. '*) pass 'it copies contents, so a second run does not nest them' ;;
*) fail 'it copies contents, so a second run does not nest them' "$plan" ;;
esac

# --- the files it generates -------------------------------------------------

wrapper=$("$INSTALL" --print wrapper)
printf '%s\n' "$wrapper" >"$TRASH/as-sgit"
ok 'the wrapper is valid shell' sh -n "$TRASH/as-sgit"
case "$wrapper" in
*'exec sudo -H -u "$USER_NAME" "$SGIT" "$@"'*)
	pass 'and passes anything it does not handle straight through' ;;
*) fail 'and passes anything it does not handle straight through' "$wrapper" ;;
esac

unit=$("$INSTALL" --print service)
case "$unit" in
*'ExecStart='*'gateway start --foreground'*)
	pass 'the service unit keeps the gateway in the foreground' ;;
*) fail 'the service unit keeps the gateway in the foreground' "$unit" ;;
esac
case "$unit" in
*'Environment=HOME='*) pass 'and sets HOME for it' ;;
*) fail 'and sets HOME for it' "$unit" ;;
esac

plist=$("$INSTALL" --print plist)
printf '%s\n' "$plist" >"$TRASH/gateway.plist"
if command -v plutil >/dev/null 2>&1; then
	ok 'the launchd plist parses' plutil -lint "$TRASH/gateway.plist"
else
	pass 'the launchd plist parses (skipped: no plutil)'
fi
case "$plist" in
*'<key>UserName</key><string>sgit</string>'*)
	pass 'and runs as the service account' ;;
*) fail 'and runs as the service account' "$plist" ;;
esac

# --- names it is given ------------------------------------------------------

named=$("$INSTALL" --dry-run --yes --user builder --home /srv/builder \
	--lib-dir /opt/sgit --wrapper /opt/bin/as-builder \
	--name Fox --email fox@example.invalid \
	--real-name A --real-email a@example.com 2>&1)
case "$named" in
*'sudo -H -u builder /opt/sgit/bin/sgit'*) pass 'every name it takes is used' ;;
*) fail 'every name it takes is used' "$named" ;;
esac
case "$named" in
*'chmod 700 /srv/builder'*) pass 'including where the store goes' ;;
*) fail 'including where the store goes' "$named" ;;
esac

# --- what it refuses --------------------------------------------------------

out=$("$INSTALL" --dry-run --yes --name Fox --email alice@example.com \
	--real-name A --real-email alice@example.com 2>&1) && rc=0 || rc=1
is 'a pseudonym equal to the identity being hidden is refused' 1 "$rc"
case "$out" in
*'must differ'*) pass 'and says why' ;;
*) fail 'and says why' "$out" ;;
esac

out=$("$INSTALL" --dry-run --yes --real-name A --real-email a@example.com </dev/null 2>&1) &&
	rc=0 || rc=1
is 'no pseudonym and nowhere to ask is refused' 1 "$rc"
case "$out" in
*'--name'*) pass 'and names the option to pass' ;;
*) fail 'and names the option to pass' "$out" ;;
esac

out=$("$INSTALL" --nonsense 2>&1) && rc=0 || rc=1
is 'an unknown option is refused' 1 "$rc"

out=$("$INSTALL" --print nonsense 2>&1) && rc=0 || rc=1
is 'so is an unknown file to print' 1 "$rc"

# --- uninstall --------------------------------------------------------------
#
# The store cannot be rebuilt from anywhere else, so removing the service must
# not take it with it.
out=$("$INSTALL" --uninstall --dry-run --yes 2>&1)
case "$out" in
*'untouched'*) pass 'uninstall leaves the account and the store' ;;
*) fail 'uninstall leaves the account and the store' "$out" ;;
esac
case "$out" in
*'would run: sudo rm -f /usr/local/bin/as-sgit'*)
	pass 'and does remove the wrapper' ;;
*) fail 'and does remove the wrapper' "$out" ;;
esac
bad=$(printf '%s\n' "$out" | grep 'would run' | grep -E 'rm -rf|userdel|deleteUser' || true)
if [ -z "$bad" ]; then
	pass 'and runs nothing that could destroy the store'
else
	fail 'and runs nothing that could destroy the store' "$bad"
fi

# --- what it tells you about removing the rest ------------------------------
#
# The store is the one thing here that cannot be rebuilt: a shadow working
# tree holds the rewritten history, not the real one, and knows no upstream
# address. So uninstall has to say how to remove it, and say plainly what that
# costs, rather than leaving the user to work it out.
case "$out" in
*'CANNOT BE UNDONE'*) pass 'it warns that removing the store is final' ;;
*) fail 'it warns that removing the store is final' "$out" ;;
esac
case "$out" in
*'reached an upstream goes with it'*) pass 'and says what is lost with it' ;;
*) fail 'and says what is lost with it' "$out" ;;
esac
case "$(uname -s)" in
Darwin) want='sysadminctl -deleteUser sgit'; home=/var/sgit ;;
*) want='userdel -r sgit'; home=/var/lib/sgit ;;
esac
case "$out" in
*"$want"*) pass 'it gives the command to remove the account' ;;
*) fail 'it gives the command to remove the account' "$out" ;;
esac
# Anchored to the whole line: the line that empties the store without touching
# the account is `rm -rf <home>/.local/share/sgit`, and a loose match on
# `rm -rf <home>` would find that one instead and prove nothing.
if printf '%s\n' "$out" | grep -qE "^[[:space:]]+sudo rm -rf ${home}\$"; then
	pass 'and to remove the home, in case that command kept it'
else
	fail 'and to remove the home, in case that command kept it' "$out"
fi
case "$out" in
*'.local/share/sgit'*) pass 'and names where the store actually is' ;;
*) fail 'and names where the store actually is' "$out" ;;
esac
case "$out" in
*'keep the account'*) pass 'and how to empty the store but keep the account' ;;
*) fail 'and how to empty the store but keep the account' "$out" ;;
esac

# Removing the program is not removing the store, and must not be dressed up
# as though it were: it costs nothing and is undone by reinstalling.
case "$out" in
*'removing it costs nothing'*) pass 'the program is distinguished from the store' ;;
*) fail 'the program is distinguished from the store' "$out" ;;
esac

# It lists what is there before removing the tools that could list it -- advice
# to look at the store afterwards would be advice that cannot be taken.
inv=$("$INSTALL" --uninstall --dry-run --yes --user "$(id -un)" \
	--home "$HOME" --lib-dir "$SGIT_SRC_ROOT" 2>&1)
case "$inv" in
*'what is in the store'*ID*'removing the service'*)
	pass 'and it lists the store before removing anything' ;;
*) fail 'and it lists the store before removing anything' "$inv" ;;
esac

# --- the wrapper, driven for real -------------------------------------------
#
# What it does beyond changing user -- refusing a transport that cannot work,
# and making a working tree on this side of the boundary -- is the part with
# logic in it, so it is run rather than read. sudo is stubbed out: it drops
# `-H -u <someone>` and execs the rest, which is what it would do here anyway
# because the store and the caller are the same user in a test.
setup_sgit_home
PORT=$((20000 + $$ % 20000))
git config -f "$SGIT_HOME/config" gateway.listen 127.0.0.1
git config -f "$SGIT_HOME/config" gateway.advertise 127.0.0.1
git config -f "$SGIT_HOME/config" gateway.port "$PORT"
git config -f "$SGIT_HOME/config" sgit.defaultTransport gateway
make_upstream

mkdir -p "$TRASH/stub"
cat >"$TRASH/stub/sudo" <<'STUB'
#!/bin/sh
# Stands in for sudo. Fails if -H is missing, which is the flag whose absence
# would put the store in the caller's own home.
saw_h=no
while [ $# -gt 0 ]; do
	case "$1" in
	-H) saw_h=yes; shift ;;
	-u) shift 2 ;;
	-v) exit 0 ;;
	*) break ;;
	esac
done
if [ "$saw_h" = no ]; then
	echo 'stub sudo: called without -H' >&2
	exit 111
fi
exec "$@"
STUB
chmod +x "$TRASH/stub/sudo"

"$INSTALL" --print wrapper --user "$(id -un)" --lib-dir "$SGIT_SRC_ROOT" 	>"$TRASH/stub/as-sgit"
chmod +x "$TRASH/stub/as-sgit"
PATH="$TRASH/stub:$PATH"
export PATH

trap 'sgit gateway stop >/dev/null 2>&1; rm -rf "$TRASH"' EXIT
if sgit gateway start >/dev/null 2>&1; then
	pass 'a gateway is running for the wrapper to use'
else
	fail 'a gateway is running for the wrapper to use' "$(cat "$SGIT_HOME/gateway.log" 2>/dev/null)"
fi

# One command, both halves.
out=$(as-sgit clone "$UPSTREAM" "$TRASH/mine" 2>&1) && rc=0 || rc=1
is 'as-sgit clone makes a working tree in one command' 0 "$rc"
ok 'the working tree is there' test -d "$TRASH/mine/.git"
is 'and it is a shadow one' 	"$(cat "$TRASH/mine/.git/sgit" 2>/dev/null)" "$(store_list_ids_first)"
is 'pointing at the gateway, not at the store' 	"git://127.0.0.1:$PORT/$(store_list_ids_first)/shadow.git" 	"$(git -C "$TRASH/mine" remote get-url origin)"
is 'committing under the pseudonym' 'Dolores' "$(git -C "$TRASH/mine" config user.name)"
ok 'with the guard hook installed' test -x "$TRASH/mine/.git/hooks/pre-push"
ok 'and the record of the URL it was given' test -f "$TRASH/mine/.git/sgit-url"

# The whole point of the deployment: nothing in the working tree names the
# store or the upstream.
leak=$(grep -rlF "$UPSTREAM" "$TRASH/mine/.git" 2>/dev/null | grep -v '/index$' || true)
is 'and no trace of the upstream in it' '' "$leak"

# --- what the wrapper refuses -----------------------------------------------

# It would fail without being refused -- a helper repository is not exported,
# so the git:// clone at the end finds nothing -- but by then there is a store
# to clean up and the error names none of the reasons. What is asserted here
# is that it stops before any of that.
before=$(sgit list 2>/dev/null | wc -l | tr -d ' ')
out=$(as-sgit clone --transport helper "$UPSTREAM" "$TRASH/nope" 2>&1) && rc=0 || rc=1
is 'the helper transport is refused' 1 "$rc"
case "$out" in
*'cannot work here'*) pass 'and the message says why' ;;
*) fail 'and the message says why' "$out" ;;
esac
not_ok 'and no working tree was started' test -e "$TRASH/nope"
is 'and no store was made first' \
	"$before" "$(sgit list 2>/dev/null | wc -l | tr -d ' ')"

out=$(as-sgit config sgit.defaultTransport helper 2>&1) && rc=0 || rc=1
is 'so is making it the default' 1 "$rc"
is 'and the default is untouched' 'gateway' "$(as-sgit config sgit.defaultTransport 2>/dev/null)"

# With no directory given, the name comes from the URL, as `git clone` and
# `sgit clone` both do. The store side is asked for --no-workdir and so never
# works one out, which is why the wrapper has to.
( cd "$TRASH" && as-sgit clone "$UPSTREAM" >/dev/null 2>"$TRASH/derived.err" ) &&
	rc=0 || rc=1
is 'a clone with no directory takes its name from the URL' 0 "$rc"
ok 'and the tree is there under that name' test -d "$TRASH/upstream/.git"
case "$(cat "$TRASH/derived.err")" in
*'directory name matches the upstream'*)
	pass 'and says that the name is not hidden' ;;
*) fail 'and says that the name is not hidden' "$(cat "$TRASH/derived.err")" ;;
esac

out=$(as-sgit clone "$UPSTREAM" "$TRASH/upstream" 2>&1) && rc=0 || rc=1
is 'a directory that already exists is refused' 1 "$rc"

# --- and what it passes straight through ------------------------------------

out=$(as-sgit clone --no-workdir "$UPSTREAM" 2>&1) && rc=0 || rc=1
is '--no-workdir still means store only' 0 "$rc"
out=$(as-sgit list 2>&1)
case "$out" in
*ID*) pass 'anything else reaches sgit unchanged' ;;
*) fail 'anything else reaches sgit unchanged' "$out" ;;
esac

# init has the same shape, and the same two halves.
out=$(as-sgit init "$TRASH/fresh" 2>&1) && rc=0 || rc=1
is 'as-sgit init makes a working tree too' 0 "$rc"
ok 'which is a git repository' test -d "$TRASH/fresh/.git"
is 'with the pseudonym set' 'Dolores' "$(git -C "$TRASH/fresh" config user.name)"


# --- running it a second time -----------------------------------------------
#
# The reason to run it again is to install a new version of sgit, and that must
# not disturb what is already there. The pseudonym in particular: repositories
# already made carry it, so changing it as a side effect of an update would
# leave the two sides disagreeing about who they belong to. The identity to
# hide is read from your own git config on a first run, so a run months later
# would quietly pick up whatever it says then.

UP="$TRASH/up2"
mkdir -p "$UP/stub" "$UP/shome" "$UP/myhome" "$UP/lib" "$UP/src"
cat >"$UP/stub/sudo" <<'STUB'
#!/bin/sh
h=no
while [ $# -gt 0 ]; do
	case "$1" in -H) h=yes; shift ;; -u) shift 2 ;; -v) exit 0 ;; *) break ;; esac
done
[ "$h" = no ] || HOME="$STUB_TARGET_HOME"
export HOME
exec "$@"
STUB
printf '#!/bin/sh\nexit 0\n' >"$UP/stub/chown"
printf '#!/bin/sh\nexit 0\n' >"$UP/stub/launchctl"
printf '#!/bin/sh\nexit 0\n' >"$UP/stub/systemctl"
cat >"$UP/stub/install" <<'STUB'
#!/bin/sh
mode=644; src=''; dst=''
while [ $# -gt 0 ]; do
	case "$1" in
	-m) mode="$2"; shift 2 ;;
	-o | -g) shift 2 ;;
	*) if [ -z "$src" ]; then src="$1"; else dst="$1"; fi; shift ;;
	esac
done
cp "$src" "$dst" && chmod "$mode" "$dst"
STUB
chmod +x "$UP/stub"/*
cp -R "$SGIT_SRC_ROOT/bin" "$SGIT_SRC_ROOT/lib" "$UP/src/"

UPCFG="$UP/shome/.local/share/sgit/config"
installer_run() {
	(
		PATH="$UP/stub:$PATH"
		HOME="$UP/myhome"
		STUB_TARGET_HOME="$UP/shome"
		export PATH HOME STUB_TARGET_HOME
		# This file's own store must not be inherited: the installed sgit
		# has to find the one belonging to the account it is setting up.
		unset SGIT_HOME SGIT_GLOBAL_CONFIG
		cd "$UP/src" &&
			./bin/install-as-sgit -y --user "$(id -un)" --home "$UP/shome" \
				--lib-dir "$UP/lib" --wrapper "$UP/stub/as-sgit" \
				--service-file "$UP/gateway.service" "$@" </dev/null
	) 2>&1
}

HOME="$UP/myhome" git config --global user.name 'My Real Name'
HOME="$UP/myhome" git config --global user.email me@example.com
installer_run --name 'Quiet Fox' --email fox@example.invalid >/dev/null 2>&1
is 'a first run sets the pseudonym' \
	'Quiet Fox' "$(git config -f "$UPCFG" shadow.name)"
is 'and the identity to hide, from your own git config' \
	'My Real Name' "$(git config -f "$UP/shome/.gitconfig" user.name)"

# A new version: one file added, one gone, and your own name changed since.
echo '# added in this version' >"$UP/src/lib/newthing.sh"
printf '#!/bin/sh\necho stale\n' >"$UP/lib/lib/goneaway.sh"
HOME="$UP/myhome" git config --global user.name 'Renamed Since'

out=$(installer_run) && rc=0 || rc=1
is 'a second run with no identity given succeeds' 0 "$rc"
is 'and leaves the pseudonym alone' \
	'Quiet Fox' "$(git config -f "$UPCFG" shadow.name)"
is 'and does not pick up the name you have since changed to' \
	'My Real Name' "$(git config -f "$UP/shome/.gitconfig" user.name)"
case "$out" in
*'updating sgit in place'*) pass 'and says it is an update, not an install' ;;
*) fail 'and says it is an update, not an install' "$out" ;;
esac

ok 'the new version of a file arrives' test -f "$UP/lib/lib/newthing.sh"
not_ok 'and one the new version does not have is removed' \
	test -e "$UP/lib/lib/goneaway.sh"
ok 'the directories are not nested by the second copy' test -f "$UP/lib/bin/sgit"
not_ok 'no bin/bin' test -e "$UP/lib/bin/bin"

# The access hook runs the installed sgit on every incoming connection, so the
# gateway has to be down while that file is replaced -- not merely restarted
# afterwards.
stop_at=$(printf '%s\n' "$out" | grep -n '^==> stopping the gateway' | cut -d: -f1)
# Anchored to the step heading: the plan above says "updating sgit in place",
# which a looser match finds first and which comes before everything.
copy_at=$(printf '%s\n' "$out" | grep -n '^==> sgit in ' | cut -d: -f1)
if [ -n "$stop_at" ] && [ -n "$copy_at" ] && [ "$stop_at" -lt "$copy_at" ]; then
	pass 'the gateway is stopped before its own program is replaced'
else
	fail 'the gateway is stopped before its own program is replaced' "$out"
fi

# Changing it on purpose is allowed, and said out loud.
out=$(installer_run --name 'Other Fox' --email other@example.invalid)
is 'an update given a new pseudonym does change it' \
	'Other Fox' "$(git config -f "$UPCFG" shadow.name)"
case "$out" in
*'changing the pseudonym'*) pass 'and warns that the two sides will disagree' ;;
*) fail 'and warns that the two sides will disagree' "$out" ;;
esac

installer_run --real-name 'Deliberate' --real-email d@example.com >/dev/null 2>&1
is 'and an identity to hide given on purpose is taken' \
	'Deliberate' "$(git config -f "$UP/shome/.gitconfig" user.name)"


test_summary
