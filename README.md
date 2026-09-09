# sgit — shadow git

**Work under a pseudonym, push as yourself.**

Your git identity and your repository's origin stay out of the copy your
agent works in.

`sgit` keeps a rewritten copy of a git repository. You work in the copy; your
commits carry a pseudonymous identity and the copy's remote URL says nothing
about where the code came from. Behind it, `sgit` translates in both directions
so that fetching and pushing behave exactly as they would against the real
repository — including failing the same way when you lack permission.

The intended use is working with an AI coding agent, or anyone else you would
rather not hand your git identity and your employer's repository URL to.

```
$ sgit clone https://github.com/acme/internal-service.git work
$ cd work
$ git log --format='%an <%ae>'
Dolores <dolores@users.noreply.github.com>
Dolores <dolores@users.noreply.github.com>
Sam Okafor <sam@acme-partners.example>        # a colleague, left as they are
$ git remote -v
origin  sgit::7f3a1c92e4b08d16 (fetch)
origin  sgit::7f3a1c92e4b08d16 (push)
$ git commit -am 'fix the retry loop' && git push
```

Upstream receives that commit under your real name and address. Your working
copy never contained it.

## What it hides, and what it cannot

**Hidden**: author, committer and tagger identities; the identity trailers in
commit messages (`Signed-off-by`, `Co-authored-by`, …); GPG signatures, which
carry a key fingerprint; the upstream URL, host, owner and repository name,
including inside error messages the upstream sends back.

**Not hidden — and this is a boundary, not a to-do item**: anything written
*into the files themselves*. `AUTHORS`, `.mailmap`, `CODEOWNERS`, the `author`
field in `package.json`, the copyright line in `LICENSE`, a badge URL in
`README.md`, an organisation name in `.github/workflows` — all stay exactly as
they are.

That is not an oversight. The shadow working tree has to be byte-identical to
the real one; that is what makes `git diff`, `git merge` and `git push` mean
the same thing on both sides. The moment file contents are rewritten, the copy
stops being a copy. **Before shadowing a repository, look at what its files say
about you.**

## Threat model

`sgit` is built to stop an agent working in the shadow repository from picking
up your identity or your upstream in the course of doing its job — reading
`git log`, `git remote -v`, `git config --list`, or anything under `.git/`.

It is **not** a sandbox. The store holds every secret it has: the upstream URL,
your real identities, and the ability to push with your credentials. Whether
that is out of reach depends entirely on where you put it:

| | store location | transport | can the agent read the store? | what you actually get |
|---|---|---|---|---|
| **Same machine, same user** | `~/.local/share/sgit` | `sgit::<id>` helper | **yes** | *does not volunteer it.* Normal work never surfaces a secret, but `cat`-ing the store does. |
| **Same machine, separate user** | that user's home, mode 700 | gateway on `127.0.0.1` | no | a real boundary, for the cost of one system account — [how to set it up](#on-one-machine-with-the-store-out-of-reach) |
| **Separate machine** | host, private path | gateway on a host-only network | no | a real boundary |

The middle row is worth knowing about: it needs no virtual machine and uses
the same gateway that is already there, and `./bin/install-as-sgit` sets the
whole thing up — [see below](#on-one-machine-with-the-store-out-of-reach).

If you use the first row, say so out loud in your own head: it lowers the
chance of accidental exposure to near zero and does nothing against an agent
that goes looking.

## Install

```sh
git clone <this repository> ~/src/sgit
export PATH="$HOME/src/sgit/bin:$PATH"     # sgit and git-remote-sgit
```

Requires git ≥ 2.30, bash ≥ 3.2 (the version macOS ships), and the usual
POSIX tools. macOS and Linux.

Then set up the one thing sgit needs to know — the name to commit under:

```sh
sgit config --init                              # asks nothing, uses defaults
sgit config --init --name 'Quiet Fox' --email fox@example.invalid
```

Or just run `sgit clone`: with no configuration it prints what is needed and
offers to write it, then carries on with the clone. (It only asks when a
person is actually there to answer — never from a hook or a script.)

Either way the result is a two-line file, `~/.local/share/sgit/config`:

```ini
[shadow]
	name = Quiet Fox
	email = fox@example.invalid
```

Pick your own name rather than the suggested one. If everybody accepts the
default, the default itself becomes recognisable — it says "this repository
went through sgit".

That is the whole minimum. **The identity to hide is the one git already uses**
— your `user.name` and `user.email`, resolved the way git resolves them: the
repository's own setting first, then your global one. A push restores exactly
that, so the upstream sees what it would have seen had you worked in the real
repository directly. Nothing is stated twice.

To give one repository a different identity, set it on the real mirror the way
you would on any repository — `sgit git` runs git there, so its path never has
to be looked up:

```sh
sgit git config user.email you@work.example
```

Add a `[real]` section only to hide *further* identities — an address you used
years ago, one from another machine, a work alias:

```ini
[real]
	email = old-address@example.com
	email = *@former-employer.example    ; globs are fine
	name = A Name You Used To Commit Under
```

Email and name are matched independently: a commit is yours if *either*
matches. Everyone else's identity is left alone, so the history still looks
like the multi-person project it is. Check the result with `git log
--format='%an <%ae>' | sort -u` and look for anything of yours that got
through.

Whatever identity a push restores is also hidden on the way down, whether or
not `[real]` mentions it. It has to be: otherwise a commit made under it
somewhere else — another clone, another machine — would arrive unrewritten and
put your name back into the shadow copy.

A `noreply` address for the shadow identity is a good idea: it will appear on
commits you push, and it should not point at a mailbox anyone can reach.

## Using it

### On one machine

```sh
sgit clone https://github.com/acme/internal-service.git work
cd work
# ... it is a normal git repository from here on
```

The directory name is the one thing sgit cannot hide for you: it is outside
the repository. Give the clone a name of your own, as above — if you leave it
off, the name comes from the upstream URL and sgit says so.

### Starting a new project

```sh
sgit init myproject
cd myproject
git commit -am 'first'
git push                    # goes no further than the real repository
```

A repository created this way has no upstream. Pushing succeeds and stops at
the real repository; nothing touches the network. Give it an upstream later:

```sh
sgit remote add origin git@github.com:acme/myproject.git
sgit sync
git push
```

### Across a virtual machine

The store stays on the host; the working tree lives in the guest.

```sh
# on the host
sgit config gateway.listen    bridge100
sgit config gateway.advertise 192.168.64.1
sgit config gateway.allowFrom 192.168.64.2

sgit clone --transport gateway --no-workdir https://github.com/acme/svc.git
sgit gateway start
sgit gateway url <id>       # prints the URL and a script to run in the guest
```

`gateway.listen` is where the daemon binds; `gateway.advertise` is what the
guest dials. They are usually the same thing, so `advertise` is derived from
`listen` — including through an interface name — and only needs setting when
the two genuinely differ, such as behind a port forward.

The same gateway serves the same-machine case. Leave everything unset and it
binds to `127.0.0.1` and advertises it, which is what the separate-user
arrangement in the table above needs:

```sh
sgit clone --transport gateway https://github.com/acme/svc.git work
```

Find the right address from inside the guest:

```sh
netstat -rn -f inet | awk '/^default/{print $2}'
```

Two things to get right:

- **Start the virtual machine before the gateway.** On macOS the `bridge100`
  interface is created when the first VM starts and removed with the last one,
  so binding to it beforehand fails.
- **Narrow `gateway.allowFrom`.** Every VM on the same bridge can reach the
  gateway, and reaching it means being able to make your machine push upstream
  with your credentials. `sgit gateway start` refuses to bind a non-loopback
  address while the allowlist is still at its default.

The gateway speaks `git://`, which is unauthenticated and unencrypted. That is
acceptable on a host-only network and nowhere else. `sgit gateway start`
refuses to bind the wildcard address or the interface carrying your default
route.

### On one machine, with the store out of reach

The middle row of the table above: no virtual machine, one extra account. The
store lives in that account's home, the gateway listens on `127.0.0.1`, and you
work as yourself against a `git://` URL.

What it buys: the agent runs as you, and as you it cannot read the store, cannot
see the upstream URL, and cannot reach your credentials. It also never needs
sgit on its `PATH` — the working tree is plain git — so there is nothing to run
that could be asked about the real repository.

What it does not buy: if the agent can run `sudo`, it can become the other user
and read everything. T2 assumes the agent has your ordinary privileges and not
administrative ones.

```sh
./bin/install-as-sgit --name 'Quiet Fox' --email fox@example.invalid
```

It creates the account, installs sgit where that account can run it, writes
the configuration as that account, puts the gateway under launchd or systemd,
and leaves you an `as-sgit` command. It prints the plan and asks before it
touches anything; `--dry-run` prints every command it would run and changes
nothing.

**Run it again to update sgit.** It recognises an installation that is already
there and behaves accordingly: it stops the gateway before replacing the
program — the access hook runs it on every incoming connection — puts back the
new copy, removes files the new version no longer has, and starts the gateway
again. The store is not touched, and neither identity is: not the pseudonym,
which repositories have already been made under, and not the identity to hide,
which would otherwise be re-read from whatever your `git config` says months
later. Pass `--name`/`--email` or `--real-name`/`--real-email` to change one on
purpose; it says what that means before doing it.

```sh
git pull && ./bin/install-as-sgit
```

Add `--clone <url>` to do the first clone at the end — store and working tree
both — while you are still at the keyboard for anything the credentials want
to ask.

| | |
|---|---|
| `--name`, `--email` | the pseudonym to commit under. Asked for if not given |
| `--real-name`, `--real-email` | the identity to hide. Defaults to your own `git config` |
| `--user`, `--home` | the account and where the store lives (default `sgit`, `/var/sgit` or `/var/lib/sgit`) |
| `--lib-dir`, `--wrapper` | where sgit and `as-sgit` are installed |
| `--service-file` | where the launchd plist or systemd unit is written |
| `-n`, `--dry-run` | print the commands, run none of them |
| `--uninstall` | remove the service and the wrapper. Never the account or the store — it lists what the store holds and prints the commands to remove it, with what that costs |
| `--print plist\|service\|wrapper` | write one generated file to stdout |

**The one thing it cannot do for you: credentials.** Pushes run from a hook
with no terminal, so they must work with nobody there to type anything. The
credentials live in the service account's home, where nothing you run as
yourself can read them — which is the arrangement working, not an obstacle.

Every command below uses `sudo -H -u sgit sh -c '…'`, and the quoting matters:
`~` is expanded by *your* shell before `sudo` runs, so an unquoted
`~/.ssh/id_ed25519` names **your** home, not the account's. Inside `sh -c '…'`
it is expanded on the other side, where you want it.

#### An SSH key

Give the account its own key rather than copying yours. Your everyday key
almost certainly has a passphrase, and this one must not have any — there is
nobody to type it at push time — so reusing it would mean stripping the
passphrase off the key you use for everything else. A separate key can also be
revoked on its own.

```sh
sudo -H -u sgit sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
sudo -H -u sgit sh -c 'ssh-keygen -q -t ed25519 -N "" -C "sgit store" -f ~/.ssh/id_ed25519'
sudo -H -u sgit sh -c 'cat ~/.ssh/id_ed25519.pub'
```

Add that public key to the forge — as a deploy key with write access on the
one repository, which is the narrowest thing that works, or as a key on your
account.

<details>
<summary>Copying your own key instead</summary>

Only worth doing if it already has no passphrase. This says so without
unlocking anything:

```sh
ssh-keygen -y -P '' -f ~/.ssh/id_ed25519 >/dev/null && echo 'no passphrase'
```

If it prints nothing, the key has one — generate a separate key as above
rather than stripping it.

```sh
sudo -H -u sgit sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
sudo cp ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub /var/sgit/.ssh/
sudo chown sgit /var/sgit/.ssh/id_ed25519 /var/sgit/.ssh/id_ed25519.pub
sudo chmod 600 /var/sgit/.ssh/id_ed25519
```

(`/var/lib/sgit` on Linux.) Copy the two key files, not the whole `~/.ssh`:
your `config` names paths inside your own home, and carrying it over produces
failures that point nowhere near their cause.

</details>

**The host key has to be accepted once, by hand.** An unattended push cannot
answer "are you sure you want to continue connecting", and there is no
terminal for it to ask at — it simply fails. Do it now, while you can read the
fingerprint and compare it against the one the forge publishes:

```sh
sudo -H -u sgit ssh -T git@github.com
```

Answer `yes`, and it writes the account's own `known_hosts`. A greeting from
the forge means the key works too. (`ssh-keyscan` can seed `known_hosts`
without a prompt, but it trusts whatever answers, so it is only worth it on a
network you already trust.)

**The remote has to be an SSH one** for any of this to be used. A repository
cloned from an `https://` URL will keep asking for a password no matter what
is in `~/.ssh`:

```sh
as-sgit list                             # the id is the first column
as-sgit --id <id> remote -v              # what the URL is now
as-sgit --id <id> remote set-url origin git@github.com:acme/internal-service.git
```

#### Or an HTTPS token

```sh
as-sgit git config --global credential.helper store
```

then put the token in the account's `~/.git-credentials` (mode 600), as
`https://<user>:<token>@github.com`.

**Not** the macOS login keychain, whichever you choose: it is locked whenever
that user is not logged in, which is always.

#### Signing

Signing belongs to the service account too, and for the same reason the
credentials do: the commit that gets signed is the one rebuilt on the way up,
in the store, under your real identity. The copy you work in never signs at
all — a signature carries a key fingerprint, which names you as surely as an
address does — so every working tree sgit makes has `commit.gpgSign false` in
it, and `sgit doctor` complains if that is ever turned back on.

So the key and the configuration go in the account's home, and `commit.gpgsign`
there decides whether the upstream gets signed commits.

**It has to work with no terminal.** Signing happens inside the push, from a
hook, with stdin closed. A key that wants a passphrase does not get to ask for
one: it fails, and sgit refuses the push rather than quietly sending an
unsigned commit.

```
error: Enter passphrase for ".../signing": ...
sgit: cannot sign the commit for the real repository
```

**SSH signing is the one that fits.** No agent, no pinentry, nothing to unlock
— just a key file the account can read:

```sh
sudo -H -u sgit sh -c 'ssh-keygen -q -t ed25519 -N "" -C "sgit signing" -f ~/.ssh/signing'

as-sgit git config --global gpg.format ssh
as-sgit git config --global user.signingkey /var/sgit/.ssh/signing.pub
as-sgit git config --global commit.gpgsign true
as-sgit git config --global tag.gpgsign true
```

(`/var/lib/sgit` on Linux. `user.signingkey` wants a real path, and it is read
by the account, so write it out rather than using `~`.) Then add
`~sgit/.ssh/signing.pub` to the forge **as a signing key** — on GitHub that is a
different list from the authentication keys, and a key added to only one of
them does only that one job.

Verifying signatures — as opposed to making them — needs to know which keys to
trust. The address on the left is the one being hidden, because that is who the
commits belong to once they are restored:

```sh
as-sgit git config --global gpg.ssh.allowedSignersFile /var/sgit/.ssh/allowed_signers
sudo -H -u sgit sh -c 'printf "%s %s\n" you@example.com "$(cat ~/.ssh/signing.pub)" > ~/.ssh/allowed_signers'
```

Check the whole thing by pushing something and looking at what arrived:

```sh
as-sgit --id <id> git log --show-signature -1
```

<details>
<summary>OpenPGP instead</summary>

Workable, but it is the path with the moving parts: the secret key has to be
in the account's own `~/.gnupg`, and it has to be usable without a passphrase,
because there is nowhere to type one. Everything below assumes you have
decided that an unprotected copy of a signing key, in a home directory only
that account can read, is a trade you want to make.

Give the account its own key rather than copying yours — same reasoning as for
the push credentials, and it can be revoked on its own. Generate it as the
account, interactively, with an empty passphrase, using your real name and
address so that the forge matches it to the commits:

```sh
sudo -H -u sgit gpg --full-generate-key
sudo -H -u sgit gpg --list-secret-keys --keyid-format=long
as-sgit git config --global gpg.format openpgp
as-sgit git config --global user.signingkey <keyid>
as-sgit git config --global commit.gpgsign true
```

Then `sudo -H -u sgit gpg --armor --export <keyid>` and add that to the forge.

To move your existing key instead, pipe it across without letting it touch the
disk in between, and then remove its passphrase on the copy:

```sh
gpg --export-secret-keys --armor <keyid> | sudo -H -u sgit gpg --batch --import
sudo -H -u sgit gpg --edit-key <keyid>      # passwd, old one, empty new one, save
```

Unlike the ssh route above, these commands are guidance rather than something
this project exercises: its own signing tests use ssh precisely because it
needs no agent.

</details>

**Then clone, as yourself.**

```sh
as-sgit clone https://github.com/acme/internal-service.git work
cd work
# ... an ordinary git repository from here on
```

`as-sgit` is not only "sgit as the other account". A working tree cannot be
made by that account — it is unprivileged, and your directories are not its to
write in — so `as-sgit clone` does it in two halves: the store as that account,
the working tree here, as you. `as-sgit init` works the same way. Both take
`--no-workdir` if you only want the store.

If the second half fails — usually because the gateway is not running — the
store is still there, and `as-sgit gateway url <id>` prints the script that
finishes the job by hand.

**The transport is not a choice here.** The helper transport is a program that
reads the store, run as whoever runs git — as you, who cannot. `as-sgit`
refuses `--transport helper` rather than letting it fail later, in the middle
of a clone, with an error that names none of this.

<details>
<summary>What it does, if you would rather do it by hand</summary>

**1. Make the account.** It never logs in; it only owns files and runs the
gateway.

```sh
# macOS
sudo sysadminctl -addUser sgit -fullName 'sgit store' -home /var/sgit -shell /bin/sh
sudo dscl . create /Users/sgit IsHidden 1      # keep it off the login screen
sudo chmod 700 /var/sgit

# Linux
sudo useradd --system --create-home --home-dir /var/lib/sgit --shell /usr/sbin/nologin sgit
sudo chmod 700 /var/lib/sgit
```

**2. Put sgit where that account can run it**, for example
`/usr/local/lib/sgit`. You do not need it on your own `PATH`.

**3. Set it up as that user.** Use `sudo -H`: without it `HOME` stays yours,
and sgit would then read your git identity and write the store into your home
— quietly defeating the whole arrangement.

```sh
sudo -H -u sgit git config --global user.name  'Your Real Name'
sudo -H -u sgit git config --global user.email you@example.com
sudo -H -u sgit /usr/local/lib/sgit/bin/sgit config --init \
    --name 'Quiet Fox' --email fox@example.invalid
sudo -H -u sgit /usr/local/lib/sgit/bin/sgit config sgit.defaultTransport gateway
```

Nothing else needs configuring: the gateway binds to `127.0.0.1` and advertises
it, which is exactly what a client on this machine dials.

**4. Run the gateway under a service manager**, so it comes back after a
reboot. `--foreground` keeps the process in the manager's hands; `sgit gateway
status` still works. `./bin/install-as-sgit --print plist` and `--print
service` write the two unit files, so you need not copy them from here.

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/local.sgit.gateway.plist
sudo systemctl enable --now sgit-gateway
```

**5. An `as-sgit` command**, so the store side is one word rather than four:

```sh
sudo install -m 755 /dev/stdin /usr/local/bin/as-sgit <<'EOF'
#!/bin/sh
exec sudo -H -u sgit /usr/local/lib/sgit/bin/sgit "$@"
EOF
```

</details>

**Who runs what, afterwards**

| | as you (and your agent) | as `sgit` |
|---|---|---|
| starting a repository | `as-sgit clone <url> <dir>` — it does both halves | |
| everyday work | `git commit`, `git push`, `git pull` | — |
| looking at the real repository | — | `as-sgit --id <id> git log`, `… remote -v` |
| upstream changes, checks | — | `as-sgit --id <id> sync`, `as-sgit doctor` |

**Pass `--id` on that side**, and get it from `as-sgit list`. sgit can usually
work out which repository you mean from the working tree you are standing in,
but here that means the service account reading your working tree, and your
home directory may well not let it. `doctor` needs no id: it looks at the whole
store.

**Worth knowing.** A gateway on `127.0.0.1` is reachable by every process on
this machine, not only the agent — on a personal machine that is your own
software. If the agent should read the repository but never publish through
your credentials:

```sh
as-sgit config gateway.allowPush false
```

## What the copy looks like

**Object ids differ.** Rewriting a commit changes it, and every descendant
follows, so only history older than your first commit keeps its original id.
Commit ids therefore do not carry between the two sides: an id quoted in an
issue, in CI, or in a commit message (`fixes abc1234`) will not resolve in the
shadow copy.

**Signatures are gone from the copy, and made afresh for the upstream.** A
rewritten commit's original signature no longer verifies, and a signature that
does not verify is worse than none, so the copy carries none. Signing is
disabled in the shadow repository for a second reason too: a signature made
there would carry your key fingerprint.

The upstream is a different matter. If `commit.gpgsign` is on — resolved
against the real repository the way git resolves it, exactly as your identity
is — then the commit sgit writes for the upstream is signed with your key, and
arrives verified. A push that cannot reach the signing key fails, and says how
to proceed; to sign everywhere but here:

```sh
sgit git config commit.gpgsign false
```

Annotated tags follow `tag.gpgsign` the same way.

**Timestamps are untouched in v0.1.** Author and committer dates keep their
original value *and time zone*, so the history still shows when and roughly
where you work. Time-zone normalisation is planned; if that matters to you,
this is not ready for you yet.

**The first clone takes a while.** The rewrite runs at roughly 150 commits a
second; tmux, at 12,796 commits, took 84 seconds on a modest machine. That is
paid once: afterwards `git fetch` costs a few seconds, because everything
already rewritten is looked up rather than redone.

It says how far it has got while it works — from `sgit clone` and from a plain
`git pull` or `git push` in the working tree alike:

```
commits 2317/2400 (2301 new)
```

When it finishes it says what it replaced:

```
sgit: synced 2400 commit(s); 2317 got a new id
```

A commit is counted as replaced whenever its id in the shadow repository
differs from the one upstream — including a commit whose own text was left
alone and only moved because an ancestor of it was rewritten. That number is
the extent of what an agent in the working tree can no longer match against
the public repository. The remainder kept their ids: commits by people you are
not hiding, with no rewritten ancestor.

A fetch that finds nothing new says nothing at all — no counter and no summary:
the history is walked only from the point it was last rewritten, so an ordinary
`git pull` with no changes upstream does no work to discover that. Set
`SGIT_NO_PROGRESS=1` to silence the counter entirely; the one-line summary is
kept, since it is what the operation did rather than a progress display.

**Submodules and git-lfs are refused.** A submodule URL lives in `.gitmodules`,
inside the tree, so it falls under the boundary above. `sgit clone` says so and
declines rather than shadowing the repository badly.

## Commands

| | |
|---|---|
| `sgit clone <url> [<dir>]` | create a shadow repository from an upstream one |
| `sgit init [<dir>]` | create a new project with no upstream |
| `sgit sync` | fetch from upstream and rewrite what is new |
| `sgit status` | mode, transport, mapping size, last sync |
| `sgit list` | every shadow repository |
| `sgit restore <id> [<dir>]` | recreate a working tree from the shadow repository |
| `sgit remove <id> [--yes]` | delete a store entry, permanently |
| `sgit remote [-v] …` | manage the *real* repository's remotes |
| `sgit git <args>…` | run git against the real repository — except `config --global`/`--system`/`--file`, which are not about a repository and need none |
| `sgit config [--global\|--repo] <key> [<value>]` | read and write sgit's own settings |
| `sgit doctor` | check the store |
| `sgit doctor --emit-probe` | print a self-contained check to run in the working tree |
| `sgit gateway start\|restart\|stop\|status\|url [--bootstrap] <id>` | the network gateway; `--bootstrap` prints the setup script alone |
| `sgit gateway fix-workdir-urls [-n] [--script]` | point working trees at the address the gateway now advertises |

And one script that is not a subcommand, because it runs before there is
anything to run subcommands as:

| | |
|---|---|
| `./bin/install-as-sgit` | set up the separate-account deployment |

Options: `-C <path>` to point at a working tree, `--id <id>` when it is not on
this machine, `--show-upstream` to unredact URLs, `--debug` for detail.

`clone` and `init` take `--no-workdir` (store only), `--transport
helper|gateway`, and `--print-id` (write the new repository's id to stdout, for
a script that has to name it afterwards).

Output is redacted by default. `sgit list`, `sgit status` and `sgit remote -v`
print `<upstream>` unless you ask for the real thing, so that a stray command
in an agent's transcript does not undo the point of the tool.

### Changing the gateway afterwards

The two halves of the configuration behave differently, and both matter:

| changed | effect |
|---|---|
| `gateway.allowFrom`, `gateway.allowPush` | immediate — the access hook reads them on every connection |
| `gateway.listen`, `gateway.port` | **needs a restart**: git daemon takes them as start-up arguments — `sgit gateway restart` |
| `gateway.listen`, `gateway.port`, `gateway.advertise` | **existing working trees keep the URL they were created with** |

Removing a setting counts as changing it: the value falls back to a default,
and that default may not be what the gateway is running with.

`sgit config` says which of these applies as you make the change, `sgit gateway
status` shows when the running daemon no longer matches the configuration, and
`sgit doctor` names each working tree still holding an old URL together with
the command that corrects it:

```sh
$ sgit gateway status
...
it is running on 127.0.0.1:9418 and the configuration now says 192.168.64.1:9418
restart it to apply that:  sgit gateway restart

$ sgit doctor
  [warn] the working tree still points at git://127.0.0.1:9418/7f3a…/shadow.git
  [note] the gateway now advertises git://192.168.64.1:9418/7f3a…/shadow.git
  [note] correct every tree on this machine: sgit gateway fix-workdir-urls
```

One command corrects every tree on this machine, and prints a script for the
ones that are not:

```sh
$ sgit gateway fix-workdir-urls
updated  /home/you/work
         git://192.168.64.1:9418/7f3a…/shadow.git
skipped  /home/you/tunnelled: origin is git://tunnel.example:2222/7f3a…/shadow.git, set by hand -- left alone
skipped  9c21…: no working tree on this machine -- run --script where it lives
1 updated, 0 already current, 2 skipped

$ sgit gateway fix-workdir-urls --script > fix-urls.sh
# copy it to the machine the trees are on, then there:
$ sh fix-urls.sh -n ~/projects      # say what would change
$ sh fix-urls.sh ~/projects         # change it
```

`-n` on either side changes nothing and reports what it would do. The script
needs git and nothing else, and carries only repository ids and the gateway
address — both of which are already in the trees it touches.

**A URL you set yourself is left alone.** sgit records the URL it wrote in
`.git/sgit-url` next to the id, and corrects a tree only when what it finds is
what it left there. The shape of the URL cannot decide this on its own: a
tunnel or a port forward keeps `/<id>/shadow.git` and changes only host and
port, which is indistinguishable from a gateway that moved. A tree set up
before sgit kept that record, or bootstrapped by hand from `sgit gateway url`
on an older version, falls back to matching the shape — run the script with
`-n` first if you have repointed any of those.

`sgit doctor` still names each stale tree individually, and points at the
script for repositories whose working tree is somewhere it cannot see.

### Reaching the real repository

The mirror is an ordinary git repository. The only awkward thing about it is
its path, which is built from a random id and buried in the store, so
`sgit git` runs git there for you:

```sh
sgit git log --oneline -5           # what the real history looks like
sgit git config user.email you@work.example
sgit --id 7f3a1c92e4b08d16 git remote -v      # when the tree is elsewhere
```

Everything after `git` is handed to git untouched, git's exit status comes back
unchanged, and it runs in your locale rather than sgit's, so a commit message
in any language reads the way it should. Two things to know: its output is **not** redacted — showing
you the real repository is the point — and the correspondence between the two
sides is kept in `refs/sgit/*` there, so deleting or rewriting those refs will
desynchronise them.

## Configuration

Two files, both in git-config format:

| | |
|---|---|
| `~/.local/share/sgit/config` | global; nearly everything lives here |
| `~/.local/share/sgit/repos/<id>/config` | one shadow repository; overrides the global file |

`sgit config` edits them, so neither path ever has to be typed:

```sh
sgit config gateway.listen bridge100     # global — the default for writes
sgit config --repo sync.downTtl 30       # this repository only
sgit config sync.downTtl                 # what is in effect here
sgit config --list                       # both files, each labelled
sgit config --unset gateway.advertise
```

Four keys hold more than one value — `real.email`, `real.name`,
`gateway.allowFrom` and `rewrite.trailerTokens`. Reading one prints every value
it holds, one per line:

```sh
sgit config --add real.email old-address@example.com
sgit config --add real.email '*@former-employer.example'
sgit config real.email                   # prints both
sgit config --replace-all real.email you@example.com
sgit config --unset real.email           # removes all of them
```

A plain `sgit config <key> <value>` over a key that already holds several is
refused rather than silently discarding the rest.

A per-repository value **replaces** the global ones for that key rather than
adding to them.

### Identity

| key | default | meaning |
|---|---|---|
| `shadow.name` | none, required | the name the copy commits under |
| `shadow.email` | none, required | the address it commits under |
| `real.email` | none | *further* addresses to hide, beyond the one git is configured with. Multi-valued; globs allowed anywhere |
| `real.name` | none | the same, for names |

The identity that is hidden and restored is the one git already resolves for
you; `[real]` only adds to it. See [Install](#install).

```ini
[shadow]
	name = Quiet Fox
	email = fox@example.invalid

[real]
	email = old-address@example.com
	email = *@former-employer.example
	name = A Name You Used To Commit Under
```

### Rewriting

| key | default | values |
|---|---|---|
| `rewrite.trailers` | `true` | `true` / `false` — rewrite identity trailers in commit messages |
| `rewrite.trailerTokens` | the nine below | further trailer names to treat as carrying an identity. Multi-valued, and **added to** the built-in list rather than replacing it |

Recognised out of the box: `Signed-off-by`, `Co-authored-by`, `Co-committed-by`,
`Reviewed-by`, `Acked-by`, `Tested-by`, `Reported-by`, `Suggested-by`,
`Helped-by`. Matching is case-insensitive.

```sh
sgit config rewrite.trailerTokens Whispered-by    # now ten are recognised
```

Configured tokens extend the list because dropping a default would quietly stop
an identity trailer from being rewritten, and recognising one name too many
costs nothing.

### Synchronisation

| key | default | meaning |
|---|---|---|
| `sync.downTtl` | `0` | seconds a fetch may reuse the previous sync instead of contacting the upstream. `0` contacts it every time, which is what makes the copy behave like a direct clone; raise it only on a slow or intermittent link |
| `sync.lockTimeout` | `120` | seconds to wait for the repository lock before giving up |

### Gateway

Read from the global file only — there is one daemon, not one per repository.
Writing them per repository is not an error, merely ineffective, and
`sgit config` says so.

| key | default | values |
|---|---|---|
| `gateway.listen` | `127.0.0.1` | an address, or an interface name such as `bridge100`, resolved when the daemon starts |
| `gateway.advertise` | the address `listen` resolves to | `host` or `host:port`, written into the copy's remote URL. Only needs setting when that is not what a client should dial — behind a port forward, or when `listen` is a wildcard |
| `gateway.port` | `9418` | |
| `gateway.allowFrom` | `127.0.0.1` and `::1` | addresses allowed to connect. Multi-valued, globs allowed (`192.168.64.*`). **An explicit list replaces the default**, so access can be narrowed to a single machine and nothing else — local processes included |
| `sgit.defaultTransport` | `helper` | `helper` or `gateway` — what a new repository gets when `--transport` is not given. Only consulted while creating one; repositories that already exist keep what they were created with |
| `gateway.allowPush` | `true` | `false` serves fetches only. For when the machine on the other side should be able to read the repository but never publish through your credentials — an agent that may read the code but not ship it |

### Maintained by sgit

Per repository, and normally left alone: `sgit clone`, `sgit init` and
`sgit remote` keep them up to date.

| key | default | values |
|---|---|---|
| `sgit.transport` | from `sgit.defaultTransport` | what *this* repository uses. `helper` — the working tree's remote is `sgit::<id>`, served by `git-remote-sgit` on this machine. `gateway` — it is `git://host:port/<id>/shadow.git`, served by `sgit gateway`. Fixed at creation by `--transport`; changing it afterwards means changing the working tree's remote URL to match, which `sgit gateway url <id>` prints |
| `upstream.fetchRemote` | set by `sgit remote` | which of the *real* repository's remotes is fetched from |
| `upstream.pushRemote` | set by `sgit remote` | which one is pushed to |
| `sgit.workdir`, `sgit.created`, `sync.lastRun` | | informational |

**Why `upstream.*` and not git's own settings.** These name a remote of the
real repository, not of the shadow copy — the copy has exactly one remote and
it never changes. `upstream.pushRemote` does overlap with git's
`remote.pushDefault`, and sgit keeps its own for two reasons: their *absence*
is what local-only means, which is a notion git does not have; and there is no
git equivalent on the fetch side, because a mirror tracks no branch. Two
sources of truth for one decision would cost more than the small duplication.
Set them with `sgit remote set-fetch` / `set-push` rather than by hand.

### When a working tree goes missing

Deleting the working tree costs nothing that was pushed to the shadow
repository: everything a working tree is made of lives there. `sgit list` and
`sgit doctor` notice and say what to do.

```sh
$ sgit list
ID                 MODE        UPSTREAM       WORKDIR
7f3a1c92e4b08d16   upstream    <upstream>     /home/you/work  (gone -- sgit restore 7f3a1c92e4b08d16)

$ sgit restore 7f3a1c92e4b08d16
```

What comes back is what the shadow repository holds. **Commits that were made
but never pushed to it, and anything uncommitted, were only ever in that
directory and are gone.** Restore refuses to write over an existing directory,
so nothing can be lost by trying.

### Getting rid of one

```sh
sgit remove <id>            # asks first
sgit remove <id> --yes      # for scripts
```

This deletes the real mirror, the shadow repository and the mapping between
them, and cannot be undone. Two situations, and it tells you which one you are
in:

- **The repository has an upstream.** The history can be cloned again, but the
  mapping goes with the store, and a fresh clone rewrites to *different object
  ids* — no existing working tree will fit it.
- **The repository has no upstream** (made with `sgit init`, or its remote was
  removed). The store is the only copy of that history. It asks you to type the
  id back before doing it.

The working tree is never deleted. It stays as an ordinary git repository whose
remote no longer leads anywhere.

## Checking that it works

```sh
sgit doctor                      # the store: placement, permissions, hardening
sgit doctor --emit-probe > probe.sh
# then, inside the working tree — including on a machine with no sgit:
sh probe.sh
```

Both colour their output when it goes to a terminal, so that a warning stands
out; both leave it plain when piped or redirected, when `NO_COLOR` is set, or
when told to with `SGIT_COLOR=never`. `SGIT_COLOR=always` forces it on.

The probe reports what someone reading the working tree could learn: which
identities appear in the history, whether anything in `.git/` looks like a URL,
whether signing is off, whether the guard hook is in place. It deliberately
carries no list of your real identities — it tells you what is there, and you
decide whether any of it is yours. That is what makes it safe to leave lying
around in the shadow repository.

## How it works

```
   working tree            store (everything secret lives here)          upstream
  ┌──────────┐      ┌──────────────────────────────────────────┐      ┌─────────┐
  │    R'    │◄────►│  shadow.git  ◄── rewrite ──►  real.git    │◄────►│ origin  │
  │ shadow   │      │  hooks/pre-receive            real ids    │      │         │
  │ identity │      │  refs/sgit/map/*              real URL    │      └─────────┘
  └──────────┘      └──────────────────────────────────────────┘
   origin =              ▲
   sgit::<id>            git-remote-sgit, or sgit gateway over git://
```

Local commits need no synchronisation at all: the working tree is an ordinary
git repository whose configured identity is already the shadow one. Only
`fetch` and `push` cross the boundary.

A fetch refreshes the real mirror, rewrites whatever is new, and serves the
result. A push runs the reverse rewrite inside `shadow.git`'s `pre-receive`
hook and forwards it upstream; **the shadow ref moves only if the upstream
accepted it**. Permission errors, branch protection and non-fast-forward
rejections therefore reach you unchanged, because none of it is reimplemented
— it is the upstream's own answer, with the repository name scrubbed out.

The correspondence between the two sides is stored as git refs
(`refs/sgit/map/<real-id>` → shadow object, and the reverse), which makes
lookups cheap, packs itself, and keeps both sides' objects safe from `git gc`.
Those refs are hidden from clients: their *names* are real-side object ids, and
for a public repository one commit id is enough to identify it.

Trees and blobs are never rewritten, so the two object databases are shared
through `alternates` and only commit and tag objects are ever written anew.

## Limitations

- Time zones are not normalised yet (v0.2).
- One upstream per repository takes part in synchronisation. You may configure
  more remotes, but only `upstream.fetchRemote` / `upstream.pushRemote` are
  used.
- No submodules, no git-lfs, no shallow or partial clones, no `refs/notes`.
- Commit ids quoted inside commit messages are not rewritten (v0.2).
- Bare email addresses in message bodies are left alone; only recognised
  trailers are rewritten.
- `sgit adopt`, for converting a clone you already have, is not written yet.
  Use `sgit clone`.

## Test

```sh
bash t/run.sh          # the full suite
bash t/host-check.sh   # gateway checks that need a real host and a real VM
```
