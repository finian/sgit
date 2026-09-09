#!/usr/bin/env bash
# Identity trailers in commit messages (spec 5.6).
. "$(dirname "$0")/test-lib.sh"

W="$TRASH/w"
work_init "$W"

msg='fix the thing

Signed-off-by: Alice Zhang <alice@example.com>
Co-authored-by: Bob Lee <bob@elsewhere.org>
Reviewed-by: A. Zhang <a.zhang@work-corp.com>
Fixes: alice@example.com'

# Authored by a collaborator, so the only thing that can trigger a rewrite is
# the trailer block itself.
commit_as "$W" 'Bob Lee' 'bob@elsewhere.org' "$msg"
setup_store "$W"

c=$(git -C "$REAL" rev-parse main)
sgit rewrite --real "$REAL" --shadow "$SHADOW" --direction down -- --all
s=$(map_of "$c")

isnt 'a trailer alone is enough to force a rewrite' "$c" "$s"
is 'the commit author is left alone' 'Bob Lee' "$(field "$SHADOW" "$s" '%an')"

body=$(git -C "$SHADOW" log -1 --format='%B' "$s")
has() { case "$body" in *"$2"*) pass "$1" ;; *) fail "$1" "not found: $2" "body: $body" ;; esac; }
hasnt() { case "$body" in *"$2"*) fail "$1" "unexpectedly found: $2" ;; *) pass "$1" ;; esac; }

has   'the subject survives'                'fix the thing'
has   'Signed-off-by is rewritten'          "Signed-off-by: Dolores <$SGIT_SHADOW_EMAIL>"
has   'Reviewed-by matched by glob is rewritten' "Reviewed-by: Dolores <$SGIT_SHADOW_EMAIL>"
has   'a collaborator trailer is untouched' 'Co-authored-by: Bob Lee <bob@elsewhere.org>'
has   'a non-identity trailer is untouched' 'Fixes: alice@example.com'
hasnt 'the real name is gone from the message' 'Alice Zhang'
hasnt 'the real address is gone from the message' 'alice@example.com
'

test_summary
