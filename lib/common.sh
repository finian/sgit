# shellcheck shell=bash
#
# Common helpers shared by every sgit component.
#
# stdio discipline (spec 6.6): whenever sgit runs as a remote helper, as a
# git-daemon access hook, or as a pre-receive hook, stdout carries the git pack
# protocol. A single stray byte on it corrupts the stream and produces failures
# that are very hard to diagnose. Every diagnostic in sgit therefore goes to
# stderr, and no helper here ever writes to stdout.

[ -n "${SGIT_COMMON_SH:-}" ] && return 0
SGIT_COMMON_SH=1

# Byte-exact string handling. Object payloads are arbitrary bytes; under a
# multibyte locale ${#s} counts characters and case patterns match by
# character, both of which would silently corrupt rewrites.
LC_ALL=C
export LC_ALL

# Give a command back the locale sgit was invoked with.
#
# The C locale above is for sgit's own string handling, not for anything a
# person reads. git writes commit messages out as bytes either way, but its
# pager does not: under a C locale `less` escapes every byte above ASCII, so a
# message in any language but English arrives as rubble. Commands that hand
# their output straight to the user restore the caller's locale first.
#
# The values are captured by bin/sgit before this file is sourced, since
# sourcing it is what replaces them.
sgit_restore_locale() {
	if [ -n "${SGIT_CALLER_LC_ALL:-}" ]; then
		LC_ALL="$SGIT_CALLER_LC_ALL"
		export LC_ALL
	else
		unset LC_ALL
	fi
	if [ -n "${SGIT_CALLER_LC_CTYPE:-}" ]; then
		LC_CTYPE="$SGIT_CALLER_LC_CTYPE"
		export LC_CTYPE
	fi
	if [ -n "${SGIT_CALLER_LANG:-}" ]; then
		LANG="$SGIT_CALLER_LANG"
		export LANG
	fi
}

NL='
'

# What sgit says about itself, with the store kept out of it when the listener
# is not entitled to hear it.
#
# Run as the shadow repository's pre-receive hook, everything these three write
# is relayed by git to whoever pushed -- the shadow side, which must not learn
# where the store is (spec 6.4). Messages are otherwise written for the store
# side, where naming the mirror that failed is the most useful thing they can
# do, so the substitution happens here, once, rather than by asking every
# message to be careful about where it might be read. Away from that boundary
# it is a no-op, and `sgit doctor` therefore still reports paths in full.
sgit_hide_paths() {
	local s="$*"
	[ -n "${SGIT_HOOK_BOUNDARY:-}" ] || { printf '%s' "$s"; return 0; }
	# An empty prefix would match everywhere, so neither is assumed set.
	[ -z "${SGIT_HOME:-}" ] || s="${s//"$SGIT_HOME"/<the store>}"
	[ -z "${SGIT_ROOT:-}" ] || s="${s//"$SGIT_ROOT"/<the sgit installation>}"
	printf '%s' "$s"
}

sgit_note() { printf 'sgit: %s\n' "$(sgit_hide_paths "$*")" >&2; }
sgit_warn() { printf 'sgit: warning: %s\n' "$(sgit_hide_paths "$*")" >&2; }
sgit_die() { printf 'sgit: fatal: %s\n' "$(sgit_hide_paths "$*")" >&2; exit 1; }

# Drop the per-repository environment git exports to helpers and hooks.
#
# A remote helper is started with GIT_DIR pointing at the shadow working tree,
# and a hook with GIT_DIR pointing at the shadow repository. Either one
# overrides `git -C <path>`, so every command aimed at the store would silently
# operate on the wrong repository. `--local-env-vars` is git's own list of the
# variables that carry this context; GIT_PROTOCOL is deliberately not among
# them and survives, so an exec'd service still negotiates the right version.
sgit_clear_git_env() {
	local v
	for v in $(git rev-parse --local-env-vars); do
		unset "$v"
	done
}

# Whether it is safe to ask the user something.
#
# sgit runs inside the remote helper, the pre-receive hook and the gateway
# access hook, where stdin carries git's protocol. A prompt there would eat
# protocol bytes, so three things must hold: the caller must be a user-facing
# command, stdin must be a terminal, and a terminal must be openable -- the
# answer is read from /dev/tty so that nothing on stdin is consumed either way.
sgit_can_prompt() {
	[ -z "${SGIT_NO_PROMPT:-}" ] || return 1
	[ -n "${SGIT_INTERACTIVE:-}" ] || return 1
	[ -t 0 ] || return 1
	[ -r /dev/tty ] || return 1
	return 0
}

# Ask a yes/no question. Anything but an explicit yes is a no, and no answer
# can be given at all when it would not be safe to ask.
sgit_confirm() {
	local reply=''
	sgit_can_prompt || return 1
	printf '%s [y/N] ' "$1" >&2
	read -r reply </dev/tty || reply=''
	case "$reply" in
	[Yy] | [Yy][Ee][Ss]) return 0 ;;
	esac
	return 1
}

# Ask for a word to be typed back, for something that cannot be undone.
sgit_confirm_word() {
	local want="$1" reply=''
	sgit_can_prompt || return 1
	printf 'Type %s to confirm: ' "$want" >&2
	read -r reply </dev/tty || reply=''
	[ "$reply" = "$want" ]
}

# Progress for the parts that take long enough to look stuck.
#
# Always on stderr, never stdout: on the helper and hook paths stdout carries
# git's pack protocol, and a single stray byte there corrupts it. Silent for
# small jobs, where a counter is noise, and silent under SGIT_NO_PROGRESS.
SGIT_PROGRESS_SHOWN=no
SGIT_PROGRESS_STEP=0
SGIT_PROGRESS_TOTAL=0
SGIT_PROGRESS_LABEL=''
SGIT_PROGRESS_TTY=no

# Decide once, before the loop, whether to report at all and how often.
#
# Everything here used to be re-decided on every object -- including whether
# stderr is a terminal, which is a system call. On a fetch that rewrites
# nothing the loop still walks the whole history, so that cost fell on the
# most ordinary operation there is.
#
# A step of 0 means "not reporting", which the caller can test without
# entering a function at all.
sgit_progress_begin() {
	SGIT_PROGRESS_TOTAL="$1"
	SGIT_PROGRESS_LABEL="$2"
	SGIT_PROGRESS_SHOWN=no
	SGIT_PROGRESS_TTY=no
	SGIT_PROGRESS_STEP=0

	[ -z "${SGIT_NO_PROGRESS:-}" ] || return 0
	[ "$1" -ge 200 ] || return 0

	# A terminal is redrawn in place and can afford to be frequent. Anything
	# else -- a log, or the sideband back to a pushing client -- gets whole
	# lines, so they had better be rare.
	if [ -t 2 ]; then
		SGIT_PROGRESS_TTY=yes
		SGIT_PROGRESS_STEP=50
	else
		SGIT_PROGRESS_STEP=1000
	fi
	return 0
}

# Print one update. Deciding *when* is left to the caller: it sits in a loop
# that runs once per object, and entering a function there -- twice, counting
# this one -- cost more than the work being reported on.
sgit_progress() {
	local done="$1" suffix="${2:-}"

	SGIT_PROGRESS_SHOWN=yes
	if [ "$SGIT_PROGRESS_TTY" = yes ]; then
		printf '\r%s %d/%d%s\033[K' \
			"$SGIT_PROGRESS_LABEL" "$done" "$SGIT_PROGRESS_TOTAL" "$suffix" >&2
	else
		printf '%s %d/%d%s\n' \
			"$SGIT_PROGRESS_LABEL" "$done" "$SGIT_PROGRESS_TOTAL" "$suffix" >&2
	fi
	return 0
}

sgit_progress_end() {
	if [ "$SGIT_PROGRESS_SHOWN" = yes ] && [ "$SGIT_PROGRESS_TTY" = yes ]; then
		printf '\n' >&2
	fi
	SGIT_PROGRESS_SHOWN=no
	return 0
}

# Paths removed when the process exits. A single trap owns all of them, so
# that a later registration (a repository lock, say) cannot silently replace an
# earlier one (the scratch directory).
SGIT_CLEANUP_PATHS=""

sgit_cleanup() {
	local p
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		rm -rf "$p"
	done <<CLEANUP
$SGIT_CLEANUP_PATHS
CLEANUP
}

sgit_cleanup_add() {
	SGIT_CLEANUP_PATHS="$SGIT_CLEANUP_PATHS$1$NL"
	if [ -z "${SGIT_TRAP_INSTALLED:-}" ]; then
		trap sgit_cleanup EXIT
		SGIT_TRAP_INSTALLED=1
	fi
}

sgit_cleanup_drop() {
	local kept="" p
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		[ "$p" = "$1" ] && continue
		kept="$kept$p$NL"
	done <<CLEANUP
$SGIT_CLEANUP_PATHS
CLEANUP
	SGIT_CLEANUP_PATHS="$kept"
}

# Ensure $SGIT_TMPDIR exists; it is removed when the process exits.
#
# This sets a global rather than printing the path, because a command
# substitution would run it in a subshell whose EXIT trap fires immediately and
# deletes the directory before the caller can use it.
sgit_tmpdir_init() {
	if [ -z "${SGIT_TMPDIR:-}" ]; then
		SGIT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sgit.XXXXXX") ||
			sgit_die "cannot create a temporary directory"
		sgit_cleanup_add "$SGIT_TMPDIR"
	fi
}

sgit_debug() {
	if [ -n "${SGIT_DEBUG:-}" ]; then
		printf 'sgit: debug: %s\n' "$*" >&2
	fi
	return 0
}

# Split a string on the first newline. Preserves bytes exactly, including a
# trailing newline or its absence, which command substitution would destroy.
#   sgit_chop "$rest"  ->  CHOP_LINE, CHOP_REST, CHOP_EOL ("" on the last line)
sgit_chop() {
	case "$1" in
	*"$NL"*)
		CHOP_LINE="${1%%"$NL"*}"
		CHOP_REST="${1#*"$NL"}"
		CHOP_EOL="$NL"
		;;
	*)
		CHOP_LINE="$1"
		CHOP_REST=""
		CHOP_EOL=""
		;;
	esac
}
