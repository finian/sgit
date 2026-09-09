# shellcheck shell=bash
#
# Configuration loading (spec 10). Config files are in git-config INI format so
# that `git config -f` can read them; sgit never parses INI itself.
#
# Precedence: environment > repository config > global config > built-in default.
# The environment layer exists so that the rewrite engine can be driven
# directly from tests and from hooks without a store on disk.

[ -n "${SGIT_CONFIG_SH:-}" ] && return 0
SGIT_CONFIG_SH=1

SGIT_DEFAULT_TRAILER_TOKENS='Signed-off-by
Co-authored-by
Co-committed-by
Reviewed-by
Acked-by
Tested-by
Reported-by
Suggested-by
Helped-by'

# Read every value of a multi-valued key, repo config first, then global.
_config_all() {
	local key="$1" out=""
	if [ -n "${SGIT_REPO_CONFIG:-}" ] && [ -f "$SGIT_REPO_CONFIG" ]; then
		out=$(git config -f "$SGIT_REPO_CONFIG" --get-all "$key" 2>/dev/null) || out=""
	fi
	if [ -z "$out" ] && [ -n "${SGIT_GLOBAL_CONFIG:-}" ] && [ -f "$SGIT_GLOBAL_CONFIG" ]; then
		out=$(git config -f "$SGIT_GLOBAL_CONFIG" --get-all "$key" 2>/dev/null) || out=""
	fi
	printf '%s' "$out"
}

_config_one() {
	local v
	v=$(_config_all "$1")
	printf '%s' "${v%%"$NL"*}"
}

# Refusing with a usable answer: without an identity to hide and one to hide
# behind there is nothing this tool can do, and the first run is exactly when
# a bare "not configured" is least helpful.
# Whether it is safe to ask the user something.
#
# sgit_config_load also runs inside the remote helper, the pre-receive hook and
# the gateway access hook, where stdin carries git's protocol. A prompt there
# would consume protocol bytes and corrupt the stream, so three things must all
# hold: the caller must be a user-facing command (SGIT_INTERACTIVE), stdin must
# be a terminal, and a terminal must be openable to read from -- the answer is
# read from /dev/tty rather than stdin so that nothing else can be swallowed.
_config_ask() {
	local prompt="$1" default="$2" answer=''
	printf '%s [%s]: ' "$prompt" "$default" >&2
	read -r answer </dev/tty || answer=''
	printf '%s' "${answer:-$default}"
}

SGIT_DEFAULT_SHADOW_NAME='Dolores'
SGIT_DEFAULT_SHADOW_EMAIL='dolores@users.noreply.github.com'

# Write the smallest configuration that works. Reached either from the prompt
# below or from `sgit config --init`, so that setting sgit up in a script is
# a supported thing rather than a matter of writing the file by hand.
sgit_config_write_minimal() {
	local name="$1" email="$2"

	store_ensure_home
	git config -f "$SGIT_GLOBAL_CONFIG" shadow.name "$name" ||
		sgit_die "cannot write $SGIT_GLOBAL_CONFIG"
	git config -f "$SGIT_GLOBAL_CONFIG" shadow.email "$email"

	SGIT_SHADOW_NAME="$name"
	SGIT_SHADOW_EMAIL="$email"

	printf 'sgit: wrote %s\n' "$SGIT_GLOBAL_CONFIG" >&2
	printf 'sgit: the identity to hide comes from your git configuration, so\n' >&2
	printf 'sgit: there is nothing else to set up.\n' >&2
}

_config_create_interactively() {
	local name email
	printf '\n' >&2
	# Everyone accepting the default would commit under the same name, which
	# is a fingerprint of its own -- it says "this repository went through
	# sgit". Worth one line at the only moment the user is looking.
	printf 'A name of your own is better than the suggested one: the suggestion\n' >&2
	printf 'is the same for everybody, which is recognisable in itself.\n\n' >&2
	name=$(_config_ask 'Name to commit as' "$SGIT_DEFAULT_SHADOW_NAME")
	email=$(_config_ask 'Email to commit as' "$SGIT_DEFAULT_SHADOW_EMAIL")
	printf '\n' >&2
	sgit_config_write_minimal "$name" "$email"
}

_config_missing() {
	printf 'sgit: no usable configuration in %s\n\n' \
		"${SGIT_GLOBAL_CONFIG:-<unset>}" >&2
	cat >&2 <<'HINT'
Write it like this, with your own values:

    [shadow]
        name = Dolores
        email = dolores@users.noreply.github.com

That is the whole minimum. The identity to hide is taken from git's own
configuration -- the same user.name and user.email you already commit with.

Add a [real] section only to hide further identities, such as an address you
used years ago or one from another machine:

    [real]
        email = old-address@example.com
        email = *@former-employer.example
HINT

	if sgit_confirm "$NL""Create it now?"; then
		_config_create_interactively
		return 0
	fi
	exit 1
}

sgit_config_load() {
	SGIT_SHADOW_NAME="${SGIT_SHADOW_NAME:-$(_config_one shadow.name)}"
	SGIT_SHADOW_EMAIL="${SGIT_SHADOW_EMAIL:-$(_config_one shadow.email)}"

	# real.email / real.name are purely a list of *additional* identities to
	# hide -- old addresses, other machines, work aliases. Globs are fine
	# anywhere in it. The identity that gets restored when pushing is not
	# taken from here; see sgit_identity_resolve.
	SGIT_REAL_EMAILS="${SGIT_REAL_EMAILS:-$(_config_all real.email)}"
	SGIT_REAL_NAMES="${SGIT_REAL_NAMES:-$(_config_all real.name)}"

	SGIT_REWRITE_TRAILERS="${SGIT_REWRITE_TRAILERS:-$(_config_one rewrite.trailers)}"
	SGIT_REWRITE_TRAILERS="${SGIT_REWRITE_TRAILERS:-true}"

	# Configured tokens extend the built-in list rather than replacing it.
	# Dropping a default would silently stop an identity trailer from being
	# rewritten -- a privacy regression arriving by way of a convenience --
	# while recognising one token too many costs nothing.
	if [ -z "${SGIT_TRAILER_TOKENS:-}" ]; then
		SGIT_TRAILER_TOKENS="$SGIT_DEFAULT_TRAILER_TOKENS$NL$(_config_all rewrite.trailerTokens)"
	fi

	if [ -z "$SGIT_SHADOW_NAME" ] || [ -z "$SGIT_SHADOW_EMAIL" ]; then
		_config_missing
	fi

}

# Whether the real repository would sign what it commits.
#
# The same reasoning as sgit_identity_resolve: if committing in the real
# repository directly would produce a signed commit, a push from the shadow
# side should produce one too. git's own configuration decides, resolved
# against the real repository -- which also means it can be turned off for one
# repository alone, without touching the rest of your setup:
#
#     sgit git config commit.gpgsign false
#
# -> SGIT_SIGN_COMMITS, SGIT_SIGN_TAGS
sgit_signing_resolve() {
	local real="$1"
	SGIT_SIGN_COMMITS=no
	SGIT_SIGN_TAGS=no
	if [ "$(git -C "$real" config --bool commit.gpgsign 2>/dev/null || printf false)" = true ]; then
		SGIT_SIGN_COMMITS=yes
	fi
	if [ "$(git -C "$real" config --bool tag.gpgsign 2>/dev/null || printf false)" = true ]; then
		SGIT_SIGN_TAGS=yes
	fi
	return 0
}

# The identity to restore when pushing, and therefore also one to hide when
# fetching.
#
# It is whatever git itself would use for the real repository: its own local
# configuration, then the user's, then the system's. Working in the shadow
# repository should reach the upstream as working in the real one would, and
# git's own precedence is the definition of that. It also means the identity is
# stated once, where it already lives, rather than repeated here.
#
# Whatever comes out is added to the hide list as well. Otherwise a commit made
# under it somewhere else -- another clone, another machine -- would come back
# down unrewritten and put the real identity into the shadow repository.
sgit_identity_resolve() {
	local real="$1" name email

	name="${SGIT_REAL_NAME:-$(git -C "$real" config user.name 2>/dev/null || true)}"
	email="${SGIT_REAL_EMAIL:-$(git -C "$real" config user.email 2>/dev/null || true)}"

	if [ -z "$name" ] || [ -z "$email" ]; then
		printf 'sgit: cannot tell which identity to restore when pushing\n' >&2
		printf 'git would not know either: user.name and user.email are unset.\n\n' >&2
		printf 'Set them as you normally would:\n' >&2
		printf '    git config --global user.name  "Your Name"\n' >&2
		printf '    git config --global user.email you@example.com\n\n' >&2
		# The mirror's path is the useful half of this advice on the store
		# side, and a leak across the pre-receive boundary (spec 6.4).
		if [ -n "${SGIT_HOOK_BOUNDARY:-}" ]; then
			printf 'or for that repository alone, where the store is:\n' >&2
			printf '    git -C <the real mirror> config user.email you@example.com\n' >&2
		else
			printf 'or for this repository alone:\n' >&2
			printf '    git -C %s config user.email you@example.com\n' "$real" >&2
		fi
		exit 1
	fi

	SGIT_REAL_NAME="$name"
	SGIT_REAL_EMAIL="$email"

	if ! ident_is_real "$name" "$email"; then
		SGIT_REAL_EMAILS="${SGIT_REAL_EMAILS:+$SGIT_REAL_EMAILS$NL}$email"
		SGIT_REAL_NAMES="${SGIT_REAL_NAMES:+$SGIT_REAL_NAMES$NL}$name"
	fi
}
