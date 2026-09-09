#!/usr/bin/env bash
# Identity parsing, matching and substitution (spec 5.1).
. "$(dirname "$0")/test-lib.sh"
. "$SGIT_SRC_ROOT/lib/common.sh"
. "$SGIT_SRC_ROOT/lib/config.sh"
. "$SGIT_SRC_ROOT/lib/ident.sh"

sgit_config_load

ident_split 'Alice Zhang <alice@example.com> 1700000000 +0800'
is 'split: name' 'Alice Zhang' "$IDENT_NAME"
is 'split: email' 'alice@example.com' "$IDENT_EMAIL"
is 'split: tail' ' 1700000000 +0800' "$IDENT_TAIL"

ident_split 'Alice <alice@example.com>'
is 'split: trailer form has empty tail' '' "$IDENT_TAIL"

ident_split ' <anon@example.com> 1 +0000'
is 'split: empty name' '' "$IDENT_NAME"

not_ok 'split: rejects a non-identity' ident_split 'not an identity'

# Reassembly must be byte-exact, otherwise unchanged objects would not keep
# their object id.
s='Alice Zhang <alice@example.com> 1700000000 +0800'
ident_split "$s"
is 'split: round-trips exactly' "$s" "$IDENT_NAME <$IDENT_EMAIL>$IDENT_TAIL"

ok      'match: exact email'        ident_is_real 'Whoever' 'alice@example.com'
ok      'match: case-insensitive'   ident_is_real 'Whoever' 'ALICE@Example.COM'
ok      'match: glob pattern'       ident_is_real 'Whoever' 'a.zhang@work-corp.com'
ok      'match: by name'            ident_is_real 'Alice Zhang' 'other@elsewhere.org'
not_ok  'match: unrelated identity' ident_is_real 'Bob Lee' 'bob@elsewhere.org'
not_ok  'match: near-miss glob'     ident_is_real 'Bob Lee' 'bob@work-corp.com.evil.org'

ok      'shadow: recognises shadow email'  ident_is_shadow 'Dolores' "$SGIT_SHADOW_EMAIL"
not_ok  'shadow: rejects other email'      ident_is_shadow 'Dolores' 'bob@elsewhere.org'

SGIT_DIRECTION=down
ident_rewrite 'Alice Zhang <alice@example.com> 1700000000 +0800'
is 'down: replaces the real identity' \
	"Dolores <dolores@users.noreply.github.com> 1700000000 +0800" "$IDENT_OUT"
is 'down: reports the change' 1 "$IDENT_CHANGED"

ident_rewrite 'Bob Lee <bob@elsewhere.org> 1700000000 +0800'
is 'down: leaves a collaborator untouched' \
	'Bob Lee <bob@elsewhere.org> 1700000000 +0800' "$IDENT_OUT"
is 'down: reports no change' 0 "$IDENT_CHANGED"

SGIT_DIRECTION=up
ident_rewrite "Dolores <$SGIT_SHADOW_EMAIL> 1700000000 +0800"
is 'up: restores the real identity' \
	'Alice Zhang <alice@example.com> 1700000000 +0800' "$IDENT_OUT"

ident_rewrite 'Bob Lee <bob@elsewhere.org> 1700000000 +0800'
is 'up: leaves a collaborator untouched' \
	'Bob Lee <bob@elsewhere.org> 1700000000 +0800' "$IDENT_OUT"

ok     'trailer token: Signed-off-by'  ident_is_trailer_token 'Signed-off-by'
ok     'trailer token: case-insensitive' ident_is_trailer_token 'signed-off-by'
ok     'trailer token: Co-authored-by' ident_is_trailer_token 'Co-authored-by'
not_ok 'trailer token: Fixes is not one' ident_is_trailer_token 'Fixes'

test_summary
