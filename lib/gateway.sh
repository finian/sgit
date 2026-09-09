# shellcheck shell=bash
#
# Gateway address resolution (spec 7.2.2). The address git-daemon binds on the
# host and the address written into the shadow repository's remote URL are two
# different things; conflating them breaks as soon as the bind address is a
# loopback, a wildcard, or an interface name.

[ -n "${SGIT_GATEWAY_SH:-}" ] && return 0
SGIT_GATEWAY_SH=1

# -> GATEWAY_ADVERTISE ("host:port")
gateway_resolve_advertise() {
	local adv port
	adv=$(_config_one gateway.advertise)
	port="${SGIT_OPT_PORT:-$(_config_one gateway.port)}"
	port="${port:-9418}"

	if [ -z "$adv" ]; then
		# What the daemon binds to is what a client dials, once an interface
		# name has been turned into the address behind it.
		#
		# A loopback address is a good answer, not a missing one: it means
		# the client is on this machine, which is how the store is put out
		# of an agent's reach without a virtual machine -- a separate user
		# account and a gateway on 127.0.0.1 (see the deployment tiers).
		gateway_resolve_listen
		case "$GATEWAY_LISTEN" in
		0.0.0.0 | ::)
			sgit_die "gateway.listen is $GATEWAY_LISTEN, which is not an address anything can dial; set gateway.advertise to the address a client should use"
			;;
		esac
		adv="$GATEWAY_LISTEN"
	fi

	case "$adv" in
	*:*) GATEWAY_ADVERTISE="$adv" ;;
	*) GATEWAY_ADVERTISE="$adv:$port" ;;
	esac
}

# --- bind address (spec 7.2.1) ----------------------------------------------

# The address of an interface, so that gateway.listen can name the interface
# rather than an address that changes.
_gateway_iface_addr() {
	local iface="$1" addr=""
	if command -v ifconfig >/dev/null 2>&1; then
		addr=$(ifconfig "$iface" 2>/dev/null | awk '/[ \t]inet /{print $2; exit}')
	fi
	if [ -z "$addr" ] && command -v ip >/dev/null 2>&1; then
		addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null |
			awk '{split($4, a, "/"); print a[1]; exit}')
	fi
	printf '%s' "$addr"
}

# The interface carrying the default route, i.e. the one facing the local
# network. Binding the gateway there would expose it to every machine on it.
_gateway_default_iface() {
	local iface=""
	if command -v route >/dev/null 2>&1; then
		iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
	fi
	if [ -z "$iface" ] && command -v ip >/dev/null 2>&1; then
		iface=$(ip route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
	fi
	printf '%s' "$iface"
}

# -> GATEWAY_LISTEN
gateway_resolve_listen() {
	local listen addr
	# A command-line --listen overrides the configuration for this run only.
	listen="${SGIT_OPT_LISTEN:-$(_config_one gateway.listen)}"
	listen="${listen:-127.0.0.1}"

	case "$listen" in
	*[!0-9.]*)
		case "$listen" in
		*:*) # an IPv6 literal, taken as given
			GATEWAY_LISTEN="$listen"
			return 0
			;;
		esac
		addr=$(_gateway_iface_addr "$listen")
		if [ -z "$addr" ]; then
			# On macOS the vmnet bridge is created when the first virtual
			# machine starts and torn down with the last one, so this is
			# the common case rather than a misconfiguration.
			sgit_die "interface $listen has no address; if it is a virtual machine bridge, start the virtual machine first, then start the gateway"
		fi
		GATEWAY_LISTEN="$addr"
		;;
	*)
		GATEWAY_LISTEN="$listen"
		;;
	esac
}

_gateway_is_loopback() {
	case "$1" in
	127.* | ::1 | localhost) return 0 ;;
	esac
	return 1
}

# The three refusals of spec 7.2.1. Each one exists because the gateway is an
# unauthenticated service that can make the upstream push run with the user's
# real credentials; reaching it must stay deliberate.
gateway_validate_listen() {
	local force="$1" allow iface ifaddr

	case "$GATEWAY_LISTEN" in
	0.0.0.0 | ::)
		[ "$force" = yes ] ||
			sgit_die "refusing to bind $GATEWAY_LISTEN: the gateway is unauthenticated; bind it to the address the client actually reaches, or pass --force-listen"
		sgit_warn "binding $GATEWAY_LISTEN: every interface on this machine can reach the gateway"
		;;
	esac

	if ! _gateway_is_loopback "$GATEWAY_LISTEN"; then
		iface=$(_gateway_default_iface)
		if [ -n "$iface" ]; then
			ifaddr=$(_gateway_iface_addr "$iface")
			if [ -n "$ifaddr" ] && [ "$ifaddr" = "$GATEWAY_LISTEN" ]; then
				[ "$force" = yes ] ||
					sgit_die "refusing to bind $GATEWAY_LISTEN: it is the address of $iface, the interface carrying the default route, so the whole local network could reach the gateway"
				sgit_warn "binding the default-route interface $iface; the local network can reach the gateway"
			fi
		fi

		allow=$(_config_all gateway.allowFrom)
		if [ -z "$allow" ] || [ "$allow" = '127.0.0.1' ]; then
			[ "$force" = yes ] ||
				sgit_die "refusing to bind the non-loopback address $GATEWAY_LISTEN while gateway.allowFrom still only permits loopback; set gateway.allowFrom to the client's address"
			sgit_warn "gateway.allowFrom has not been narrowed to the client"
		fi
	fi
}

# --- client authorisation ---------------------------------------------------

# Anything that can reach the gateway can make it push upstream with the user's
# real credentials, so the client address is checked before any work is done.
# Sibling virtual machines share the same bridge, which is why the default of
# loopback-only has to be narrowed deliberately.
gateway_ip_allowed() {
	local ip="$1" pat allow
	# Loopback is the default, not an unconditional exemption: once
	# gateway.allowFrom is set it replaces the default entirely, so an
	# operator can narrow access to one virtual machine and exclude
	# everything else, local processes included.
	allow=$(_config_all gateway.allowFrom)
	if [ -z "$allow" ]; then
		allow="127.0.0.1
::1"
	fi
	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		case "$ip" in
		$pat) return 0 ;;
		esac
	done <<PATTERNS
$allow
PATTERNS
	return 1
}

# --- daemon -----------------------------------------------------------------

# The resolvers end the process when they cannot answer, which is right for a
# command about to act on the answer and wrong for one that is only reporting.
# A subshell turns "cannot answer" back into an empty string, so that a status
# or a check keeps going instead of stopping mid-report.
_gateway_listen_or_empty() {
	(gateway_resolve_listen >/dev/null 2>&1 && printf '%s' "$GATEWAY_LISTEN") 2>/dev/null
}

_gateway_advertise_or_empty() {
	(gateway_resolve_advertise >/dev/null 2>&1 && printf '%s' "$GATEWAY_ADVERTISE") 2>/dev/null
}

gateway_pid_file() { printf '%s' "$SGIT_HOME/gateway.pid"; }

# git daemon takes its address and port as arguments, so a change to either
# does nothing until it is restarted -- while gateway.allowFrom and
# allowPush are read afresh by the access hook on every connection. Recording
# what it was started with is what lets the difference be pointed out instead
# of quietly waited on.
gateway_write_state() {
	printf 'listen=%s\nport=%s\n' "$1" "$2" >"$SGIT_HOME/gateway.state"
}

# What the running daemon was actually started with, read from the process
# rather than from anything sgit wrote down. --base-path cannot be changed
# after the daemon is up, and it is the one setting that never appears in the
# status output: a daemon serving a base path that no longer holds the
# repositories refuses every request with git's generic "access denied or
# repository not exported", which reads as a problem with the store.
#
# A base path containing a space would be cut short here. Reporting a wrong
# path is no worse than reporting none, and the comparison that uses this
# fails safe: it only speaks up when the two differ.
gateway_running_base_path() {
	local pid
	pid=$(gateway_running_pid) || return 1
	ps -o command= -p "$pid" 2>/dev/null |
		sed -n 's/.*--base-path=\([^ ]*\).*/\1/p' | sed -n 1p
}

# -> GATEWAY_RUN_LISTEN, GATEWAY_RUN_PORT
gateway_running_params() {
	GATEWAY_RUN_LISTEN=''
	GATEWAY_RUN_PORT=''
	[ -f "$SGIT_HOME/gateway.state" ] || return 1
	GATEWAY_RUN_LISTEN=$(sed -n 's/^listen=//p' "$SGIT_HOME/gateway.state")
	GATEWAY_RUN_PORT=$(sed -n 's/^port=//p' "$SGIT_HOME/gateway.state")
	[ -n "$GATEWAY_RUN_LISTEN" ] || return 1
	return 0
}

# How many repositories would need their remote URL rewritten if the
# advertised address changed.
gateway_repo_count() {
	local id n=0 saved_id="${SGIT_ID:-}" saved_cfg="${SGIT_REPO_CONFIG:-}"
	while read -r id; do
		[ -n "$id" ] || continue
		if [ "$(git config -f "$SGIT_HOME/repos/$id/config" --get sgit.transport 2>/dev/null)" = gateway ]; then
			n=$((n + 1))
		fi
	done <<IDS
$(store_list_ids)
IDS
	SGIT_ID="$saved_id"
	SGIT_REPO_CONFIG="$saved_cfg"
	printf '%s' "$n"
}

gateway_running_pid() {
	local pid
	pid=$(cat "$SGIT_HOME/gateway.pid" 2>/dev/null) || return 1
	[ -n "$pid" ] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	printf '%s' "$pid"
}

# git-daemon calls this before every connection with the service name, the
# repository path, the host names, the client address and the port. A non-zero
# exit declines the request.
gateway_access_hook() {
	local service="$1" path="$2" ip="${5:-}" id

	case "$path" in
	"$SGIT_HOME/repos/"*) id="${path#"$SGIT_HOME/repos/"}"; id="${id%%/*}" ;;
	*) printf 'not a shadow repository\n'; return 1 ;;
	esac
	[ -d "$SGIT_HOME/repos/$id" ] || { printf 'unknown repository\n'; return 1; }

	if ! gateway_ip_allowed "$ip"; then
		sgit_warn "refused $service for $id from $ip"
		printf 'not permitted\n'
		return 1
	fi

	# Read before store_use, so that this stays a property of the gateway
	# rather than of one repository -- there is only one daemon.
	case "$service" in
	receive-pack | git-receive-pack)
		if [ "$(_config_one gateway.allowPush)" = false ]; then
			sgit_warn "refused a push for $id from $ip: gateway.allowPush is false"
			printf 'pushing through this gateway is disabled\n'
			return 1
		fi
		;;
	esac

	store_use "$id"
	sgit_config_load

	# Same split as the local helper: a fetch must see current data or fail,
	# while a push gets a better error from pre-receive anyway.
	case "$service" in
	upload-pack | git-upload-pack)
		{ sync_down; } >&2 </dev/null || {
			printf 'the upstream is unreachable\n'
			return 1
		}
		;;
	*)
		{ sync_down; } >&2 </dev/null ||
			sgit_warn "could not refresh $id before $service; continuing"
		;;
	esac
	return 0
}

gateway_hook_path() { printf '%s' "$SGIT_HOME/access-hook"; }

gateway_write_hook() {
	local hook
	hook=$(gateway_hook_path)
	cat >"$hook" <<HOOK
#!/bin/sh
exec "$SGIT_ROOT/bin/sgit" gateway-access "\$@"
HOOK
	chmod +x "$hook"
}

gateway_start() {
	local force="$1" foreground="$2" port pid attempt

	if pid=$(gateway_running_pid); then
		sgit_die "the gateway is already running (pid $pid)"
	fi

	gateway_resolve_listen
	gateway_validate_listen "$force"
	port="${SGIT_OPT_PORT:-$(_config_one gateway.port)}"
	port="${port:-9418}"

	mkdir -p "$SGIT_HOME/repos"
	gateway_write_hook
	rm -f "$SGIT_HOME/gateway.pid"

	# --export-all is deliberately absent: only shadow.git carries the
	# git-daemon-export-ok marker, so real.git stays invisible even though it
	# sits under the same base path.
	set -- git daemon \
		--base-path="$SGIT_HOME/repos" \
		--access-hook="$(gateway_hook_path)" \
		--listen="$GATEWAY_LISTEN" \
		--port="$port" \
		--timeout=60 --init-timeout=30 --max-connections=8

	export SGIT_HOME SGIT_GLOBAL_CONFIG

	gateway_write_state "$GATEWAY_LISTEN" "$port"

	if [ "$foreground" = yes ]; then
		# The pid file is written in this mode too. A service manager owns
		# the process here, but `sgit gateway status` should still be able
		# to answer whether one is running.
		exec "$@" --pid-file="$SGIT_HOME/gateway.pid"
	fi

	# Retry for a short while rather than give up on the first refusal.
	# git daemon forks a child per connection, and a child inherits the
	# listening socket, so for a moment after the daemon is killed the port
	# can still be held by one that has not finished. That moment is exactly
	# when a restart happens.
	attempt=0
	while [ "$attempt" -lt 20 ]; do
		rm -f "$SGIT_HOME/gateway.pid"
		"$@" --detach --pid-file="$SGIT_HOME/gateway.pid" \
			>>"$SGIT_HOME/gateway.log" 2>&1 || true
		if gateway_wait_ready; then
			[ "$attempt" = 0 ] ||
				sgit_debug "the port was busy; bound on attempt $((attempt + 1))"
			break
		fi
		attempt=$((attempt + 1))
		sleep 0.5
	done

	if ! gateway_running_pid >/dev/null; then
		# --detach sends git daemon's own diagnostics to /dev/null, so the
		# log is empty exactly when it would be worth reading. Run the same
		# command once more in the foreground, briefly, purely to find out
		# what it objects to.
		sgit_tmpdir_init
		(
			"$@" >"$SGIT_TMPDIR/why" 2>&1 &
			_p=$!
			sleep 1
			kill "$_p" 2>/dev/null
			wait "$_p" 2>/dev/null
		) >/dev/null 2>&1 || true
		sgit_warn "the gateway did not come up:"
		[ -s "$SGIT_TMPDIR/why" ] && sed 's/^/  /' "$SGIT_TMPDIR/why" >&2
		sgit_die "see also $SGIT_HOME/gateway.log"
	fi

	printf 'gateway listening on %s:%s\n' "$GATEWAY_LISTEN" "$port" >&2
}

# Whether the daemon we just launched has come up. Short, because the caller
# retries: a longer wait here would only delay each retry.
gateway_wait_ready() {
	local i=0
	while [ "$i" -lt 20 ]; do
		if gateway_running_pid >/dev/null; then
			return 0
		fi
		i=$((i + 1))
		sleep 0.05
	done
	return 1
}

gateway_stop() {
	local pid i=0
	pid=$(gateway_running_pid) || sgit_die "the gateway is not running"
	kill "$pid" 2>/dev/null || sgit_die "cannot stop the gateway (pid $pid)"

	# Wait for it to actually go. Returning while it still holds the
	# listening socket makes `restart` a race with itself, and leaves anyone
	# who stops and starts by hand with the same problem.
	while [ "$i" -lt 100 ]; do
		kill -0 "$pid" 2>/dev/null || break
		i=$((i + 1))
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		sgit_die "the gateway (pid $pid) did not stop"
	fi

	rm -f "$SGIT_HOME/gateway.pid" "$SGIT_HOME/gateway.state"
	printf 'gateway stopped\n' >&2
}

gateway_status() {
	local pid id n=0 allow port listen advertise raw base

	port=$(_config_one gateway.port)
	port="${port:-9418}"

	if pid=$(gateway_running_pid); then
		printf 'state        running (pid %s)\n' "$pid"
	else
		printf 'state        not running\n'
	fi

	# The subshell exits non-zero when it cannot resolve, and that status
	# reaches the assignment; without the fallback, set -e would end the
	# report at exactly the moment it has something to report.
	listen=$(_gateway_listen_or_empty) || listen=''
	if [ -n "$listen" ]; then
		printf 'listen       %s:%s\n' "$listen" "$port"
	else
		raw=$(_config_one gateway.listen)
		printf 'listen       %s:%s  (unresolved: if that names an interface, the machine on it may not be running)\n' \
			"${raw:-127.0.0.1}" "$port"
	fi

	advertise=$(_gateway_advertise_or_empty) || advertise=''
	printf 'advertise    %s\n' "${advertise:-<unset; sgit gateway url would fail>}"


	allow=$(_config_all gateway.allowFrom | tr '\n' ' ')
	printf 'allowFrom    %s\n' "${allow:-127.0.0.1 ::1 (default)}"
	while read -r id; do
		[ -n "$id" ] || continue
		[ -f "$SGIT_HOME/repos/$id/shadow.git/git-daemon-export-ok" ] || continue
		n=$((n + 1))
	done <<IDS
$(store_list_ids)
IDS
	printf 'exported     %s repository(ies)\n' "$n"

	# Kept out of the field list above so that it reads as the exception it
	# is, rather than as another property of the gateway.
	if gateway_running_pid >/dev/null; then
		base=$(gateway_running_base_path) || base=''
		if [ -n "$base" ] && [ "$base" != "$SGIT_HOME/repos" ]; then
			printf '\nit is serving %s, and this store is %s\n' "$base" "$SGIT_HOME/repos"
			printf 'so every request is refused as "not exported"\n'
			printf 'restart it to serve this store:  sgit gateway restart\n'
		fi
		if gateway_running_params; then
			if [ "$GATEWAY_RUN_LISTEN:$GATEWAY_RUN_PORT" != "$listen:$port" ]; then
				printf '\nit is running on %s:%s and the configuration now says %s:%s\n' \
					"$GATEWAY_RUN_LISTEN" "$GATEWAY_RUN_PORT" "$listen" "$port"
				printf 'restart it to apply that:  sgit gateway restart\n'
			fi
		else
			# Nothing recorded: started before this was written down, or by
			# something other than sgit. Silence would look like agreement.
			printf '\nwhat this gateway was started with is not recorded, so it\n'
			printf 'cannot be compared with the configuration above.\n'
			printf 'restart it to be sure:  sgit gateway restart\n'
		fi
	fi
}

# --- pointing existing working trees at a changed gateway (spec 7.5) --------
#
# gateway.listen, gateway.port and gateway.advertise decide the URL sgit writes
# into a shadow working tree's origin, but only at the moment it writes it. A
# tree created before the change keeps the address the gateway used to be at,
# and git's error for that is a connection failure with no hint of the cause.
#
# Two forms, because the store and the working tree need not be on the same
# machine. On this one sgit can do it; on any other it cannot even see the
# tree, so it emits a script instead.

# Whether the URL now in a working tree is the one sgit put there.
#   $1 id, $2 the URL found, $3 the URL sgit recorded writing (may be empty)
#
# With a record the question is exact. The shape of the URL cannot answer it:
# a tunnel or a port forward keeps `/<id>/shadow.git` and changes only host and
# port, which is indistinguishable from a gateway that moved -- so a shape test
# would overwrite precisely the deliberate setting it is meant to protect.
#
# Without a record -- a tree bootstrapped by hand on another machine, or one
# created before sgit kept this -- the shape is all there is. That is the
# weaker guard, and the reason the emitted script has a dry run.
_gateway_url_is_ours() {
	if [ -n "$3" ]; then
		[ "$2" = "$3" ]
		return
	fi
	case "$2" in
	git://*/"$1"/shadow.git) return 0 ;;
	*) return 1 ;;
	esac
}

# Say so when the daemon is still serving the address the URLs just moved off.
_gateway_note_restart_needed() {
	local listen port
	gateway_running_pid >/dev/null 2>&1 || return 0
	gateway_running_params || return 0
	port=$(_config_one gateway.port)
	port="${port:-9418}"
	listen=$(_gateway_listen_or_empty) || listen=''
	[ -n "$listen" ] || return 0
	[ "$GATEWAY_RUN_LISTEN:$GATEWAY_RUN_PORT" != "$listen:$port" ] || return 0
	printf '\nthe gateway is still running on %s:%s, so the corrected URL will not\n' \
		"$GATEWAY_RUN_LISTEN" "$GATEWAY_RUN_PORT"
	printf 'connect until:  sgit gateway restart\n'
}

# $1 dry-run (yes/no), $2 a single id or empty for all.
gateway_fix_workdir_urls() {
	local dry="$1" only="$2"
	local id want have wrote verb n_up=0 n_cur=0 n_skip=0
	local saved_id="${SGIT_ID:-}" saved_cfg="${SGIT_REPO_CONFIG:-}"

	# Fails here rather than part way through the list if the address cannot
	# be worked out at all.
	gateway_resolve_advertise
	[ "$dry" = no ] || printf 'dry run: nothing is written\n'

	while read -r id; do
		[ -n "$id" ] || continue
		[ -z "$only" ] || [ "$only" = "$id" ] || continue
		store_use "$id"

		# A helper URL is `sgit::<id>`: no host, no port, nothing that a
		# gateway setting could invalidate.
		[ "$(repo_config_get sgit.transport)" = gateway ] || continue

		store_workdir_state
		case "$STORE_WD_STATE" in
		none)
			n_skip=$((n_skip + 1))
			printf '%-7s  %s: no working tree on this machine -- run --script where it lives\n' \
				skipped "$id"
			continue
			;;
		missing)
			n_skip=$((n_skip + 1))
			printf '%-7s  %s: %s is gone -- sgit restore %s would rebuild it\n' \
				skipped "$id" "$STORE_WD" "$id"
			continue
			;;
		foreign)
			n_skip=$((n_skip + 1))
			printf '%-7s  %s: %s is no longer this working tree\n' \
				skipped "$id" "$STORE_WD"
			continue
			;;
		esac

		workdir_remote_url
		want="$WORKDIR_URL"
		wrote=$(cat "$STORE_WD/.git/sgit-url" 2>/dev/null || true)
		have=$(git -C "$STORE_WD" remote get-url origin 2>/dev/null || true)

		if [ "$have" = "$want" ]; then
			n_cur=$((n_cur + 1))
			printf '%-7s  %s\n' current "$STORE_WD"
			# Catches up a tree that predates the record, or one corrected
			# by hand to the right address.
			[ "$dry" = yes ] || printf '%s\n' "$want" >"$STORE_WD/.git/sgit-url"
			continue
		fi
		if ! _gateway_url_is_ours "$id" "$have" "$wrote"; then
			n_skip=$((n_skip + 1))
			printf '%-7s  %s: origin is %s, set by hand -- left alone\n' \
				skipped "$STORE_WD" "${have:-unset}"
			continue
		fi

		n_up=$((n_up + 1))
		if [ "$dry" = yes ]; then
			# The state it is in, not an action taken: in a dry run none is.
			verb=stale
		else
			git -C "$STORE_WD" remote set-url origin "$want" ||
				sgit_die "cannot set the remote URL in $STORE_WD"
			printf '%s\n' "$want" >"$STORE_WD/.git/sgit-url"
			verb=updated
		fi
		printf '%-7s  %s\n         %s\n' "$verb" "$STORE_WD" "$want"
	done <<IDS
$(store_list_ids)
IDS

	SGIT_ID="$saved_id"
	SGIT_REPO_CONFIG="$saved_cfg"

	printf '%d updated, %d already current, %d skipped\n' "$n_up" "$n_cur" "$n_skip"
	[ "$n_up" = 0 ] || [ "$dry" = yes ] || _gateway_note_restart_needed
	return 0
}

# The same job, for working trees this machine cannot reach.
#
# What travels is repository ids and the gateway address -- both of which are
# already in the working trees the script is going to touch, in `.git/sgit` and
# in origin. Nothing about the store, the upstream or the real identity is in
# here, and t2800 holds that to be true.
gateway_workdir_url_script() {
	local only="$1" id n=0

	gateway_resolve_advertise

	cat <<'HEAD'
#!/bin/sh
# Generated by sgit. Points shadow working trees at the address the gateway
# now advertises, for trees on a machine sgit cannot see.
#
# Run it where the working trees live. It needs git and nothing else.
#
#   sh fix-urls.sh [-n] [<dir>...]     default: the current directory
#     -n   say what would change, change nothing
#
# Each directory is searched for shadow working trees, so one run over the
# parent of them all is enough.

# The URL each repository should be reached at now.
want_url() {
	case "$1" in
HEAD
	while read -r id; do
		[ -n "$id" ] || continue
		[ -z "$only" ] || [ "$only" = "$id" ] || continue
		store_use "$id"
		[ "$(repo_config_get sgit.transport)" = gateway ] || continue
		n=$((n + 1))
		printf '\t%s) printf %%s '\''git://%s/%s/shadow.git'\'' ;;\n' \
			"$id" "$GATEWAY_ADVERTISE" "$id"
	done <<IDS
$(store_list_ids)
IDS
	[ "$n" -gt 0 ] || sgit_die "no repository uses the gateway transport, so there is no URL to correct"

	cat <<'TAIL'
	*) return 1 ;;
	esac
}

fix_one() {
	dir="$1"
	id=$(cat "$dir/.git/sgit" 2>/dev/null) || return 0
	[ -n "$id" ] || return 0

	if ! new=$(want_url "$id"); then
		printf '%-7s  %s: not a repository this script knows about\n' skipped "$dir"
		return 0
	fi
	have=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
	if [ "$have" = "$new" ]; then
		printf '%-7s  %s\n' current "$dir"
		[ "$dry" = yes ] || printf '%s\n' "$new" >"$dir/.git/sgit-url"
		return 0
	fi

	# What sgit last wrote here, recorded beside the id it wrote at the same
	# time. Absent on a tree set up before sgit kept it.
	old=$(cat "$dir/.git/sgit-url" 2>/dev/null || true)

	# Is this the URL sgit wrote, or one set here on purpose? With a record
	# of what sgit wrote the answer is exact. Without one -- this tree was
	# set up by hand -- all that can be checked is that the id is in the
	# path, which a tunnel would also satisfy. Hence -n.
	if [ -n "$old" ]; then
		if [ "$have" != "$old" ]; then
			printf '%-7s  %s: origin is %s, set by hand -- left alone\n' \
				skipped "$dir" "${have:-unset}"
			return 0
		fi
	else
		case "$have" in
		git://*/"$id"/shadow.git) ;;
		*)
			printf '%-7s  %s: origin is %s, which sgit did not write\n' \
				skipped "$dir" "${have:-unset}"
			return 0
			;;
		esac
	fi

	if [ "$dry" = yes ]; then
		printf '%-7s  %s\n         %s\n' stale "$dir" "$new"
		return 0
	fi
	if git -C "$dir" remote set-url origin "$new"; then
		printf '%s\n' "$new" >"$dir/.git/sgit-url"
		printf '%-7s  %s\n         %s\n' updated "$dir" "$new"
	else
		printf '%-7s  %s\n' FAILED "$dir"
		failed=$((failed + 1))
	fi
}

dry=no
while [ $# -gt 0 ]; do
	case "$1" in
	-n) dry=yes; shift ;;
	--) shift; break ;;
	-*) echo "unknown option: $1" >&2; exit 2 ;;
	*) break ;;
	esac
done
[ "$dry" = no ] || printf 'dry run: nothing is written\n'

failed=0
[ $# -gt 0 ] || set -- .
for root in "$@"; do
	# Read in this shell rather than through a pipe, so that what the loop
	# counts is still there after it.
	while IFS= read -r marker; do
		[ -n "$marker" ] || continue
		fix_one "${marker%/.git/sgit}"
	done <<MARKERS
$(find "$root" -type f -path '*/.git/sgit' 2>/dev/null)
MARKERS
done
exit $((failed > 0))
TAIL
}
