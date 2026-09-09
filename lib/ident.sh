# shellcheck shell=bash
#
# Git identity parsing, matching and substitution (spec 5.1).
#
# An identity string is "NAME <EMAIL>" optionally followed by a tail. In a
# commit header the tail is " <timestamp> <tz>"; in a message trailer there is
# no tail. Splitting off the tail rather than parsing it keeps the two cases on
# one code path and makes reassembly byte-exact, which matters because an
# unchanged identity must reproduce its input exactly.

[ -n "${SGIT_IDENT_SH:-}" ] && return 0
SGIT_IDENT_SH=1

# ident_split "Alice <a@x.com> 1700000000 +0800"
#   -> IDENT_NAME="Alice" IDENT_EMAIL="a@x.com" IDENT_TAIL=" 1700000000 +0800"
# Returns non-zero if the string is not a well-formed identity.
ident_split() {
	local s="$1" rest
	case "$s" in
	*' <'*'>'*) ;;
	*) return 1 ;;
	esac
	IDENT_NAME="${s%% <*}"
	rest="${s#*<}"
	IDENT_EMAIL="${rest%%>*}"
	IDENT_TAIL="${rest#*>}"
	return 0
}

# Does this identity belong to the user we are hiding? Email is the primary
# key and patterns may be globs (spec 5.1); name is an optional OR-ed match.
# Matching is case-insensitive.
ident_is_real() {
	local name="$1" email="$2" pat saved rc=1

	saved=$(shopt -p nocasematch)
	shopt -s nocasematch

	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		case "$email" in
		$pat)
			rc=0
			break
			;;
		esac
	done <<PATTERNS
${SGIT_REAL_EMAILS:-}
PATTERNS

	if [ $rc -ne 0 ]; then
		while IFS= read -r pat; do
			[ -n "$pat" ] || continue
			case "$name" in
			$pat)
				rc=0
				break
				;;
			esac
		done <<PATTERNS
${SGIT_REAL_NAMES:-}
PATTERNS
	fi

	eval "$saved"
	return $rc
}

# Is this the shadow identity? Used on the way up, where the substitution is
# an exact-match restore rather than a pattern match.
ident_is_shadow() {
	local email="$2" saved rc=1
	saved=$(shopt -p nocasematch)
	shopt -s nocasematch
	case "$email" in
	"$SGIT_SHADOW_EMAIL") rc=0 ;;
	esac
	eval "$saved"
	return $rc
}

# Rewrite one identity in the direction given by SGIT_DIRECTION.
#   -> IDENT_OUT (byte-identical to the input when nothing matched)
#   -> IDENT_CHANGED (0 or 1)
ident_rewrite() {
	IDENT_OUT="$1"
	IDENT_CHANGED=0

	ident_split "$1" || return 0

	if [ "$SGIT_DIRECTION" = down ]; then
		if ident_is_real "$IDENT_NAME" "$IDENT_EMAIL"; then
			IDENT_OUT="$SGIT_SHADOW_NAME <$SGIT_SHADOW_EMAIL>$IDENT_TAIL"
			IDENT_CHANGED=1
		fi
	else
		if ident_is_shadow "$IDENT_NAME" "$IDENT_EMAIL"; then
			IDENT_OUT="$SGIT_REAL_NAME <$SGIT_REAL_EMAIL>$IDENT_TAIL"
			IDENT_CHANGED=1
		fi
	fi
	return 0
}

# Is this trailer token one that carries an identity (spec 5.6)?
ident_is_trailer_token() {
	local tok pat saved rc=1
	tok="$1"
	saved=$(shopt -p nocasematch)
	shopt -s nocasematch
	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		case "$tok" in
		"$pat")
			rc=0
			break
			;;
		esac
	done <<TOKENS
${SGIT_TRAILER_TOKENS:-}
TOKENS
	eval "$saved"
	return $rc
}
