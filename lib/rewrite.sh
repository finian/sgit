# shellcheck shell=bash
#
# The rewrite engine (spec 5).
#
# Rewriting a commit changes only header identity fields; the tree is never
# touched, which is what keeps the shadow working tree byte-identical to the
# real one (spec G1/N1). Because a changed header changes the object id, every
# descendant must be rewritten too, so the engine walks in topological order
# and remaps parent pointers through a persistent table (spec 5.2, 5.8).
#
# The map lives in git refs rather than a side database: lookups are cheap,
# packed-refs compresses it, and ref reachability keeps both sides' objects
# safe from `git gc` for free.
#
#   shadow.git  refs/sgit/map/<real-sha>    -> shadow object
#   real.git    refs/sgit/rmap/<shadow-sha> -> real object
#
# Both refs are written on every rewrite regardless of direction, so either
# side can be looked up from either direction.

[ -n "${SGIT_REWRITE_SH:-}" ] && return 0
SGIT_REWRITE_SH=1

SGIT_MAP_REF=refs/sgit/map
SGIT_RMAP_REF=refs/sgit/rmap

# When "no", sgit_rewrite leaves the map updates in its batch files instead of
# committing them, and the caller commits them with sgit_rewrite_flush_refs.
#
# The push path needs this. Its objects live in receive-pack's quarantine and
# are discarded if the hook fails, so a map ref written before the upstream has
# accepted the push would end up pointing at an object that never existed.
SGIT_REWRITE_COMMIT_REFS=yes

# --- in-memory map ----------------------------------------------------------
#
# Loaded once per run and consulted per parent pointer. Shell variable
# indirection is used as the hash table: bash 3.2 (the version macOS ships)
# has no associative arrays, and forking `git rev-parse` per parent would
# dominate the runtime.

SGIT_MAP_LOADED=no
SGIT_MAP_REPO=''
SGIT_MAP_PREFIX=''

map_put() { eval "SGITMAP_$1=\$2"; }

# Where to ask when the table has not been loaded.
map_source() {
	# Unchanged source keeps whatever has already been loaded: the tag pass
	# runs straight after the commit pass and would otherwise throw away a
	# table that was just read in.
	if [ "$1" = "$SGIT_MAP_REPO" ] && [ "$2" = "$SGIT_MAP_PREFIX" ]; then
		return 0
	fi
	SGIT_MAP_REPO="$1"
	SGIT_MAP_PREFIX="$2"
	SGIT_MAP_LOADED=no
}

# Consult the table, and fall back to asking git when there is no table.
#
# Loading is 80 microseconds an entry, so a repository with twelve thousand
# commits spends over a second on it -- worth paying to rewrite a thousand
# objects, and pure waste to answer the three questions a fetch that rewrote
# nothing actually asks.
map_lookup() {
	eval "MAP_VALUE=\${SGITMAP_$1-}"
	[ -z "$MAP_VALUE" ] || return 0
	[ "$SGIT_MAP_LOADED" = no ] || return 0
	[ -n "$SGIT_MAP_REPO" ] || return 0

	MAP_VALUE=$(git -C "$SGIT_MAP_REPO" rev-parse --verify --quiet \
		"$SGIT_MAP_PREFIX/$1" 2>/dev/null) || MAP_VALUE=''
	[ -z "$MAP_VALUE" ] || map_put "$1" "$MAP_VALUE"
	return 0
}

# Object sizes, prefetched in bulk. Sizes are needed only to detect payloads
# the shell cannot carry, and asking for them one at a time would add a third
# of the process spawns to a run that is already dominated by them.
size_put() { eval "SGITSZ_$1=\$2"; }
size_lookup() { eval "SIZE_VALUE=\${SGITSZ_$1-}"; }

size_prefetch() {
	local repo="$1" list="$2" sha type size
	while read -r sha type size; do
		[ "$type" = missing ] && continue
		[ -n "$size" ] || continue
		size_put "$sha" "$size"
	done <<SIZES
$(git -C "$repo" cat-file --batch-check <"$list" 2>/dev/null)
SIZES
}

map_load() {
	local repo="$1" prefix="$2" invert="$3" sha ref key
	SGIT_MAP_LOADED=yes
	while read -r sha ref; do
		[ -n "$ref" ] || continue
		key="${ref##*/}"
		if [ "$invert" = yes ]; then
			map_put "$sha" "$key"
		else
			map_put "$key" "$sha"
		fi
	done <<REFS
$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)' "$prefix" 2>/dev/null)
REFS
}

# --- object rewriting -------------------------------------------------------

# Strip a trailing PGP signature block from a tag message. Tag signatures are
# appended to the message body rather than carried in a header, so they need a
# different removal path from a commit's gpgsig (spec 5.5, 5.7).
_strip_tag_signature() {
	local m="$1" marker="${NL}-----BEGIN PGP SIGNATURE-----${NL}"
	case "$m" in
	*"$marker"*) printf '%s' "${m%%"$marker"*}$NL" ;;
	*) printf '%s' "$m" ;;
	esac
}

# Rewrite identity trailers in a commit or tag message (spec 5.6).
#   -> MSG_OUT, MSG_CHANGED
#
# Deviation from spec 5.6, deliberate: every line matching a configured token
# is considered, not only lines inside the final trailer block. Missing a
# Signed-off-by leaks an identity, while touching one quoted mid-message is
# cosmetic, so the engine errs toward privacy. The rule is symmetric, so
# round-trips still reproduce the original bytes.
_rewrite_message() {
	local rest="$1" out="" token value
	MSG_CHANGED=0

	while [ -n "$rest" ]; do
		sgit_chop "$rest"
		rest="$CHOP_REST"

		case "$CHOP_LINE" in
		*': '*)
			token="${CHOP_LINE%%: *}"
			value="${CHOP_LINE#*: }"
			if ident_is_trailer_token "$token"; then
				ident_rewrite "$value"
				if [ "$IDENT_CHANGED" = 1 ]; then
					CHOP_LINE="$token: $IDENT_OUT"
					MSG_CHANGED=1
				fi
			fi
			;;
		esac

		out="$out$CHOP_LINE$CHOP_EOL"
	done

	MSG_OUT="$out"
}

# Rewrite one raw object.
#   $1 raw object bytes, $2 type (commit|tag)
#   -> REWRITE_OUT, REWRITE_CHANGED
#
# REWRITE_CHANGED stays 0 when nothing in the object needed touching. Such an
# object keeps its original object id (spec 5.2) and, importantly, keeps its
# signature: a signature is only dropped from an object that is being rewritten
# anyway, because a stale signature that no longer verifies is worse than none.
rewrite_object_text() {
	local raw="$1" type="$2"
	local hdr msg out="" line key val changed=0 in_drop=0 has_msg=0

	case "$raw" in
	*"$NL$NL"*)
		hdr="${raw%%"$NL$NL"*}"
		msg="${raw#*"$NL$NL"}"
		has_msg=1
		;;
	*)
		hdr="$raw"
		msg=""
		;;
	esac

	local rest="$hdr"
	while [ -n "$rest" ]; do
		sgit_chop "$rest"
		rest="$CHOP_REST"
		line="$CHOP_LINE"

		# A leading space continues the previous header, which is how
		# gpgsig and mergetag carry their multi-line payloads.
		case "$line" in
		' '*)
			if [ "$in_drop" = 0 ]; then
				out="$out$line$NL"
			fi
			continue
			;;
		esac
		in_drop=0

		case "$line" in
		*' '*)
			key="${line%% *}"
			val="${line#* }"
			;;
		*)
			key="$line"
			val=""
			;;
		esac

		case "$key" in
		parent | object)
			map_lookup "$val"
			[ -n "$MAP_VALUE" ] ||
				sgit_die "unmapped $key $val: ancestors must be rewritten first"
			if [ "$MAP_VALUE" != "$val" ]; then
				changed=1
			fi
			out="$out$key $MAP_VALUE$NL"
			;;
		author | committer | tagger)
			ident_rewrite "$val"
			if [ "$IDENT_CHANGED" = 1 ]; then
				changed=1
			fi
			out="$out$key $IDENT_OUT$NL"
			;;
		gpgsig | gpgsig-sha256)
			# Dropped only if the object turns out to be rewritten;
			# see the note above. Not setting `changed` is deliberate.
			in_drop=1
			;;
		mergetag)
			# Embeds a whole tag object, tagger identity and signature
			# included (spec 5.3). Metadata only: dropping it affects
			# neither the tree nor the parent pointers.
			in_drop=1
			;;
		*)
			out="$out$line$NL"
			;;
		esac
	done

	if [ "$SGIT_REWRITE_TRAILERS" = true ] && [ -n "$msg" ]; then
		_rewrite_message "$msg"
		msg="$MSG_OUT"
		if [ "$MSG_CHANGED" = 1 ]; then
			changed=1
		fi
	fi

	if [ "$changed" = 1 ] && [ "$type" = tag ]; then
		msg=$(_strip_tag_signature "$msg"; printf X)
		msg="${msg%X}"
	fi

	if [ "$has_msg" = 1 ]; then
		REWRITE_OUT="$out$NL$msg"
	else
		REWRITE_OUT="$out"
	fi
	REWRITE_CHANGED="$changed"
}

# Read an object's exact bytes. Command substitution eats trailing newlines,
# so a sentinel is appended and stripped.
_read_object() {
	local repo="$1" sha="$2" type="$3" raw size
	raw=$(git -C "$repo" cat-file "$type" "$sha" && printf X) ||
		sgit_die "cannot read $type $sha from $repo"
	raw="${raw%X}"

	# A NUL byte would have been truncated by the shell. Refuse rather than
	# silently write a corrupted object.
	size_lookup "$sha"
	size="$SIZE_VALUE"
	if [ -z "$size" ]; then
		size=$(git -C "$repo" cat-file -s "$sha")
	fi
	[ "${#raw}" = "$size" ] ||
		sgit_die "object $sha contains bytes the shell cannot carry (size $size, read ${#raw})"

	OBJ_RAW="$raw"
}

# What to say when signing does not work. The signing tool names the key, and a
# key is named after its owner, so its output is scrubbed before it travels
# back to the shadow side.
_signing_failed() {
	local what="$1" setting="$2"
	sgit_warn "cannot sign the $what for the real repository:"
	if [ -f "$SGIT_TMPDIR/tokens" ]; then
		scrub_stream "$SGIT_TMPDIR/tokens" <"$SGIT_TMPDIR/sign-err" >&2
	else
		sed 's/^/  /' <"$SGIT_TMPDIR/sign-err" >&2
	fi
	sgit_die "make the signing key available, or turn signing off for this repository: sgit git config $setting false"
}

# Write a commit through git itself, so that it comes out signed the way the
# real repository signs.
#
# The hand-assembled path below cannot sign: a signature covers the object's
# own bytes, and producing one would mean reimplementing git's signing for
# every format it supports -- openpgp, x509, ssh -- with the certainty of
# getting it subtly wrong and shipping commits that look signed and do not
# verify. commit-tree does it properly, at the cost of only being able to
# express the headers it knows about.
#
# -> WROTE_SHA
_write_commit_signed() {
	local dst="$1" text="$2"
	local hdr msg rest line key val tree='' enc='' p
	local an ae ad cn ce cd

	case "$text" in
	*"$NL$NL"*)
		hdr="${text%%"$NL$NL"*}"
		msg="${text#*"$NL$NL"}"
		;;
	*)
		hdr="$text"
		msg=''
		;;
	esac

	set --
	rest="$hdr"
	while [ -n "$rest" ]; do
		sgit_chop "$rest"
		rest="$CHOP_REST"
		line="$CHOP_LINE"
		key="${line%% *}"
		val="${line#* }"
		case "$key" in
		tree) tree="$val" ;;
		parent) set -- "$@" -p "$val" ;;
		encoding) enc="$val" ;;
		author)
			ident_split "$val" || sgit_die "malformed author line while signing"
			an="$IDENT_NAME"
			ae="$IDENT_EMAIL"
			ad="${IDENT_TAIL# }"
			;;
		committer)
			ident_split "$val" || sgit_die "malformed committer line while signing"
			cn="$IDENT_NAME"
			ce="$IDENT_EMAIL"
			cd="${IDENT_TAIL# }"
			;;
		*)
			# Better to stop than to drop a header nobody expected.
			sgit_die "cannot sign a commit carrying a '$key' header; turn signing off for this repository with: sgit git config commit.gpgsign false"
			;;
		esac
	done
	[ -n "$tree" ] || sgit_die "no tree in the commit being signed"

	sgit_tmpdir_init
	printf '%s' "$msg" >"$SGIT_TMPDIR/sign-msg"

	WROTE_SHA=$(
		GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" 			GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" 			GIT_COMMITTER_DATE="$cd" 			git -C "$dst" ${enc:+-c "i18n.commitEncoding=$enc"} 			commit-tree -S "$@" -F "$SGIT_TMPDIR/sign-msg" "$tree" 			2>"$SGIT_TMPDIR/sign-err" </dev/null
	) || _signing_failed commit commit.gpgsign
	[ -n "$WROTE_SHA" ] || sgit_die "signing produced no object"
}

# Write an annotated tag through git itself, for the same reason.
#
# `git tag` writes refs/tags/<name> as a side effect, and the name cannot be
# moved out of the way because it is part of the object being signed. So the
# ref is saved and put back: the object survives on its own, and the real ref
# is set later, once the upstream has accepted the push. The repository lock is
# held throughout, so nothing else can look in between.
#
# -> WROTE_SHA
_write_tag_signed() {
	local dst="$1" text="$2"
	local hdr msg rest line key val
	local obj='' name='' tn='' te='' td='' saved=''

	case "$text" in
	*"$NL$NL"*)
		hdr="${text%%"$NL$NL"*}"
		msg="${text#*"$NL$NL"}"
		;;
	*)
		hdr="$text"
		msg=''
		;;
	esac

	rest="$hdr"
	while [ -n "$rest" ]; do
		sgit_chop "$rest"
		rest="$CHOP_REST"
		line="$CHOP_LINE"
		key="${line%% *}"
		val="${line#* }"
		case "$key" in
		object) obj="$val" ;;
		type) ;;
		tag) name="$val" ;;
		tagger)
			ident_split "$val" || sgit_die "malformed tagger line while signing"
			tn="$IDENT_NAME"
			te="$IDENT_EMAIL"
			td="${IDENT_TAIL# }"
			;;
		*)
			sgit_die "cannot sign a tag carrying a '$key' header; turn signing off for this repository with: sgit git config tag.gpgsign false"
			;;
		esac
	done
	[ -n "$obj" ] || sgit_die "no object in the tag being signed"
	[ -n "$name" ] || sgit_die "no name in the tag being signed"

	sgit_tmpdir_init
	printf '%s' "$msg" >"$SGIT_TMPDIR/sign-msg"

	saved=$(git -C "$dst" rev-parse --verify --quiet "refs/tags/$name" || true)

	# --cleanup=verbatim, or a line beginning with # would be taken for a
	# comment and removed from someone else's release notes.
	GIT_COMMITTER_NAME="$tn" GIT_COMMITTER_EMAIL="$te" GIT_COMMITTER_DATE="$td" 		git -C "$dst" tag -s -f --cleanup=verbatim 		-F "$SGIT_TMPDIR/sign-msg" "$name" "$obj" 		>/dev/null 2>"$SGIT_TMPDIR/sign-err" </dev/null ||
		_signing_failed tag tag.gpgsign

	WROTE_SHA=$(git -C "$dst" rev-parse --verify "refs/tags/$name") ||
		sgit_die "signing produced no tag object"

	if [ -n "$saved" ]; then
		git -C "$dst" update-ref "refs/tags/$name" "$saved"
	else
		git -C "$dst" update-ref -d "refs/tags/$name"
	fi
}

# --- the object stream (spec 15) --------------------------------------------
#
# Rewriting is two git calls per commit -- read the original, write the
# replacement -- and on a real repository that is tens of thousands of
# processes. Measured on tmux/tmux, system time matched user time, which is
# what fork/exec domination looks like.
#
# Both calls have a form that stays running and answers one request at a time:
# `cat-file --batch` and `hash-object --stdin-paths`. Kept open over FIFOs for
# the length of the walk, they turn two processes per commit into two for the
# whole rewrite. Falls back to the process-per-object path whenever the pair
# cannot be set up, so this is an optimisation and never a requirement.

SGIT_STREAM=off
SGIT_STREAM_RPID=''
# Whether the destination already reaches the source's objects; settled
# once per walk in sgit_rewrite, and false for every other caller.
SGIT_DST_SEES_SRC=no
SGIT_STREAM_WPID=''

# Not a valid object name, so `cat-file --batch` answers it with one known
# line. Sent after every request, it marks where one answer ends -- see
# _stream_read for why that matters.
SGIT_STREAM_SYNC=sgit-resync

_rewrite_stream_open() {
	local src="$1" dst="$2" d

	SGIT_STREAM=off
	[ -z "${SGIT_NO_STREAM:-}" ] || return 0

	sgit_tmpdir_init
	d="$SGIT_TMPDIR/stream"
	mkdir -p "$d" 2>/dev/null || return 0
	SGIT_STREAM_DIR="$d"
	SGIT_STREAM_OBJ="$d/object"
	mkfifo "$d/rin" "$d/rout" "$d/win" "$d/wout" 2>/dev/null || return 0

	# GIT_FLUSH=1 so that neither writes into a buffer while this end waits
	# for the answer that is sitting in it.
	GIT_FLUSH=1 git -C "$src" cat-file --batch <"$d/rin" >"$d/rout" &
	SGIT_STREAM_RPID=$!
	GIT_FLUSH=1 git -C "$dst" hash-object -w -t commit --stdin-paths \
		<"$d/win" >"$d/wout" &
	SGIT_STREAM_WPID=$!

	# Opening a FIFO blocks until the other end opens it too, so the order
	# here is the order the two children take their redirections in: each
	# waits on its input first, then its output.
	exec 6>"$d/rin" 7<"$d/rout" 8>"$d/win" 9<"$d/wout"

	SGIT_STREAM=on
	sgit_cleanup_add "$d"
	return 0
}

_rewrite_stream_close() {
	[ "$SGIT_STREAM" = on ] || return 0
	SGIT_STREAM=off
	# Closing the input is what tells each of them to finish.
	exec 6>&- 8>&-
	wait "$SGIT_STREAM_RPID" 2>/dev/null || true
	wait "$SGIT_STREAM_WPID" 2>/dev/null || true
	exec 7<&- 9<&-
	return 0
}

# One object out of the reader.
#   $1 sha -> OBJ_RAW
#
# `cat-file --batch` answers with a header line, the object's bytes, and a
# newline of its own. Taking exactly <size> bytes is the awkward part: bash 3.2
# has no `read -N`, so the object is read a line at a time and the bytes are
# counted. Commit objects are newline-separated text, so that is exact rather
# than approximate -- but a shell variable cannot hold a NUL, and a NUL would
# make the count short and quietly slide the reader into the next object.
# Hence the sync line: every request is followed by one git cannot resolve, so
# a misread is caught at the object it happens on instead of corrupting the
# rest of the walk.
_stream_read() {
	local sha="$1" rsha rtype size got line raw

	printf '%s\n%s\n' "$sha" "$SGIT_STREAM_SYNC" >&6

	IFS=' ' read -r rsha rtype size <&7 ||
		sgit_die "the object reader stopped before $sha"
	[ "$rtype" != missing ] || sgit_die "object $sha is missing from the source"
	[ "$rsha" = "$sha" ] ||
		sgit_die "asked the object reader for $sha and it answered about $rsha"

	raw=''
	got=0
	while [ "$got" -lt "$size" ]; do
		IFS= read -r line <&7 ||
			sgit_die "the object reader stopped inside $sha"
		raw="$raw$line$NL"
		got=$((got + ${#line} + 1))
	done

	if [ "$got" = "$size" ]; then
		# The object ended with a newline of its own, so the one git adds
		# after every object is still to come.
		IFS= read -r line <&7 ||
			sgit_die "the object reader stopped after $sha"
		[ -z "$line" ] ||
			sgit_die "object $sha did not end where git said it would"
	elif [ "$got" = "$((size + 1))" ]; then
		# It did not, and git's own newline is the one that ended the last
		# line read.
		raw="${raw%$NL}"
	else
		sgit_die "object $sha: read $got bytes where git said $size"
	fi

	IFS=' ' read -r line rtype <&7 ||
		sgit_die "the object reader stopped after $sha"
	[ "$line" = "$SGIT_STREAM_SYNC" ] && [ "$rtype" = missing ] ||
		sgit_die "the object reader lost its place after $sha"

	OBJ_RAW="$raw"
}

# One object into the writer.
#   $1 text -> WROTE_SHA
#
# --stdin-paths takes paths rather than content, so the object goes through a
# file. A write and a read of a few hundred bytes that stay in the page cache
# is a great deal less than a process.
_stream_write() {
	printf '%s' "$1" >"$SGIT_STREAM_OBJ" ||
		sgit_die "cannot stage an object for writing"
	printf '%s\n' "$SGIT_STREAM_OBJ" >&8
	IFS= read -r WROTE_SHA <&9 ||
		sgit_die "the object writer stopped"
	case "$WROTE_SHA" in
	????????????????????????????????????????) ;;
	*) sgit_die "the object writer answered '$WROTE_SHA'" ;;
	esac
}

# Rewrite a single object and record it in both map refs.
#   $1 src repo, $2 dst repo, $3 sha, $4 type
#   -> REWROTE_SHA
_rewrite_one() {
	local src="$1" dst="$2" sha="$3" type="$4" new streamed=no

	if [ "$SGIT_STREAM" = on ] && [ "$type" = commit ]; then
		streamed=yes
		_stream_read "$sha"
	else
		_read_object "$src" "$sha" "$type"
	fi
	rewrite_object_text "$OBJ_RAW" "$type"

	if [ "$REWRITE_CHANGED" = 0 ]; then
		# Unchanged objects keep their identity on both sides. The object
		# still has to exist in the destination: shadow.git reaches
		# real.git through alternates, but not the other way round.
		#
		# When it does, that is settled for the whole walk rather than
		# asked about once per object -- and most of a history is usually
		# other people's commits, which take exactly this path.
		new="$sha"
		if [ "$SGIT_DST_SEES_SRC" != yes ] &&
			! git -C "$dst" cat-file -e "$sha" 2>/dev/null; then
			new=$(printf '%s' "$OBJ_RAW" |
				git -C "$dst" hash-object -w -t "$type" --stdin)
			[ "$new" = "$sha" ] ||
				sgit_die "copying $sha into $dst produced $new"
		fi
	elif [ "$type" = commit ] && [ "${SGIT_DIRECTION:-}" = up ] &&
		[ "${SGIT_SIGN_COMMITS:-no}" = yes ]; then
		_write_commit_signed "$dst" "$REWRITE_OUT"
		new="$WROTE_SHA"
	elif [ "$type" = tag ] && [ "${SGIT_DIRECTION:-}" = up ] &&
		[ "${SGIT_SIGN_TAGS:-no}" = yes ]; then
		_write_tag_signed "$dst" "$REWRITE_OUT"
		new="$WROTE_SHA"
	elif [ "$streamed" = yes ]; then
		_stream_write "$REWRITE_OUT"
		new="$WROTE_SHA"
	else
		new=$(printf '%s' "$REWRITE_OUT" |
			git -C "$dst" hash-object -w -t "$type" --stdin) ||
			sgit_die "cannot write rewritten $type for $sha"
	fi

	map_put "$sha" "$new"
	REWROTE_SHA="$new"
}

# One step of the progress counter.
#
# The walk covers everything reachable, and most of it is usually already
# mapped and skipped in an instant. Reporting how many were actually rewritten
# alongside it is the difference between a counter that looks stuck and one
# that shows work happening. Reads sgit_rewrite's locals, and is called after
# each object is dealt with so that the last line it prints is right.
_rewrite_tick() {
	if [ "$n" -gt 0 ]; then
		sgit_progress "$seen" " ($n new)"
	else
		sgit_progress "$seen"
	fi
}

# Rewrite a set of commits, plus optionally the annotated tags pointing into
# them, from one side of the store to the other.
#
#   sgit_rewrite REAL_REPO SHADOW_REPO down|up [rev-list args...]
#
# Direction decides which repo is source and which is destination; the map ref
# layout is fixed and identical either way.
sgit_rewrite() {
	local real="$1" shadow="$2" direction="$3"
	shift 3

	local src dst map_batch rmap_batch sha n=0 changed=0 total=0 seen=0 suffix='' \
		map_repo map_prefix
	SGIT_DIRECTION="$direction"

	case "$direction" in
	down)
		src="$real"
		dst="$shadow"
		map_repo="$shadow"
		map_prefix="$SGIT_MAP_REF"
		;;
	up)
		src="$shadow"
		dst="$real"
		map_repo="$real"
		map_prefix="$SGIT_RMAP_REF"
		;;
	*) sgit_die "unknown direction: $direction" ;;
	esac
	map_source "$map_repo" "$map_prefix"

	local tmp revs
	sgit_tmpdir_init
	tmp="$SGIT_TMPDIR"
	map_batch="$tmp/map.batch"
	rmap_batch="$tmp/rmap.batch"
	revs="$tmp/revs"
	: >"$map_batch"
	: >"$rmap_batch"

	# Written to a file rather than consumed from a here-doc so that a
	# rev-list failure is caught instead of silently yielding no work.
	git -C "$src" rev-list --topo-order --reverse "$@" >"$revs" ||
		sgit_die "rev-list failed in $src"
	total=$(wc -l <"$revs" | tr -d ' ')

	# Load the whole table only when it is about to earn its keep. With
	# nothing to rewrite the only questions left are one per branch and tag,
	# and asking git those directly is cheaper than reading every entry --
	# unless there are a great many refs, in which case it is not.
	if [ "$total" -gt 0 ]; then
		map_load "$map_repo" "$map_prefix" no
	elif [ "$(git -C "$src" for-each-ref --format=x refs/heads refs/tags |
		wc -l | tr -d ' ')" -gt 50 ]; then
		map_load "$map_repo" "$map_prefix" no
	fi

	# Does the destination already reach the source's objects? Down it does:
	# shadow.git is created with an alternates link to real.git, so an
	# object that comes out of the rewrite unchanged is readable from the
	# other side without being copied. Asked once here, because the answer
	# cannot change during a walk and the question was costing a process per
	# unchanged commit.
	SGIT_DST_SEES_SRC=no
	if [ "$(cat "$dst/objects/info/alternates" 2>/dev/null)" = "$src/objects" ]; then
		SGIT_DST_SEES_SRC=yes
	fi

	if [ "$total" -gt 0 ]; then
		_rewrite_stream_open "$src" "$dst"
		# Sizes come with the objects when they are streamed; prefetching
		# them is a whole pass over the history for nothing.
		[ "$SGIT_STREAM" = on ] || size_prefetch "$src" "$revs"
	fi
	sgit_progress_begin "$total" 'commits' 

	while read -r sha; do
		[ -n "$sha" ] || continue
		seen=$((seen + 1))
		map_lookup "$sha"
		if [ -n "$MAP_VALUE" ]; then
			# The throttle is spelled out here, not inside a function: this
			# runs once per object in the history, and a skipped object is
			# otherwise two builtins' worth of work.
			if [ "$SGIT_PROGRESS_STEP" != 0 ] &&
				[ "$((seen % SGIT_PROGRESS_STEP))" -eq 0 ]; then
				_rewrite_tick
			fi
			continue
		fi

		_rewrite_one "$src" "$dst" "$sha" commit
		n=$((n + 1))
		# An object whose text came out unchanged keeps its id on both
		# sides; everything else gets a new one, including a commit that
		# only moved because an ancestor did. Comparing the two ids says
		# which happened without caring why.
		[ "$REWROTE_SHA" = "$sha" ] || changed=$((changed + 1))

		if [ "$direction" = down ]; then
			printf 'update %s/%s %s\n' "$SGIT_MAP_REF" "$sha" "$REWROTE_SHA" >>"$map_batch"
			printf 'update %s/%s %s\n' "$SGIT_RMAP_REF" "$REWROTE_SHA" "$sha" >>"$rmap_batch"
		else
			printf 'update %s/%s %s\n' "$SGIT_RMAP_REF" "$sha" "$REWROTE_SHA" >>"$rmap_batch"
			printf 'update %s/%s %s\n' "$SGIT_MAP_REF" "$REWROTE_SHA" "$sha" >>"$map_batch"
		fi
		if [ "$SGIT_PROGRESS_STEP" != 0 ] &&
			[ "$((seen % SGIT_PROGRESS_STEP))" -eq 0 ]; then
			_rewrite_tick
		fi
	done <"$revs"

	# The last object rarely lands on a step boundary, and the final count is
	# the one worth being right.
	if [ "$SGIT_PROGRESS_STEP" != 0 ] &&
		[ "$((total % SGIT_PROGRESS_STEP))" -ne 0 ]; then
		_rewrite_tick
	fi
	sgit_progress_end
	_rewrite_stream_close

	SGIT_REWROTE_COUNT="$n"
	SGIT_REWROTE_CHANGED="$changed"
	sgit_debug "rewrote $n object(s) $direction, $changed with a new id"

	if [ "$SGIT_REWRITE_COMMIT_REFS" = no ]; then
		return 0
	fi
	sgit_rewrite_flush_refs "$real" "$shadow"
}

# One transaction per side, so an interrupted run leaves unreferenced objects
# behind but never a half-written map. Re-running is idempotent.
sgit_rewrite_flush_refs() {
	local real="$1" shadow="$2" map_batch rmap_batch
	sgit_tmpdir_init
	map_batch="$SGIT_TMPDIR/map.batch"
	rmap_batch="$SGIT_TMPDIR/rmap.batch"

	if [ -f "$map_batch" ] && [ -s "$map_batch" ]; then
		git -C "$shadow" update-ref --stdin <"$map_batch" ||
			sgit_die "cannot write map refs into $shadow"
	fi
	if [ -f "$rmap_batch" ] && [ -s "$rmap_batch" ]; then
		git -C "$real" update-ref --stdin <"$rmap_batch" ||
			sgit_die "cannot write map refs into $real"
	fi
	: >"$map_batch"
	: >"$rmap_batch"
}

# Rewrite the annotated tag objects under refs/tags/.
#
# Lightweight tags need nothing: they are just refs, and follow whatever their
# target was remapped to. Annotated tags are real objects carrying a tagger
# identity, so they go through the same engine (spec 5.4). Commits must be
# rewritten first, since a tag points at one.
sgit_rewrite_tags() {
	local real="$1" shadow="$2" direction="$3"
	local src dst tag_sha ref type tmp list n=0

	SGIT_DIRECTION="$direction"
	case "$direction" in
	down) src="$real"; dst="$shadow"; map_source "$shadow" "$SGIT_MAP_REF" ;;
	up) src="$shadow"; dst="$real"; map_source "$real" "$SGIT_RMAP_REF" ;;
	*) sgit_die "unknown direction: $direction" ;;
	esac

	sgit_tmpdir_init
	tmp="$SGIT_TMPDIR"
	list="$tmp/tags"
	: >"$tmp/tag-map.batch"
	: >"$tmp/tag-rmap.batch"
	git -C "$src" for-each-ref --format='%(objectname) %(objecttype) %(refname)' \
		refs/tags >"$list" || sgit_die "for-each-ref failed in $src"
	cut -d' ' -f1 <"$list" >"$tmp/tag-shas"
	size_prefetch "$src" "$tmp/tag-shas"

	while read -r tag_sha type ref; do
		[ "$type" = tag ] || continue
		map_lookup "$tag_sha"
		[ -z "$MAP_VALUE" ] || continue

		_rewrite_one "$src" "$dst" "$tag_sha" tag
		n=$((n + 1))

		if [ "$direction" = down ]; then
			printf 'update %s/%s %s\n' "$SGIT_MAP_REF" "$tag_sha" "$REWROTE_SHA"
		else
			printf 'update %s/%s %s\n' "$SGIT_MAP_REF" "$REWROTE_SHA" "$tag_sha"
		fi >>"$tmp/tag-map.batch"
		if [ "$direction" = down ]; then
			printf 'update %s/%s %s\n' "$SGIT_RMAP_REF" "$REWROTE_SHA" "$tag_sha"
		else
			printf 'update %s/%s %s\n' "$SGIT_RMAP_REF" "$tag_sha" "$REWROTE_SHA"
		fi >>"$tmp/tag-rmap.batch"
	done <"$list"

	if [ -s "$tmp/tag-map.batch" ]; then
		git -C "$shadow" update-ref --stdin <"$tmp/tag-map.batch" ||
			sgit_die "cannot write tag map refs into $shadow"
	fi
	if [ -s "$tmp/tag-rmap.batch" ]; then
		git -C "$real" update-ref --stdin <"$tmp/tag-rmap.batch" ||
			sgit_die "cannot write tag map refs into $real"
	fi

	SGIT_REWROTE_TAG_COUNT="$n"
	sgit_debug "rewrote $n tag object(s) $direction"
}
