# shellcheck shell=bash
#
# Self-examination (spec 9.1).
#
# Split in two, because the two sides can hold different things. The store side
# may name the upstream and the real identities -- it holds them anyway. The
# working-tree side must not, so it ships as a self-contained probe that judges
# by whitelist: it can report what is present and let a person decide whether
# any of it is theirs, but it never carries a list of what to look for.

[ -n "${SGIT_DOCTOR_SH:-}" ] && return 0
SGIT_DOCTOR_SH=1

DOCTOR_PROBLEMS=0

# Colour, so that a problem is visible without reading every line.
#
# Off when the output is not a terminal -- piped into grep, or redirected to a
# file to be sent somewhere -- off when NO_COLOR is set, and overridable either
# way with SGIT_COLOR=never|always. Only the labels are coloured, so the text
# stays as greppable as it was.
D_HEAD=''
D_OK=''
D_WARN=''
D_OFF=''

doctor_colours() {
	D_HEAD=''
	D_OK=''
	D_WARN=''
	D_OFF=''
	case "${SGIT_COLOR:-auto}" in
	never) return 0 ;;
	always) ;;
	*)
		[ -t 1 ] || return 0
		[ -z "${NO_COLOR:-}" ] || return 0
		;;
	esac
	D_HEAD=$(printf '\033[1m')
	D_OK=$(printf '\033[32m')
	D_WARN=$(printf '\033[1;31m')
	D_OFF=$(printf '\033[0m')
	return 0
}

d_head() { printf '\n%s%s%s\n' "$D_HEAD" "$*" "$D_OFF"; }
d_ok() { printf '  %s[ok]%s   %s\n' "$D_OK" "$D_OFF" "$*"; }
d_warn() {
	printf '  %s[warn]%s %s\n' "$D_WARN" "$D_OFF" "$*"
	DOCTOR_PROBLEMS=$((DOCTOR_PROBLEMS + 1))
}
d_note() { printf '  [note] %s\n' "$*"; }

# The filesystem a path sits on, so that a store on a share can be recognised.
_doctor_fstype() {
	local path="$1" line mp type best="" besttype=""
	while IFS= read -r line; do
		case "$line" in *' on '*) ;; *) continue ;; esac
		mp="${line#* on }"
		mp="${mp%% (*}"
		mp="${mp%% type *}"
		case "$line" in
		*' type '*) type="${line#* type }"; type="${type%% *}" ;;
		*) type="${line##*(}"; type="${type%%,*}"; type="${type%)}" ;;
		esac
		# A mount point of "/" would otherwise build the pattern "//*".
		case "$mp" in
		/) mp='' ;;
		*/) mp="${mp%/}" ;;
		esac
		case "$path/" in
		"$mp"/*)
			if [ "${#mp}" -ge "${#best}" ]; then
				best="$mp"
				besttype="$type"
			fi
			;;
		esac
	done <<MOUNTS
$(mount 2>/dev/null)
MOUNTS
	printf '%s' "$besttype"
}

# The filesystems where "another machine can see this too" is the default.
# Named in one place because two different things follow from it: a store on a
# share can be read from the other side, and a working tree on a share can be
# written from it.
_doctor_is_shared_fs() {
	case "$1" in
	AppleVirtIOFS | virtiofs | nfs | smbfs | cifs | 9p | vboxsf) return 0 ;;
	esac
	return 1
}

# Every hook sgit installs is a two-line shim that execs sgit by absolute path,
# written once -- when the gateway started, or when the repository was created
# -- and never revised. Moving or renaming the sgit tree breaks all of them at
# once, and the breakage is close to invisible: git-daemon replaces whatever an
# access hook prints with "access denied or repository not exported", which
# reads as a problem with the store, and a pre-receive that cannot start
# rejects a push while naming a path nobody recognises.
#
# So checking that the hook file is executable proves nothing. What it execs
# has to be there too, which is what these two read and test.
_doctor_hook_target() {
	sed -n 's/^exec "\([^"]*\)".*/\1/p' "$1" 2>/dev/null | sed -n 1p
}

# Run it rather than stat it. Resolving its own root and sourcing the library
# is most of what sgit does before a hook can report anything, and --version
# exercises exactly that: it is answered after the library is loaded and before
# any command touches a repository, the network, or the store lock.
_doctor_hook_starts() {
	[ -n "$1" ] || return 1
	"$1" --version >/dev/null 2>&1
}

doctor_store_placement() {
	local fstype mode

	d_head 'store placement (spec 2.2, 2.4)'
	d_note "store: $SGIT_HOME"

	fstype=$(_doctor_fstype "$SGIT_HOME")
	d_note "filesystem: ${fstype:-unknown}"
	if _doctor_is_shared_fs "$fstype"; then
		d_warn "the store is on a shared filesystem ($fstype); anything that can see the share can read the upstream URL, the real identities and the mapping table"
		d_note 'move the store to a path private to this machine'
	else
		d_ok 'the store is not on a shared filesystem'
	fi

	mode=$(stat -f '%Lp' "$SGIT_HOME" 2>/dev/null || stat -c '%a' "$SGIT_HOME" 2>/dev/null || printf '')
	if [ -n "$mode" ]; then
		case "$mode" in
		7[0-7][0-7])
			case "$mode" in
			*00) d_ok "the store is readable only by its owner (mode $mode)" ;;
			*) d_warn "the store is readable beyond its owner (mode $mode); chmod 700 it" ;;
			esac
			;;
		*) d_note "store mode $mode" ;;
		esac
	fi

	# Deployment tier: the same architecture gives very different guarantees
	# depending on whether the agent can simply read the store (spec 2.4).
	d_note 'if the agent runs as this user on this machine, isolation is'
	d_note 'only "does not volunteer it" -- reading the store is still possible.'
	d_note 'A separate user or a virtual machine turns that into a real boundary.'
}

doctor_config() {
	d_head 'configuration'
	if [ -n "${SGIT_SHADOW_NAME:-}" ] && [ -n "${SGIT_SHADOW_EMAIL:-}" ]; then
		d_ok "shadow identity: $SGIT_SHADOW_NAME <$SGIT_SHADOW_EMAIL>"
	else
		d_warn 'the shadow identity is not configured'
	fi
	case "$SGIT_SHADOW_EMAIL" in
	*noreply* | *invalid*) d_ok 'the shadow address cannot receive mail' ;;
	*) d_note 'the shadow address looks deliverable; a noreply domain avoids pointing at a real mailbox' ;;
	esac
	# Both halves count. Reporting on addresses alone said "nothing is
	# configured" to anyone who had listed only names.
	local emails names ecount ncount
	emails="${SGIT_REAL_EMAILS:-}"
	names="${SGIT_REAL_NAMES:-}"
	ecount=$(printf '%s\n' "$emails" | grep -c . || true)
	ncount=$(printf '%s\n' "$names" | grep -c . || true)

	if [ "$((ecount + ncount))" -eq 0 ]; then
		d_note 'nothing listed in [real]; the identity git is configured with is hidden, and nothing else'
	else
		d_ok "[real] hides $ecount further address pattern(s) and $ncount name pattern(s):"
		printf '%s\n%s\n' "$emails" "$names" | grep -v '^$' | sed 's/^/           /'
	fi
}

# The identity git itself would use for this repository -- what a push
# restores, and what a fetch has to hide.
doctor_identity() {
	local name email
	name=$(git -C "$SGIT_REAL" config user.name 2>/dev/null || true)
	email=$(git -C "$SGIT_REAL" config user.email 2>/dev/null || true)
	if [ -z "$name" ] || [ -z "$email" ]; then
		d_warn 'git has no user.name / user.email for this repository, so a push could not be attributed; set them globally or in the real mirror'
		return 0
	fi
	d_ok "pushes restore $name <$email> (from git configuration)"
	if [ "$email" = "$SGIT_SHADOW_EMAIL" ]; then
		d_warn 'that is the shadow address; the upstream would receive the pseudonym instead of you'
	fi
}

doctor_repo() {
	local id="$1" v hidden n missing counted transport expected actual wdfs target
	store_use "$id"
	transport=$(repo_config_get sgit.transport)

	d_head "repository $id (transport: ${transport:-helper})"

	[ -d "$SGIT_REAL" ] && d_ok 'the real mirror is present' || d_warn 'the real mirror is missing'
	[ -d "$SGIT_SHADOW" ] && d_ok 'the shadow repository is present' || d_warn 'the shadow repository is missing'

	if [ "$(cat "$SGIT_SHADOW/objects/info/alternates" 2>/dev/null)" = "$SGIT_REAL/objects" ]; then
		d_ok 'the shadow repository shares the real object database'
	else
		d_warn 'the alternates link is missing or wrong'
	fi

	for v in allowAnySHA1InWant allowTipSHA1InWant allowReachableSHA1InWant; do
		if [ "$(git -C "$SGIT_SHADOW" config "uploadpack.$v" 2>/dev/null)" = false ]; then
			d_ok "uploadpack.$v is off"
		else
			d_warn "uploadpack.$v is not false; a client could ask for an unrewritten object by name"
		fi
	done

	hidden=$(git -C "$SGIT_SHADOW" config --get-all transfer.hideRefs 2>/dev/null | tr '\n' ' ')
	case "$hidden" in
	*refs/sgit/map*)
		d_ok 'the mapping refs are hidden from clients'
		;;
	*)
		d_warn 'transfer.hideRefs does not cover refs/sgit/; the map ref names are real-side object ids and would be advertised'
		;;
	esac

	if [ -x "$SGIT_SHADOW/hooks/pre-receive" ]; then
		target=$(_doctor_hook_target "$SGIT_SHADOW/hooks/pre-receive")
		if _doctor_hook_starts "$target"; then
			d_ok 'the pre-receive hook is installed and starts'
		else
			d_warn "the pre-receive hook execs ${target:-a path it does not state}, which does not run; every push to this repository would be rejected"
			d_note 'the path is fixed when the repository is created, so it breaks when the sgit tree moves or is renamed'
			d_note "repair it by writing this into $SGIT_SHADOW/hooks/pre-receive, and chmod +x:"
			d_note '  #!/bin/sh'
			d_note "  exec \"$SGIT_ROOT/bin/sgit\" --id \"$id\" pre-receive"
		fi
	else
		d_warn 'the pre-receive hook is missing; pushes would bypass the upward path'
	fi

	if [ "$transport" = gateway ]; then
		[ -f "$SGIT_SHADOW/git-daemon-export-ok" ] &&
			d_ok 'the shadow repository is exported to the gateway' ||
			d_warn 'the gateway transport is configured but the repository is not exported'
	else
		[ -f "$SGIT_SHADOW/git-daemon-export-ok" ] &&
			d_warn 'this repository is exported to the gateway although its transport is the local helper' ||
			d_ok 'the repository is not exported'
	fi
	[ -f "$SGIT_REAL/git-daemon-export-ok" ] &&
		d_warn 'the REAL mirror is exported to the gateway' ||
		d_ok 'the real mirror is not exported'

	# Asked in one batch rather than once per entry. A mapping table has one
	# entry per commit in the history, so a process each meant minutes of
	# silence on a large repository -- which is indistinguishable from a
	# hang, and was reported as one.
	counted=$(git -C "$SGIT_SHADOW" for-each-ref --format='%(objectname)' refs/sgit/map |
		git -C "$SGIT_SHADOW" cat-file --batch-check 2>/dev/null |
		awk '{ n++ } $2 == "missing" { m++ } END { printf "%d %d\n", n + 0, m + 0 }')
	n=${counted%% *}
	missing=${counted##* }
	if [ "$missing" = 0 ]; then
		d_ok "$n mapping entries, all resolvable"
	else
		d_warn "$missing of $n mapping entries point at objects that are gone"
	fi

	store_workdir_state
	case "$STORE_WD_STATE" in
	ok)
		d_ok "working tree at $STORE_WD"
		# A tree on a share has a second machine able to write it, and
		# a file watcher over there is enough to leave .git/index
		# unopenable: git then falls back to an empty index and calls
		# every tracked file deleted. Whether anything is watching
		# cannot be seen from here, so this warns on the arrangement.
		wdfs=$(_doctor_fstype "$STORE_WD")
		if _doctor_is_shared_fs "$wdfs"; then
			d_warn "the working tree is on a shared filesystem ($wdfs); an editor or file watcher on the other side of the share can destroy its .git/index"
			d_note 'the sign is git calling every tracked file deleted while git ls-files prints nothing; git reset rebuilds it'
			d_note 'keep the tree off the share, or at least never open it from the other side'
		fi
		;;
	missing)
		d_warn "the working tree recorded at $STORE_WD is gone"
		d_note "recreate it with: sgit restore $id [<dir>]"
		d_note 'only what reached the shadow repository comes back'
		;;
	relative)
		d_warn "the working tree is recorded as the relative path $STORE_WD, which means something different from every directory"
		d_note "record where it really is: sgit --id $id config --repo sgit.workdir <absolute path>"
		;;
	foreign)
		d_warn "$STORE_WD is no longer this shadow working tree"
		d_note 'it may have been replaced; sgit restore would refuse to overwrite it'
		;;
	none)
		d_note 'no working tree was created here; it may live on another machine'
		[ "$transport" != gateway ] ||
			d_note 'if the gateway address changed, run there: sgit gateway fix-workdir-urls --script'
		;;
	esac

	# A working tree carries the URL it was created with. Changing what the
	# gateway advertises leaves it pointing at the old address, and only the
	# trees on this machine can be seen from here.
	if [ "$transport" = gateway ] && [ "$STORE_WD_STATE" = ok ]; then
		expected=$( (workdir_remote_url >/dev/null 2>&1 && printf '%s' "$WORKDIR_URL") 2>/dev/null ) ||
			expected=''
		actual=$(git -C "$STORE_WD" remote get-url origin 2>/dev/null || true)
		if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
			d_warn "the working tree still points at $actual"
			d_note "the gateway now advertises $expected"
			d_note 'correct every tree on this machine: sgit gateway fix-workdir-urls'
		fi
	fi

	doctor_identity

	if [ -n "$(repo_config_get upstream.fetchRemote)" ]; then
		d_ok "synchronising with remote '$(repo_config_get upstream.fetchRemote)'"
	else
		d_note 'local-only: a push stops at the real repository (spec G5 exception)'
	fi
}

# The access hook, exercised end to end rather than inspected.
#
# git-daemon hands the hook a repository path and refuses the connection on a
# non-zero exit. Giving it a path outside the store makes the hook take its
# very first branch and decline -- which is a complete run of the shim, of
# sgit's own startup and of the hook itself, and reaches no store, no lock and
# no network. A healthy hook therefore fails here, in one specific way, and
# anything else means it could not get that far.
doctor_gateway_hook() {
	local hook target out rc
	hook=$(gateway_hook_path)

	if [ ! -f "$hook" ]; then
		d_note 'no access hook is installed; it is written when the gateway starts'
		return 0
	fi
	if [ ! -x "$hook" ]; then
		d_warn "the access hook $hook is not executable; the gateway would refuse every request"
		d_note 'sgit gateway restart rewrites it'
		return 0
	fi

	target=$(_doctor_hook_target "$hook")
	out=$("$hook" upload-pack /sgit-doctor-probe probe probe 127.0.0.1 9418 2>&1) && rc=0 || rc=$?
	case "$rc:$out" in
	1:*'not a shadow repository'*)
		d_ok 'the access hook runs and declines a path outside the store'
		;;
	*)
		d_warn "the access hook does not run; the gateway would refuse every request as \"not exported\""
		d_note "it execs ${target:-a path it does not state}"
		[ -z "$out" ] || d_note "it said: $(printf '%s' "$out" | sed -n 1p)"
		d_note 'the path is fixed when the gateway starts, so it breaks when the sgit tree moves or is renamed'
		d_note 'sgit gateway restart rewrites it'
		;;
	esac
	return 0
}

doctor_gateway() {
	local listen allow port want base
	d_head 'gateway (spec 7.2.1)'
	if [ "$(_config_one gateway.allowPush)" = false ]; then
		d_note 'pushing through the gateway is disabled (gateway.allowPush)'
	fi
	if gateway_running_pid >/dev/null; then
		d_ok "running (pid $(gateway_running_pid))"
		# Fixed when the daemon started and unchangeable while it runs, so
		# a store that has moved since leaves a daemon serving nothing.
		base=$(gateway_running_base_path) || base=''
		if [ -z "$base" ]; then
			d_note 'what it is serving could not be read from the process'
		elif [ "$base" = "$SGIT_HOME/repos" ]; then
			d_ok "it is serving this store ($base)"
		else
			d_warn "it is serving $base, but this store is $SGIT_HOME/repos; every request would be refused as \"not exported\""
			d_note 'sgit gateway restart'
		fi
	else
		d_note 'not running'
	fi
	doctor_gateway_hook
	listen=$(_gateway_listen_or_empty) || listen=''
	if [ -n "$listen" ]; then
		d_note "bind address: $listen"
		case "$listen" in
		0.0.0.0 | ::) d_warn 'bound to the wildcard: every interface can reach it' ;;
		127.* | ::1) d_ok 'loopback only' ;;
		*)
			allow=$(_config_all gateway.allowFrom)
			if [ -z "$allow" ]; then
				d_warn "a non-loopback bind address with no gateway.allowFrom; every host that can route to $listen could make this machine push upstream with your credentials"
			else
				d_ok "client allowlist: $(printf '%s' "$allow" | tr '\n' ' ')"
			fi
			;;
		esac

		# Read after the addresses, so that the report says what is
		# configured before it says how the running process differs.
		port=$(_config_one gateway.port)
		port="${port:-9418}"
		if gateway_running_pid >/dev/null; then
			if gateway_running_params; then
				if [ "$GATEWAY_RUN_LISTEN:$GATEWAY_RUN_PORT" != "$listen:$port" ]; then
					d_warn "it is running on $GATEWAY_RUN_LISTEN:$GATEWAY_RUN_PORT, the configuration says $listen:$port"
					d_note 'sgit gateway restart'
				fi
			else
				d_warn 'what the running gateway was started with is not recorded, so it cannot be compared with the configuration'
				d_note 'sgit gateway restart'
			fi
		fi
	else
		d_note 'bind address unresolved (the interface may not exist while no guest is running)'
	fi
	return 0
}

doctor_store_side() {
	local id
	doctor_colours
	doctor_store_placement
	doctor_config
	while read -r id; do
		[ -n "$id" ] || continue
		doctor_repo "$id"
	done <<IDS
$(store_list_ids)
IDS
	doctor_gateway

	d_head 'the other half'
	d_note 'This covered the store only. The shadow working tree has to be'
	d_note 'examined from where it lives, which may be another machine:'
	d_note '  sgit doctor --emit-probe > probe.sh   # then run it inside the tree'

	printf '\n'
	if [ "$DOCTOR_PROBLEMS" = 0 ]; then
		printf '%sno problems found on the store side%s\n' "$D_OK" "$D_OFF"
	else
		printf '%s%d problem(s) found on the store side%s\n' \
			"$D_WARN" "$DOCTOR_PROBLEMS" "$D_OFF"
	fi
	return 0
}

# The working-tree probe. Self-contained POSIX shell, carries no secret, and
# needs neither sgit nor a store: it can be pasted into a virtual machine.
doctor_probe_text() {
	cat <<'PROBE'
#!/bin/sh
# sgit probe -- run this inside a shadow working tree.
#
# It reports what someone reading this repository could learn. It deliberately
# carries no list of real identities: it can only show what is here, and you
# decide whether any of it is yours. That is why it is safe to keep in a place
# the shadow repository's reader can see.

problems=0

# Colour unless the output is being captured, or NO_COLOR asks otherwise.
# SGIT_COLOR=never|always overrides either way.
head_c='' ok_c='' warn_c='' off_c=''
case "${SGIT_COLOR:-auto}" in
never) ;;
always) colour=yes ;;
*) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then colour=yes; fi ;;
esac
if [ "${colour:-no}" = yes ]; then
	head_c=$(printf '\033[1m')
	ok_c=$(printf '\033[32m')
	warn_c=$(printf '\033[1;31m')
	off_c=$(printf '\033[0m')
fi

head() { printf '\n%s%s%s\n' "$head_c" "$*" "$off_c"; }
ok() { printf '  %s[ok]%s   %s\n' "$ok_c" "$off_c" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$warn_c" "$off_c" "$*"; problems=$((problems + 1)); }
note() { printf '  [note] %s\n' "$*"; }

# The filesystem a path sits on: the longest mount point that prefixes it wins.
# Written out here rather than shelled out to, because the probe has to run
# where sgit is not installed. Pure shell, and no pipeline: this file defines a
# `head` of its own, and the loop has to keep state across iterations.
fstype_of() {
	_best='' _bt=''
	while IFS= read -r _line; do
		case "$_line" in *' on '*) ;; *) continue ;; esac
		_mp=${_line#* on }
		_mp=${_mp%% (*}
		_mp=${_mp%% type *}
		case "$_line" in
		*' type '*) _t=${_line#* type }; _t=${_t%% *} ;;
		*) _t=${_line##*(}; _t=${_t%%,*}; _t=${_t%)} ;;
		esac
		# A mount point of "/" would otherwise build the pattern "//*".
		case "$_mp" in /) _mp='' ;; */) _mp=${_mp%/} ;; esac
		case "$1/" in
		"$_mp"/*)
			if [ "${#_mp}" -ge "${#_best}" ]; then
				_best=$_mp
				_bt=$_t
			fi
			;;
		esac
	done <<MOUNTS
$(mount 2>/dev/null)
MOUNTS
	printf '%s' "$_bt"
}

git rev-parse --git-dir >/dev/null 2>&1 || {
	echo 'not inside a git repository' >&2
	exit 2
}
gitdir=$(git rev-parse --absolute-git-dir)

head 'where this tree lives'
fstype=$(fstype_of "$(pwd -P)")
note "filesystem: ${fstype:-unknown}"
case "$fstype" in
AppleVirtIOFS | virtiofs | nfs | smbfs | cifs | 9p | vboxsf)
	warn "this tree is on a shared filesystem ($fstype); whatever else mounts the share can read every file in it, and an editor or file watcher on the other side can destroy .git/index"
	note 'a destroyed index shows as git calling every tracked file deleted'
	note 'while git ls-files prints nothing; git reset rebuilds it, but a'
	note 'commit made in that state commits the deletions'
	note 'keep the tree off the share, or never open it from the other side'
	;;
*)
	ok 'this tree is not on a shared filesystem'
	;;
esac

head 'identity used here'
name=$(git config user.name)
email=$(git config user.email)
if [ -n "$name" ] && [ -n "$email" ]; then
	ok "commits are made as $name <$email>"
else
	warn 'user.name and user.email are not set for this repository'
fi
[ "$(git config commit.gpgSign)" = false ] &&
	ok 'commit signing is off' ||
	warn 'commit.gpgSign is not false; a signature would carry a key fingerprint'
[ "$(git config tag.gpgSign)" = false ] &&
	ok 'tag signing is off' ||
	warn 'tag.gpgSign is not false'
[ -x "$gitdir/hooks/pre-push" ] &&
	ok 'the pre-push guard is installed' ||
	warn 'the pre-push guard is missing'

head 'identities recorded in history'
others=$(git log --all --format='%an <%ae>%n%cn <%ce>' 2>/dev/null | sort -u |
	awk -v me="$name <$email>" '$0 != me')
if [ -z "$others" ]; then
	ok 'every commit carries this repository own identity'
else
	note 'these identities appear besides your own:'
	printf '%s\n' "$others" | sed 's/^/         /'
	note 'none of them should be yours -- check the list'
fi

signed=$(git log --all --format='%G?' 2>/dev/null | grep -vc '^N$' || true)
[ "${signed:-0}" -eq 0 ] &&
	ok 'no commit carries a signature' ||
	warn "$signed commit(s) carry a signature, which identifies a key"

head 'traces of an origin'
origin=$(git config remote.origin.url 2>/dev/null)
note "remote: ${origin:-none}"
# Everything git keeps about this repository, minus the object database
# (binary and large) and the sample hooks git ships, which are inert and
# contain URLs of their own -- reporting those would be a false alarm.
hits=$(find "$gitdir" -path "$gitdir/objects" -prune -o -name '*.sample' -prune -o \
	-type f -print 2>/dev/null |
	while IFS= read -r f; do
		grep -In -e 'https\{0,1\}://' -e 'ssh://' \
			-e '[A-Za-z0-9._-]@[A-Za-z0-9._-]*:' "$f" 2>/dev/null |
			sed "s|^|${f}:|"
	done | grep -v -F "${origin:-@@none@@}" || true)
if [ -z "$hits" ]; then
	ok 'nothing in the git metadata looks like another URL or address'
else
	warn 'these lines look like a URL or an address:'
	printf '%s\n' "$hits" | sed 's/^/         /'
fi

head 'what the remote advertises'
refs=$(git ls-remote origin 2>/dev/null) || refs=''
if [ -z "$refs" ]; then
	note 'the remote could not be reached; skipping'
else
	case "$refs" in
	*refs/sgit/*)
		warn 'the remote advertises sgit mapping refs, whose names are object ids from the real repository'
		;;
	*)
		ok 'the remote advertises branches and tags only'
		;;
	esac
fi

printf '\n'
if [ "$problems" = 0 ]; then
	printf '%sno problems found in this working tree%s\n' "$ok_c" "$off_c"
else
	printf '%s%d problem(s) found in this working tree%s\n' "$warn_c" "$problems" "$off_c"
fi
exit 0
PROBE
}
