#!/usr/bin/env bash
# The creation-time leak check, and the two false positives it used to raise.
#
# Reported as: `sgit clone https://github.com/Kylin010/tcpfit.git` refusing to
# finish, naming .git/config and .git/index. Neither was a leak.
. "$(dirname "$0")/test-lib.sh"
. "$SGIT_SRC_ROOT/lib/common.sh"
. "$SGIT_SRC_ROOT/lib/config.sh"
. "$SGIT_SRC_ROOT/lib/ident.sh"
. "$SGIT_SRC_ROOT/lib/scrub.sh"
. "$SGIT_SRC_ROOT/lib/store.sh"
. "$SGIT_SRC_ROOT/lib/workdir.sh"

URL='https://github.com/Kylin010/tcpfit.git'
has() { printf '%s\n' "$2" | grep -qx -- "$1"; }

# --- which forms of a URL may be searched for -------------------------------

loose=$(scrub_url_tokens "$URL")
exact=$(scrub_url_tokens_exact "$URL")

ok 'scrubbing a message still replaces the bare host'  has 'github.com' "$loose"
ok 'and the bare repository name'                      has 'tcpfit'     "$loose"

ok     'verification keeps the whole URL'          has "$URL" "$exact"
ok     'and the URL without .git'                  has 'https://github.com/Kylin010/tcpfit' "$exact"
ok     'and owner/repo, which is specific'         has 'Kylin010/tcpfit' "$exact"
# The address sgit itself suggests contains the host of every GitHub upstream,
# so searching for a bare host reports the tool's own configuration as a leak.
not_ok 'but never the bare host'                   has 'github.com' "$exact"
# A project's name runs through its own files, which are out of scope.
not_ok 'and never the bare repository name'        has 'tcpfit'     "$exact"
not_ok 'nor the bare owner'                        has 'Kylin010'   "$exact"

is 'a filesystem path is a token on its own' \
	"$TRASH/up.git" "$(scrub_url_tokens_exact "$TRASH/up.git" | sed -n 1p)"

# --- the check itself -------------------------------------------------------

setup_sgit_home
sgit_config_load
SGIT_HOME="$TRASH/store"
store_use deadbeefdeadbeef
mkdir -p "$SGIT_REAL" "$SGIT_SHADOW"
git init -q --bare "$SGIT_REAL"
git -C "$SGIT_REAL" remote add origin "$URL"
git config -f "$SGIT_REPO_CONFIG" upstream.fetchRemote origin

W="$TRASH/tcpfit"
git init -q -b main "$W"
git -C "$W" config user.name Dolores
git -C "$W" config user.email dolores@users.noreply.github.com
git -C "$W" remote add origin sgit::deadbeefdeadbeef
# A file named after the project, which is what put "tcpfit" into .git/index.
printf 'x\n' >"$W/tcpfit.c"
git -C "$W" add -A
git -C "$W" commit -qm 'a commit'

# workdir_verify ends the process when it objects, so each call is made in a
# subshell of its own.
verify() { ( workdir_verify "$1" ) >/dev/null 2>&1; }

ok 'a working tree like the reported one passes' verify "$W"
ok 'even though its index does contain the project name' \
	sh -c "grep -qa tcpfit '$W/.git/index'"

# It still has to catch a real one.
git -C "$W" config sgit.leak "$SGIT_REPO_DIR"
not_ok 'a store path in the configuration is caught' verify "$W"
git -C "$W" config --unset sgit.leak

git -C "$W" config sgit.leak "$URL"
not_ok 'and so is the upstream URL' verify "$W"
git -C "$W" config --unset sgit.leak

git -C "$W" config sgit.leak 'Kylin010/tcpfit'
not_ok 'and owner/repo on its own' verify "$W"
git -C "$W" config --unset sgit.leak

ok 'clean again once they are gone' verify "$W"

test_summary
