#!/usr/bin/env bash
# The gateway end to end (spec 7.2): a shadow working tree created from
# nothing but a git:// URL, with no sgit on the client side.
#
# Runs over loopback here. On a real deployment the same path carries traffic
# from a virtual machine over the host's vmnet bridge; only the bind address
# differs, and that is covered by t1400.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
trap 'sgit gateway stop >/dev/null 2>&1; rm -rf "$TRASH"' EXIT

PORT=$((20000 + $$ % 20000))
git config -f "$SGIT_HOME/config" gateway.listen 127.0.0.1
git config -f "$SGIT_HOME/config" gateway.advertise 127.0.0.1
git config -f "$SGIT_HOME/config" gateway.port "$PORT"

make_upstream
sgit clone --transport gateway --no-workdir "$UPSTREAM" >/dev/null 2>&1
id=$(store_list_ids_first)
SHADOW=$(store_shadow "$id")

ok 'the shadow repository is exported' test -f "$SHADOW/git-daemon-export-ok"
not_ok 'the real mirror is not' test -f "$(store_real "$id")/git-daemon-export-ok"

if ! sgit gateway start >/dev/null 2>&1; then
	fail 'the gateway starts' "$(cat "$SGIT_HOME/gateway.log" 2>/dev/null)"
	test_summary
	exit 1
fi
pass 'the gateway starts'

URL="git://127.0.0.1:$PORT/$id/shadow.git"
is 'the advertised URL matches' "$URL" "$(sgit gateway url "$id" | head -1)"

# --- what the gateway will and will not serve -------------------------------

not_ok 'the real mirror cannot be fetched' git ls-remote "git://127.0.0.1:$PORT/$id/real.git"
refs=$(git ls-remote "$URL")
case "$refs" in
*refs/sgit/*) fail 'the map refs stay hidden over the network too' "$refs" ;;
*) pass 'the map refs stay hidden over the network too' ;;
esac

# --- a client with no sgit installed ----------------------------------------

P="$TRASH/proj"
git clone -q "$URL" "$P"
git -C "$P" config user.name Dolores
git -C "$P" config user.email dolores@users.noreply.github.com
printf '%s\n' "$id" >"$P/.git/sgit"
rm -rf "$P/.git/logs" "$P/.git/FETCH_HEAD"

is 'the clone carries the rewritten history' \
	"$(git -C "$UPSTREAM" rev-list --count main)" "$(git -C "$P" rev-list --count HEAD)"
is 'with the shadow identity' 'Dolores' "$(git -C "$P" log --format='%an' | sed -n 2p)"
leak=$(grep -rIl -e "$SGIT_HOME" -e "$UPSTREAM" -e 'alice@example.com' -e 'Alice Zhang' \
	"$P/.git" 2>/dev/null || true)
is 'and nothing identifying in its metadata' '' "$leak"

snippet=$(sgit gateway url "$id")
case "$snippet" in
*"$SGIT_HOME"* | *"$UPSTREAM"* | *alice@example.com* | *'Alice Zhang'*)
	fail 'the bootstrap snippet carries no secret' "$snippet" ;;
*) pass 'the bootstrap snippet carries no secret' ;;
esac

# --- fetch and push over the network ----------------------------------------

printf 'over the wire\n' >"$P/gateway.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'pushed through the gateway'
ok 'a push over git:// succeeds' git -C "$P" push -q origin main
is 'and reaches the upstream with the real identity' \
	'Alice Zhang <alice@example.com>' "$(git -C "$UPSTREAM" log -1 --format='%an <%ae>')"
is 'with the new file' 'over the wire' "$(git -C "$UPSTREAM" show main:gateway.txt)"

# The shadow side pushed since this working copy last looked, so catch up
# before adding to it; otherwise the push below fails and the pull assertion
# below would pass without proving anything.
git -C "$UPWORK" fetch -q origin
git -C "$UPWORK" reset -q --hard origin/main
commit_as "$UPWORK" 'Alice Zhang' 'alice@example.com' 'upstream moved on'
git -C "$UPWORK" push -q origin main
ok 'a pull over git:// picks the change up' git -C "$P" pull -q --ff-only
is 'and the new commit really arrived' \
	'upstream moved on' "$(git -C "$P" log -1 --format='%s')"
is 'rewritten on the way down' 'Dolores' "$(git -C "$P" log -1 --format='%an')"
is 'and no duplicate appears' \
	"$(git -C "$UPSTREAM" rev-list --count main)" "$(git -C "$P" rev-list --count HEAD)"

# --- the bootstrap on its own -----------------------------------------------
#
# `gateway url` prints a URL and then a script. A caller that means to run the
# script rather than read it should not have to know how many lines come
# first, so --bootstrap prints the script and nothing else.

full=$(sgit gateway url "$id" 2>/dev/null)
script=$(sgit gateway url --bootstrap "$id" 2>/dev/null)
is 'the URL line is what --bootstrap leaves out' \
	"$(printf '%s\n' "$full" | tail -n +2)" "$script"
case "$script" in
"$URL"*) fail 'and the script does not start with the URL' "$script" ;;
*) pass 'and the script does not start with the URL' ;;
esac
printf '%s\n' "$script" >"$TRASH/boot.sh"
ok 'what it prints is valid shell' sh -n "$TRASH/boot.sh"
( cd "$TRASH" && sh boot.sh from-bootstrap ) >"$TRASH/boot.out" 2>&1 ||
	cat "$TRASH/boot.out" >&2
ok 'and running it produces a working tree' test -d "$TRASH/from-bootstrap/.git"
is 'pointing at the gateway' "$URL" \
	"$(git -C "$TRASH/from-bootstrap" remote get-url origin 2>/dev/null)"


# --- the client allowlist gates the connection ------------------------------

git config -f "$SGIT_HOME/config" gateway.allowFrom '10.99.99.99'
not_ok 'a client outside allowFrom is refused' git ls-remote "$URL"
git config -f "$SGIT_HOME/config" --unset-all gateway.allowFrom
ok 'and allowed again once the list is cleared' git ls-remote "$URL"

# --- a read-only gateway ----------------------------------------------------

git config -f "$SGIT_HOME/config" gateway.allowPush false
printf 'blocked\n' >>"$P/gateway.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'should not get through'
not_ok 'with gateway.allowPush false a push is declined' git -C "$P" push -q origin main
ok 'while fetching still works' git ls-remote "$URL"
git config -f "$SGIT_HOME/config" --unset gateway.allowPush
ok 'and the same push works once it is allowed again' git -C "$P" push -q origin main

# --- a change that needs a restart, and one that does not -------------------
#
# git daemon takes its address and port as start-up arguments; the allowlist
# and the push switch are read by the access hook on every connection.

# A repository sgit created a working tree for, so that it knows where the
# tree is and can notice when its URL goes stale. The one above was cloned by
# hand from a --no-workdir store, which sgit has no record of.
sgit clone --transport gateway "$UPSTREAM" "$TRASH/withwd" >/dev/null 2>&1

out=$(sgit config gateway.port $((PORT + 7)) 2>&1)
case "$out" in
*'sgit gateway restart'*) pass 'changing the port says a restart is needed' ;;
*) fail 'changing the port says a restart is needed' "$out" ;;
esac
case "$out" in
*'still hold the old URL'*) pass 'and that existing working trees are stale' ;;
*) fail 'and that existing working trees are stale' "$out" ;;
esac
case "$(sgit gateway status 2>&1)" in
*'restart it to apply'*) pass 'status shows what it is actually running on' ;;
*) fail 'status shows what it is actually running on' "$(sgit gateway status 2>&1)" ;;
esac

# doctor sees the other half: the working tree still carries the old URL.
out=$(sgit doctor 2>&1)
case "$out" in
*'still points at'*) pass 'doctor reports the stale remote' ;;
*) fail 'doctor reports the stale remote' "$out" ;;
esac
case "$out" in
*'sgit gateway fix-workdir-urls'*) pass 'and gives the command that fixes it' ;;
*) fail 'and gives the command that fixes it' "$out" ;;
esac

git config -f "$SGIT_HOME/config" gateway.port "$PORT"
case "$(sgit gateway status 2>&1)" in
*'restart it to apply'*) fail 'putting the value back clears the warning' "$(sgit gateway status 2>&1)" ;;
*) pass 'putting the value back clears the warning' ;;
esac

# Removing a setting changes it as surely as writing one: the value falls back
# to a default, which may not be what the gateway is running with.
sgit config gateway.port $((PORT + 7))
out=$(sgit config --unset gateway.port 2>&1)
case "$out" in
*restart*) pass 'unsetting a gateway key advises a restart too' ;;
*) fail 'unsetting a gateway key advises a restart too' "$out" ;;
esac
git config -f "$SGIT_HOME/config" gateway.port "$PORT"

# Nothing recorded about the running process -- started before sgit wrote it
# down, or by something else. Saying nothing would look like agreement.
mv "$SGIT_HOME/gateway.state" "$SGIT_HOME/gateway.state.away"
case "$(sgit gateway status 2>&1)" in
*'not recorded'*) pass 'an unrecorded gateway is called out, not passed over' ;;
*) fail 'an unrecorded gateway is called out, not passed over' "$(sgit gateway status 2>&1)" ;;
esac
case "$(sgit doctor 2>&1)" in
*'not recorded'*) pass 'and doctor says the same' ;;
*) fail 'and doctor says the same' "$(sgit doctor 2>&1 | tail -5)" ;;
esac
mv "$SGIT_HOME/gateway.state.away" "$SGIT_HOME/gateway.state"

out=$(sgit config gateway.allowFrom '127.0.0.1' 2>&1)
case "$out" in
*'restart'*) fail 'the allowlist needs no restart' "$out" ;;
*) pass 'the allowlist needs no restart' ;;
esac
git config -f "$SGIT_HOME/config" --unset-all gateway.allowFrom

# --- lifecycle --------------------------------------------------------------

case "$(sgit gateway status)" in
*running*) pass 'status reports it running' ;;
*) fail 'status reports it running' "$(sgit gateway status)" ;;
esac
not_ok 'starting a second gateway is refused' sgit gateway start
# restart is stop-then-start, and works whether or not one is running.
ok 'restart works while it is running' sgit gateway restart
ok 'and it is reachable afterwards' git ls-remote "$URL"
ok 'the gateway stops' sgit gateway stop
ok 'restart works from stopped, too' sgit gateway restart
ok 'and it is reachable again' git ls-remote "$URL"
ok 'stopping it once more' sgit gateway stop
not_ok 'and is then unreachable' git ls-remote "$URL"
not_ok 'stopping twice is an error' sgit gateway stop

# --- under a service manager ------------------------------------------------
#
# --foreground keeps the process in the manager's hands, which is how the
# launchd and systemd units in the README run it. The pid file is written all
# the same, so that status can still answer.

FGPORT=$((PORT + 1))
git config -f "$SGIT_HOME/config" gateway.port "$FGPORT"
sgit gateway start --foreground >/dev/null 2>&1 &
fgpid=$!
i=0
while [ "$i" -lt 50 ]; do
	sgit gateway status 2>/dev/null | command grep -q running && break
	i=$((i + 1))
	sleep 0.1
done
case "$(sgit gateway status 2>&1)" in
*running*) pass 'a foreground gateway is still reported as running' ;;
*) fail 'a foreground gateway is still reported as running' "$(sgit gateway status 2>&1)" ;;
esac
ok 'and can be stopped' sgit gateway stop
wait "$fgpid" 2>/dev/null || true

test_summary
