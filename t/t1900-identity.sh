#!/usr/bin/env bash
# Which identity a push restores, and which ones a fetch hides.
#
# The identity comes from git's own configuration, resolved against the real
# repository, so working in the shadow copy reaches the upstream exactly as
# working in the real one would. Whatever comes out is also hidden on the way
# down, which is what keeps it from reappearing later.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
REAL=$(store_real "$id")

# --- the global git identity is what gets restored --------------------------

is 'the fixture has a global git identity' \
	'alice@example.com' "$(git config --global user.email)"
case "$(cat "$SGIT_HOME/config")" in
*alice@example.com*) fail 'and sgit was not told about it separately' 'it is in the sgit config' ;;
*) pass 'and sgit was not told about it separately' ;;
esac

printf 'a\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'first'
ok 'a push works' git -C "$P" push -q origin main
is 'and lands under the git identity' \
	'Alice Zhang <alice@example.com>' "$(git -C "$UPSTREAM" log -1 --format='%an <%ae>')"

# It is hidden on the way down even though [real] never mentions it: whatever
# a push restores has to be something a fetch would rewrite, or the same
# address made elsewhere would come back in the clear.
is 'and is hidden in the shadow copy' 'Dolores' "$(git -C "$P" log -1 --format='%an')"
is 'as is the history it came down with' \
	'Dolores' "$(git -C "$P" log --format='%an' | sed -n 3p)"

# --- git's own precedence: a repository-local setting wins -------------------

git -C "$REAL" config user.name 'A. Zhang'
git -C "$REAL" config user.email 'a.zhang@another.example'

printf 'b\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'second'
ok 'a push still works after the override' git -C "$P" push -q origin main
is 'and uses the repository-local identity' \
	'A. Zhang <a.zhang@another.example>' "$(git -C "$UPSTREAM" log -1 --format='%an <%ae>')"

# --- the resolved identity is hidden without being listed -------------------

case "$(git config -f "$SGIT_HOME/config" --get-all real.email)" in
*another.example*) fail 'the override is not in the sgit config' 'it is listed' ;;
*) pass 'the override is not in the sgit config' ;;
esac

# The same address, arriving from somewhere else entirely.
git -C "$UPWORK" fetch -q origin
git -C "$UPWORK" reset -q --hard origin/main
printf 'c\n' >>"$UPWORK/file.txt"
git -C "$UPWORK" add -A
GIT_AUTHOR_NAME='A. Zhang' GIT_AUTHOR_EMAIL='a.zhang@another.example' \
	GIT_COMMITTER_NAME='A. Zhang' GIT_COMMITTER_EMAIL='a.zhang@another.example' \
	git -C "$UPWORK" commit -qm 'made on another machine'
git -C "$UPWORK" push -q origin main

ok 'fetching it works' git -C "$P" pull -q --ff-only
is 'and it arrives rewritten, though nothing listed it' \
	'Dolores' "$(git -C "$P" log -1 --format='%an')"
leak=$(git -C "$P" log --all --format='%ae%n%ce' | grep -c 'another.example' || true)
is 'the address appears nowhere in the shadow history' 0 "$leak"

git -C "$REAL" config --unset user.name
git -C "$REAL" config --unset user.email

# --- extra patterns still hide older identities -----------------------------

# The upstream history contains a commit by a.zhang@work-corp.com, matched
# only by the glob in [real] and by nothing git knows about.
is 'the upstream really has a work-corp commit' 1 \
	"$(git -C "$UPSTREAM" log --all --format='%ae' | grep -c 'work-corp.com')"
is 'and in the shadow copy it is the shadow identity' 'Dolores' \
	"$(git -C "$P" log --all --format='%an %s' | awk '/third at work/{print $1}' | head -1)"
leak=$(git -C "$P" log --all --format='%ae%n%ce' | grep -c 'work-corp.com' || true)
is 'no work-corp address survives anywhere' 0 "$leak"

# --- no git identity at all -------------------------------------------------

git config --global --unset user.name
git config --global --unset user.email
out=$(sgit --id "$id" sync 2>&1) && rc=0 || rc=1
is 'without a git identity the operation is refused' 1 "$rc"
case "$out" in
*'git would not know either'*) pass 'and the message says git could not either' ;;
*) fail 'and the message says git could not either' "$out" ;;
esac
case "$out" in
*'git config --global user.email'*) pass 'and gives the command to fix it' ;;
*) fail 'and gives the command to fix it' "$out" ;;
esac
git config --global user.name 'Alice Zhang'
git config --global user.email 'alice@example.com'

# --- doctor reports it ------------------------------------------------------

out=$(sgit doctor 2>&1)
case "$out" in
*'pushes restore Alice Zhang <alice@example.com>'*) pass 'doctor reports the resolved identity' ;;
*) fail 'doctor reports the resolved identity' "$out" ;;
esac

git -C "$REAL" config user.email "$(git config -f "$SGIT_HOME/config" --get shadow.email)"
git -C "$REAL" config user.name 'Dolores'
out=$(sgit doctor 2>&1)
case "$out" in
*'that is the shadow address'*) pass 'and warns if it is the shadow identity' ;;
*) fail 'and warns if it is the shadow identity' "$out" ;;
esac

test_summary
