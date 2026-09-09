#!/usr/bin/env bash
# Self-examination (spec 9.1): the store side, and the probe that travels to
# the working tree.
. "$(dirname "$0")/test-lib.sh"
setup_sgit_home
make_upstream

P="$TRASH/proj"
sgit clone "$UPSTREAM" "$P" >/dev/null 2>&1
id=$(id_of "$P")
SHADOW=$(store_shadow "$id")
REAL=$(store_real "$id")

# --- store side -------------------------------------------------------------

out=$(sgit doctor 2>&1)
case "$out" in
*'no problems found on the store side'*) pass 'a healthy store reports nothing' ;;
*) fail 'a healthy store reports nothing' "$out" ;;
esac
case "$out" in
*'mode 700'*) pass 'and confirms the store is owner-only' ;;
*) fail 'and confirms the store is owner-only' "$out" ;;
esac

# Each hardening setting is load-bearing, so removing one has to be noticed.
git -C "$SHADOW" config --unset-all transfer.hideRefs
out=$(sgit doctor 2>&1)
case "$out" in
*'transfer.hideRefs does not cover'*) pass 'a missing hideRefs is caught' ;;
*) fail 'a missing hideRefs is caught' "$out" ;;
esac
git -C "$SHADOW" config --add transfer.hideRefs refs/sgit/map
git -C "$SHADOW" config --add transfer.hideRefs refs/sgit/rmap

git -C "$SHADOW" config uploadpack.allowAnySHA1InWant true
out=$(sgit doctor 2>&1)
case "$out" in
*'allowAnySHA1InWant is not false'*) pass 'a loosened upload-pack is caught' ;;
*) fail 'a loosened upload-pack is caught' "$out" ;;
esac
git -C "$SHADOW" config uploadpack.allowAnySHA1InWant false

: >"$REAL/git-daemon-export-ok"
out=$(sgit doctor 2>&1)
case "$out" in
*'REAL mirror is exported'*) pass 'an exported real mirror is caught' ;;
*) fail 'an exported real mirror is caught' "$out" ;;
esac
rm -f "$REAL/git-daemon-export-ok"

mv "$SHADOW/hooks/pre-receive" "$SHADOW/hooks/pre-receive.off"
out=$(sgit doctor 2>&1)
case "$out" in
*'pre-receive hook is missing'*) pass 'a missing pre-receive hook is caught' ;;
*) fail 'a missing pre-receive hook is caught' "$out" ;;
esac
mv "$SHADOW/hooks/pre-receive.off" "$SHADOW/hooks/pre-receive"

out=$(sgit doctor 2>&1)
case "$out" in
*'no problems found on the store side'*) pass 'and everything is clean again' ;;
*) fail 'and everything is clean again' "$out" ;;
esac

# --- what [real] contributes ------------------------------------------------
#
# Reported as: a configuration holding only real.name was described as holding
# nothing, because only the addresses were counted.

git config -f "$SGIT_HOME/config" --unset-all real.email 2>/dev/null || true
git config -f "$SGIT_HOME/config" --unset-all real.name 2>/dev/null || true
out=$(sgit doctor 2>&1)
case "$out" in
*'nothing listed in [real]'*) pass 'an empty [real] is reported as empty' ;;
*) fail 'an empty [real] is reported as empty' "$out" ;;
esac

git config -f "$SGIT_HOME/config" --add real.name 'A Former Name'
out=$(sgit doctor 2>&1)
case "$out" in
*'nothing listed in [real]'*) fail 'a name-only [real] is not reported as empty' "$out" ;;
*) pass 'a name-only [real] is not reported as empty' ;;
esac
case "$out" in
*'1 name pattern'*) pass 'and the name is counted' ;;
*) fail 'and the name is counted' "$out" ;;
esac
case "$out" in
*'A Former Name'*) pass 'and shown, so it is clear the file was read' ;;
*) fail 'and shown, so it is clear the file was read' "$out" ;;
esac

git config -f "$SGIT_HOME/config" --add real.email 'old@example.com'
out=$(sgit doctor 2>&1)
case "$out" in
*'1 further address pattern(s) and 1 name pattern(s)'*) pass 'both halves are counted together' ;;
*) fail 'both halves are counted together' "$out" ;;
esac
git config -f "$SGIT_HOME/config" --unset-all real.name
git config -f "$SGIT_HOME/config" --unset-all real.email
git config -f "$SGIT_HOME/config" --add real.email '*@work-corp.com'

# --- colour ------------------------------------------------------------------
#
# A warning has to be visible without reading every line, but the output is
# also piped into things, and escape sequences would end up in whatever reads
# it.

esc=$(printf '\033')
escapes() { command grep -c "$esc" || true; }

is 'no colour when the output is not a terminal' 0 "$(sgit doctor 2>/dev/null | escapes)"
isnt 'colour when it is asked for' 0 "$(SGIT_COLOR=always sgit doctor 2>/dev/null | escapes)"
is 'NO_COLOR turns it off' 0 "$(NO_COLOR=1 SGIT_COLOR=auto sgit doctor 2>/dev/null | escapes)"
is 'and so does SGIT_COLOR=never' 0 "$(SGIT_COLOR=never sgit doctor 2>/dev/null | escapes)"
isnt 'while SGIT_COLOR=always overrides NO_COLOR' 0 \
	"$(NO_COLOR=1 SGIT_COLOR=always sgit doctor 2>/dev/null | escapes)"

# Only the labels are coloured, so the text stays greppable.
out=$(SGIT_COLOR=always sgit doctor 2>/dev/null)
case "$out" in
*"$esc[1;31m[warn]$esc[0m"*) pass 'a warning label is coloured' ;;
*"[warn]"*) fail 'a warning label is coloured' 'found [warn] without colour' ;;
*) pass 'a warning label is coloured (none present to check)' ;;
esac
case "$out" in
*"the pre-receive hook is installed"*) pass 'and the message text is left alone' ;;
*) fail 'and the message text is left alone' "$out" ;;
esac

probe=$(sgit doctor --emit-probe)
case "$probe" in
*NO_COLOR*) pass 'the probe honours the same rules' ;;
*) fail 'the probe honours the same rules' 'no NO_COLOR handling in the probe' ;;
esac

# --- the probe --------------------------------------------------------------

probe=$(sgit doctor --emit-probe)
case "$probe" in
*alice@example.com* | *'Alice Zhang'* | *"$UPSTREAM"* | *"$SGIT_HOME"*)
	fail 'the probe carries no secret' "it named something it should not" ;;
*) pass 'the probe carries no secret' ;;
esac
printf '%s\n' "$probe" >"$TRASH/probe.sh"
ok 'the probe is valid shell' sh -n "$TRASH/probe.sh"

out=$(cd "$P" && sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'no problems found in this working tree'*) pass 'a healthy working tree reports nothing' ;;
*) fail 'a healthy working tree reports nothing' "$out" ;;
esac
# It cannot know which identities are the user's, so it lists what it found and
# leaves the judgement to a person.
case "$out" in
*'Bob Lee <bob@elsewhere.org>'*) pass 'it lists the other identities it found' ;;
*) fail 'it lists the other identities it found' "$out" ;;
esac
case "$out" in
*'none of them should be yours'*) pass 'and asks for them to be checked' ;;
*) fail 'and asks for them to be checked' "$out" ;;
esac

git -C "$P" config sgit.leak 'https://github.com/acme/secret.git'
out=$(cd "$P" && sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'look like a URL'*) pass 'a URL planted in the metadata is caught' ;;
*) fail 'a URL planted in the metadata is caught' "$out" ;;
esac
git -C "$P" config --unset sgit.leak

mv "$P/.git/hooks/pre-push" "$P/.git/hooks/pre-push.off"
out=$(cd "$P" && sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'pre-push guard is missing'*) pass 'a missing guard is caught' ;;
*) fail 'a missing guard is caught' "$out" ;;
esac
mv "$P/.git/hooks/pre-push.off" "$P/.git/hooks/pre-push"

git -C "$P" config commit.gpgSign true
out=$(cd "$P" && sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'commit.gpgSign is not false'*) pass 'signing left on is caught' ;;
*) fail 'signing left on is caught' "$out" ;;
esac
git -C "$P" config commit.gpgSign false

# --- the mapping table, which is as long as the history ---------------------
#
# One entry per commit, so a check that spends a process on each is linear in
# the size of the repository: 17ms an entry measured, which is minutes of
# silence on a real repository and was reported as a hang. The bound below is
# far above what one batched query costs and far below what a process each
# does, so it fails on the shape of the code rather than on the speed of the
# machine.

pad=$(git -C "$SHADOW" rev-parse --verify refs/heads/main)
i=0
while [ "$i" -lt 2000 ]; do
	printf 'create refs/sgit/map/%040d %s\n' "$i" "$pad"
	i=$((i + 1))
done | git -C "$SHADOW" update-ref --stdin

start=$(date +%s)
out=$(sgit doctor 2>&1)
elapsed=$(( $(date +%s) - start ))
case "$out" in
*'200'[0-9]' mapping entries, all resolvable'*)
	pass 'a large mapping table is checked in full' ;;
*) fail 'a large mapping table is checked in full' "$out" ;;
esac
if [ "$elapsed" -lt 15 ]; then
	pass 'without a process per entry'
else
	fail 'without a process per entry' "took ${elapsed}s for 2000 entries"
fi

# A ref pointing at an object that is gone is exactly what this check is for,
# and the batched form must not lose it. Written as a loose ref because git
# refuses to create one pointing at a missing object.
mkdir -p "$SHADOW/refs/sgit/map"
printf 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00\n' \
	>"$SHADOW/refs/sgit/map/00000000000000000000000000000000deadbeef"
out=$(sgit doctor 2>&1)
case "$out" in
*'mapping entries point at objects that are gone'*)
	pass 'and a dangling entry is still caught' ;;
*) fail 'and a dangling entry is still caught' "$out" ;;
esac
rm -f "$SHADOW/refs/sgit/map/00000000000000000000000000000000deadbeef"


# The probe has to work in a virtual machine where sgit was never installed,
# so run it with sgit off the PATH entirely rather than reading the script for
# mentions of it.
out=$(cd "$P" && PATH=/usr/bin:/bin sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'no problems found in this working tree'*) pass 'the probe works with sgit off the PATH' ;;
*) fail 'the probe works with sgit off the PATH' "$out" ;;
esac

# --- a working tree on a shared filesystem ----------------------------------
#
# The arrangement the README warns about: the tree can be written from another
# machine, and a file watcher over there is enough to leave .git/index
# unopenable, after which git reads an empty index and calls every tracked file
# deleted. A test cannot mount a share, so the mount table is fabricated.
#
# The tree gets a path of its own, resolved, because the fabricated table is
# matched by prefix and $TRASH reaches this file by way of a symlink and a
# doubled slash. The store stays outside that path, which also checks that the
# two placements are judged separately.

SHARE="$(cd "$TRASH" && pwd -P)/share"
mkdir -p "$SHARE"
sgit clone "$UPSTREAM" "$SHARE/tree" >/dev/null 2>&1

mkdir -p "$TRASH/fakebin"
cat >"$TRASH/fakebin/mount" <<EOF
#!/bin/sh
echo '/dev/disk1s1 on / (apfs, local, journaled)'
echo 'virtio-fs on $SHARE (AppleVirtIOFS, nodev, nosuid, mounted by you)'
EOF
chmod +x "$TRASH/fakebin/mount"

out=$(PATH="$TRASH/fakebin:$PATH" sgit doctor 2>&1)
case "$out" in
*'the working tree is on a shared filesystem (AppleVirtIOFS)'*)
	pass 'a working tree on a share is caught' ;;
*) fail 'a working tree on a share is caught' "$out" ;;
esac
case "$out" in
*'git ls-files prints nothing'*) pass 'and the symptom is named, so it can be recognised' ;;
*) fail 'and the symptom is named, so it can be recognised' "$out" ;;
esac
case "$out" in
*'the store is not on a shared filesystem'*)
	pass 'while the store, elsewhere, is judged on its own' ;;
*) fail 'while the store, elsewhere, is judged on its own' "$out" ;;
esac

# The probe is what reaches a tree the store cannot see -- the cross-VM case,
# where the store is on the host and never records a working tree at all.
out=$(cd "$SHARE/tree" && PATH="$TRASH/fakebin:$PATH" sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'[warn]'*'shared filesystem (AppleVirtIOFS)'*)
	pass 'and the probe catches it from inside the tree' ;;
*) fail 'and the probe catches it from inside the tree' "$out" ;;
esac

# Not every system has mount(8) where the probe can reach it, and a mount table
# it cannot read is not a finding.
out=$(cd "$SHARE/tree" && PATH=/usr/bin:/bin sh "$TRASH/probe.sh" 2>&1)
case "$out" in
*'filesystem: unknown'*) pass 'an unreadable mount table reports unknown' ;;
*) fail 'an unreadable mount table reports unknown' "$out" ;;
esac
case "$out" in
*'[warn]'*'shared filesystem'*) fail 'and does not guess' "$out" ;;
*) pass 'and does not guess' ;;
esac

# --- hooks that cannot start ------------------------------------------------
#
# Every hook sgit installs is a shim holding an absolute path to bin/sgit,
# written once and never revised, so renaming the sgit tree breaks all of them.
# Neither failure announces itself: git-daemon replaces an access hook's own
# message with "access denied or repository not exported", and doctor used to
# call a pre-receive hook installed on the strength of it being executable.

SH="$SGIT_HOME/repos/$id/shadow.git"
cp "$SH/hooks/pre-receive" "$TRASH/pre-receive.good"

out=$(sgit doctor 2>&1)
case "$out" in
*'the pre-receive hook is installed and starts'*)
	pass 'a working pre-receive hook is reported as starting' ;;
*) fail 'a working pre-receive hook is reported as starting' "$out" ;;
esac

printf '#!/bin/sh\nexec "/nowhere/bin/sgit" --id "%s" pre-receive\n' "$id" >"$SH/hooks/pre-receive"
chmod +x "$SH/hooks/pre-receive"
out=$(sgit doctor 2>&1)
case "$out" in
*'the pre-receive hook execs /nowhere/bin/sgit, which does not run'*)
	pass 'a pre-receive hook pointing nowhere is caught' ;;
*) fail 'a pre-receive hook pointing nowhere is caught' "$out" ;;
esac
# Being executable is exactly what the old check tested, so say it plainly.
ok 'and the hook file itself is executable, which is what made this invisible' \
	test -x "$SH/hooks/pre-receive"
case "$out" in
*'exec "'*'/bin/sgit" --id "'"$id"'" pre-receive'*)
	pass 'and the repair is printed ready to paste' ;;
*) fail 'and the repair is printed ready to paste' "$out" ;;
esac
cp "$TRASH/pre-receive.good" "$SH/hooks/pre-receive"

# The access hook is run rather than inspected: handed a path outside the
# store, a healthy one declines at its first branch, reaching no store, no lock
# and no network.
printf '#!/bin/sh\nexec "%s/bin/sgit" gateway-access "$@"\n' "$SGIT_SRC_ROOT" >"$SGIT_HOME/access-hook"
chmod +x "$SGIT_HOME/access-hook"
out=$(sgit doctor 2>&1)
case "$out" in
*'the access hook runs and declines a path outside the store'*)
	pass 'a working access hook is run, not just stat-ed' ;;
*) fail 'a working access hook is run, not just stat-ed' "$out" ;;
esac

printf '#!/bin/sh\nexec "/nowhere/bin/sgit" gateway-access "$@"\n' >"$SGIT_HOME/access-hook"
chmod +x "$SGIT_HOME/access-hook"
out=$(sgit doctor 2>&1)
case "$out" in
*'the access hook does not run'*) pass 'an access hook pointing nowhere is caught' ;;
*) fail 'an access hook pointing nowhere is caught' "$out" ;;
esac
case "$out" in
*'No such file or directory'*)
	pass "and what the shell said is passed on, since git-daemon discards it" ;;
*) fail "and what the shell said is passed on, since git-daemon discards it" "$out" ;;
esac
rm -f "$SGIT_HOME/access-hook"

# --- a daemon serving a store that has moved --------------------------------
#
# --base-path is fixed when the daemon starts and never appears in the status
# output, so a store that moved since leaves a daemon refusing everything with
# the same message a missing repository gives. Faked through ps, since the test
# has no daemon of its own.

printf '%s\n' "$$" >"$SGIT_HOME/gateway.pid"
cat >"$TRASH/fakebin/ps" <<'EOF'
#!/bin/sh
echo "/usr/libexec/git-core/git-daemon --base-path=/somewhere/else/repos --access-hook=/x --listen=127.0.0.1 --port=9418"
EOF
chmod +x "$TRASH/fakebin/ps"
out=$(PATH="$TRASH/fakebin:$PATH" sgit doctor 2>&1)
case "$out" in
*'it is serving /somewhere/else/repos'*)
	pass 'a daemon serving another base path is caught' ;;
*) fail 'a daemon serving another base path is caught' "$out" ;;
esac

cat >"$TRASH/fakebin/ps" <<EOF
#!/bin/sh
echo "/usr/libexec/git-core/git-daemon --base-path=$SGIT_HOME/repos --access-hook=/x --listen=127.0.0.1 --port=9418"
EOF
chmod +x "$TRASH/fakebin/ps"
out=$(PATH="$TRASH/fakebin:$PATH" sgit doctor 2>&1)
case "$out" in
*'it is serving this store'*) pass 'and the matching case is reported as serving this store' ;;
*) fail 'and the matching case is reported as serving this store' "$out" ;;
esac
rm -f "$TRASH/fakebin/ps" "$SGIT_HOME/gateway.pid"

test_summary
