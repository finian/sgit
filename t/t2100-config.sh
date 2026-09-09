#!/usr/bin/env bash
# `sgit config`, and the first-run offer to create a configuration.
#
# The interactive prompt itself is driven by hand (a pty is not worth the
# flakiness here); what is tested is everything deterministic around it, above
# all that it never fires anywhere it could eat git's protocol stream.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")

# --- writing and reading ----------------------------------------------------

sgit config gateway.listen bridge100
is 'a global setting is written and read back' \
	'bridge100' "$(sgit config gateway.listen)"
is 'and it really is in the global file' \
	'bridge100' "$(git config -f "$SGIT_HOME/config" --get gateway.listen)"

sgit -C "$P" config --repo sync.downTtl 30
is 'a per-repository setting lands in the repository file' \
	'30' "$(git config -f "$SGIT_HOME/repos/$id/config" --get sync.downTtl)"
is 'and not in the global one' '' \
	"$(git config -f "$SGIT_HOME/config" --get sync.downTtl 2>/dev/null || true)"

# A read without a scope answers the useful question: what is in effect.
sgit config --global sync.downTtl 5
is 'a scoped read sees only that file'  '5'  "$(sgit config --global sync.downTtl)"
is 'an unscoped read sees what wins'    '30' "$(sgit -C "$P" config sync.downTtl)"
sgit -C "$P" config --repo --unset sync.downTtl
is 'and follows the global value once the override is gone' \
	'5' "$(sgit -C "$P" config sync.downTtl)"

not_ok 'reading something unset fails' sgit config nosuch.key
not_ok 'unsetting something unset fails' sgit config --unset nosuch.key

# --- keys that hold several values ------------------------------------------
#
# real.email, real.name, gateway.allowFrom and rewrite.trailerTokens all take
# more than one value. Showing only the first would hide configuration the
# tool is acting on.

sgit config real.email 'first@example.com'
sgit config --add real.email 'second@example.com'
sgit config --add real.email '*@third.example'
is 'every value is shown, in order' \
	'first@example.com second@example.com *@third.example' \
	"$(sgit config real.email | tr '\n' ' ' | sed 's/ $//')"
is 'and a scoped read agrees' \
	"$(sgit config real.email)" "$(sgit config --global real.email)"

# git refuses to collapse several values into one and explains it in terms of
# regexps; the answer here is in terms of what was actually meant.
out=$(sgit config real.email 'fourth@example.com' 2>&1) && rc=0 || rc=1
is 'a plain write over several values is refused' 1 "$rc"
case "$out" in
*'--add'*) pass 'and points at --add' ;;
*) fail 'and points at --add' "$out" ;;
esac
case "$out" in
*'--replace-all'*) pass 'and at --replace-all' ;;
*) fail 'and at --replace-all' "$out" ;;
esac

sgit config --replace-all real.email 'only@example.com'
is '--replace-all collapses them' 'only@example.com' "$(sgit config real.email)"

sgit config --add real.name 'Alice Zhang'
sgit config --add real.name 'A. Zhang'
out=$(sgit config --list | command grep -c '^  real\.name=')
is 'listing shows each value separately' 2 "$out"

sgit config --unset real.name
not_ok 'unsetting removes every value' sgit config real.name

# A repository value replaces the global ones rather than adding to them.
sgit -C "$P" config --repo real.email 'repo-only@example.com'
is 'a per-repository value wins outright' \
	'repo-only@example.com' "$(sgit -C "$P" config real.email)"
is 'while the global one is untouched' \
	'only@example.com' "$(sgit config --global real.email)"
sgit -C "$P" config --repo --unset real.email

# --- the two scopes are distinguished ---------------------------------------

out=$(sgit -C "$P" config --repo gateway.port 1234 2>&1)
case "$out" in
*'no effect'*) pass 'a gateway setting written per repository is flagged' ;;
*) fail 'a gateway setting written per repository is flagged' "$out" ;;
esac
out=$(sgit config --global upstream.pushRemote origin 2>&1)
case "$out" in
*'no effect'*) pass 'a per-repository setting written globally is flagged' ;;
*) fail 'a per-repository setting written globally is flagged' "$out" ;;
esac

out=$(sgit -C "$P" config --list 2>&1)
case "$out" in
*'# global'*) pass 'listing shows the global file' ;;
*) fail 'listing shows the global file' "$out" ;;
esac
case "$out" in
*"# repository $id"*) pass 'and the repository file, labelled' ;;
*) fail 'and the repository file, labelled' "$out" ;;
esac

not_ok 'a repository scope needs a repository' \
	sh -c "cd '$TRASH' && sgit config --repo sync.downTtl 1"

# --- creating a configuration -----------------------------------------------

FRESH="$TRASH/fresh-store"
mkdir -p "$FRESH"

out=$(SGIT_HOME="$FRESH" SGIT_GLOBAL_CONFIG="$FRESH/config" sgit config --init 2>&1)
ok 'a configuration can be created without any interaction' test -f "$FRESH/config"
is 'with the default shadow name' 'Dolores' \
	"$(git config -f "$FRESH/config" --get shadow.name)"
is 'and only the shadow section' '2' \
	"$(git config -f "$FRESH/config" --list | wc -l | tr -d ' ')"
is 'the store is created owner-only' '700' \
	"$(stat -f '%Lp' "$FRESH" 2>/dev/null || stat -c '%a' "$FRESH")"

rm -rf "$FRESH"
mkdir -p "$FRESH"
SGIT_HOME="$FRESH" SGIT_GLOBAL_CONFIG="$FRESH/config" \
	sgit config --init --name 'Quiet Fox' --email 'fox@example.invalid' >/dev/null 2>&1
is 'a name can be given instead' 'Quiet Fox' \
	"$(git config -f "$FRESH/config" --get shadow.name)"
is 'and an address' 'fox@example.invalid' \
	"$(git config -f "$FRESH/config" --get shadow.email)"

# --- the prompt must never fire where git is listening ----------------------

rm -rf "$FRESH"
mkdir -p "$FRESH"
out=$(SGIT_HOME="$FRESH" SGIT_GLOBAL_CONFIG="$FRESH/config" \
	sgit clone "$UPSTREAM" "$TRASH/nope" </dev/null 2>&1) && rc=0 || rc=1
is 'without a terminal the command just fails' 1 "$rc"
not_ok 'and writes no configuration behind the user back' test -f "$FRESH/config"
case "$out" in
*'[shadow]'*) pass 'having said what to write' ;;
*) fail 'having said what to write' "$out" ;;
esac

# The remote helper's stdin is git's protocol stream. A prompt there would
# consume it, so the helper must never be able to reach one.
printf 'capabilities\n' | SGIT_HOME="$FRESH" SGIT_GLOBAL_CONFIG="$FRESH/config" \
	git-remote-sgit origin "$id" >/dev/null 2>&1 || true
not_ok 'the remote helper cannot be prompted either' test -f "$FRESH/config"

test_summary
