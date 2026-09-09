#!/usr/bin/env bash
# Text that is not ASCII: through the rewrite, and out to the user.
#
# sgit works in the C locale so that its string handling counts bytes rather
# than characters, which is what keeps a rewritten object exact. That must not
# reach anything a person reads: reported as `sgit git log` turning Chinese
# commit messages into escapes, which is git's pager under a C locale.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home

SUBJECT='修复: 单流探测偶发偏低'
BODY='详细说明：把 40M 的机器整形到 12M。

Signed-off-by: Alice Zhang <alice@example.com>'
AUTHOR_NAME='张三'

UPWORK="$TRASH/up"
UPSTREAM="$TRASH/upstream.git"
work_init "$UPWORK"
printf 'x\n' >"$UPWORK/file.txt"
git -C "$UPWORK" add -A
GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL='zhangsan@elsewhere.org' \
	GIT_COMMITTER_NAME='Alice Zhang' GIT_COMMITTER_EMAIL='alice@example.com' \
	GIT_AUTHOR_DATE='2024-01-01T00:00:00 +0800' \
	GIT_COMMITTER_DATE='2024-01-01T00:00:00 +0800' \
	git -C "$UPWORK" commit -qm "$SUBJECT

$BODY"
git clone -q --bare "$UPWORK" "$UPSTREAM"
git -C "$UPWORK" remote add origin "$UPSTREAM"

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1

# --- the rewrite must not disturb a single byte ------------------------------

is 'the subject survives the rewrite exactly' \
	"$(git -C "$UPSTREAM" log -1 --format='%s')" "$(git -C "$P" log -1 --format='%s')"
hex() { od -An -tx1 | tr -d ' \n'; }
# Everything above the trailer block, which is the part that must not move.
# The trailer itself is rewritten on purpose and is checked separately below.
is 'and the body, byte for byte' \
	"$(git -C "$UPSTREAM" log -1 --format='%B' | sed -n '1,3p' | hex)" \
	"$(git -C "$P" log -1 --format='%B' | sed -n '1,3p' | hex)"
is 'a non-ASCII author who is not you is left alone' \
	"$AUTHOR_NAME" "$(git -C "$P" log -1 --format='%an')"
is 'while the committer, who is you, is replaced' \
	'Dolores' "$(git -C "$P" log -1 --format='%cn')"
is 'and the trailer inside the message with it' \
	"Signed-off-by: Dolores <dolores@users.noreply.github.com>" \
	"$(git -C "$P" log -1 --format='%B' | command grep '^Signed-off-by:')"

# --- and the same on the way up ---------------------------------------------

MSG='新增: 中文提交信息'
printf 'y\n' >>"$P/file.txt"
git -C "$P" add -A
git -C "$P" commit -qm "$MSG"
ok 'a commit written in Chinese can be pushed' git -C "$P" push -q origin main
is 'and reaches the upstream byte for byte' \
	"$(printf '%s\n' "$MSG" | hex)" \
	"$(git -C "$UPSTREAM" log -1 --format='%s' | hex)"
is 'under the real identity' 'Alice Zhang' "$(git -C "$UPSTREAM" log -1 --format='%cn')"

# --- what reaches the user is rendered in the user's locale -----------------

showenv() {
	sgit -C "$P" git -c 'alias.showenv=!env' showenv 2>/dev/null |
		command grep "^$1=" || true
}
# The value need not name a locale that exists; only that it arrives.
is 'the caller locale is handed to the git it runs' \
	'LC_ALL=xx_YY.UTF-8' "$( { LC_ALL=xx_YY.UTF-8 showenv LC_ALL; } 2>/dev/null )"
is 'and none is imposed when the caller set none' \
	'' "$( unset LC_ALL; showenv LC_ALL )"
is 'sgit git prints the message unchanged' \
	"$SUBJECT" "$(sgit -C "$P" git log --format='%s' | sed -n 2p)"

test_summary
