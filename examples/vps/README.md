# Running the agent on a host of its own

For the installation whose runner does not live on a machine that is always on.
The agent runs on a small Ubuntu host; the machine you work at builds the image,
verifies it, and ships it there. Cron lives on the host, so your own machine can
be turned off.

`provision.sh` beside this file does the mechanical half — packages, docker,
`just`, the account. Everything below is the half where a wrong answer costs
something.

Commands here use `AGENT_USER` — what the runner derives from `AGENT_NAME`, and
what names the image and the volume. Export it first, or read it out of `.env`:

    export AGENT_USER=$(just --evaluate agent_user)

## Two accounts, and what the split is worth

`ubuntu` provisions and has passwordless sudo. A second account runs the agent
and receives deploys, and has no sudo — which is also what lets a CI job deploy
there later without holding a root-capable key.

It does have the `docker` group, and **that group is root-equivalent**: anyone
who can reach the socket can mount `/` into a container and come out root. The
split is a guard against a mistyped command and a narrow blast radius, not a
boundary against someone holding the key. Rootless docker is what would make it
one, at the cost of cgroup delegation to keep `mem_limit` working — worth it
where the host runs something else, and not where it runs only this.

## Sizing

Measured on a live session: **~450 MB steady, CPU idling under 1% between API
calls and bursting to two cores**. So 1 vCPU and 2 GB runs it, with swap; the
build does not — `apt` and `npm` in the image build are where 2 GB runs out, and
that is the reason the image is built on your machine and shipped.

| | at rest | grows |
| --- | --- | --- |
| the OS and docker | ~3 GB | no |
| the volume — the agent's whole world | 2.3 GB | bounded: Claude Code prunes transcripts past `AGENT_TRANSCRIPT_RETENTION_DAYS` |
| the image, both tags | ~1.2 GB, layers shared | no, but deploys leave dangling layers — prune them |
| the archive clone | a few hundred MB | yes, and without a bound: one transcript per session, forever |
| the runner checkout, with its worktree | ~60 MB | no |

**About 7 GB goes before anything runs.** 40 GB is comfortable for years, 10 is
the floor — under that it does not fit with room to work. The one line that
grows without end is the archive clone. A shallow clone of the runner saves
25 MB of this and breaks `git rev-list` and the `deployed` reflog
`just deploy --state` reads: take the full clone.

## Layout

Mirror the machine you work at. `.env` is copied there verbatim by `just deploy`
and carries relative paths — `AGENT_ARCHIVE=../archive` resolves from the
checkout — so the checkout goes at `~/runner`, its `deployed/` worktree inside
it, and the archive clone lands beside it at `~/archive`. Mirroring is what lets
`.env` need no per-machine edit.

---

## 0. Two ssh aliases, on your own machine

The one place the address and the account names are written down, so nothing
below carries either. In `~/.ssh/config`:

    Host vps-admin
        HostName <address>
        User ubuntu
        IdentityFile ~/.ssh/id_ed25519

    Host vps
        HostName <address>
        User <the deploy account>
        IdentityFile ~/.ssh/id_ed25519

**Check:** `ssh vps-admin true` succeeds. `ssh vps true` fails — that account
does not exist yet.

## 1. Run the script

    scp examples/vps/provision.sh vps-admin:
    ssh vps-admin 'DEPLOY_USER=<the deploy account> TIMEZONE=<the zone you work in> bash provision.sh'

`TIMEZONE` is not cosmetic. A cloud image ships UTC, and a record's `local_day`
and every day `just stats` counts are read in the host's zone. Measured
2026-09-10: a session that started at 01:07 in the operator's night was written
down on the day before, beside 650 records that said otherwise.

It creates the account, puts it in the `docker` group, copies `ubuntu`'s
`authorized_keys` across so your key reaches it, and **probes that it cannot
sudo** rather than assuming it.

**Check:** it ends `0 failed`, and `ssh vps true` then succeeds. If
`daemon reachable` failed, run it once more: the docker group is not in the
session that granted it, and the second run proves it took.

It installs `gh` and does not log it in: that happens at step 7, with a token
made for this host and narrow enough that it can ask the audit record to refresh
and never write it. A token wide enough to write the mirror must not be the one
put here.

## 2. The tailnet, and Tailscale SSH

Two sections at the end of this file — joining the tailnet, and then closing
port 22 to everything but your own address. Long enough to stand on their own,
and nothing below depends on them. Do them now if you intend to close the port
at all; the order matters, and it is the one they are written in.

## 3. `.env`, here

Two lines, on the machine you work at, and they are what turn `just deploy`
into a deploy to somewhere else:

    RUNNER_DEPLOY_HOST=vps
    RUNNER_DEPLOY_DIR=runner

`RUNNER_DEPLOY_HOST` is the ssh alias from step 0. Nothing is copied by hand
after this: the deploy carries `.env` and the three untracked `image/config/`
files itself, with these two filtered out — they say the agent runs elsewhere,
which is false over there.

**Check:** `just deploy --state` answers `worktree: absent` and dashes for the
rest. That is the host reached, the account accepted and the path read — a
failure to reach it says so instead, and does not print fields.

## 4. `just deploy`

    just deploy

It refuses an unclean tree, shows what goes live on both machines and asks. Then
it resets `deployed/` here, builds the image from it, **proves it with a full
`just verify`**, creates the checkout over there, pushes the branch, copies
`.env` and the config files, ships the image as `:incoming`, and has that host
land it: tree, branch and tag moved together inside a pause of its schedule.

**Check:** it ends `Landed: <sha> -> <sha>, image <id>`. Expect
`CONFIG_NOT_BACKED_UP` on a first deploy — the archive is not cloned there yet,
and that line is not fatal by design.

## 5. The Claude login the budget guard reads

    ssh -t vps 'bash -lc "claude login"'

`bash -lc`, and not `claude login` on its own: `ssh host 'command'` runs a shell
that is neither interactive nor a login shell, so it reads no profile and never
sees `~/.npm-global/bin` — `claude: command not found`, on a machine where it is
installed.

It prints a URL; open it on your own machine and paste the code back. It must be
**that account's** file, because that is the account cron runs as — the guard
reads `~/.claude/.credentials.json` and refreshes it in place.

**Check:**

    ssh vps 'python3 runner/image/claude-usage.py --advisory'

prints numbers. Nothing means the file is absent or carries no `user:profile`
scope, and the guard would then stand every session down — its defined
behaviour, and silent.

## 6. The archive's key

`just collect` commits and pushes transcripts, so that account needs write on
the archive repository:

That host has never spoken to github.com, so its host key is not known and the
first ssh to it would stop to ask — with no terminal, that is a command that
hangs rather than fails. Take the key first:

    ssh vps 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts'

Then the account's own key:

    ssh vps 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub'

Add it as a **deploy key with write access on the archive repository** — not on
the agent's own repository, and not on the mirror's.

    ssh -t vps 'cd runner && just setup-archive'

That account also needs a git identity, and there is none to inherit: a fresh
account has no `~/.gitconfig`, and the deploy carries `.env` and the config
files, not git's own settings. Without it `just collect` gets all the way
through the extraction and the secret scan and then dies on the commit —

    Author identity unknown
    fatal: empty ident name (for <deploy@host>) not allowed

— which is the end of the first session, after the work is done.

Use the identity the archive's commits already carry, so its history stays one
author. Read it here, then set it there:

    git -C "$(just --evaluate AGENT_ARCHIVE)" log -1 --format='%an <%ae>' sessions

    ssh vps 'git config --global user.name "<that name>" \
        && git config --global user.email "<that email>"'

**Check:**

    ssh -o ForwardAgent=no vps 'ssh -T git@github.com'   # names the archive; exit 1 is its success
    ssh vps 'git -C archive ls-remote origin'   # answers; an empty archive is an answer
    ssh vps 'git config --global --get-regexp "^user\."'   # both lines

`-o ForwardAgent=no` on the first, if your own ssh config forwards the agent:
with it, the check authenticates with your key and passes on a host that has
none of its own.

## 7. The mirror's token, and the credential helper on both machines

The record that says the agent's memory was not rewritten lives in a repository
of its own, and this host asks it to refresh at the end of every session. Two
things follow: it needs a token, and that token must be the narrow one.

Make a **second** fine-grained PAT — not the one the mirror's workflow pushes
with:

    Resource owner      your account
    Repository access   Only select repositories -> the mirror's
    Permissions         Contents: Read-only
                        Actions:  Read and write

`Actions: Write` is what dispatches a run. `Contents: Read` is what fetches the
clone `mirror-status` reads. Neither writes a ref: this host can ask the record
to update itself and cannot touch it, which is the whole reason the mirror is
not in the archive.

Then let the recipe do the rest, on that host:

    ssh -t vps 'cd runner && just setup-gh'

It prompts for the token, so it needs a terminal — that is what `ssh -t` is
for. Paste the token and press **Enter**; nothing else ends it. It checks what
is already there, tells you exactly what token to make if none is, takes it on a
prompt, runs `gh auth setup-git` so the clone fetches with the
same credential, and then **proves all three**: that it reads the record, that
git can fetch it, and — on a host that runs the agent — that it **cannot write**
it. It refuses to finish if that last one fails.

Run it on your own machine too:

    just setup-gh

There it does not check the write: this is where `setup-mirror` runs from, and
your own credential is the one that installs the workflow's. What it does do
there is `gh auth setup-git`, which writes four lines under `credential` in
`~/.gitconfig` — undone with
`git config --global --unset-all 'credential.https://github.com.helper'` —
and that is what lets the clone here fetch over HTTPS.

**Checking it later**, without re-running anything: the same write attempt the
recipe makes, by hand.

    ssh vps 'cd runner && eval "$(grep ^AGENT_MIRROR_REPO= .env)" \
        && gh api -X POST "repos/$AGENT_MIRROR_REPO/git/refs" \
             -f ref=refs/probe/permcheck \
             -f sha="$(gh api "repos/$AGENT_MIRROR_REPO/git/ref/memory/mirror" --jq .object.sha)"'

A 403 — `Resource not accessible by personal access token` — is the pass. Not
`--jq .permissions` on the repository: that field is the **user's** role, and on
a repository you own it says `admin` whatever the token can do. Measured
2026-09-09, it reported `push:true` for a token that could not create a ref.

**Then that it works, on both machines:**

    just mirror-status
    ssh vps 'cd runner && just mirror-status'

Each makes its own clone if it has none, fetches, and ends `ok — the backup is
running`. That proves `Contents: Read`. The other half, `Actions: Write`, is
proved by asking for a run and watching the record move:

    ssh vps 'gh workflow run <the workflow file> --repo <owner>/<the mirror>'
    ssh vps 'cd runner && just mirror-status'      # last run: a moment ago

`setup-gh` prints that first line filled in. Not `dispatch-mirror.sh` by hand:
that script is invoked by `just`, which loads `.env` and derives `AGENT_USER`,
and typed on its own it has neither.

## 8. Stop the schedule where it is now — before anything else moves

**The step that cannot be got wrong.** Two hosts running sessions against two
copies of the volume fork the agent's memory, and both push to origin.

Read the crontab first — it names the directory cron runs from, and that is the
value `just schedule` must be given:

    crontab -l | grep 'just run'

`just schedule` recognises an entry only when it names `$RUNNER_DEPLOYED`, and
in step 3 you pointed that at the worktree deploys build from. Given the wrong
value it finds nothing, removes nothing, and reports `absent` — you would read
that as disabled while cron kept firing, and copy the volume out from under a
live session. So name the directory the crontab showed, and keep the recipe on
this machine — with `RUNNER_DEPLOY_HOST` set it would run on that host instead:

    RUNNER_DEPLOYED=<that directory> just RUNNER_IS_DEPLOYED=yes schedule --disable

**Check with the crontab and not with the recipe**, for the same reason:

    crontab -l | grep -c 'just run'    # 0

And check the session with docker, not with `just status`: that page is drawn
around `$RUNNER_DEPLOYED`, which step 3 repointed, so it reports the deploy
worktree's schedule and the other host's deployment — not the pair you are
stopping here. The session container is the evidence `status` itself reads:

    docker ps --filter name=-session --format '{{.Names}}'   # nothing

Wait for a running one to finish; do not force it. Do this immediately before
the volume copy: from here to the first session on the other host, the agent
runs nowhere.

## 9. The volume — once, with nothing running

The volume has to carry compose's **project** label. Without it every `docker
compose` command from then on prints `volume … already exists but was not
created by Docker Compose` — it still works, and it says so on every session,
every probe and in every log, which is how a real warning stops being read.

Measured 2026-09-09: that one label is the whole of it. `com.docker.compose.volume`
changes nothing — absent, or holding any value at all, compose is silent. And
creating the volume this way starts no container, so nothing seeds it from the
image before your own content lands.

    ssh vps 'cd runner && docker volume create \
        --label com.docker.compose.project=$(just --evaluate COMPOSE_PROJECT_NAME) \
        $(just --evaluate AGENT_VOLUME)'

Then fill it:

    docker run --rm -v "$AGENT_USER-home":/vol -w /vol alpine \
        tar -cpf - --numeric-owner . \
      | ssh vps "docker run --rm -i -v $AGENT_USER-home:/vol -w /vol alpine \
            tar -xpf - --numeric-owner"

`--numeric-owner` on both ends, and what it does here is not what it looks like.
Measured 2026-09-09: alpine's tar is busybox, which **accepts the option and
ignores it** — and preserves numeric ownership anyway, because it never looks a
name up. A round trip of a file owned by 1001 comes back owned by 1001. The flag
is kept because it is what makes this correct on the day the image is one with
GNU tar, where a name-based restore would hand the agent's world to whoever
holds that name in the image.

**Check, before trusting it.** The same command on each machine, and the two
answers are one hash to compare:

    docker run --rm -v "$AGENT_USER-home":/vol:ro alpine sh -c \
        'find /vol -type f -exec md5sum {} + | LC_ALL=C sort | md5sum'

    ssh vps "docker run --rm -v $AGENT_USER-home:/vol:ro alpine sh -c \
        'find /vol -type f -exec md5sum {} + | LC_ALL=C sort | md5sum'"

It reads all of it — around half a minute on one vCPU — and it is the only check
that speaks about content. `:ro` on both, so neither can touch what it measures.
Nothing may be running: with the schedule stopped at step 8 the volume is
quiescent, and a session writing during the read would make the two hashes
differ for a reason that is not a fault.

Not `du -sh`, which was the check here until 2026-09-10: measured on that day's
migration, a correct copy answered 2403189719 bytes here and 2403202007 there —
12288 apart, three blocks, and all of it **directories**. A directory that has
lost many entries keeps the blocks it grew into; the one `tar` recreates starts
at the minimum. `du` on a volume therefore disagrees with itself across a
faithful copy, which is the shape of a check that gets ignored the first time it
is believed.

`find /vol -type f | wc -l` beside it, if you want a number a person can read —
15518 on that migration, and the same both sides.

The hash says nothing about **ownership**, which is what the paragraph above is
about, so ask for it as a set rather than reading it off an `ls`:

    docker run --rm -v "$AGENT_USER-home":/vol:ro alpine sh -c \
        'find /vol ! -type l -exec stat -c %u:%g {} + | sort -u'

    ssh vps "docker run --rm -v $AGENT_USER-home:/vol:ro alpine sh -c \
        'find /vol ! -type l -exec stat -c %u:%g {} + | sort -u'"

One line on each, the image's uid and gid — `1001:1001` on that migration. A
second line is a file the copy handed to somebody else.

**`! -type l` is not tidying up.** Measured 2026-09-10: with symlinks counted,
the copy answers `1001:1001` here and `0:0` *and* `1001:1001` there — the whole
of the difference being seven symlinks, which busybox tar recreates without
`lchown`, so they end up owned by the uid the extracting container ran as. It is
inert: the kernel takes its permission decision from the **target**, never from
the link, `fs.protected_symlinks` restricts only world-writable sticky
directories, and the agent can still replace any of them because that right
belongs to the directory, which is its own. Counted in, it is a second line on
every copy this way and nothing to act on — which would make the check
unreadable the day it has something to say.

**Keep the old volume** until a full session has run on the new host: deleting
it is a one-way door.

## 10. One session, by hand

    ssh -t -o ForwardAgent=no vps 'cd runner && just run --listen'

**The real acceptance test**, and nothing below it matters until this passes: the
session starts, does work, the exit hook backs the memory up, `just collect`
files the transcript, and `just records` writes its record — the last line about
records says published, not `RECORDS_NOT_SEALED`. Without the agent forwarded,
for the reason step 6 gives. Watch what it costs while it runs:

    ssh vps 'docker stats --no-stream'

The mirror is asked to refresh as the session ends: `just mirror-status` there
should show a run from that minute.

## 11. cron there, and only there

    ssh -t vps 'cd runner && just schedule --enable'

**Check:** `ssh vps crontab -l` names the checkout, and `crontab -l | grep -c
'just run'` on your own machine still says `0`.

## The tailnet, and Tailscale SSH

`provision.sh` installs Tailscale and enables the daemon; joining is yours,
because it is a credential and an ACL decision.

    ssh -t vps-admin 'sudo tailscale up --ssh --advertise-tags=tag:server \
        --hostname=<the node name>'

`--hostname` and not the machine's own: Tailscale otherwise derives the node
name from the OS hostname, and on a VPS that name belongs to the provider —
cloud-init reapplies it from the instance metadata at every boot unless
`preserve_hostname` is set, so a `hostnamectl` change is undone silently and the
node name drifts with it. The flag lives in the node's own preferences and
survives both a reboot and the provider rewriting the hostname.

The name becomes the MagicDNS name, `<the node name>.<tailnet>.ts.net`, so give
it a second entry in your `~/.ssh/config`: the alias pointing at the public
address only works from the one place the firewall allows, and this one works
everywhere else.

`--ssh` makes the node accept Tailscale SSH, where access is decided by the
tailnet policy rather than by a key on disk. Three things it does not do on its
own:

- **It needs an `ssh` rule in the tailnet policy.** The default is deny, so
  `--ssh` alone advertises a capability nobody may use. The rule names which
  users may land as which local accounts — name both the admin account and the
  deploy account, or you lose the one you left out.
- **It does not replace `sshd`.** Both run, so until port 22 is closed to the
  internet this is a second door rather than a better one. Closing it is the
  actual gain on a machine holding a Claude credential and the agent's whole
  world — only once Tailscale SSH is proved, and knowing where the provider's
  console is before you try.
- **`--advertise-tags` is not cosmetic.** A node's key expires after 180 days by
  default and the machine then leaves the tailnet with no symptom; a tagged node
  does not expire. The tag has to exist in the policy's `tagOwners` first, or
  `tailscale up` refuses it — `requested tags [tag:server] are invalid or not
  permitted`, which reads like a plan limitation and is not one: tags, ACLs and
  Tailscale SSH are all on the free tier.

**The tag is why there are two `ssh` entries and not one.** Tagging a node
transfers its ownership from you to the tag — that is the same act that stops the
key expiring — so the node leaves `autogroup:self`, which is what the default
rule matches on. Tag it without adding a rule for the tag and you get a host that
never expires and that you can no longer reach over Tailscale SSH.

Both keys live in one document — *Access controls* in the admin console, HuJSON,
trailing commas and `//` allowed. `tagOwners` is new; the `ssh` rule is an entry
**added to** the array the default policy already has, the one already there
covering your own machines:

    "tagOwners": {
        "tag:server": ["autogroup:admin"],
    },

    "ssh": [
        // the default entry, kept — your own devices
        {
            "action": "check",
            "src":    ["autogroup:member"],
            "dst":    ["autogroup:self"],
            "users":  ["autogroup:nonroot", "root"],
        },
        {
            "action": "accept",
            "src":    ["autogroup:member"],
            "dst":    ["tag:server"],
            "users":  ["<the admin account>", "<the deploy account>"],
        },
    ]

`accept` rather than `check` on the second: `check` asks for a browser
re-authentication periodically, which is the wrong trade for the host you reach
*because* something is wrong with it.

**Check:** the node appears in `tailscale status` from your own machine, ssh over
the tailnet lands in the right account, and `provision.sh` re-run reports
`tailnet joined, and this node's key does not expire`.

What the tag and a closed port 22 cost later: a deploy from CI would have to join
the tailnet itself with an ephemeral auth key instead of holding an ssh key. A
supported shape, and better decided here than discovered there.

## The firewall — after the tailnet is proved, not before

Two ways in, each covering the other's failure: a key from one fixed address, and
the tailnet from anywhere. Close the rest.

**Do it at the provider's edge if you have one.** It holds even when the host is
compromised, and it avoids the trap below. What to allow inbound:

| | |
| --- | --- |
| TCP 22, from your own fixed address only | the direct path, and the fallback for a tailnet that is down, expired, or locked out by an ACL |
| UDP 41641, from anywhere | Tailscale's direct path. Without it the tailnet still works, over relays — and a 1.15 GB image ships through them |

Everything else denied, **IPv6 included**. A rule that names an IPv4 address and
says nothing about v6 leaves `sshd` reachable from the whole internet on the
other family, and nothing about it looks wrong.

Order matters: only once Tailscale SSH is proved. Closing the direct path while
the tailnet path is unverified leaves nothing.

Once it is proved there are three ways in, and they fail independently, which is
what makes closing the port reasonable rather than brave: the direct key from
your one address survives Tailscale being down; Tailscale SSH from a client
survives your address changing; and the admin console's browser terminal
survives your having no machine of your own at hand. The provider's own console
remains under all three.

**Check, from home, and this is the one that catches the classic mistake:**

    ssh -4 vps true      # succeeds — your address is allowed
    ssh -6 vps true      # must time out

If the second lands you in a shell, the v6 side is open to everyone.

**On the host instead of the edge**, `ufw` does the same, from a session you keep
open until a second one has proved the rules:

    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow from <your fixed address> to any port 22 proto tcp
    sudo ufw allow in on tailscale0
    sudo ufw allow 41641/udp
    sudo ufw enable

With one caveat that does not apply to an edge firewall: **Docker writes its own
iptables rules ahead of ufw's**, so a published container port is reachable
whether or not ufw denies it. Nothing here publishes a port — `compose.yaml`
says so deliberately — but the day something does, ufw will not be what stops it.

`provision.sh` reports nothing about any of this on purpose: an edge firewall is
invisible from inside the machine, and a verdict that reads `ufw inactive` on a
correctly protected host is a verdict that teaches you to skip the list.

---

## What is still missing after all this

- **The proxy** — `just chat`, `just listen`, `just status` typed at home reach
  this host. Until then, `ssh -t vps 'cd runner && just …'`. `just deploy` is
  the exception: it already crosses on its own.
- **`just listen --remote` against a system daemon** — `host/session/remote.sh`
  starts its own `tailscaled` in userspace, in the foreground, because the
  machine it was written for may keep nothing alive past a window. On a host
  with a permanent daemon it would register a second node for the same machine;
  it has to use the running one instead.
- **Alarms** — nothing reports off this host that a run crashed, that a session
  could not start, or that a backup failed.
