#!/usr/bin/env bash
# Gateway address resolution and the bind refusals (spec 7.2.1, 7.2.2).
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
. "$SGIT_SRC_ROOT/lib/common.sh"
. "$SGIT_SRC_ROOT/lib/config.sh"
. "$SGIT_SRC_ROOT/lib/gateway.sh"

cfg() { git config -f "$SGIT_HOME/config" "$@"; }
clear_gw() { cfg --remove-section gateway 2>/dev/null || true; }

# Run something that may call sgit_die, and capture what it said.
try() { ( "$@" ) 2>&1; }
try_rc() { ( "$@" ) >/dev/null 2>&1 && printf 0 || printf 1; }

# --- advertise (spec 7.2.2) -------------------------------------------------

# What the daemon binds to is what a client dials, so an unset advertise is
# derived from listen rather than refused. Loopback is a real answer: it is the
# same-machine, separate-user arrangement.
clear_gw
gateway_resolve_advertise
is 'a loopback listen advertises itself' '127.0.0.1:9418' "$GATEWAY_ADVERTISE"

cfg gateway.listen 0.0.0.0
is 'only a wildcard has no answer' 1 "$(try_rc gateway_resolve_advertise)"
case "$(try gateway_resolve_advertise)" in
*gateway.advertise*) pass 'and the message names the setting to fix' ;;
*) fail 'and the message names the setting to fix' "$(try gateway_resolve_advertise)" ;;
esac
clear_gw

clear_gw
cfg gateway.listen 192.168.64.1
gateway_resolve_advertise
is 'a concrete listen address is advertised as itself' '192.168.64.1:9418' "$GATEWAY_ADVERTISE"

cfg gateway.port 29418
gateway_resolve_advertise
is 'the configured port is used' '192.168.64.1:29418' "$GATEWAY_ADVERTISE"

cfg gateway.advertise 'sgit-gateway'
gateway_resolve_advertise
is 'a host name is advertised with the port appended' 'sgit-gateway:29418' "$GATEWAY_ADVERTISE"

cfg gateway.advertise 'sgit-gateway:1234'
gateway_resolve_advertise
is 'an explicit port in advertise wins' 'sgit-gateway:1234' "$GATEWAY_ADVERTISE"

# An interface name resolves, so the common cross-machine setup needs only
# gateway.listen: the address behind the interface is what the other machine
# dials.
clear_gw
loop_iface=''
for i in lo0 lo; do
	if [ -n "$(_gateway_iface_addr "$i")" ]; then loop_iface="$i"; break; fi
done
if [ -n "$loop_iface" ]; then
	cfg gateway.listen "$loop_iface"
	gateway_resolve_advertise
	is 'an interface name advertises the address behind it' \
		"$(_gateway_iface_addr "$loop_iface"):9418" "$GATEWAY_ADVERTISE"
else
	pass 'an interface name advertises the address behind it (no loopback interface found; skipped)'
fi

clear_gw
cfg gateway.listen 'sgit-nonexistent0'
is 'an interface with no address still cannot' 1 "$(try_rc gateway_resolve_advertise)"

# --- listen resolution ------------------------------------------------------

clear_gw
gateway_resolve_listen
is 'the default listen address is loopback' '127.0.0.1' "$GATEWAY_LISTEN"

cfg gateway.listen 'sgit-nonexistent0'
out=$(try gateway_resolve_listen)
is 'an interface with no address is an error' 1 "$(try_rc gateway_resolve_listen)"
case "$out" in
*'start the virtual machine first'*) pass 'and the message says why it is usually missing' ;;
*) fail 'and the message says why it is usually missing' "$out" ;;
esac

# --- the three refusals (spec 7.2.1) ----------------------------------------

clear_gw
GATEWAY_LISTEN=0.0.0.0
is 'binding the wildcard is refused' 1 "$(try_rc gateway_validate_listen no)"
is 'unless forced'                   0 "$(try_rc gateway_validate_listen yes)"

GATEWAY_LISTEN=192.0.2.1
is 'a non-loopback address with the default allowFrom is refused' \
	1 "$(try_rc gateway_validate_listen no)"
case "$(try gateway_validate_listen no)" in
*allowFrom*) pass 'and the message names allowFrom' ;;
*) fail 'and the message names allowFrom' "$(try gateway_validate_listen no)" ;;
esac

cfg gateway.allowFrom '192.168.64.*'
is 'once allowFrom is narrowed it is permitted' 0 "$(try_rc gateway_validate_listen no)"

GATEWAY_LISTEN=127.0.0.1
clear_gw
is 'loopback needs no allowlist' 0 "$(try_rc gateway_validate_listen no)"

# --- the client allowlist ---------------------------------------------------

clear_gw
ok     'loopback is allowed by default'    gateway_ip_allowed 127.0.0.1
not_ok 'and nothing else is'                gateway_ip_allowed 192.168.64.2

cfg gateway.allowFrom '192.168.64.2'
ok     'an explicit address is allowed'     gateway_ip_allowed 192.168.64.2
not_ok 'a sibling on the same bridge is not' gateway_ip_allowed 192.168.64.3
# An explicit list replaces the default rather than extending it, so access can
# be narrowed to one machine.
not_ok 'and loopback is no longer implied'  gateway_ip_allowed 127.0.0.1

cfg gateway.allowFrom '192.168.64.*'
ok     'a glob covers the bridge'           gateway_ip_allowed 192.168.64.3
not_ok 'but not another network'            gateway_ip_allowed 10.0.0.5

# --- reporting must survive what it is reporting on -------------------------
#
# Reported as: `sgit gateway status` showing "listen 127.0.0.1:" with no port.
# The missing port turned out to be the small half of it -- the resolvers end
# the process when they cannot answer, so the report stopped wherever the first
# unanswerable question was, which is the normal state before anything is set
# up.

lines() { sgit gateway status 2>/dev/null | grep -c .; }
field() { sgit gateway status 2>/dev/null | sed -n "s/^$1 *//p"; }

clear_gw
ok 'status works with nothing configured at all' sgit gateway status
is 'and reports every line' 5 "$(lines)"
is 'including the default port' '127.0.0.1:9418' "$(field listen)"
is 'and derives the advertised address from it' '127.0.0.1:9418' "$(field advertise)"

cfg gateway.listen 'sgit-nonexistent0'
ok 'status works when the bind address cannot be resolved' sgit gateway status
is 'and still reports every line' 5 "$(lines)"
case "$(field listen)" in
*unresolved*) pass 'saying so, rather than stopping' ;;
*) fail 'saying so, rather than stopping' "$(field listen)" ;;
esac
ok 'and doctor survives it too' sh -c 'sgit doctor >/dev/null 2>&1 || true'
# Whatever it concludes, it has to get as far as concluding something.
case "$(sgit doctor 2>&1)" in
*'on the store side'*) pass 'reaching the end of its report' ;;
*) fail 'reaching the end of its report' "$(sgit doctor 2>&1 | tail -3)" ;;
esac

clear_gw
cfg gateway.listen 127.0.0.1
cfg gateway.advertise 192.168.64.1
cfg gateway.port 29418
is 'a configured port is shown'      '127.0.0.1:29418'   "$(field listen)"
is 'and the advertised address too'  '192.168.64.1:29418' "$(field advertise)"

test_summary
