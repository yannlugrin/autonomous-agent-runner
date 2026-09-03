# Release

## What it is, and what to do

Nothing you edit in this checkout reaches the agent until you say so. That is
the whole of it. An agent that runs unattended on a schedule picks up whatever
is in the tree at its next wake-up, so without something between them, "let me
build it and see" and "I shipped it" are the same act — and a change still
under review goes live because proving it meant building it.

The sequence is `build`, `verify`, `deploy`, and only the last of the three
reaches the agent. With what surrounds it:

| command | what it does |
| --- | --- |
| `just setup` | once per clone: create `.venv`, install the pinned tooling and the pre-commit hooks, so the hook and the command cannot run different versions — and make the three per-installation files under `image/` from their committed examples. `--restore` takes them from the archive's `config` branch instead |
| `just lint` | the pre-commit hooks over the whole tree — `ruff check`, `ruff format --check`, `shellcheck`, `gitleaks`, `check-auto-mode` — at the versions `.pre-commit-config.yaml` pins, then `mypy`. Each says `[ ok ]` or `[FAIL]` itself, and the count at the end is what you read; the exit status is what CI reads |
| `just pin` | pin the base image to today's digest, as a diff to read. It refuses a dirty file and never commits |
| `just build` | build `<agent>-agent:candidate` and run the selftests baked into the build. **Nothing scheduled runs that tag.** `--deployed` tags the live one instead, and only the deployed checkout may |
| `just verify --build` | rebuild the candidate, then prove it. The flag is the point: a stale image passes in the same words a correct one does |
| `just deploy` | go live. `--diff` is the patch between what is live and what would be, `.env` included and masked and the three per-installation files included and not; `--state` reports the same facts as parseable fields. It backs those three up to the archive's `config` branch once it has succeeded |

**The rule.** `build` tags a candidate; `verify` proves *that* candidate;
`deploy` resets the deployed checkout — `deployed/`, a git worktree of the
`deployed` branch, inside the project and gitignored, and the tree cron
actually runs from — to `HEAD`, and then **builds the live image from that
checkout**. The code that is live and the image that is live are therefore one
thing rather than two that have to agree, and that spelling is also the only
one that covers `.env`, whose values are build arguments and which git does not
track.

**What you type,** for a change to `image/`: `just lint`, `just verify
--build`, read what it printed, then `just deploy`. Deploy shows what is about
to go live and asks; it holds the schedule for the duration and puts it back as
it stood. **Building and verifying need no paused schedule**, because a build
is not a deploy — the consequence worth stating out loud, since it is the whole
reason the three commands are three.

**What it refuses.** A tree that is not clean, full stop — what goes live is
`HEAD`, so an uncommitted edit here would be in neither the commit nor the
build, and a deploy that proceeded would ship something other than what you can
see. `.env` is not covered by that and cannot be: it is gitignored and copied
live, which is what `--diff` shows you, masked. And deploy does **not** retag
the candidate: a retag ships a checkout at `HEAD` beside an image built
whenever `build` last happened to run, and nothing could report it, because
both `deploy` and `status` compared the two tags — which are equal in exactly
the case where the mistake has been made.

**What you see afterwards.** The image records the commit it was built from, so
a session can name its own version, and `just status` says in one phrase what
this checkout has that is not live yet.

## How it is built

Nothing edited in this checkout reaches the agent until `just deploy`. The
sequence is `just build`, `just verify`, `just deploy`: `build` tags a
candidate image, `verify` proves that candidate, and `deploy` resets the
deployed checkout to `HEAD` and builds the live image *from* that checkout,
after showing what is about to go live and asking. It lives in
`host/release/` — `build.sh`, `deploy.sh`, `undeployed.sh`, `pin.sh` with
`pin.py`, `setup.sh`, `lint.sh`, `check-auto-mode.py` — with the two image
tags and the deployed path named once in the `justfile` and the run-time
`image:` default in `compose.yaml`.

## A build was a deploy

Until 2026-08-28, `compose.yaml`'s `image:` said `agent:local`: one tag that
every build overwrote, and the only tag anything ran. Twice a change that was
still under review went live on the next scheduled session, because the only
way to prove it was to build it.

The fix is the two tags. `just build` sets `RUNNER_IMAGE` to
`<agent>-agent:candidate`; `just verify` and every `--build` flag run the
candidate; `<agent>-agent:deployed` is what cron's session runs on, and only
`just deploy` moves it. A bare `docker compose build` typed by hand still
tags `compose.yaml`'s default, which is the deployed one — that is why
`just build` exists rather than the raw command.

The consequence worth stating: building and verifying no longer need the
schedule paused.

## Deploy builds, and does not retag

The operator's ruling of 2026-08-30. Deploy used to move the deployed tag onto
the candidate image. A retag ships a checkout at `HEAD` beside an image built
whenever `build` last happened to run, and for a day and a half it shipped
managed settings without the `gh` verbs that commit `e5884cc` had added.

Nothing could have reported it. The image recorded no commit, and both
`deploy` and `status` compared the candidate tag to the deployed tag — which
are equal in exactly the case where the mistake has been made. Building from
the deployed checkout makes the code that is live and the image that is live
one thing rather than two things that have to agree, and it is the only
spelling that also covers `.env`, whose values are baked in as build
arguments and which git does not track.

`deploy.sh` runs `( cd "$target" && just build --deployed )` after the reset
and after the `.env` copy, because both are inputs. Through `just` in that
checkout and not `docker compose` here: compose cannot derive `AGENT_USER`
from `AGENT_NAME` on its own, and a second derivation spelled in `deploy.sh`
would be the copy that drifts. `build.sh` refuses `--deployed` anywhere but
the deployed checkout, since that checkout *is* the build context — run in
the tree under edit it would build what is being edited and tag it live.

A failure at that point leaves the checkout moved and the image old. That
half-state is handled rather than prevented: the schedule stays paused and
nothing starts on the pair until someone has looked.

## The candidate follows the live image

Also 2026-08-30. After a successful deploy, `deploy.sh` tags the deployed
image as the candidate too. `just verify` proves the candidate, and a verify
reporting on an image older than the one running is the same class of quiet
wrong answer the change above is about.

It is a statement of fact and not an approximation: the tree was refused
unless clean, the deployed checkout was reset to `HEAD`, and `.env` was
copied from here — so the context and the build arguments that produced the
live image are byte-for-byte what `just build` in this tree would use. The
two tags name one image because one image is what both describe.

## Where the deployed checkout lives

**The operator's ruling, 2026-08-28.** The deployed checkout is a git worktree
of the `deployed` branch at `deployed/` *inside* this project, gitignored like
`draft/`, and moved only by `just deploy`. It is not a sibling directory:
`~/projects/<agent>` is the operator's project layout, not a place to deploy
into, and a demonstration anyone can clone must arrange nothing outside its own
directory.

It exists because cron reads whatever tree it is pointed at, committed or not.
For as long as the crontab named the working tree, an edit to a recipe was live
on the next scheduled session, and so was an image rebuilt to verify it.
`host/schedule/schedule.sh` writes this path into the crontab entry,
`host/release/deploy.sh` resets it to `HEAD`, and `just status` says how far
behind `main` it is.

The justfile derives both `RUNNER_ROOT` and `RUNNER_DEPLOYED` from the *project
root*, which is not always the justfile's own directory: the deployed
checkout's copy of the justfile must compute the same archive and the same
deployed path as the checkout above it, or a session run from it would collect
into a directory that does not exist. A justfile whose directory is called
`deployed` therefore takes its parent as the root — the derivation chain is
in `docs/configuration.md`.

## Reset, not merge

The operator's ruling of 2026-08-28. The deployed checkout is an environment
and holds nothing to protect. A merge is a step that can fail — a diverged
branch, a stray edit in the tree — where a reset cannot. `deploy.sh` does
`git reset --hard` to `HEAD` plus `git clean -fdq`, which moves the
`deployed` branch and the tree with it, takes any untracked file that
appeared, and leaves what is ignored — which is where `.env` lives.

An environment is *set* to a commit, never merged toward one, so a deployed
branch that has wandered (a commit made in it by hand, a `main` that was
rewritten) is not a refusal: the question names those commits as dropped and
the reset then discards them.

On a first deploy there is no worktree, and it is created with
`git worktree add -B deployed` — `-B` and not `-b`, so a `deployed` branch
left behind by a removed worktree is reused and moved rather than refused.

## The one refusal, and what it does not cover

A tree that is not clean, the operator's ruling of 2026-08-30. What goes live
is `HEAD`, and the build runs on the deployed checkout at `HEAD`, so an
uncommitted edit here is in neither — a deploy that proceeded would ship
something other than what the person looking at this tree can see. The check
sits above the terminal check, because it is true whether or not anyone is
there to be asked.

`.env` is not covered and cannot be: it is gitignored, it is copied live by
this recipe, and its values are build arguments. A clean tree is not a claim
about `.env`; `env_diff` is what shows it, masked, since a terminal gets
copied into issues. It is copied and never linked — a link would make an edit
in this tree live for the deployed runner with no deploy at all, which is the
hole the recipe exists to close. `cp --remove-destination`, because the
deployed one was a link once and `cp` onto a link writes through it, into
this checkout's own file.

## The schedule is held for the duration

The operator's ruling of 2026-08-28: a deploy pauses the schedule so no
session starts while the checkout and the tag move, and puts it back as it
stood. A session already running is not stopped — it finishes on the scripts
it loaded — but it is named in the question, since pausing prevents only the
next one.

The schedule is enabled again only when everything succeeded. Not on failure,
which was the operator's own question on 2026-08-28: what a failed deploy
leaves depends on where it failed, and after the reset it is either a
checkout on the new commit with the old image, or a crontab that still names
the working tree. A session started on either is exactly what the recipe
exists to prevent, so a failure leaves the schedule paused and says so on
every exit path — the way the budget guard refuses rather than guessing. See
docs/schedule.md.

## `--state` is parsed twice

`deploy --state` prints the same facts as fields, and both `just status`'s
`sed` and `fields()` in `host/archive/status-collect.py` read them. The
undeployed commits are printed one per line with the key `commit:` repeated,
rather than as a `git log` block pasted in: a subject that happened to begin
`word: ` would otherwise enter either reader as a field of its own. The
repeated key keeps the shape — the `sed` reader returns all of them, and
`fields()` keeps only the last, so a reader wanting the list must accumulate
rather than assign.

The count answers "how far behind"; only the subjects answer "does this
deploy need me to warn the agent first", which is what a person reads it for.

## Docker format strings collide with `just`

`deploy.sh`'s `image_id()` uses `docker images -q --no-trunc` and not
`docker inspect --format`, because a docker format string is a pair of braces
and so is a `just` interpolation, and the escaping has been wrong before.

## What "not deployed" is counted against

`undeployed.sh` counts commits against the *deployed checkout's* `HEAD`, not
against the `deployed` branch. The branch is what `just deploy` moves; the
checkout is what cron actually reads. The two are the same until something
has gone wrong, and in that case the checkout is the honest answer.

It prints one phrase — "2 commit(s) not deployed, and 3 uncommitted
change(s)" — or nothing, exiting 1, so each caller decides for itself whether
that silence deserves a sentence. Two callers wrap it: the forwarder in
`host/lib/deployed.sh`, before it sends a live command to the deployed
checkout, and `just listen --live` between one session
and the next. One spelling, because the one that drifts is the one nobody was
looking at when it did.

## What the image was built from

`build.sh` measures the commit and its date on the host and exports
`RUNNER_COMMIT` and `RUNNER_COMMITTED_AT`, because nothing inside the build
can measure them: the build context is `image/` and carries no `.git`. It
measures the checkout being built and not the project root, since
`--deployed` runs in the deployed checkout, which is exactly what it is
building. Empty on a tree that is not a repository, which reads downstream as
"the image does not say" rather than as a commit. See
docs/image.md#what-the-image-was-built-from.

`--progress auto` is the one override of the quiet compose settings the
`justfile` sets. A build is the one compose command whose progress *is* the
answer: which layers were cached is how you see whether a pin actually
reinstalled, and a silent build that exits zero is the shape of failure this
process is written against.

## The two pins

A tag is not a pin, and neither is "latest": both move underneath you and the
rebuild says nothing. `just pin` resolves both things the Dockerfile takes from
outside — the base image's tag to the digest it points at today, and Claude
Code to the version npm publishes as latest — writes each into its line with a
dated stamp, and commits nothing: what it produces is a diff to read. `--image`
and `--claude` do one of the two. The Claude Code half asks the npm registry
and needs no docker daemon; the image half pulls, so it does.

`pin.py` edits the file that defines the agent's confinement, and the agent
wrote the script. Its contract is therefore narrow by rule, not because of a
defect found: it refuses unless exactly one `FROM` line and exactly one
`ARG CLAUDE_CODE_VERSION` line exist, it refuses a line in a shape it cannot
pin, it changes only those lines and their stamps, and it never commits. The
image reference and the current version are read out of the Dockerfile rather
than kept in a second place, because two copies drift and nothing notices.
`pin.sh` refuses to run at all while `image/Dockerfile` has uncommitted
changes, so the pin lands alone.

Until 2026-09-03 `just pin` pinned the image only, and the Claude Code version
was moved by hand. A version moved by hand is one that stays where it was,
which is the failure `docs/image.md#the-claude-code-pin-held-for-one-day`
records from the other direction.

## check-auto-mode, and the sibling it outlived

`check-auto-mode.py` proves the auto-mode configuration is whole: the sources,
the document `AUTO-MODE.md`, and the `autoMode` block inside
`image/managed-settings.json`. It runs from `just build` and from
`just verify`, and its findings are collected rather than fatal at the first
one, so a single run says everything that is wrong.

It was the sibling of `check-backstop.py`, which compared the guard's
deny rules against the managed deny list until both shrank to nothing on
2026-09-01, when the enforcement over force-push and history rewrite was
withdrawn and check-backstop was deleted with them. The reason that one was
written is the reason this one survives it: two artifacts describe one set of
decisions, and when they drift nothing says so.

That drift was measured twice while the document was being written — a
hand-fixed rendering was overwritten by the next build, and once the document
said a rule was dropped while the config still shipped it. `build.sh` records
the same thing a third way: a fix typed into either output is erased by the
next build with no symptom, and that happened three times. Hence the freshness
comparison calls `auto-mode/build.py`'s own builder rather than reimplementing
it, so there is one description of how the outputs are made.

The four structural checks each fail silently otherwise: every rule the
document marks as shipping has installed text and the per-section counts
match the config's; the index lists exactly the entries that exist; all 20
environment slots are present in the shipped `**Slot**: value` shape, because
the array is a full replacement and a slot nobody writes disappears with no
symptom; and no `$defaults` or unresolved fragment reached the config.

`build.py --check` does the same freshness comparison on its own and stays for
iterating on the sources. `just build` and `just verify` call the one command,
because a stale output and a self-inconsistent one are the same question to
whoever reads the answer.

## Setup, the project-local `.venv`, and the lint set

`just setup` creates `.venv` and installs `requirements-dev.txt` into it, then
installs the pre-commit hook. Nothing is installed outside the project, and
the versions are pinned there, so `just lint`, the pre-commit hook and CI all
run the same ones — a hook and a command cannot differ.

It then makes the three per-installation files under `image/` from their
committed examples, and only the ones that are absent: an edit is the
operator's, and this recipe is run again after every pull. It says which files
it made and is silent when there was nothing to make — a line printed on every
run is a line nobody reads on the day it says something. `--restore` takes them
from the archive's `config` branch instead, for a machine that lost them, and
says which of the two it did for each. See
[configuration](configuration.md#the-three-files-that-are-yours).

`just lint` runs the pre-commit hooks over the whole tree, then `mypy`, which
is not a hook because it is too slow for every commit. CI runs exactly those
two steps, and nothing of its own: until 2026-09-03 it ran `shellcheck` from
the runner's apt, a version behind the one the hook pins, and failed on
findings the pinned one does not make — a hook and a command that had been
told not to differ, differing. The hooks find the shell files themselves,
because a glob per directory is a list that stops covering the directory added
after it, silently. Each step prints `[ ok ]` or `[FAIL]` itself, the count is
what a person reads and the exit status is what CI reads. An absent `.venv` is
a FAIL and not a skip: a check that quietly did not run is the shape this
repository is written against.

**2026-09-02.** `target-version = "py311"` in `pyproject.toml`, and
`python_version = "3.11"` for mypy, are the *container's* interpreter and not
the host's: the base image is Debian Bookworm, whose `python3` was confirmed by
running it to be 3.11.2, while this host is on 3.14. The floor matters because
`ruff format` under `py314` may emit PEP 758 syntax — an unparenthesized
`except` tuple — which is a `SyntaxError` under 3.11, so a formatted
`image/*.py` would fail to parse in the image that runs it. `host/**/*.py` and
`auto-mode/*.py` run on the host, but 3.11-valid code is a subset any newer
interpreter accepts, so one target covers both. CI runs both ends, 3.11 and
3.14, for the same reason.
