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

## A deleted checkout repairs itself

Measured 2026-09-09 on git 2.53.0, after the operator deleted the deploy
checkout by hand. Removing the directory does not remove its registration under
`.git/worktrees/`, and git then refuses the next
`git worktree add -B <branch> <path>` with

    fatal: '<branch>' is already used by worktree at '<the path that is gone>'

— the branch, not the path, and the path it names no longer exists, so the
message reads as a conflict with something that is not there. `--force` would
also clear it, but it would clear a *live* registration just as happily.
`deploy.sh` runs `git worktree prune` first instead, which drops exactly the
registrations whose directory is missing and leaves every other one alone.

A deleted checkout is a state with nothing to lose: it holds only what the next
deploy writes into it. So it is repaired rather than reported, on the same
reasoning as the reset above. The far side already behaved this way —
`host_checkout_state` answers `absent` and `host_checkout_create` makes it
again — and this is the near half catching up.

## The deployed branch is published

**The operator's ruling, 2026-09-10.** `just deploy` pushes `deployed` to
origin, on both paths, before anything runs the commit.

Until then the branch existed on the machine that deploys and — when the agent
runs elsewhere — in the `git init` repository on that host, and nowhere a record
can be read back from. `deploy.sh` already pushed it to the remote named `host`;
that push is the delivery, not a publication.

**Where, and why not at the end.** Immediately after the checkout is reset to
`HEAD`, which is the instant the branch moves. Origin then says what this branch
says, at every instant, including while a deploy is failing — a push at the end
would leave the two disagreeing for the length of a build, a verify and a 1.2 GB
upload, and disagreeing for good whenever one of those refused. It is also
before the switch on both paths, which is the point: the local one goes live at
`build --deployed`, the remote one at `land`, and neither should be the first
place the commit exists.

**Not fatal**, on the same reasoning as the config backup: a deploy that is
built, proved and shipped does not stop because a network did. It prints
`BRANCH_NOT_PUBLISHED` and the retry, and goes on.

**Under its own name**, and not renamed to `deployed` the way the `host` push
is. That push delivers a branch into a repository whose only job is to hold one,
so the name there is fixed; this one publishes what this machine actually has,
and `vps-deploy` on origin is the truth about a second deployed checkout where
`deployed` would be a claim about what is live. `+`, because a deploy that drops
commits moves the branch backwards and nothing else writes this ref.

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

Every `schedule` call in the deploy passes `RUNNER_IS_DEPLOYED=yes`, because
the recipe otherwise forwards to the deployed checkout, and a first deploy has
not created it yet: `--state` answers nothing and an enabled schedule is never
paused. The crontab is the user's whichever checkout reads it, so staying here
loses nothing.

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
that silence deserves a sentence. The forwarder in `host/lib/deployed.sh` wraps
it, before it sends a live command to the deployed checkout. Between two
sessions `just listen --live` shows how far the live build is behind origin
instead — see "Behind origin is asked of origin".

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

## The first match cannot close the pipe

Measured 2026-09-10, on the first deploy whose commit had already been pushed:

    error: recipe `build` failed on line 517 with exit code 141

141 is SIGPIPE. `build.sh` reads `RUNNER_PUSHED_AT` out of the reflog of
`refs/remotes/origin/main`, and its awk ended `{ print $2; exit }` — the exit
closes the pipe while `git reflog show` is still writing into it, `git` takes
SIGPIPE, and `set -o pipefail` hands 141 to a `set -e` that stops the build.

**It had never run.** The awk only exits early when it finds a match, and a
match means this checkout's HEAD is a commit that reached origin — which, until
that day, no build had ever been. Every earlier build read the reflog to the end
and produced an empty `RUNNER_PUSHED_AT`, the value that means "the image was
built where nothing goes to origin". The success path of the measurement was
written, shipped, and first executed months later, by a `git push` the operator
made by hand.

The fix is to take the first match without leaving: `&& !found { print $2; found
= 1 }`. A reflog is a few hundred lines and reading it whole costs nothing —
where stopping early costs the whole build, silently until the day it works.

**Three others had the same shape**, found the same day and changed with it:
`host/archive/ledger.sh`'s `ruling`, the two lookups in `host/archive/rule.sh`,
and the crontab marker in `host/verify/host-tools.sh`. The first three run under
`collect.sh`, which is `set -e` and `set -o pipefail` both, so each was one
oversized ledger away from stopping a collection; the fourth only loses a value
nobody checks. Measured with a writer big enough to still be writing — 200000
lines into the pipe, matched on the first: `exit` answers 141, the flag answers
0. Below 64 KB neither does, which is why the shape survives review.

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

## Each side is proved on its own interpreter

**2026-09-08.** CI ran `static-checks` twice, on 3.11 and 3.14, and the 3.11
half proved nothing the build did not: `image/Dockerfile` runs
`bash-guard.py`, `claude-usage` and `session-cost` with `--selftest` as `RUN`
steps, so `docker-build` already proves them on the interpreter they actually
run on — bookworm's 3.11.2, not a runner's 3.11.16 on another base. The matrix
is gone. `static-checks` is one job on 3.14 running the host selftests, the
hooks and `mypy`; the image's three come out of it and stay where the image is
built. `requires-python` follows what is proved and is now `>=3.14`;
`target-version = "py311"` and mypy's `python_version = "3.11"` do not move,
because they are about the syntax and the types `image/*.py` may carry.

The matrix was also hiding a failure while it was there. `fail-fast` cancelled
the 3.14 job the moment 3.11 failed, so four red runs reported one end and left
the other unknown — and the fault was in neither interpreter. `status.py`'s
selftest builds `now` from a naive `datetime` and hands `reset_text` a UTC
instant, so the reset lands on the next local day at `+02:00` and on the same
day at `UTC`: green on this host, red on every runner. The zone is pinned in
`selftest()` now. Reproduce either half with
`TZ=UTC python3 host/session/status.py --selftest`.

## Build here, run there

`RUNNER_DEPLOY_HOST` and `RUNNER_DEPLOY_DIR` in `.env` name the machine the
agent runs on when that is not the machine you work at. Empty is the single-host
installation, unchanged: `deploy` builds from the deployed checkout as it always
did, and none of the code below is reached.

Set, `just deploy` still does everything it always did here — refuse an unclean
tree, ask, reset `deployed/` to HEAD, copy `.env` and the three untracked files
into it, **build from that checkout** — and then, instead of tagging the result
live, it proves it, sends it and has the far side land it.

**The schedule that is held is the one of the machine being deployed to.**
Deploying elsewhere, that is the far one, and `land` holds it for its own work;
this machine's is left alone, because nothing live here is touched and pausing
it would stop the agent for a build, a verify and a 1.2 GB upload.

**The deployed image on the building machine is not touched.** The build there
tags the candidate, which is what it is: built from `deployed/` and about to be
proved. Only the far side's tag is flipped. What does move here is `deployed/`
and `refs/heads/deployed`, because they are the build context and the ref that
is pushed — so while an agent still runs on this machine, its schedule has to be
off before the first deploy elsewhere, or it runs new scripts beside the image
it already had.

Building from `deployed/` first is the point, and it is what the earlier
draft of this got wrong by building on the working tree and shipping what
`verify` had proved at some earlier moment. In that shape the tree can move
between the two, and the mismatch is caught by a commit comparison on the far
side — after 1.2 GB has crossed. Building in the worktree closes the window
instead of catching it: the image and `refs/heads/deployed` are the same commit
by construction, and that pair is what travels.

`verify` therefore runs inside `deploy`, on the image that will ship rather than
on a candidate built from the working tree. That is a departure from the
three-step sequence in `CLAUDE.md`, and it was ruled deliberately: a verify
before every deploy was already what happened by hand, and this one proves the
exact artifact instead of a byte-identical sibling. `just verify` typed by hand
keeps its meaning on the candidate you build while working.

## The tag flip is the deploy

Two things cross, and neither of them is live on arrival.

`refs/heads/deployed` is pushed into a repository whose HEAD is **detached** —
`land` leaves it that way — so `deployed` is never that checkout's current
branch, the push is accepted without any `receive.denyCurrentBranch` setting,
and it moves a ref and nothing else. The working tree follows later, inside the
pause. `updateInstead` was considered and dropped for exactly that: it joins the
ref arriving to the tree moving, which is the seam this needs.

The image travels as `:incoming`, because a tag goes with the image through
`docker save` and one sent under its live name would be live on arrival, ahead
of every check.

`just land` on that host is the other half, and it is a separate script rather
than a branch of `deploy` because the two mean opposite things by the same
names: here HEAD is new and `deployed` is what is live, there `deployed` is what
has just arrived and the tree is what is still live. It checks the shipped id,
the image's baked commit against the branch that arrived, and refuses a tree
somebody has edited; then pauses the schedule, moves the tree, flips the tag,
**reads back what is actually live** and only then enables the schedule again. A
failure anywhere after the pause leaves it paused and says so.

It is private in the justfile and refuses to run without `RUNNER_SHIPPED_ID`,
which only the deploying machine sets. That is what tells the far half of a
deploy from a hand on the wrong terminal.

The remote deploy is invoked with `RUNNER_DEPLOY_HOST=` emptied, because that
host's own `.env` is a copy of this one and would otherwise have it forward to
itself. The two `RUNNER_DEPLOY_*` lines are filtered out of that copy for the
same reason: they say the agent runs elsewhere, which is false there.

Rejected: a docker daemon reached over ssh, with the runner staying here. It
needs the machine you work at to be up for cron to fire at all, which is the
whole thing this arrangement exists to stop.

## The environment beats dotenv

Measured 2026-09-09 on `just 1.58.0`, because the whole split rests on it: with
`set dotenv-load := true`, an environment assignment on the command line beats
the value in `.env` — **and an empty assignment beats it too**, rather than
falling back. `env_var_or_default` sees dotenv values as well, so both halves of
the justfile agree.

Re-measure:

    printf 'PROBE=from-dotenv\n' > .env
    printf 'set dotenv-load := true\nshow:\n    @echo $PROBE\n' > justfile
    just show          # from-dotenv
    PROBE= just show   # empty

If that ever prints `from-dotenv`, `host/lib/deploy-host.sh` needs a sentinel
variable instead, and the remote deploy is forwarding to itself.

## The id and the commit answer different questions

Two checks stand where building from the deployed checkout used to stand alone,
and they are not redundant.

**The id** — what `verify` proved, against what arrived — answers *is this the
image that was tested*. The commit cannot: it is written into the image by the
build, not derived from its content, so two builds of one commit both carry it.
They differ whenever `.env` changes (`AGENT_MODEL`, the retention days and the
names are build arguments), whenever one of the three untracked
`image/config/*.txt` changes, or simply on a later rebuild — `apt-get install`
in the Dockerfile is unpinned, unlike the base image and Claude Code. `docker
load` is content-addressed, so an id that survives the trip is every byte
surviving the trip.

**The commit** — baked `AGENT_RUNNER_COMMIT` against the checkout beside it —
answers *does the code next to it match*. The id cannot: it says nothing about
what the host scripts are.

The gate reads the commit from `docker image inspect`, not by starting a
container: a session may be running on that host, and a deploy has no business
putting a second container against the volume to learn something a label
already carries. `host/verify/image-commit.sh` asks the same of a *running*
container deliberately — its question is whether the value still reaches a
session — and reports `LOOK` rather than failing, because a checkout that has
moved on since the last build is a state and not a defect. The same comparison
is a refusal in `deploy`, which is the shape `image/claude-usage.py` already
has: one fact, two readers, opposite dispositions.

## The branch follows the directory

`deploy` names the branch its deployed checkout holds after that checkout's own
directory — `basename "$RUNNER_DEPLOYED"` — rather than fixing it to `deployed`.
Measured: git refuses to check one branch out in two worktrees, so a second
deployed checkout for testing, made by pointing `RUNNER_DEPLOYED` elsewhere,
fails at `worktree add -B` with *'deployed' is already used by worktree at …*
while the real one holds it. Naming the branch after the directory makes the
second checkout a second branch, and the two stop colliding.

The far side is not named from here: `land` looks for `refs/heads/deployed` on
that host whatever this one is called, and the push spells the rename —
`+"$ref":refs/heads/deployed`.

**And that host does not derive its own name either.** Its `RUNNER_DEPLOYED` is
the checkout itself, so a basename there would give the checkout's own name —
`runner`, say — while the branch it actually holds is `deployed`. It is keyed on
`RUNNER_RUNTIME_ONLY`, which that host already carries: the machine that deploys
names the branch after its worktree, the machine that runs holds the name it was
sent. Without it the only casualty is `deploy --state` run there, which `just
status` asks for over ssh — it would find no such ref and report nothing as
live, which is a wrong answer in the shape of a right one.

A directory whose name is already a branch checked out somewhere else fails the
same way, and the message says which worktree holds it.

## The first deploy has no working tree

The checkout on that host is made with `git init`, so until something checks a
commit out its HEAD is unborn and the directory holds no files. The first push
therefore lands a ref beside nothing — and `just land`, which is what would
check the tree out, cannot run, because there is no justfile to run it from.
Measured on the first real deploy: `error: no justfile found`.

So the deploy checks the tree out once, straight after that first push, guarded
on `rev-parse --verify HEAD` failing. It is safe exactly there and nowhere else:
nothing is live on that host yet, so there is nothing for a moving tree to
surprise. Every later deploy leaves the tree alone and lets `land` move it
inside the pause it holds the schedule with, which is the whole separation.

## The runtime host is its own deployed checkout

There the checkout cron runs from IS the checkout, so `RUNNER_DEPLOYED` in the
`.env` that reaches it holds that checkout's own absolute path — written by the
deploy, which asks that account's shell to resolve it, and never carried over
from this machine, where the same name means a worktree that only exists here.

Absolute, not relative: the justfile decides `RUNNER_IS_DEPLOYED` by comparing
`justfile_directory()` with this value, and a relative one is resolved from the
project root, so it can never equal it. `no` there is not a small wrongness —
every live recipe (`run`, `chat`, `shell`, `listen`, `read`, `status`,
`collect`, `publish-status`) forwards on it, and would forward into a directory
that does not exist. With `yes` they all run in place, which is what that host
needs and what they already do: none of them needed changing.

`just schedule --relocate` writes the crontab line from the same value, so cron
there names the checkout rather than a worktree under it.

## Behind origin is asked of origin

`deploy --state` says how far the live commit is behind, and the answer is only
as good as what it is counted against. Where the agent runs on this machine,
that is the checkout `deploy` was run from. Where it runs on a host of its own,
the checkout there is the live commit itself — `land` leaves its HEAD detached
at it — so the same count is zero by construction, whatever has been pushed
since. Measured on 2026-09-11: the status snapshot read `head` and `deployed`
both `1b8aaef` with `ahead: 0`, and `just status` said "up to date with main",
while origin's `main` was three commits past it.

So on a runtime host origin is asked:
`gh api repos/<RUNNER_REPO>/compare/<live>...<default branch>` gives the count
behind, the count live and not on it, and the subjects. `deploy` writes
`RUNNER_REPO` into the `.env` it sends, because that checkout was made by
`git init` and has no origin to name. The token there is the mirror's, which
needs *Contents: Read-only* on this repository too — see
`examples/vps/README.md`, step 7.

It fails into words and never into a zero. No `RUNNER_REPO`, no `gh`, a token
that cannot read the repository, or no answer: "how far behind origin could not
be read", and why. A 404 on a repository gh has just read is a live commit
origin does not have, which is a problem of its own.

## The runtime host originates nothing

That machine holds two checkouts, as this one does: the one a push lands in, and
`deployed/` that cron reads. The gap between them is the point — a deploy that
half arrives, image sent and a gate refusing, leaves cron on the old code
because nothing moved `deployed/`. Collapsing to a single checkout there would
make the push itself change what runs, ahead of every check.

What it must not be is the **origin** of a release. `just build` refuses there:
the image is built where the code is edited, and a build on a machine sized to
run one session would produce a second image nobody proved. `just deploy`
refuses too, unless it carries `RUNNER_SHIPPED_ID` — which only the deploying
machine sets, and which is therefore what tells "the operator typed this on the
wrong terminal" from "the workshop is running its second half here".

Both read `RUNNER_RUNTIME_ONLY`, stamped into that host's `.env` by the deploy
that sends it, rewritten every time so it cannot be lost by an edit. It is a
guard against a mistake and not a boundary: anyone who can type on that machine
can edit the file it reads. The boundary is that nothing there has a credential
to push an image anywhere.

## The image crosses whole

`docker save | ssh docker load`, about 1.2 GB every deploy. `save` is not
layer-aware: `load` skips writing layers it already has, but the bytes cross
regardless. A registry would send only the changed layers — usually the `COPY`
ones, a few MB — and the trade was made deliberately for the simplicity of
having nothing between the two machines and no third party holding the image.

Progress while it crosses comes from `pv` when it is installed — the size is
known in advance, so it gets a real bar and an ETA — and from an elapsed-time
counter when it is not. **Not `dd status=progress`**: measured 2026-09-09 on
uutils coreutils 0.8.0, which is what Ubuntu 26.04 ships and what this machine
runs, the flag is *accepted and prints nothing* but the closing summary. GNU dd
prints a line a second. Re-measure with

    ( dd if=/dev/zero bs=1M count=8 2>/dev/null; sleep 3 ) | dd status=progress bs=1M of=/dev/null

which on GNU shows progress lines during the three seconds and on uutils shows
only the summary at the end. A progress flag that silently does nothing is worse
than no flag, which is why neither is used.

`host/release/ship.sh` is the only caller-facing name, so replacing its inside
with a push to a `registry:2` on that host, reached through an `ssh -L` that
dies with the command, changes nothing above it. That is the move to make if the
transfer time ever stops being worth it.
