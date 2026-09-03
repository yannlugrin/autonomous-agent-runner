# Image

## What it is, and what to set

The agent needs a machine: a shell, git, `gh`, a Claude Code, a home that
survives between sessions, and a network. What it must **not** have is yours.
The image is that machine — Debian/Node, deliberately small, running the agent
as an unprivileged user with no sudo, with a named docker volume as its whole
world and no view of the host filesystem at all.

The Dockerfile is only half of it. **Every capability that matters is granted
at run time**, so a careful image launched carelessly is not isolated in the
least; `compose.yaml` is where `no-new-privileges`, `cap_drop: ALL`, the
absence of any bind mount, the absence of any published port and the memory and
CPU limits live.

| handle | what it does |
| --- | --- |
| `image/Dockerfile` | what is installed, and the pins: `CLAUDE_CODE_VERSION`, `BWS_VERSION` with the `BWS_SHA256` the download is checked against, and the base image by digest |
| `compose.yaml` | how it is run. Its closing comment lists six settings that each, alone, would undo everything above. Do not add them |
| `image/entrypoint.sh` | what runs on **every** start: git identity, the ssh key, the first clone, and the greeting that reports where the session stands |
| `AGENT_USER`, `AGENT_HOME`, `AGENT_VOLUME`, `<NAME>_REPO_DIR` | the account, its home, the volume and the checkout inside it. All derived from `AGENT_NAME`; changing one later is a migration |
| `AGENT_SKIP_CLONE` | testing only. Any non-empty value skips the clone, so the image can be exercised with no repository and no key GitHub knows. It announces itself on every start |
| `just pin` | resolve the base image to today's digest and Claude Code to npm's latest, and edit the Dockerfile, as a diff to read; `--image` or `--claude` for one of them. It refuses a dirty file and never commits |
| `just shell` | a shell in that container, on the real volume. What bootstrap uses |
| `just test-container` | the same container with **no volume** — an empty home every run, for rehearsing the morning the volume is gone |

**The rule that shapes the rest of it: a named volume is seeded from the image
only once.** Anything written under the agent's home at build time freezes at
the volume's first creation and silently ignores every later rebuild. So
nothing personal is placed in the home at build time, and everything that must
be able to change lives in the entrypoint, which runs on every start — the git
identity, the ssh key, the checkout. System configuration goes under `/etc`,
which is inside the image and replaced by every rebuild: that is why the
permission boundary is at `/etc/claude-code/` and the ssh host-key policy at
`/etc/ssh/ssh_config.d/`.

**What you type.** `just pin`, read the diff and commit it, then `just verify --build`, then `just deploy`.
On a fresh volume, `just shell` **twice**: the first run finds no key,
generates one, prints the public half and stops at exit 78 with nothing
started; you add that key to the agent's GitHub account, and the second run
clones and drops you in the home. Bootstrap goes through `shell` rather than
`run` because `run` passes a working directory, and Docker creates a missing
one **as root** before anything in the image runs.

**What you see.** Every start prints who the agent is, which repository it is
on, the key fingerprint, which `gh` account answers, which Claude login the
session will run on, and the runner commit the image was built from. Exit 78 is
the entrypoint saying something only a human can supply is missing — no key
GitHub knows, no repository, no login — and that **nothing started**.

**What it refuses.** No bind mount and no published ports: the agent reads the
world and nothing reaches in. No `container_name`, so the containers that
coexist stay distinguishable. And the test twin has no volume by construction
rather than by convention — a rehearsal that wipes a home must not be pointable
at the home it exists to protect.

## How it is built

The agent lives in a Debian/Node container built from `image/Dockerfile` and
run by `compose.yaml`. The image is deliberately small — git, `gh`, `jq`,
ripgrep, python3, openssh-client, a pinned Claude Code, and the few root-owned
tools the boundary needs — and the agent runs in it as an unprivileged user
with no sudo. The Dockerfile is only half the story: every dangerous
capability is a *run-time* flag, so a careful image launched carelessly is not
isolated at all, and `compose.yaml` is where `no-new-privileges`, `cap_drop:
ALL`, the absence of any bind mount and the resource limits live.
`image/entrypoint.sh` runs on every start and brings the home into the state a
session needs, then hands over to `vault-env`.

## The volume is seeded once

The agent's home is a named volume, and a named volume is seeded from the
image only when it is *first created*. Anything written under `/home/agent` at
build time therefore freezes at first run and silently ignores every later
rebuild: rebuild with a better config and an existing volume keeps the old
one, with no symptom.

This is why nothing personal is placed in the home at build time, and why
configuration that must be able to change lives in the entrypoint instead of
in the Dockerfile — git identity, the SSH key and the checkout are all the
entrypoint's job, and it runs on every start. It is also why the ssh
host-key policy is written to `/etc/ssh/ssh_config.d/10-github.conf`: system
configuration under `/etc` is outside the volume and updates with every
rebuild.

The same fact is what makes the test twin honest. `compose.yaml`'s
`agent-test` service `extends` the real one and clears the volume with
`!reset null` rather than overriding it, so it has no volume at all — its
`/home/agent` is the image's own, in the container's writable layer, and
`--rm` takes it away with the container. That is closer to a fresh named
volume than an empty tmpfs would be, precisely because a new volume is
*seeded* from the image. Measured: with the volume merely overridden, the
service kept `agent-home` — the one mistake here that must not be possible.
`extends` and not a copy, so the hardening exists once: a second copy would
drift, and a test container that quietly lost `cap_drop` would still pass
every test it was written for.

## `docker run -w` creates the path as root

A working directory passed with `-w` is created by Docker, as root, before the
entrypoint runs. When that happens the clone fails with a permission error
that none of the usual causes explain, so `entrypoint.sh` checks for a
`REPO_DIR` that exists and is not writable and names it, with the command that
removes it from the volume.

The Dockerfile deliberately creates no checkout directory. `git clone` makes
it, owned by the agent, and a pre-existing one is only ever in the way. One
was added once as belt-and-braces against exactly the `-w` case above — but
the real fix was removing `-w` from every recipe, which landed in the same
change, and keeping both left a directory that clone then refuses to write
into. The entrypoint decides the working directory now.

## `set -e` at the hand-over

Three failures of the same family, all in `entrypoint.sh`.

`[ -d x ] && cd x` under `set -e` exits before `exec`. A test-and-do compound
that ends false is the script's last command, and the shell leaves with its
status — so the `exec` below it never happens, and the container simply stops
with nothing said.

`out=$(vault ssh-restore …)` has the same shape. A bare assignment whose
command exits non-zero takes the whole entrypoint down with it, silently,
before the report that would have said why — which is why it is written
`out=$(…) && rc=0 || rc=$?` and the status is read afterwards. The
`if out=$(…)` form this replaced was safe for the same reason any compound
condition is; reading the *status* instead of the truth of it is what needs
the guard.

The bypass path ends at its `exec` with no `exit` after it, and that is
correct rather than an omission: `execfail` is off, so a failed `exec` leaves
the shell with 127 rather than falling through into the code below the `fi`.

## uid 1001, not 1000

The node base image already owns uid 1000, and a collision on a named volume
produces permission errors that read as anything but. The home directory
created by `useradd` is what gives a fresh volume its ownership; nothing else
needs to be placed in it.

## The ssh key, and restoring it from the vault

The entrypoint keeps an ed25519 key at `~/.ssh/id_ed25519`, inside the volume.
On a home with no key it tries the vault first and generates only as the
fallback, under the hardcoded secret name `github-ssh-key`. Hardcoded and not
read from the environment: a name that can be changed in `.env` is a name that
can silently come to point at nothing, and the failure would be a container
that generated a fresh key and waited for a human — which is the morning this
exists to remove. Absent from the vault is not an error.

Only when there is no key. A restore that ran on every start would replace a
working identity with whatever the vault happens to hold, and the vault is the
copy most likely to be out of date.

A generated key is one GitHub has never seen, so it cannot clone — the old
behaviour on an empty home was always "stop and wait for a human", and on the
morning the volume is gone that is the whole of the outage.

`vault ssh-restore` exiting 3 means the key was restored and GitHub answered
that it does not know it. The restored key is **kept**, not replaced:
generating over it would swap one identity the account does not know for
another and lose the fingerprint that says which. It is reported as a setup
problem instead, with the public half printed — which is the whole of the fix,
pasted into the account. `vault`'s output is otherwise held back unless
something was restored, because "no secret named 'github-ssh-key'" is correct
and is also a scary line to print at a first bootstrap where the vault has
legitimately never held one. See docs/vault.md.

The enforcement that gated reading the key was withdrawn on 2026-09-01:
`Read(~/.ssh/**)` and `Bash(ssh-keygen *)` left the managed deny list, and
neither had a guard rule behind it. See docs/boundary.md.

## The Claude Code pin held for one day

An agent whose harness changes underneath it cannot tell a behaviour change
from one of its own mistakes, and every measurement it recorded was taken on a
version. So the Dockerfile pins `CLAUDE_CODE_VERSION` and `npm install -g`s
exactly that.

The line was decoration for five days. Read out of the transcripts on
2026-08-28: 2.1.238 was served from 2026-08-22 20:50 until 2026-08-23 14:24,
and then the CLI updated itself into the volume — 2.1.241, then 2.1.246 on
08-26, then 2.1.250 that morning — while the `ARG` went on naming 2.1.238 and
nothing anywhere said a word. 2,627 transcript entries on the pinned version
against 31,859 on versions nobody chose. It was the updater and not the agent:
`npm install -g` appears in no transcript ever. The `ARG` was then set to
2.1.250 because that is what was already running; moving it down would have
been the only actual change of harness.

Since 2026-09-03 `just pin --claude` moves the `ARG` to the version npm
publishes as latest and stamps the date, so the version is chosen on purpose and
the choice has a date; see `docs/release.md#the-two-pins`.

## PATH defeats the pin

The pin installs a version; on its own it does not keep one. The npm tree is
root-owned and the agent cannot write it — but the Dockerfile's `PATH` puts
`${AGENT_HOME}/.npm-global/bin` and `${AGENT_HOME}/.local/bin` ahead of
`/usr/local/bin`, and both are inside the volume. A second `claude` written
there, by hand or by the CLI's own updater, wins the lookup, survives every
rebuild, and leaves the `ARG` naming a version nothing runs.

Two things close the halves of that. `DISABLE_AUTOUPDATER=1` in
`compose.yaml` closes the automatic half — verified on 2026-08-28 as the
spelling the pinned binary actually reads, by grepping the installed
`bin/claude.exe` rather than trusting memory. The other half is *noticed*, not
prevented: `AGENT_CLAUDE_VERSION` is assigned from the `ARG` (never retyped —
a second hand-maintained copy of a version is the copy that goes stale, and
the staleness would be invisible in exactly the case this exists to catch),
the entrypoint moves it into the agent's namespace, `claude-session.py`
measures `claude --version` beside it in the session's environment header,
and `just verify` compares three values and prints SHADOWED with the path. A
rule against installing one by hand would have to live in the guard, and
nothing has needed one. See docs/verify.md.

## accept-new, not yes

The ssh host-key policy for github.com is `StrictHostKeyChecking accept-new`:
the first connection to a host is trusted and recorded, and a later change of
host key is refused rather than swallowed. Unattended runs cannot answer an
interactive prompt, and the alternative — baking GitHub's host key at build
time — pins a key that has rotated before and would fail silently when it
rotates again. Confirm the include is honoured at a first build with
`ssh -G github.com | grep stricthostkeychecking`, which prints what is in
force.

## Everything derives from AGENT_USER

The container's identity is a value, not a literal: this repository is meant
to be readable by someone running an agent of their own, and a name spelled
into forty files is forty places for theirs to be wrong. The Dockerfile's
defaults are generic and must never be anyone's real name — a default that
happens to be right for one installation is a default nobody notices is being
used.

`AGENT_USER` is the one value `compose.yaml` requires rather than defaults:
the `justfile` lowercases `AGENT_NAME` to get it and compose cannot, so a
default would let a bare `docker compose` address some other agent's volume in
silence. `AGENT_REPO_DIR` appears both as a build argument and in
`environment:` on purpose — the build bakes it into a permission rule inside
`managed-settings.json`, the run-time value is the real checkout, and
`just verify` compares them. A rendered rule that no longer matches the
running checkout denies nothing and allows nothing, so every tool call quietly
starts asking for approval instead.

The classifier's names travel the same way. The `autoMode` block describes
*this* installation, because a classifier that cannot resolve a name it meets
in a transcript against the trusted list is judging blind — which is in
tension with the rule that this tree names nobody. The committed file carries
placeholders and the substitution happens inside the image. Empty renders as
empty and the classifier is told nothing rather than told wrong.

The community sentence is the one that does not travel as a build argument: it
is a sentence and not a name, so it comes from `community.txt` in the build
context, read and removed in the render step itself. Comments are dropped and
whitespace collapsed, because it lands *inside* a sentence, and nothing left
renders the word `none` — where empty would leave a hole that reads as a broken
renderer rather than as "it has none". See
[configuration](configuration.md#the-three-files-that-are-yours).

The render step refuses before writing rather than after: a template that
still carries a `{{` placeholder is a boundary nobody chose, and it is silent
in both directions. The transcript retention is the one value that must land
as a JSON *number*, so its quotes are replaced along with it and the committed
file stays parseable for its host-side readers; `0` is valid JSON and means
delete everything at the next session start, so a typo in `.env` would wipe
the corpus with no symptom until it was gone — hence the whole-number check.

## Selftests at build time

`bash-guard.py`, `claude-usage` and `session-cost` each run `--selftest` in
their own `RUN` layer. The guard fails *open* — a syntax error, a lost `+x`, a
python3 that moved, and Claude Code logs the failure and carries on to the
permission rules, which is the silent death this repository is built against.
Running the selftest at build means a guard that cannot decide correctly stops
the build instead of shipping quiet. It runs no container and touches nothing
outside the image.

The other two are proofs that cost nothing: the arithmetic is pure, so it
needs no credential, no network and no container, and a wrong allowance or a
wrong price prints in exactly the shape a right one does. `claude-session
--render` runs for the same reason — a placeholder the script cannot fill
stops the build here rather than the first session, where a literal `{{NOW}}`
is invisible. See docs/budget.md and docs/boundary.md.

`bws` is pinned to a version *and* to the sha256 of the archive that version
resolves to: a tag can be moved and a release asset replaced, and neither
leaves a mark. It is unpacked with python3's `zipfile` rather than `unzip`,
which is one package this image does not otherwise need. See docs/vault.md.

## What the image was built from

`RUNNER_COMMIT` and `RUNNER_COMMITTED_AT` are build arguments measured on the
host by `just build`, because the build context is `image/` and carries no
`.git` — nothing inside a build can read them. They are the *last* `ARG`s in
the Dockerfile on purpose: they change with every commit and an `ARG`
invalidates every layer below it, so placed higher they would rebuild the
whole image for a one-line change.

Empty is a legitimate answer rather than a defect — a bare
`docker compose build` passes nothing, and `claude-session.py` then tells the
session the image does not say, rather than naming a commit that is not one.
Like `AGENT_CLAUDE_VERSION`, the baked name is literal because a Dockerfile
`ENV` name cannot be computed, and the entrypoint moves it into the agent's
own namespace so a session sees one spelling rather than two. See
docs/release.md#what-the-image-was-built-from.

## The agent's own namespace

What is genuinely the agent's is named for it — `<AGENT>_REPO`, not a
generic one — so `entrypoint.sh` builds the variable names rather than
writing them out. The account *is* the agent by construction, so `id -un` is
the authority and nothing has to be passed in to say who this is. Two `tr`s
and not one: mixing a character class with a literal in a single set is not
portable, and a shell name cannot hold a dash. Reading one of them back
needs indirect expansion, which is why every script here is bash and not sh.

`compose.yaml` writes those variables in **list form**, not as a mapping:
compose interpolates a list item whole, key included, which is the only way to
write a name built from `AGENT_PREFIX`. A mapping key is literal, so the
agent's own namespace cannot be spelled there.

## No container_name, and a volume named explicitly

Measured: `compose run` ignores `container_name`. It would also be one fixed
name where containers deliberately coexist, and it would hide which of them is
a session.

The volume, by contrast, is named explicitly so its identity does not depend
on the project name. Compose otherwise prefixes it, and the project name is
environment-derived — this machine sets `COMPOSE_PROJECT_NAME` per directory,
so `just` and a bare `docker compose` were addressing two different worlds.
Containers may be named however compose likes; they are ephemeral. The volume
is the only thing whose identity must hold. The project name itself is
declared rather than inferred, and derived rather than written out, because
`COMPOSE_PROJECT_NAME` exported by the `justfile` outranks the key — a stale
value there would never be used and never be noticed.

## What Claude Code sends that is not a session

`DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1`, both on the operator's
ruling of 2026-08-28. The argument is not the bandwidth: an error report
carries stack traces, file paths and command fragments out of a container
whose whole design is that what leaves is deliberate, and nothing on this side
reads either channel, so nothing is lost.

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` belongs to the same family and is
**absent on purpose**. Measured 2026-08-28: a real transcript carries
`ai-title` entries, and `host/archive/session-meta.jq` is the only writer of a
session's title, with no fallback behind it. Turn that traffic off and every
future session lists as "(untitled)" while the ones already archived keep
their names — the record splits into a titled past and an untitled future,
months before anyone connects it to a line in `compose.yaml`. See
docs/archive.md.

## Literal `1`, never `${VAR:-}`

Those three variables mean "any non-empty value, including `0`, turns the
behaviour ON; unset or empty turns it OFF" — backwards from every other flag
in `compose.yaml`. Written as `${DISABLE_TELEMETRY:-}`, an unset host variable
would arrive as the empty string, which is the OFF value, and the line would
look set while doing nothing.

That is the shape of a failure already measured here:
`ACCOUNT_BUDGET_GUARD` was set to `true` in `.env` and silently overridden by
an empty duplicate assignment twenty lines later. `just` and compose both take
the last assignment, and a shadowed line has no symptom at all — it was found
only because someone said out loud that they had just enabled it. `just
verify` now proves `.env` names nothing twice. See docs/verify.md.

## The bws region has no safe default

`BWS_SERVER_URL` is not optional. `bws` ships pointing at the US server, and a
token issued on bitwarden.eu is rejected there as `invalid_client` — which
reads exactly like a revoked or mistyped token, and sent someone checking the
token three times. Measured 2026-08-24. Empty means bws's own default, which
is US. See docs/vault.md.

## The Claude login is reported on every start

`entrypoint.sh` prints the Claude login beside the `gh` account, because a
container whose Claude login is gone looks exactly like a healthy one until
the first unattended session stands down — and the budget gate, which is what
stands it down, reads the same credential.

It is a function and not a substitution inside the report heredoc.
`claude auth status` exits non-zero when it is logged out, `set -o pipefail`
makes the whole pipeline fail with it, and the `||` fallback then printed its
answer on a line of its own *under* the correct one. Measured 2026-08-25 — it
looked like two findings and was one command's exit status. See
docs/sessions.md.

## The testing bypass announces itself

`AGENT_SKIP_CLONE` skips the clone entirely, and it sits *ahead* of the setup
gate rather than behind it: its whole purpose is exercising the image without
a repository or a key GitHub knows about, and a gate that still stopped for
the key it told you to generate would defeat that on the very first run.
Nothing blocks under the bypass — but it prints a banner on every start,
because a quiet bypass is one that gets left in `.env` and then nobody can
explain why the checkout is missing.

It skips the repository, not the environment: it execs through `vault-env` and
calls the usage read on that path too, exactly as the real path does. A
container that started with a different set of variables depending on a
testing flag is the one thing this whole arrangement is trying not to be, and
a bypass that quietly changed which credential is in force would make every
test under it a test of something else.

Exit 78 is sysexits' `EX_CONFIG`, used everywhere the entrypoint stops for
something only a human can supply: an unattended run that did not happen must
be distinguishable from one that did.

## Workspace trust is pre-accepted, carefully

The entrypoint pre-accepts the workspace trust dialog for the checkout so an
interactive session starts in it rather than at a prompt. `just run` passes
`-p`, where the dialog is skipped outright, so this changes nothing for an
unattended session — it is for `just chat`.

Trust is not a permission. It gates that one dialog and nothing else: the deny
list and `defaultMode` come from `/etc/claude-code/managed-settings.json`,
which nothing in the volume can reach. The agent could set this key itself;
that it cannot set the ones that matter is the whole design.

The care around the edit is because `~/.claude.json` also holds the Claude
Code login. It is rewritten through a temporary file in the same directory and
moved into place, and a file that does not parse is left untouched rather than
replaced — a clobbered `.claude.json` logs the agent out, and the next
unattended session would fail with nothing pointing here.


**The first-run wizard, marked complete (2026-09-03).** The same file carries
`hasCompletedOnboarding`. Without it an interactive session opens Claude
Code's onboarding — the theme choice, then a login step that asks even when
`vault-env` has put the setup-token in the environment and `claude auth
status` says logged in. `-p` sessions never see the wizard, so every verify
probe passed while the demo's first `just chat` on a fresh volume asked the
operator to log in. The entrypoint sets the key the way it accepts the trust
dialog: read, add, write back with the same mode, and say so once.

## The build context is image/

Narrowed to `image/` deliberately: `.env` and the host-side scripts are then
not in the build context at all, so no `COPY` can reach them by accident.
`vault-exempt.txt` and `secret-shapes.txt` sit beside the guard in
`/usr/local/bin` rather than in `/etc`, because the guard is the only thing in
the image that reads either and a path with one reader is one fewer place for
the two to disagree — the host's copies are the same files in the checkout, and
`COPY` is the comparison, which `just verify` makes. Both are untracked, as
`community.txt` in the same directory is; see
[configuration](configuration.md#the-three-files-that-are-yours).

## No bind mount, and no published ports

There is deliberately no bind mount — not even a read-only one. The container
cannot see the host filesystem, which is what makes "it can do as it likes in
there" true rather than aspirational; it clones what it wants to read. No
ports are published: the agent reads the world, and nothing reaches in. A
runaway session should cost a container and not the machine, so `mem_limit`
and `cpus` are set.

`compose.yaml` closes with the list of six settings that would each, alone,
make all of that theatre — the docker socket, `privileged`, host networking,
host pid, any bind mount, `user: root` — and the failure would be silent,
since the container goes on working exactly as before. That list is current
doctrine and lives at the end of the file, not here.
