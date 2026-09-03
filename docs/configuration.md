# Configuration

## What it is, and what to set

An installation has to know one thing: who the agent is. Everything else — the
unix account, its home, the checkout path, the docker volume, the Compose
project, the two image tags, the three vault projects, every lock and stamp and
log — is built from that name. A setup that made you spell the same name into
eight variables would be a setup where seven of them are eventually wrong, and
six of those wrong in silence.

`.env` is the file. Copy it from `.env.example`, which shows every optional
value beside what it derives to; `VARIABLES.md` is the reference of all of them
by category; the justfile's header is where the derivation actually happens.

Four values cannot be computed, and a fifth is what the vault runs on:

| variable | what it is |
| --- | --- |
| `AGENT_NAME` | what the agent is called. Everything below derives from it |
| `<NAME>_REPO` | the agent's own repository, over SSH. `<NAME>` is `AGENT_NAME` uppercased, dashes as underscores — an agent called Demo reads `DEMO_REPO` |
| `<NAME>_GIT_EMAIL` | what it commits as. Use the account's own `users.noreply` address: the numeric id in it is not a function of the handle, so nothing can derive it |
| `AGENT_ARCHIVE_REPO` | `owner/name` of the transcript archive, which is usually not the agent's own account |
| `BWS_ACCESS_TOKEN` | the vault's machine-account token. Unset is not a failure — the vault is simply not configured, and says so |

**The rule.** `AGENT_NAME` gives `AGENT_USER` (lowercased, spaces closed up,
because a unix account, a volume and an image tag can hold neither a capital
nor a space), and `AGENT_USER` gives the rest. **An override becomes the input
to every step under it**: set `AGENT_USER` and the home, the checkout, the
volume, the project, the image tags and the vault projects move together,
rather than five of them going on naming the old agent.

Names say **what they are about**, not who reads them. `<NAME>_*` is genuinely
the agent's and a session sees it; `AGENT_*` is the agent's but held by the
runner and never shown to it; `RUNNER_*` is machinery, identical whichever
agent ran here; a tool keeps whatever it already calls its own.

**What you type.** `cp .env.example .env`, edit those five lines, and read the
rest of the file once — the optional ones are commented out beside the value
they become, so uncommenting is how you depart from a default rather than how
you discover one. `just verify` then proves the two halves that cannot be seen
by eye: that `.env` names nothing twice, and that Compose still refuses to
guess which agent it is.

**Three things are not in `.env`**, because they are lists and sentences rather
than values, and because what they hold is this installation's rather than this
repository's. They live under `image/`, one file each, and none of the three is
committed:

| file | what it holds |
| --- | --- |
| `image/config/vault-exempt.txt` | the vault entries that are identifiers and not credentials, so that an account id stored beside a token stops holding transcripts back |
| `image/config/secret-shapes.txt` | the shapes of the secrets this agent holds because of what it does — a forum's key format, a feed token, a webhook URL — added to the floor the collection and the guard already carry |
| `image/config/community.txt` | one sentence naming the community the agent belongs to, rendered into the classifier's own environment at build |

`just setup` makes each from its committed `<name>.example.txt` when it is
absent, and leaves an edited one alone. `just build` refuses without them.
`just deploy` copies them into the deployed checkout beside `.env`, shows them
**unmasked** in `--diff` — they are rules, not values — and, once the deploy has
succeeded, backs the three up to a `config` branch on the archive: that is the
moment they take effect, and it is the only moment at which the branch and what
is live are the same thing. `just setup --restore` reads that branch back, for
the machine that lost them. `.env` is never carried there.

**What it refuses.** No value may be named twice — `just` and Compose both take
the *last* assignment, and a shadowed line has no symptom at all; that is how
`ACCOUNT_BUDGET_GUARD=true` sat silently overridden by an empty duplicate
twenty lines below it. Changing the identity after an installation has run is a
**migration and not an edit**: the volume holds absolute paths and none of them
move on their own. And there is deliberately no recipe that deletes the volume
— the agent's memory lives there, deletion is not recoverable, and a one-word
footgun is how that happens by accident.

## How it is built

One value is required — `AGENT_NAME` — and everything else is derived from it
in the justfile's header, step by step, each step overridable in `.env`. An
override becomes the input to every step under it, so setting `AGENT_USER`
moves the home, the checkout, the volume, the Compose project, the image tags
and the vault projects together rather than leaving five of them naming the old
agent.

`.env.example` is the copy-and-edit template, `VARIABLES.md` is the reference
of every variable by category, and the justfile header is where the derivation
actually happens. This document holds the measured records behind the shapes
those three have.

## One name, everything derived

A setup that makes you spell the same name into eight variables is a setup
where seven of them are eventually wrong, and six of those are wrong silently.
So `.env` asks for the name, the agent's repository and the address it commits
as, and derives the rest.

The lowercasing happens in the justfile, and that is why the chain roots at
`AGENT_USER` rather than at `AGENT_NAME` everywhere else. `compose.yaml`
derives the same chain with the same defaults — it can nest them — but Compose
has no way to change a case, so `Borges` could never become `borges` there.
`just` does it once and exports the answer; `compose.yaml` then *requires*
`AGENT_USER` rather than guessing at one, so a bare `docker compose` typed by
hand says what is missing instead of quietly addressing an empty volume beside
the real one.

The same asymmetry produces the plumbing names. Compose can *build* a key from
`AGENT_PREFIX` — a list item is interpolated whole — but a value reference
`${...}` must name a literal variable, and `just` cannot export a computed name
at all. So the justfile reads `<NAME>_REPO` out of `.env` and hands Compose
`AGENT_REPO`, which Compose emits into the container as `<NAME>_REPO` again.
The middle name is plumbing; nobody writes it and nobody reads it.

## The three files that are yours

**2026-09-03.** `image/config/vault-exempt.txt` was committed, and it holds vault key
names — which is to say the names of an installation's own secrets, in a
repository meant to be published. The other two did not exist: this agent's
secret shapes were three patterns typed into `host/archive/scan.sh` and
`image/bash-guard.py`, and its community was a sentence in `.env`. All three are
the same kind of thing — configuration that is a list or a sentence, that
belongs to the installation and not to the tree — so all three are now untracked
files under `image/`, each with a committed `<name>.example.txt` beside it.

**Why under `image/` and not somewhere tidier.** The build context is `image/`,
deliberately, so nothing outside it can be `COPY`'d by accident. Two of the
three are read inside the container — the guard reads both from
`/etc/agent/`, where configuration belongs — and the third is read by the
build itself. A file the build
needs has to be in the context, and a second location for the ones that are not
would be a second place to look.

**The example carries the header, the live file carries the answer.** Each
example is the documentation: what a line is, what the file is for, what editing
it costs. Neither ships a real entry — the placeholders are commented out, so a
fresh installation's file is a file that adds nothing until it is edited, which
is the right default for all three.

**Why the backup is on `deploy` and not on a schedule.** They are untracked, so
nothing else keeps a copy, and a machine that loses them loses rules nobody
wrote down anywhere else. A deploy is the moment a change to them takes effect,
which makes it the one moment at which "what is on the branch" and "what is in
force" are the same sentence. `host/release/config-backup.sh` writes the
`config` branch the way `publish-status.sh` writes `status`: a throwaway
worktree, a non-blocking lock, and nothing committed when nothing changed. See
docs/archive.md#the-config-branch.

**`.env` is deliberately not backed up with them.** It holds
`BWS_ACCESS_TOKEN`, which is the key to every other secret this installation
has, and the archive is a repository like any other. The three files hold rules
and no values, which is what makes them safe to carry and safe to show unmasked
in `deploy --diff`.

**What a missing file does.** `just build` refuses and names `just setup`,
because the alternative is docker's account of a build context that does not
hold what a `COPY` asked for — a true message about the wrong layer. Inside the
image, an absent `secret-shapes.txt` adds nothing to the guard's floor and an
absent `vault-exempt.txt` exempts nothing, both of which are the strict
direction; an empty `community.txt` renders the word `none`.

## The placeholder lines ship commented out

**2026-09-02.** `<NAME>_REPO=` is not a name a shell can hold, and under `set
dotenv-load := true` `just` refuses the *whole* file on one such line —
"Failed to load environment file", on every recipe, before anything runs.
`.env.example` shipped those two lines live until then, so `cp .env.example
.env` broke every command until the file had been read. They are commented out
now, required though they are, and the header says `<NAME>` is `AGENT_NAME`
uppercased with dashes as underscores. Measured.

## No value may be named twice

Both `just` and Compose take the *last* assignment in `.env`, and a shadowed
line has no symptom at all. `ACCOUNT_BUDGET_GUARD` was set to `true` and
silently overridden by an empty duplicate twenty lines later; it was found only
because someone said out loud that they had just enabled it. `just verify`
proves `.env` names nothing twice — see `docs/verify.md`.

## Compose's project name decides where the volume is not

`name:` in `compose.yaml` declares the project, but the `COMPOSE_PROJECT_NAME`
environment variable outranks that key — and this machine sets
`COMPOSE_PROJECT_NAME` per directory, which is how the volume once ended up
under a project-name prefix instead of the name `compose.yaml` declares.
Exporting it from the justfile is what decides. The volume itself is named
explicitly in `compose.yaml`, so it never depends on where this repository
sits; the project name prefixes container names only.

## Compose narration is quiet, and `build` turns it back on

**2026-08-29, Compose v5.4.0.** Compose narrates every container it makes — two
lines of "Creating"/"Created" naming a container that exists for one command
and is gone before you read them. Nearly everything here is `compose run`, so
that noise sat above almost every answer this repository gives: the transcript
listing, the status check, the settings check, each verify probe. It was set as
a flag on three of eighteen call sites and missing from fifteen, so it became
one export: `COMPOSE_PROGRESS := "quiet"`.

What was measured is that it suppresses *progress*, not output and not errors:
the container's own stdout still prints, `no such service` still prints, and a
build that fails still prints the failing line and the whole `failed to solve`
block. What it does silence is a *successful* build's layer output — which is
why `just build` overrides it back to `auto`, and is the only place that does.

## The lock path is literal, the cache path follows XDG

`RUNNER_LOCK` spells `/tmp` out rather than following `TMPDIR`. `just` has no
temp-directory function — 1.45.0 offered `cache_dir`, `config_dir`, `data_dir`,
`data_local_dir`, `home_dir` and `executable_dir`, and nothing for temp — and
it would be the wrong thing here if it did: cron sets no `TMPDIR`, so a lock
that followed one would put a `just run` typed by hand and the scheduled one on
*different files*, each taking a lock the other cannot see. Two sessions at
once is the exact thing the lock exists to prevent, and it would arrive on the
day someone exported `TMPDIR` in a shell profile, with no symptom until it
happened. `RUNNER_SNAPSHOT_LOCK` is literal for the same reason.

`RUNNER_CACHE_DIR` is the opposite case and follows `XDG_CACHE_HOME`: what it
holds is read by whoever wrote it, and the worst a split there costs is a
cooldown measured from a stamp cron cannot see — a session spaced wrong, not
two sessions at once. The lock still holds underneath it either way.

## One cache directory, plain names inside it

The cache files were six siblings spelled `<agent>-last-chat`,
`<agent>-run.log`, `<agent>-runner/` and so on, loose in a `~/.cache` that
belongs to every other tool on the machine as well: the agent's name repeated
in each was doing, six times and by convention, the work one directory does
once. They are one directory per agent now — two agents sharing a cache would
invalidate each other's scan on every run, so the grouping gives up nothing
that the spelling bought. The root is a *default* for the names below it, not a
prefix they are forced through, which is what lets a test recipe point one file
elsewhere without moving the rest.

## The variables are defaults, not overrides

Every derived value is `env_var_or_default(...)` and not a bare `export X :=
"..."`. A bare export overrides the environment rather than defaulting to it,
so the value could never be pointed elsewhere — which is how the first test of
the session lock passed while testing nothing, the recipe holding one file and
the test holding another.

## Changing the identity later is a migration

Changing `AGENT_USER`, `AGENT_HOME` or `<NAME>_REPO_DIR` on an installation
that has already run is a migration, not an edit: the volume holds absolute
paths — the `~/.claude` login, and the transcript directory Claude Code names
after the checkout — and none of them move on their own. uid 1001 does not
change, so ownership survives; the paths do not.

## The operator marker is matched literally

`OPERATOR_SAYS` is written in front of every message `just chat` seeds, and
`host/session/last-chat.sh` finds a conversation in the volume by grepping for
exactly that string with `-F`. Changing `OPERATOR_NAME` on an installation that
has been running therefore makes every earlier conversation unfindable by `chat
--continue`. Nothing breaks loudly; it just stops resuming anything from before
the change. It is one variable and not three literals for the same reason: two
spellings of one marker would drift, and the reader is the half that would go
on believing the old one.

## What `just`'s own settings buy

- `set minimum-version := '1.55.0'` — so a `just` that cannot read this file
  says which version it wants instead of failing to parse a line that is fine.
  The declared flags arrived in 1.46.0, but `set minimum-version` is itself
  newer than all of them and runs in just's parser, so an older `just` reports
  an unknown setting rather than the sentence — the number has to be the one
  that makes the sentence appear. `just verify` reads the number back out of
  that line and asks it of the `just` the installed crontab entry's own PATH
  resolves, which is not the one you type with — see `docs/schedule.md`.
- `set positional-arguments := true` — so a recipe reads its arguments as `$@`
  rather than as text spliced into its body. `just chat --force "a prompt, with
  commas"` needs the flag and the prompt to stay separate words, which `{{ ARGS
  }}` interpolation cannot promise.
- `set ignore-comments := true` — a recipe without a shebang has every line
  echoed as it runs, comments included, which is not obvious until a four-line
  explanation appears above every `just shell`. A comment inside a recipe body
  is not inert either way: `just` expands `{{ ... }}` in it exactly as it does
  in code, so a name mentioned in passing inside a recipe comment is
  interpolated and an unknown one is a parse error in a line that only
  explains something. Comments naming a `{{ }}` value therefore sit at file
  level, above the recipe, where nothing interpolates them.
- `set dotenv-load := true` — the budget guard runs on the host, so the
  `ACCOUNT_BUDGET_*` values have to be readable by the recipes as well as by
  Compose. `just` parses the file properly; grepping one line out of it would
  be a second reader of a format that already has one.

## There is no recipe that removes the volume

Deliberately. The agent's memory lives there, deletion is not recoverable, and
a one-word footgun is how that happens by accident. `docker volume rm` by hand,
naming the volume in full, is the only way.
