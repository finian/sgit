# shellcheck shell=bash
#
# Minimal test harness. Each test file sources this, runs assertions, and ends
# with test_summary. Assertions never abort the file, so one failure does not
# hide the rest.

SGIT_T_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SGIT_SRC_ROOT=$(cd "$SGIT_T_DIR/.." && pwd)
PATH="$SGIT_SRC_ROOT/bin:$PATH"
export PATH

TEST_COUNT=0
TEST_FAIL=0

TRASH=$(mktemp -d "${TMPDIR:-/tmp}/sgit-t.XXXXXX") || exit 1
trap 'rm -rf "$TRASH"' EXIT
cd "$TRASH" || exit 1

# Identity fixture shared by every test.
export SGIT_SHADOW_NAME='Dolores'
export SGIT_SHADOW_EMAIL='dolores@users.noreply.github.com'
export SGIT_REAL_EMAILS='alice@example.com
*@work-corp.com'
export SGIT_REAL_NAMES='Alice Zhang'
export SGIT_REAL_EMAIL='alice@example.com'
export SGIT_REAL_NAME='Alice Zhang'

# Keep the harness free of the developer's own git configuration.
export GIT_CONFIG_NOSYSTEM=1
export HOME="$TRASH/home"
mkdir -p "$HOME"

pass() {
	TEST_COUNT=$((TEST_COUNT + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	TEST_COUNT=$((TEST_COUNT + 1))
	TEST_FAIL=$((TEST_FAIL + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local line
	for line in "$@"; do printf '       | %s\n' "$line"; done
}

is() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1" "expected: $2" "actual:   $3"
	fi
}

isnt() {
	if [ "$2" != "$3" ]; then
		pass "$1"
	else
		fail "$1" "expected a difference, both were: $2"
	fi
}

ok() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "failed: $*"; fi
}

not_ok() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then fail "$name" "unexpectedly succeeded: $*"; else pass "$name"; fi
}

test_summary() {
	printf '  %d test(s), %d failure(s)\n' "$TEST_COUNT" "$TEST_FAIL"
	[ "$TEST_FAIL" = 0 ]
}

# --- git fixtures -----------------------------------------------------------

work_init() {
	git init -q -b main "$1"
	git -C "$1" config user.name 'Nobody'
	git -C "$1" config user.email 'nobody@example.invalid'
	git -C "$1" config commit.gpgsign false
}

# commit_as <repo> <name> <email> <message> [extra commit args...]
commit_as() {
	local d="$1" n="$2" e="$3" m="$4"
	shift 4
	printf '%s\n' "$m" >>"$d/file.txt"
	git -C "$d" add -A
	GIT_AUTHOR_NAME="$n" GIT_AUTHOR_EMAIL="$e" \
		GIT_COMMITTER_NAME="$n" GIT_COMMITTER_EMAIL="$e" \
		GIT_AUTHOR_DATE='2024-01-01T00:00:00 +0800' \
		GIT_COMMITTER_DATE='2024-01-01T00:00:00 +0800' \
		git -C "$d" commit -q -m "$m" "$@"
}

# Build a store: bare real.git cloned from <workdir>, plus an empty shadow.git
# whose object database reaches the real one through alternates, exactly as
# `sgit clone` will lay it out (spec 4.1).
setup_store() {
	REAL="$TRASH/store/real.git"
	SHADOW="$TRASH/store/shadow.git"
	rm -rf "$TRASH/store"
	mkdir -p "$TRASH/store"
	git clone -q --bare "$1" "$REAL"
	git init -q --bare "$SHADOW"
	printf '%s\n' "$REAL/objects" >"$SHADOW/objects/info/alternates"
}

map_of() { git -C "$SHADOW" rev-parse --verify --quiet "refs/sgit/map/$1"; }
rmap_of() { git -C "$REAL" rev-parse --verify --quiet "refs/sgit/rmap/$1"; }

field() { git -C "$1" log -1 --format="$3" "$2"; }

# --- store fixtures ---------------------------------------------------------

# A store with a real configuration file, so that config loading is exercised
# rather than bypassed by the environment.
setup_sgit_home() {
	export SGIT_HOME="$TRASH/store"
	export SGIT_GLOBAL_CONFIG="$SGIT_HOME/config"
	mkdir -p "$SGIT_HOME"
	# Only the shadow identity is stated here. The identity to hide and to
	# restore comes from git's own configuration, exactly as it would for a
	# real user; [real] lists nothing but the extra address to catch.
	cat >"$SGIT_HOME/config" <<'CFG'
[shadow]
	name = Dolores
	email = dolores@users.noreply.github.com
[real]
	email = *@work-corp.com
CFG
	git config --global user.name 'Alice Zhang'
	git config --global user.email 'alice@example.com'
	unset SGIT_SHADOW_NAME SGIT_SHADOW_EMAIL
	unset SGIT_REAL_EMAILS SGIT_REAL_NAMES SGIT_REAL_EMAIL SGIT_REAL_NAME
}

# A bare "upstream" plus the working repository that feeds it.
make_upstream() {
	UPWORK="$TRASH/up"
	UPSTREAM="$TRASH/upstream.git"
	work_init "$UPWORK"
	commit_as "$UPWORK" 'Bob Lee'     'bob@elsewhere.org'     'first by bob'
	commit_as "$UPWORK" 'Alice Zhang' 'alice@example.com'     'second by alice'
	commit_as "$UPWORK" 'A. Zhang'    'a.zhang@work-corp.com' 'third at work'
	git clone -q --bare "$UPWORK" "$UPSTREAM"
	git -C "$UPWORK" remote add origin "$UPSTREAM"
}

id_of() { cat "$1/.git/sgit"; }
store_real() { printf '%s' "$SGIT_HOME/repos/$1/real.git"; }
store_shadow() { printf '%s' "$SGIT_HOME/repos/$1/shadow.git"; }

store_list_ids_first() {
	local d
	for d in "$SGIT_HOME/repos"/*; do
		[ -d "$d/real.git" ] || continue
		printf '%s' "${d##*/}"
		return 0
	done
}
