# Sessions

## What it is, and what to do

A session is one Claude Code process, in one container, on the agent's volume.
Everything else here exists to start one, keep two from running at once, watch
one, or read one afterwards. There is nothing in `.env` to set; these are the
commands.

| command | what it does |
| --- | --- |
| `just run` | one unattended session, whole — the opening message, the session, the backup push at its end, the collection afterwards. This is what cron calls. `--listen` renders it live, `--wait` queues behind a running one, `--force` starts a second beside it, `--ignore-budget` starts one over the allowance, `--cooldown N` starts one only if the last **ended** N minutes ago |
| `just chat "…"` | a conversation you sit in. It waits for a running session rather than standing down; `--continue` resumes the last **conversation**, which is not the last session |
| `just shell` | a shell in the container, carrying the environment a session gets, without starting one. What bootstrap uses. `--build` looks inside the candidate instead |
| `just test-container` | the same container with **no volume** — an empty home every run, for rehearsing recovery. Never where the agent runs |
| `just listen` | the running session from its first line, live — or, with nothing running, the last one's tail. `--all` lifts the read ceiling, `--wait` waits for the next, `--live` never closes, `--remote` serves the live view to the tailnet |
| `just read <n\|id>` | one transcript whole, and the only reader there is. A row number from `just sessions`, or a session or subagent id. `--subagent K`, `--full` |
| `just status` | the one-screen answer: what is running and of what kind, what it has spent, whether scheduling is on, what the budget gate sees, what the collection gate is holding, and what this checkout has that is not live |

**One session at a time**, and the lock is held by whoever starts one rather
than by cron — so a `just run` typed by hand cannot walk into a scheduled
session. `run` stands down at once and exits **75**; `chat` waits instead,
showing how long that session has been up and how long you have been waiting.
The lock **cannot go stale**: `flock` holds through an open file descriptor, so
a held lock means a live process is genuinely holding it. That is why `--force`
does not remove it — it starts a **second** session beside the first, and says
so.

**Every session runs the deployed checkout and the deployed image**, whichever
directory you typed the command in: the live recipes forward into `deployed/`
and say so on the way. There is no flag that runs a session on this tree.

**What a session is told about itself** is a handful of environment variables
plus a rendered system prompt: how often it is run and when it last was, when
you last spoke to it, what the budget gate saw, whether another session is
running beside it, and — from `image/system-prompt-template.md` — the situation
it is in, pointing at its own `CLAUDE.md` for everything else. They carry
**facts and never direction**: this channel reaches the agent through a layer
it cannot read in its own repository, reply to, or send a pull request against,
so a sentence in it saying what to do would be direction down the one path
nobody reviews. `claude-session --render` prints what a session would be told,
with no session.

**What you type day to day.** Usually nothing — cron runs `just run`. When you
want to see it, `just listen`; when you want to talk to it, `just chat "…"`,
which goes in prefixed with a marker saying a *person* wrote it, the one
channel the agent's own rules treat as direction. Afterwards, `just read 1`.

**Two distinctions worth knowing before they surprise you.** `chat --continue`
resumes the last conversation and not the last session — usually the hourly
unattended run — which is possible only because `chat` decides each
conversation's session id itself and writes it down. And **every time you read
is local; every time the agent is given is UTC**: the container runs `TZ=UTC`
and the archive files a session under its UTC day, while what reaches your
screen is converted to the clock in the room. Display only — nothing written
down moves.

## How it is built

A session is one Claude Code process in one container on the agent's volume.
`just run` starts an unattended one — what cron runs — and `just chat` an
interactive one the operator sits in; `just shell` opens a shell in the same
world without starting a session, `just listen` watches one live, `just read`
opens a finished transcript and `just status` says what is happening. Their
implementations are `host/session/*`; the pieces they share are
`host/lib/session-lock.sh` (the lock and everything that answers "is a session
running"), `host/lib/deployed.sh` (forwarding to the deployed checkout),
`host/lib/root.sh` (the working directory) and `host/lib/docker-up.sh` (the
daemon check). What a session is told at launch is
`image/system-prompt-template.md`, rendered by `image/claude-session.py`.
What a session cost is `host/session/session-stats.py` on the host and
`image/session-cost.py` in the image.

## One session at a time

The hourly unattended run and a conversation the operator starts both drive
the same container against the same volume, and two at once means two Claude
Code sessions writing one checkout and one transcript directory.

`just schedule` used to wrap cron's invocation in `flock`, which covered the
scheduled side only — a `just run` typed by hand walked straight into a
running session. The lock lives in `host/lib/session-lock.sh` now, so it binds
whoever starts a session and not merely whoever cron starts.

It is SOURCED rather than executed, and that is load-bearing: the lock lives
on an open file descriptor and a descriptor belongs to the process that opened
it. A child could take the lock but would release it the moment it exited,
which is the opposite of what is wanted.

Descriptor 9 is written plainly rather than held in a variable: `exec` cannot
take the number from one without an `eval`, and an `eval` around the one line
that establishes the boundary is not worth the flexibility.

`RUNNER_LOCK` is required, never defaulted. A shared fallback would be two
agents on one lock — and worse, one agent whose recipes lock
`/tmp/<name>-session.lock` while a script that missed the export locks the
fallback: two locks, neither excluding the other, and nothing to see.

## There is no stale lock

Worth knowing before reaching for `--force`. `flock` holds on the inode
through an open descriptor, so the kernel releases it when the holder exits —
crash, `kill -9`, power cut, all the same. Measured: a shell that acquires and
dies leaves the lock free. A lock that is held therefore means a process is
*alive* holding it.

Deleting the lock file would be worse than useless: `flock` keys on the inode,
so a new file of the same name is a different lock, and two processes would
each hold "the" lock and neither would know.

Nor does a forced run break the lock on its way out. Its own `exec 9>` is a
second open file description on the same inode; the lock lives on the
description, and that one never acquired anything, so closing it releases
nothing. Measured: holder still locked after a forced run exited, a third
process still refused. `fork` and `dup` are the exception — they copy the
reference, not the description, which is why an inherited fd 9 keeps the lock
alive.

So `--force` does not steal the lock. It runs a second session alongside the
first, and that second session holds nothing. What it is really for is the
case the schedule already names: a session that hangs holds the lock for as
long as it hangs.

## The lock records attempts, not outcomes

The lock cannot say when a session last FINISHED and never could: `lock_open`
opens the file before `lock_try` decides, so a run refused because a session
was already running stamps it just the same. Measured. During the one stretch
you would ask about — an hourly cron behind a long session — the lock file
therefore looks freshly touched precisely because nothing is running.

So a session records its own end, and only its end, in
`RUNNER_LAST_SESSION_ENDED_AT` under `~/.cache/<agent>` rather than beside the
lock in `/tmp`: this record has to survive a reboot to mean anything, and a
cooldown that forgets is a cooldown that lets a session start immediately
after every restart. `--cooldown` on `just run` reads it.

No record reads as "long ago", because the first run after an install or a
reboot has to be allowed to happen. A record in the FUTURE means the clock
moved, and the answer there is to run and say so rather than to wait: waiting
would stall every session until real time caught up, and a stall is the
failure this repository is built to avoid. Running once costs nothing the lock
does not already cover.

`session_ended_at` renders the same moment as an ISO-8601 UTC instant for the
container to be told. It lives beside the writer rather than beside its reader
because this file is the one place that knows the format of that record: two
readers of it is one that goes on parsing the old shape after the writer
changes. There a future record means "say nothing" instead of "run now" — both
readings decline to pretend.

## The wedge alarm, and its threshold

A session that hangs is the one failure nothing else reports. It never reaches
the end of `host/session/run.sh`, so it never exits and never trips the exit
trap; every wake-up afterwards lands at the lock and exits 75 in silence,
which is exactly what a healthy cooldown looks like.

The threshold is measured rather than guessed: of 289 completed sessions
recorded on the archive's status branch, the 90th percentile is 16 minutes and
the longest ever was 54. The long ones are all just before midnight, where the
agent waits out a `sleep` for the date to turn, and that is legitimate. Two
hours is more than twice anything that has ever finished, so
`RUNNER_WEDGE_MINUTES` defaults to 120.

Unattended sessions only. A conversation legitimately runs for hours — 157
minutes, measured 2026-08-26 — and the operator is sitting in it.

An explicit `0` turns the alarm off, which is somebody's decision. Anything
else that is not a number is a typo, and a typo must not silently disable the
only report a wedge ever produces — so a non-numeric value falls back to the
default rather than to off. The notification stamp is written BEFORE the alert
rather than after, so a notifier that hangs cannot become a toast a minute for
as long as the wedge lasts.

## Waiting for the lock

`lock_wait` redraws a line while it waits, but only when someone is watching.
`just run --wait` from cron writes to a log, and a redrawn line there is a file
full of carriage returns — so without a terminal it says one sentence and
blocks on `flock` instead of polling, which is also cheaper. It asks docker
every fifth pass only: the clock is arithmetic and costs nothing, `docker
inspect` is a process each time.

The `INT` trap sits AHEAD of that split, so giving up reads the same whether
or not anyone is watching. Without it there, the blocking branch died on
Ctrl-C with a bare failure — measured, because the first harness for this gave
stdout a pipe and every case took that branch unnoticed.

`run` refuses by default and exits 75, because that is what cron has always
read as "skipped an hour" rather than "the session failed". Refusing is the
default precisely because cron is the usual caller: an hour that queued behind
a long session would still be running when the next hour came round. `chat`
waits instead — a conversation is a thing the operator wants to happen, not a
job to skip.

`--force` on `run` asks first, and no terminal means no forcing: a `--force`
wired into a script would quietly become the normal path and the lock would be
decoration. `--force --continue` on `chat` is refused outright — it would
resume the conversation that is running, so two claude processes would append
one transcript, and a running chat IS the last chat, so there is no case where
that refusal is wrong.

`--force` and `--ignore-budget` are separate flags on `run` because they
answer different refusals — one starts a session beside a running one, the
other starts a session the account cannot afford — and a single flag meaning
both would override the one you were not thinking about. `--wait` and
`--force` contradict each other and are refused together. The `parallel`
variable is set only where the lock was actually held and stepped past, since
`--force` on a free lock starts nothing in parallel and must not claim to.

## Naming a session's container

The name is the whole mechanism, because compose's own is useless here: it
calls every one-off container `<project>-<service>-run-<hash>`, whatever
command it was given. So `just shell`, both `just verify` probes — which run
`claude -p` and would even be reported as unattended sessions — and any
`docker compose run` typed by hand all wore the name a session wears. Measured,
reported as `just status` announcing a session while a shell was open.

`RUNNER_SESSION_NAME` fixed it, and `$$` is added by the caller so two sessions
under `--force` do not collide. `just listen` had already named its own
container for exactly this reason, from the other side. Everything that asks
whether a session is running filters on that name; `session_id` exists as its
own function because three things ask for it and the filter is the one string
they must all spell the same — a typo in a copy of it does not fail, it answers
"nothing is running".

`session_kind` tells headless from interactive by reading element 1 of the
container's `Cmd` EXACTLY, not by searching the whole command line: the message
`chat` passes is the operator's own prose and could contain anything, `-p`
included. It is read from the container rather than inferred from which recipe
is running, because by the time anyone asks, no recipe is — cron started it an
hour ago. `session_started` is read from docker for the same reason, so the age
shown is the session's and not the age of our waiting.

`service_container` names anything else compose is running on the service — a
shell, a verify probe, a container someone started by hand. None of them takes
the lock, but "nothing is running" while you are sitting in a container is the
answer that sent someone looking for a bug.

## Which conversation `--continue` resumes

`claude --continue` inside the container resumes the most RECENT session in the
checkout, and most of the time that is the hourly unattended run — so the
obvious spelling resumes the wrong conversation, and does it silently: what it
opens looks exactly like what was meant until someone reads it.

So `just chat` decides the session id itself, out of the container, passes it
as `--session-id`, and writes it to `RUNNER_LAST_CHAT_ID`; `--continue` asks
for that one by name and nothing else. It uses `python3` rather than
`uuidgen`, which is not among the tools `just verify` says this repository
needs — `python3` is, and one required tool doing a second job is cheaper than
a new line in that table.

The id is recorded when the session STARTS and not when it ends: a conversation
that died in its first minute is one worth resuming, and a record written at
the end would not exist for it. It is written where the session is launched
rather than where the id was chosen, because everything above that line can
still end in a refusal or a Ctrl-C at the lock.

`last_chat` shape-checks the value rather than trusting it: it is handed to
claude as the session to resume, and a truncated write, an empty file or
something edited by hand has to read as "no record" — which starts a fresh
conversation and says so — rather than as an id that resumes nothing and fails
in claude's words instead of ours.

`RUNNER_LAST_CHAT_ENDED_AT` is a second, different fact, written at the END of
a conversation: the moment the operator last spoke, told to the next session so
it can tell silence from inactivity.

## Reading the volume for a conversation

`host/session/last-chat.sh` is the fallback under that record. The cache is a
shortcut; the volume is the truth. The record is the exact answer — an id
`chat` chose itself, with nothing to infer — but it only knows about
conversations started since it began being written. Every chat before that, and
every chat on a machine whose cache has been cleared, is still sitting in the
volume where the record cannot see it, and refusing to continue a conversation
that plainly exists is the worse answer.

How a conversation is told from a session: `just chat` puts a bracket in front
of the operator's message saying the words are theirs and not the runner's —
the line rule 1 rests on — and the unattended prompt says the opposite of it,
in the opposite order. So the bracket is the marker, and it is passed in rather
than written in the script: one definition in the justfile, used by the recipe
that writes it and by the one that reads it.

The `grep` NARROWS and does not decide. A transcript quoting the marker in some
later message would be picked by it, and continuing an unattended run because a
sentence in it looked like the operator is precisely the silent wrongness
`--continue` exists to avoid. So each candidate's FIRST user message is parsed
and checked, newest first, and the first that really begins with the operator
speaking wins. A first user line that will not parse is skipped rather than
guessed at: skipping costs one resume, guessing costs the wrong one.

Ordered by mtime, not by the first message's timestamp: what is wanted is the
conversation last spoken in, and a resumed old chat is the most recent one
again.

It runs through a throwaway container, read-only, the same shape as
`host/archive/read-volume.sh` and for the same reason — see
docs/archive.md. One container, one pass, root inside because the transcripts
are 0600 owned by uid 1001; nothing is written anywhere.

## Always the deployed checkout

The operator's ruling, 2026-08-28: from this repository, `just chat` is talking
to the agent and `just listen` is listening to it, and both must act in the
deployed environment by default — its recipes, its scripts, its `.env`, its
image. The working tree is where changes are made and tested, and a live
command that ran the working tree would make every edit live before any deploy,
which is the hole `just deploy` closes. Testing is what runs in the working
tree: `verify`, `test-env`, and `just shell --build`.

`host/lib/deployed.sh` is sourced by the scripts that are the live runner:
run, chat, shell, listen, read, status, collect, publish-status.

WHAT WAS TYPED CANNOT BE FORWARDED. `just` parses the declared flags itself and
hands the script their values, so the argv is gone by the time anything here
runs; each caller rebuilds the flags it is on, in the spelling the deployed
recipe parses, into the `typed` array. `typed_flag` is the whole of that
rebuild for one flag, since `yes`/`no` is what every declared flag in the
justfile carries. `chat` rebuilds by hand because `just` handed it its flags
and its message as one variadic list; `listen` rebuilds only one of `--live`
and `--wait`, since `--live` is the stronger of the two and implies the wait.

## How loudly the forwarder speaks

The operator's ruling, 2026-08-30. The question is worth asking only where
answering `n` saves something: `run`, `chat` and `shell` start a session,
`collect` and `publish-status` write to the archive, and stopping there means
deploying first and typing it again. `listen` and `read` only look, so `n` does
nothing an interrupt would not — they are told, not asked. And `status` is told
nothing at all: it reports the same fact three lines later, in full, with the
subjects. An unrecognised verb asks, because the recipe that has not been
thought about is the one to be careful with.

The heads-up when this tree is not what is deployed is the operator's idea,
2026-08-28: a person typing `just chat` here while sitting on undeployed
commits may have forgotten to deploy, or may mean exactly this — so it asks,
and Enter means go on. Not a gate: with no terminal to ask on it says so and
continues, because a scripted `just listen` must not hang on a question. The
deployed checkout itself never gets there, so cron is never asked.

The phrase comes from `host/release/undeployed.sh`, which `just listen --live`
also prints between sessions: one spelling of what is not live, wrapped in the
question in one place and in a note in the other.

## The checkout is not always the project root

`host/lib/root.sh` is sourced on the first line of every script under `host/`.
It resolves its OWN location rather than the caller's, so a script may sit at
any depth under `host/` and still get the same answer, and it cds there: `just`
already runs a recipe from the justfile's directory, but a script run by hand
from somewhere else must not read a different tree than the one it belongs to.

The deployed checkout is a worktree at `deployed/` inside the project, with its
own copy of this tree. `RUNNER_ROOT` — exported by the justfile — is the
project ABOVE it, and is what `AGENT_ARCHIVE` and `RUNNER_DEPLOYED` are derived
from. `RUNNER_CHECKOUT` is the other one: the files this script was shipped
beside. `just listen --live` uses `RUNNER_ROOT` deliberately when it asks what
is still undeployed, because the tree that would be deployed is not the one the
forwarded script is running in.

## The build flag left run and chat

The operator's ruling, 2026-09-02. `--build` built the candidate and ran a
session on it, for that invocation only. It was what this repository was driven
with while there was nothing deployed to run instead, and once there was, an
unattended session on an unproven image is a risk taken for nothing. `just
shell --build` is what looks inside a candidate now, and `just verify` is what
proves it — see docs/verify.md.

`chat` keeps a named refusal for `--build`, and that is not politeness. Its
flag loop stops at the first non-flag and keeps the rest verbatim, deliberately,
so that a message may begin with a dash. A flag removed without a case there is
therefore not an error but a conversation seeded with its own spelling: exactly
that happened on 2026-09-02, minutes after `--build` was taken out, and it
opened a session on the operator's account.

## The docker daemon, and a missing image

`host/lib/docker-up.sh` runs as a command rather than being sourced — there is
no state to share, and a command works the same in a shebang recipe and a plain
one. It is called by the recipes that need docker and by
`host/archive/collect.sh`.

The daemon on this machine comes and goes: it is stopped by hand to free
resources. Without a check, every recipe reports that absence as whatever its
own first docker call happens to say, and one of them says something false —
the collection probes the volume first, so a stopped daemon arrived
as `No docker volume named 'agent-home'`, which reads as a lost volume rather
than a stopped service. That is the worst possible wording for the one thing in
this system that must never be assumed lost.

It matters most from cron, where nobody reads the failure as it happens: an
hourly session that cannot start should say so in one line the log can be
grepped for, not in a stack of compose diagnostics.

`docker version` rather than `docker info`: both ask the server, and it is
measured at ~22ms against ~130ms. On a check that runs before every recipe, the
cheaper one is the honest default.

`--image NAME` additionally requires that image to exist locally. It is opt-in,
because `build` runs before there is one and `collect` reads the volume through
alpine. The recipes that start a container on compose's default pass the tag
that would run, since a missing tag otherwise surfaces as compose trying to
pull `agent:deployed` from Docker Hub and being refused — which reads as a
credential problem, not as "nothing was deployed yet".

Exit 69 is `EX_UNAVAILABLE`, chosen to sit beside the two this repository
already uses: 75 for an hour skipped because a session held the lock, and 78
for bootstrap regressed. Three causes, three codes, so a runner can tell them
apart without parsing text.

## What a session is told

Claude Code's default system prompt describes an interactive coding assistant
helping a user at a terminal. The agent is neither, so `image/claude-session.py`
renders `image/system-prompt-template.md` and passes it as
`--system-prompt-file`.

Measured 2026-08-27: `--system-prompt` replaces exactly block [2] of three,
with the billing header and the one-line SDK identity still sent, and `tools`
and `messages` untouched — which is where CLAUDE.md actually travels. So the
replacement describes the situation a session is in and points at CLAUDE.md and
SELF.md for everything else. It never says what to do now: that is the opening
message's job, and it names its sender.

The template is a boundary in all but name. It is not enforcement, but it is
the one thing that speaks to the agent every session through a layer it cannot
read in its own repository, reply to, or send a pull request against. It lives
in the image for that reason — the agent may read it, never write it — and a
change to it is reviewed the way `image/managed-settings.json` is; see
docs/boundary.md.

Placeholders carry values this script MEASURES, never sentences it decides. A
placeholder that resolved to "focus on X today" would be direction arriving
outside the trusted channel, in the one layer nobody reviews. Everything the
renderer fills in is checkable against a command.

A placeholder that survives is a refusal to start. From inside the session a
literal `{{NOW}}` is invisible — nothing checks the prompt but the model, and
the model does not know what it should have said. So the script exits before
exec'ing claude, naming what it could not fill, and `just verify` renders in
the test twin to prove none survive. `--render` exists for that probe and for
reading what a session would be told; it starts nothing and needs no
credential.

`_prefix()` builds the variable names from `getpass.getuser()` rather than
writing them out: what is genuinely the agent's is named for it, the
container's account IS the agent, so nothing has to be passed in to say who
this is. A dash cannot appear in a shell name.

## One renderer, two templates

`image/claude-session.py` takes `--template PATH` and fills only the
placeholders that template actually contains. The container's sessions pass
none and get the image's own; `just drift-audit` passes the auditor's, which
asks for a subset and for none of the image's own labels — there is no image to
read a version out of on the host, and asking anyway would spend the read to
print "(unreadable)" in a line nobody wrote.
The values are held as callables for that reason, with the three measurements
that answer two placeholders each cached, so both halves still cost one `git`
and one `claude --version`.

Which settings file the model and retention lines name is read out of the
arguments rather than assumed: `--settings PATH` when there is one, since that
is the file that will govern the session about to start, and
`/etc/claude-code/managed-settings.json` otherwise. It is read and not
consumed — the flag is claude's own and still has to reach it.

`{{AGENT_NAME}}` and `{{OPERATOR_NAME}}` exist for the auditor's template,
which has to name the agent it is reading and the operator whose corpus quotes
them. They are read from the environment `just` exports, and a template that
asks for one the environment does not carry is a refusal to start rather than a
sentence with a hole in it — the same failure an unfilled placeholder is, and
as invisible from inside the session.

Until 2026-09-02 the drift audit had its own copy of this script, in the
`monitoring` repository. It had already drifted: fewer placeholders, relative
paths, `datetime.timezone` where this one had moved to `datetime.UTC`. A second
renderer is a second thing to keep true about what a session is told, and this
one is reviewed like the boundary. It was deleted when the monitor was folded
in; see docs/monitor.md.

## Three lines that are read, not measured

`{{MODEL_SETTING}}` is the `model` key of `/etc/claude-code/managed-settings.json`,
read at launch and never a constant in the template. It is what was ASKED FOR.
What answers is decided later by the CLI, and the two diverged for two days in
August 2026 under a setting that asked for Opus — found by reading the default
prompt's own "you are powered by" line, which is written after resolution and
which this prompt cannot carry. So the line says "requested", never "you are",
and the served model is read from the transcript afterwards by
`host/session/session-stats.py`, every time the cost is.

`{{CLAUDE_VERSION_INTENDED}}` is `<PREFIX>_CLAUDE_VERSION`, baked into the
image from the Dockerfile's `ARG` at build: what the image was built to
install, which is not the same claim as what runs.
`{{CLAUDE_VERSION_RUNNING}}` is `claude --version` resolved THROUGH PATH — the
binary this script then execs, not the pinned path. Asked by absolute path it
would report the pin back to itself and agree with the `ARG` forever, which is
the failure wearing the probe's own clothes. The two can differ without
anything being broken elsewhere: PATH puts `~/.npm-global/bin` and
`~/.local/bin`, both volume-backed, ahead of `/usr/local/bin`, so a `claude`
installed by hand or by the CLI's own updater wins the lookup and outlives
every rebuild.

Neither half refuses. The operator's ruling of 2026-08-28: a mismatch is
reported and never fatal. Refusing would stand down every scheduled session
until someone intervened — and the session it stood down is the one that could
have opened the issue about it. The mismatch note appended to the running line
is a comparison of two measured strings, not a judgement about it: what to do
next is CLAUDE.md's to say, not the header's.

`{{RUNNER_COMMIT}}` and `{{RUNNER_COMMITTED_AT}}` are the commit of the runner
checkout this image was built from, and when that commit was made. They are
measured on the host by `just build` in the checkout it is building and baked
in: the build context is `image/` and carries no `.git`, so nothing inside a
build could read it. They exist so a session can name its own version without
comparing anything: until 2026-09-02 the image recorded no commit at all, and a
30-hour-old image looked deployed because nothing could say otherwise. See
docs/release.md.

An unreadable or absent value says so in words — "(the image does not say)",
"none", "(unreadable)" — for one reason repeated everywhere: a blank would read
as agreement, and a session told nothing about its version cannot tell that
from being told there is nothing to tell. Nothing refuses over a missing label
either; an image that predates a field is an image, and standing a session down
would cost the session that could have reported it.

`{{CLAUDE_VERSION_RUNNING}}` also declines a first word that does not look like
a version: `claude --version` prints `2.1.238 (Claude Code)` today, and a CLI
that started printing something else must not have its first word silently
adopted as one.

## Retention is read from the file that decides it

`{{TRANSCRIPT_RETENTION}}` is `cleanupPeriodDays`, read back out of managed
settings rather than passed in. The number reaches the image as a build
argument and is rendered into that file; a second copy in the environment would
be a second thing to keep true, and the day the two parted this line would
report a retention that is not the one in force — with no symptom, since the
only witness is a file quietly still there or quietly gone.

## Telling a session it is not alone

`{{CONCURRENCY}}` is empty unless `<PREFIX>_OTHER_SESSION_STARTED_AT` is set,
which `run --force` and `chat --force` do when they start a session beside a
running one. Then the block names the measured instant and explains that the
two are separate containers with one volume mounted: the working tree can
change between two of the session's own commands, `git status` can be stale as
it is read, `.git/index.lock` can be held by the other session, and both sets
of commits land in one history. It is a snapshot taken at launch and never
updated.

It used to be the opening message's job. It moved into the system prompt
because it is a fact about where the session is, and because in `chat` it
landed in front of the sender line — which is the line rule 1 rests on being
first.

## The opening message names its sender

`run` starts the session with `-p`, deliberately. Nobody is there, so an
interactive session would orient itself and then sit at a prompt forever: the
container never exits, `SessionEnd` never fires, nothing is backed up or
collected — see docs/backup.md. A session no one is in must finish by itself.

The opening message says plainly that it is not the operator. It arrives
through the same channel their messages do, and that channel is the one the
agent treats as direction — so a start prompt that did not identify itself
would read as them. The sender comes first because rule 1 rests on it.

`chat` is not `-p`: that mode ends after one turn whoever is on the other side,
so a conversation cannot happen in it. Its bracket goes ahead of the operator's
greeting — the operator is present and could have said it themselves, but they
did not; the runner did, and the line between the two is the thing rule 1 rests
on. The greeting is for a conversation that is beginning: resuming one is not
that, and re-introducing themselves into a thread already underway would read
as the operator having forgotten it. The bracket stays in both.
`${message+"$message"}` rather than `"$message"`, because an empty message is a
`--continue` with nothing to say and passing `""` would hand claude an empty
first turn instead of none at all.

## Where the budget verdict is read, and where it is not

One reading serves both what the session is told about its own cadence and what
the gate sees: `host/lib/session-env.sh` — see docs/budget.md.

`run` enforces it, after the lock and the cooldown so a wake-up that stands
down on either never pays for it, and before `--listen` and before the start
timestamp so a run refused there has started no viewer and stamped nothing. It
exits 75 whichever way it went, because both are an hour that started no
session. Over budget is routine and says so only on a terminal, exactly as the
cooldown does; a gate that could not tell is not routine and has already
written its one line to stderr, which is where cron finds it.

`chat` and `shell` read the verdict and deliberately do not enforce it: a
conversation is the operator spending their own quota on purpose, and a gate
that refused them would be protecting them from themselves. The numbers still
reach the session, and the call still renews the container's access token on
the days nothing is scheduled.

`shell` builds the same environment for a different reason: a session started
BY HAND from that shell is a session, and it should not see a different world
than one started for it. That is not hypothetical — running `claude` in there
goes around the budget guard exactly as `--ignore-budget` does, and a session
that can read where it stands is better placed than one left to infer it. No
collection follows a shell: it produces no transcript.

## The cooldown, and the page's heartbeat

`--cooldown` is checked before the build and before the daemon probe, because
it is the one check that is pure arithmetic on this side: with
`* * * * * just run --cooldown 15` in cron, most invocations are this and
nothing else, and they should cost a file read. It is silent when nothing is
watching — a skipped minute that announces itself writes 1440 lines a day into
a log nothing rotates, and a log that is all skips is one nobody reads on the
day it holds something.

`host/archive/publish-status.sh` is called immediately after, and that
placement is the point: everything below it can exit — a cooldown minute
returns above, a dead daemon exits 69, a held lock stands down at 75 — and
those are exactly the states worth seeing from a phone. Its own floor makes all
but one call in ten cost a file read, so it is affordable on `* * * * *`, and
it is why `just run` is the thing that publishes rather than a second crontab
line: one schedule to reason about, not two. See docs/archive.md.

## What wakes the operator

Nobody is in an unattended run, so a failure that only reaches the log is a
failure nobody hears about — that log is 1440 lines a day of skipped minutes
and is read on no other day. `host/schedule/notify.sh` is silent on a terminal,
so a run typed by hand is unchanged. See docs/schedule.md.

0 is a session that worked. 2 is a usage error, which only a terminal can
produce. 75 is the routine stand-down — cooldown, held lock, over budget —
dozens of times a day, and toasting it would teach anyone to dismiss the toast
without reading it. Everything else is worth being pulled away for: 69 is a
docker daemon that did not answer, 78 is bootstrap regressed, and the rest is
whatever the session itself exited.

## The bookkeeping after a session

The session's end is recorded before the archiving, because what `--cooldown`
counts from is the session ending. It is recorded whatever the status, because
a session that failed still ran. A conversation additionally records when the
operator last spoke, which is a second fact.

`just collect --push`, not a bare collect: a commit that only ever lands in the
local archive checkout is a second copy on the same disk as the volume it
copies, which is not a backup. The review gate has already taken the
credential-shaped transcripts out of that commit — they stay in the volume and
are offered again next time — so what goes to origin is exactly what was never
at risk. The mirror is asked for immediately afterwards because the memory has
just been pushed and GitHub keeps its schedule badly; a mirror that was not
dispatched costs an hour of fidelity, not a run that went wrong. See
docs/archive.md.

The status page is republished with `--force`, skipping its floor: a session
has just ended, and the page saying one is running ten minutes after it stopped
is the staleness anybody would actually notice. It comes after the collection,
so the count of transcripts held back for review is this session's rather than
the one before.

The summary is last, after the archiving it describes: it is the line worth
having in the eye when the run ends, and collect's output would push it up the
screen. It is never allowed to reach the exit status — a summary that could not
be produced is not a session that failed. The start timestamp it takes is
stamped before the session, because the summary takes the newest transcript in
the volume: a container that died during bootstrap writes none, leaves the
PREVIOUS session's as the newest, and its numbers would be printed as this
run's own.

## Watching a session live

Whether `just listen` FOLLOWS is not a flag. A session that is running is one
you want whole and live — from its first line, then onwards as it is written. A
session that has finished is a file that will never grow again, and its tail is
the whole of what there is to see. The answer is always visible from the host,
one `docker ps` away. So a running session comes first whatever was asked for,
and the flags only say what happens when there is none: `--wait` waits, the
plain form reads the last session's tail, `--live` waits again when the session
it watched ends.

`seen` and `began` are settled before the watch loop rather than inside it, and
that is not tidiness: the loop only asks docker every five seconds, so a
session that ended inside those first seconds would never be seen at all, and a
follow that never saw one never closes itself.

The transcript is read out of the volume, which is written as the session runs
and is the same file `just collect` archives afterwards. Nothing is added to
the session to make this work, so it costs the session nothing and cannot
perturb it. It is read as the agent rather than as root: the transcripts are
0600 owned by that uid, so this needs no privilege — and a root container is the
one that leaves root-owned files behind. `--entrypoint` overrides the
bootstrap, so no session starts and nothing is cloned.

Following waits for a transcript at least as new as a floor, because the file
that is newest right now may be the previous session's — always for `--wait`,
which `just run --listen` starts before the session does, and for the few
seconds a running session has been up without having written yet. The `+1`
second on that floor is the whole guard: a transcript that ended inside the
current second would otherwise pass "newer than now" and be tailed forever. The
wait runs in the container because that is where the volume is; the floor is
decided on the host, where docker can be asked. It is rebuilt once per session
rather than once per run, since `--live` follows more than once and the floor
moves with every session.

## The 4000-line ceiling

It is a ceiling on the FILE, not on the count asked for, and it used to be
silent: `just listen 20000` rendered whatever messages happened to live in the
last 4000 lines and looked exactly like a complete transcript. It stays as the
default path's guard against reading a session-long file to print twenty
messages, and now says so when it bites. `--all` removes it, and the message
count with it — `cat` and not a very large N, because a number there is the
same lie the 4000 was, one layer up.

The count is in messages, not lines, so the selection happens before the
rendering: a rendered message is many lines. `cond` is one definition of what
counts as a message, because two things have to agree about it — the count
`just listen N` takes, and what the renderer prints.

## Stopping a follow without leaving anything behind

`set -m` puts the pipeline in a process group of its own, which is what makes
one kill end both halves of it — and keeps `just` out of the blast radius,
since it shares the script's group and a signal reaching it prints an error
whatever the recipe then does. The same isolation means Ctrl-C no longer
reaches the pipeline from the terminal, so the trap has to end it explicitly.
`</dev/null` is what makes `q` reachable at all: `compose run` attaches stdin
even with `-T`, so without it compose swallows the keypress and the read loop
waits forever on a terminal something else is already draining.

`--name`, because ending the client does not end the container. `compose run`
leaves it RUNNING when its client dies, so every stop used to leave a `tail -F`
up in the background — invisible unless you look at `docker ps`. A name is the
only handle the stop can use, and `$$` keeps two follows from colliding.

`INT` and not `TERM`. On `TERM` compose exits in about 100ms and abandons the
removal `--rm` promised, leaving a container behind every time; on `INT` it
stops the container and removes it. Measured.

The stop removes the container FIRST — that is what actually ends the follow,
and it makes the client exit and jq read EOF on its own. The signal after it is
not a second cure for the same ailment: it is what ends a client whose
container never started, where there is nothing to remove. Then it waits for
the group to actually go, by polling rather than by `wait`, because in the
piped path the trap interrupts a `wait` that is already running and a second
one returns at once — measured, one orphaned container per Ctrl-C. An empty
process group is the honest signal whichever path got there. The second
`docker rm -f` is not superstition: if the stop lands while compose is still
creating the container it finds nothing and the container turns up a moment
later, outliving the client that asked for it. Seen once in a batch of runs
under load, never in six deliberate ones.

`stopped` is the difference between "the user asked" and "it fell over".
Without it a compose that cannot start would look exactly like a clean quit,
which is the failure this repository is built against, in miniature.

The `INT` trap sits ahead of both branches on purpose: interrupting a long
render is the same act as interrupting a follow. Ctrl-C is how this is meant to
end, so it must not come back as a failure — a non-interactive bash takes
SIGINT's default action and dies with 130, which `just` then reports as a
failed recipe, and the status check that would normalise it never runs because
the shell is already gone. The trap is the only thing that makes stopping
ordinary.

## When a follow ends

A follow does not end when the session does: `tail -F` holds a file that has
simply stopped growing, and nothing in the transcript marks the end — a session
writes its last message and exits. The container going away is the end, and it
is visible only from outside. Only after one has been SEEN, which is the whole
guard for `--wait`: it starts before the session exists, and a viewer that
closed on "no container" would close the instant it opened.

The loop asks docker every tenth pass — five seconds — as `lock_wait` does it:
the arithmetic is free and `docker ps` is a process each time. That interval is
also how late the close can be, which is why it is not a minute. There is no
keyboard when stdin is not a terminal (`just listen > log`, or
`just run --listen`), but the wait still has to happen or the poll spins; `-t`
so the loop keeps its own time rather than blocking on a key that may never
come, `-s` so the keypress is not echoed into the transcript being rendered.

Two seconds pass before the viewer is stopped, and `just run --listen` waits
the same two before stopping its own: the closing message is written
immediately before the session exits, and killing the tail in the same instant
loses the end of what you asked to watch.

`--live` parts from `--wait` here. The end of a session is a shell prompt for
one and the beginning of the wait for the next for the other — nobody watching
a run of sessions wants to type the command again between them. Anything but a
session that ended leaves: a compose that would not start, or a `q`, is not a
thing to sit through twice. In the gap it prints what is still not live, then
moves the floor to the next session and never the one just watched, whose
transcript is newer than the floor that pass used: a loop that kept the old
floor would follow that same file again and wait for an end that has already
happened.

## The viewer `run --listen` starts

`--listen` renders the transcript as the session writes it. `just listen` does
that already, so `run` starts one rather than growing a second copy of the
renderer — with `--wait`, which waits for a transcript newer than that moment,
since the newest one right then belongs to the previous session and would never
grow again.

`--force` is the one case this gets wrong, since 2026-09-02: `--wait` now shows
a session that is already running in preference to waiting, and under `--force`
there is one — so the viewer follows the session this run starts BESIDE, and
closes when that one ends rather than when ours does. Only the view is wrong.

It is a job in its own process group, so stopping it at the end signals the
viewer and not the shell. `--quiet`, because stopping it means SIGINT and
`just` prints its own interrupt line over the last of the transcript otherwise.
`</dev/null` for two reasons at once: a background process that reads the
terminal is stopped by SIGTTIN, and it is also what tells `listen` there is no
keyboard to offer `q` on. The session's own output is held back while a view is
up, and printed after all if it failed — which is the case where it is the only
place the reason appears.

## The live view from another device

`just listen --remote` shows the same live transcript on any device on the
tailnet — a phone, a tablet, the laptop in the other room — that
`just listen --live` shows here. It puts a web terminal in front of that recipe
and a tailnet address in front of the web terminal, prints the URL, and holds
the window: `http://100.x.y.z:7681`, opened in that device's browser.

Nothing to set. `RUNNER_REMOTE_PORT` moves the port off 7681 if something else
on this machine wants it. `ttyd`, `tailscale` and `tailscaled` must be
installed — `~/.dotfiles` puts the last two in `~/.local/bin` — and the first
run asks Tailscale for a login, once: the node's key is kept in
`${XDG_STATE_HOME:-~/.local/state}/tailscaled`, so every run after it is the
same machine in the admin console rather than a new one.

**Both halves live in this window and are taken down with it**, which is the
machine's own rule and not a nicety. `tailscaled` runs in userspace networking
mode — no tun device, no root, no system service, and nothing registered to
come back — and that mode is also what makes the port reachable: an inbound
connection to the tailnet address is proxied to the same port on `127.0.0.1`,
which is the only address the web terminal is bound to. So the LAN cannot see
it, and stopping the stream takes this machine off the tailnet with it — see
**Ctrl-C is the stop** below for what that turns on. The cost is the other side of
the same coin: the stream cannot be started FROM the device that watches it. It
has to be left running before you go, which is what `--live` is for — it waits
for the next session, so leaving it up before a scheduled one is the workflow.

`host/session/remote.sh` is the transport and nothing else. `--remote` is caught
in `listen.sh` ahead of the forwarding to the deployed checkout, so the follow
is a plain `just listen --live` that forwards, locks, renders and stops exactly
as a typed one does. The flag reaches nothing below that line.

**The follow runs in the window and is tee'd to a file; ttyd serves `tail -F`
of that file.** Not the recipe itself, which was the first shape and was worse
in three ways at once: the window showed a web server's log instead of the
transcript, every viewer started a follow and a container of its own, and a
phone going to sleep killed one. Now the window shows what it would have shown
anyway, one container feeds any number of devices, and a viewer costs a `tail`
to start and a `tail` to stop. The file is a `mktemp` buffer that dies with the
run — it is not a record, and `just collect` is where records come from.

ttyd's flags, three of them measured on 2026-09-05 with ttyd 1.7.7 because the
wrong spelling fails silently:

- `--interface 127.0.0.1`, spelled as an address. `-i lo` binds
  `10.255.255.254`, a second address WSL keeps on the loopback interface —
  libwebsockets takes the first one there that is not `127.0.0.1` — and the
  tailnet proxy hands its connections to `127.0.0.1` and nowhere else, so that
  listener is unreachable from the tailnet while looking perfectly healthy from
  here. `-i localhost` binds nothing at all and says so nowhere. With no
  `--interface` it binds `0.0.0.0`, which includes this machine's LAN address.
- **No `--writable`.** ttyd is read-only unless asked, and this is not asked:
  the page renders, and nothing it sends reaches anything. It also means `q`
  cannot be pressed from there — the stream is stopped at this end.
- `--check-origin`, so that a page the viewing browser happens to be visiting
  cannot open this socket from the side and read the transcript out of it.
- `-d 3`. libwebsockets prints 25 lines of notices at its default level and one
  more per connection, which is exactly what was filling the window. Measured:
  25 lines at `7` and at `4`, none at `3` or `1`, and the level reaches nothing
  but the log.
- `-t fontSize=18`, because 13 is ttyd's default and a phone is held at arm's
  length. It is a default and not a setting: every client option can be
  overridden from the URL, so `?fontSize=24` sizes it for the device reading
  it, and two devices need not agree. The real limit is columns rather than
  size — about 50 at 13px on a phone held upright, 36 at 18px, and around 78 in
  landscape — and the renderer does not wrap, so the terminal does.

A device that sleeps drops the socket, and the reconnect replays the file from
the top of the session. tmux, or a detacher, is what would hold a view across
that; both are the long-lived helper this machine may not keep, and the replay
is the price of the rule. It is a cheap price now: what replays is a `tail`
over a file that is already written, not a session followed a second time.

**Ctrl-C is the stop.** It reaches the whole foreground group, so the follow
takes it, cleans up its container and returns, and only then does this script's
own trap run and take the daemon and the web server down with it — bash defers
a trap while a foreground command is running, which is what puts them in that
order. What a *closed window* does is the terminal's business and not measured
here; what was measured on 2026-09-05 is that a bare pty hangup delivers no
signal at all — closing the master leaves the tree alive with its controlling
terminal gone (`tty` becomes `?`) and no trap run. So on a closed window the
unwind begins only when `tee` next tries to write to a pty that is not there.

Two more measurements from the same day, kept because they are the reason this
shape is not another one. **ttyd's close signal reaches the whole process
group**, not just the child it started — so the `tail` it kills really does go,
and an orderly close and a connection reset behave identically. And **`just`
ignores `HUP`, `INT` and `TERM` sent to its own pid**, so anything that means
to stop a recipe by signalling the process it started reaches nothing under it.
Between them they are why the traps here are on the group's own signals and why
the two in `listen.sh` stop at `INT`: nothing sends that script a `HUP` any
more, and a trap for a caller that does not exist is a line that goes stale
unread.

## Opening one finished transcript

`just read` is the only reader there is: `just sessions` lists, this opens, and
two implementations of "show me a transcript" is one of them drifting out of
date unread. `listen` follows the session that is running; this reads one that
has finished, by name, and shows the subagent lines `listen` leaves out — a
subagent's transcript is made of nothing else, so filtering them there and
keeping them here is the same rule read from two sides.

What tells a listing position from an id is the SHAPE, and it has to be a rule
a person can hold in their head: a position is one to three decimal digits, an
id fragment is hex and at least four characters. `just read 12` is the twelfth
row of the last listing; `just read 2db4` is the session whose id begins that
way. Four decimal digits are therefore an id and not a position — a list long
enough to need one is read with `--day` or `--all` and then by id, which is the
durable handle anyway.

A position is counted into the same table `just sessions` prints, from the same
function, so the number on screen and the number taken here cannot mean two
different sessions. An id is matched on the FILE NAME, never on the whole path:
a subagent's transcript lives under a directory named for the session that
spawned it, so `just read 2db4fc43` matched both and refused as ambiguous —
when one of the two is plainly the thing asked for.

A session outranks its own subagents. They are filed beside it as
`<session-id>--agent-<id>.jsonl`, so the session's id is a prefix of every one
of their names and `just read <session-id>` matched the lot. When exactly one
hit is not a subagent, that is plainly the thing asked for; ask for a subagent
by its own id and the rule never fires.

The archive first, the volume second. The archive holds every transcript ever
collected, including those of a home that has since been rebuilt, and the
volume holds only what is there now. Where both have a file they have the same
bytes — except a redacted one, and there the archive's copy is the rewritten
one, which is the copy anybody should be reading. See docs/archive.md.

The bytes are materialised rather than streamed, because two things read them:
the header's numbers and the render. From the archive that is a blob read twice
for nothing; from the volume it would be a second container.

A subagent's header is not its session's: the numbers in the session header are
totals with this subagent's work cumulated into them, and printed over a
subagent's transcript they would read as its own. The duration is deliberately
not in the parenthetical either — the second line states it to the second, and
the same fact twice in two shapes is one of them going stale. The token
rounding adds 0.5 because `%d` truncates and the other half of the pair rounds:
119,500 tokens printed as 119k here and 120k there is two implementations
disagreeing about one session. Where the transcript can be read again is named
by its `git show` command when it is in the archive, and said to be
uncollected when it is only in the volume, which is the point.

## One renderer for both readers

`host/session/transcript.jq` is a jq module included by `just listen` and
`just read`. Two spellings of "what a message looks like" drift, and the one
that drifts is the one nobody is reading at the moment it does.

What is deliberately NOT in it is which entries to show: `listen` skips
subagent lines because they are noise beside a running session, and `read`
shows them because a subagent's transcript is entirely made of them. That is
the caller's question, and each caller has exactly one answer to it.

Who is speaking is read from the entry rather than from which recipe called. A
subagent's transcript holds the same two types a session's does, and the `user`
side of it is a prompt the agent wrote plus tool results — calling that
"operator" would put words in their mouth, which is the one thing these files
must never do. An unattended session's first message is the runner's, not the
operator's, and it says so in its own first words while the name printed above
it said "operator": a label that contradicts the line under it is the exact
confusion rule 1 exists to prevent, so the marker `run` writes is read back
here. It comes from the justfile, which is the one place it is spelled.

Times are converted to LOCAL here rather than sliced out of the string, because
a time read by a PERSON is local and a time given to the AGENT — its
environment, its system prompt, the transcript, the day-directory the archive
files it under — is UTC. The conversion is display only: nothing written down
changes. The `[0:19]` slice comes BEFORE the parse, because `fromdateiso8601`
rejects the fractional seconds the transcript actually carries (`…:42.818Z`),
and a rejection in jq kills the whole render rather than the one line — the
same slice-then-parse spelling `host/archive/session-meta.jq` already uses. The
`try`/`catch` fallback is the raw UTC slice this line printed before: an entry
with no timestamp, a null, or anything that will not parse still renders. A
clock an hour out is a bug report; a transcript that will not display is a
session nobody can read.

The ANSI escapes arrive as jq arguments rather than as literals in the program:
a control character in a source file is invisible to whoever edits it next, and
survives exactly until someone reflows the line. `$full` is passed by every
caller, because an undefined variable is a compile error in jq and not a null —
`listen` passes false, since a live view is long enough, and `read --full`
passes true, where a heredoc or a long prompt is the reason the flag was
reached for and ninety characters of it is the same nothing as none. Each line
of an expanded payload carries its own dim/reset, because a single span around
a multi-line block leaves the colour on if the output is cut short.

`tool_result` blocks arrive as `user` messages and are pure noise in a session
view; they fall through to `empty`.

## What a session cost, and which model answered

`host/session/session-stats.py` prints three lines at the end of `just run` and
`just chat`, in `just status`, and into the status page. The clauses that have
nothing to say disappear, the rest do not move. The third line changes shape:
it starts with `MODEL MISMATCH` or `MODEL UNPINNED` when it has something to
say, because it is the line an unattended log is grepped for — the same grep
that finds `COLLECT_FAILED`.

It reads the transcript out of the volume through a throwaway container,
exactly as `host/archive/read-volume.sh` does and for the same reason:
nothing here should depend on anything the agent can execute.

  output    Everything the model generated: visible text, thinking, and the
            JSON of every tool call. Tool RESULTS are not output; they come
            back as input on the next request. Thinking is a subset of output,
            not an addition to it.

  requests  Assistant records are streaming snapshots, several per API
            request, all carrying the same `requestId` and a usage that GROWS
            across them — measured, 5 output tokens then 152 in one request of
            a sub-agent. So the last record of a `requestId` is the true one,
            and counting records rather than `requestId`s inflates the count by
            more than two.

  agents    Sub-agents are NOT in the session transcript. They are separate
            files under `<session-id>/subagents/`, marked `isSidechain`, and in
            one measured session they out-produced the main chain 313k to 213k.
            Their requests and their output are cumulated; how many there were
            is the number of distinct `agentId` values, not the number of files
            — every agent has a `.meta.json` beside its `.jsonl`, so the file
            count is exactly double.

  context   NOT cumulated, and it is the one number that must not be: each
            agent has a context of its own, and adding them together names
            nothing that ever existed. This is the main chain's last request,
            whose input + cache write + cache read is what was actually sent
            that one time.

  cache     Deliberately absent. `cache_read` is the same context re-read once
            per request — 204M on a long session, a number that says
            "turns × size" and reads as catastrophe. It stays in the
            transcript, so a cost figure can still be worked out later.

  time      Elapsed is first record to last, and it is the main chain's own
            span: a sub-agent runs inside it, so it can only widen the window
            by the rounding of a timestamp. Generating is the CLI's own
            per-turn measure and exists only where there are turns — every
            transcript in the volume has zero of those records, because
            `just run` is headless and a headless session has no interactive
            turns. So the clause is a `just chat` clause, and for a run the
            elapsed time IS the working time; printing it twice under two
            names would be the lie, not the omission.

Elapsed is truncated to whole seconds deliberately: the archive computes the
same elapsed time from the same transcript with jq, which parses whole seconds
and nothing finer, and a session that reads 27m46s here and 27m47s there is two
implementations disagreeing about one fact. `fromisoformat` learned to read the
trailing `Z` in 3.11 and this machine is newer, but the replacement costs
nothing and keeps this readable on an older interpreter — in the one place
where the failure would be a stack trace after a finished session.

## The model witness

Which model AUTHORED the main chain, read from the `model` field of its
assistant records, against the `model` key of `image/managed-settings.json`.
The setting is what was asked for; the transcript is what answered.

The two diverged for two days in August 2026 with nothing saying so — a session
ran on Sonnet under a setting that asked for Opus — and it was found by
accident, reading a captured system prompt. The runner's own prompt no longer
carries the model the CLI resolved, so this line is the witness that replaces
it, read every time the summary is printed.

Main chain only: a sub-agent runs on the model its definition names, and Haiku
there is by design. An alias matches any id that contains it, so `opus` is
satisfied by `claude-opus-5` and by its successor, and not by Sonnet. A missing
setting is named rather than passed: an unpinned model is the credential
deciding, which is exactly how the two days happened (runner commit 22d055c).

The setting is read from the repository, not from the running container — the
same reading `host/archive/status-collect.py` takes of the Dockerfile, and
honest for the same reason: it is what the next build uses, and a container
built before the last edit is a stale container worth noticing. `None` is not
an error to raise on: the summary still has two lines worth printing, and the
third is where "no model is pinned" gets said.

## Which transcripts are a session's

`AGENT_VOLUME` and `AGENT_PROJECT_DIR` are required, not defaulted: a fallback
naming some other agent's volume reads as "no sessions yet" rather than as a
mistake.

Claude Code files a transcript under the working directory it was started in,
encoded. `run` and `chat` both pass `-w` into the agent's repository, so a
session lands under that directory and nothing else does: most `just verify`
probes start in the home and file under `-home-agent`, as does a `claude`
someone typed inside `just shell`. Those are deliberately not sessions —
measured, because the newest transcript in the volume was one of them while the
last session had ended half an hour earlier, and the summary would have been
printed under its heading. The archive filters on the same directory for the
same reason.

**No probe writes in the volume at all, and two of them used to write in the
agent's own project directory.** `tools allow` and `project rules` must run with
the checkout as their working directory, so Claude Code filed their transcripts
where `just listen` follows them, `just collect` archives them and `just cost`
prices them as the agent's work. Every probe now runs with a `HOME` of its own,
which moves the transcript root without moving the working directory. The
record is in [`docs/verify.md`](verify.md), under "A probe does not file in the
agent's directory".

`--since` is what stops a session that wrote no transcript at all from being
reported with the previous session's numbers. That is not hypothetical
tidiness: a container that dies during bootstrap leaves the transcript before it
as the newest file in the volume, and its summary would be printed as if it
were this run's. The glob is one level deep on purpose: sub-agent transcripts
sit a directory further down and would otherwise be candidates for "newest"
themselves.

## Pricing a session

`image/session-cost.py` prices a transcript at published per-token API rates.
It is baked into the image and root-owned, for the same reason as
`image/claude-usage.py`: a second copy of the arithmetic is the copy that
drifts, and it drifts silently because both answers look like numbers.

A path is required and nothing is guessed: there is no default transcript and
no "the last one". The transcript layout — `~/.claude/projects/<working
directory, every / turned into a ->/`, with a session's sub-agents beside it in
`<session-id>/subagents/` — is OBSERVED rather than documented, and a working
directory holding characters other than `/` may well be spelt some other way.
The newest file is the session running now only because one session runs at a
time here; it is being appended to while it is read, so the figure covers the
requests that have completed and not the one in flight.

It is the agent's OWN number, which the account percentage cannot be: the usage
endpoint `claude-usage` reads answers for the ACCOUNT — one login shared with
the operator's own sessions and chats — so nothing there can say how much of it
one session accounts for. Every assistant record carries the usage of the
request that produced it, in that session's own file, and no other session can
contaminate it. See docs/budget.md.

Dollars rather than tokens, because tokens are not comparable: an Opus output
token costs five times a Sonnet one, a cache read a tenth of a fresh input
token, and a 1-hour cache write twice one.

THE FIGURE IS NOT MONEY THAT WAS SPENT. Nothing was invoiced. It is what the
same traffic WOULD have cost at published rates, and this container runs on a
subscription, which is not billed per token at all. AND IT DOES NOT CONVERT
INTO THAT ALLOWANCE: how a subscription turns usage into the percentages
`claude-usage` reads is not published anywhere, so there is no rate here to
multiply by. A session priced at twice another has not been shown to consume
twice the window. What it is for is comparing sessions against each other in
one unit, and seeing which PART of a session weighs — a comparison that holds
whatever the subscription does with it.

## What the corpus measured

  iterations  SUMMED, never read from the top level. Measured over 397
              archived transcripts: two requests carry an `iterations` array of
              two — a `message` attempt and then a `fallback_message` — and the
              top-level `usage` reports ONLY the last one. The first attempt's
              1452 output and 3977 cache-write tokens were really consumed and
              are absent from the top level. 110 records carry no `iterations`
              at all, and those are the only ones the top level answers for.

  requests    Measured over the same corpus: every assistant record has a
              `requestId`, and no `requestId` appears in two files — a resumed
              session does not re-contain the history it resumed, so
              deduplication never has to reach across sessions.

  models      Priced per request from the record's own `model`, because a
              sub-agent runs on the model its definition names. Ids carry an
              optional eight-digit date suffix, so matching normalises it away
              — eight digits and not any tail, since a real id ending in a
              number must survive. An id the table does not know is NAMED and
              the exit is non-zero: a model silently priced at zero looks
              exactly like a cheap session.

  sub-agents  Cumulated into the session that asked for the work, in both
              layouts this file ever sees: the volume nests them at
              `<session-id>/subagents/agent-<id>.jsonl`, the archive flattens
              them to `<session-id>--agent-<id>.jsonl`. A sub-agent priced as a
              session of its own would make both numbers wrong. Which file a
              request came out of is what says who ran it, and that is known
              from the path without trusting a field.

  thinking    Reported under output, never added to it. Thinking tokens are a
              SUBSET of output and are already counted there. They are shown
              because effort is one of the few levers there is, and its whole
              weight is in that line.

Prices are Anthropic list, $/MTok, read from the published pricing page on
2026-09-01: input, 5-minute cache write, 1-hour cache write, cache read,
output. Cache multipliers are 1.25x, 2x and 0.1x of base input, and they are
written out rather than computed so that one wrong price is one wrong number
rather than a wrong column. Fast mode is a different price for the same model,
Opus 5 and 4.8 only, with the cache multipliers on top; `usage.speed` says
which ran. RE-READ the table when a model is added or a session starts
answering on an id it does not hold; a stale price prints in exactly the same
shape as a current one.

Web search bills $10 per 1000 on top of tokens and web fetch is free;
US-pinned inference bills 1.1x on every category. Neither was ever observed in
the 397 archived transcripts — every record reads `not_available` — so both
lines are priced from the published rate and have never been exercised against
real data. A missing cache-TTL split was never seen either: every record in the
corpus carries it, and the fallback charges at the dearer rate, because
under-reporting a cost is the failure that goes unnoticed.

The MAIN CHAIN dates a session, whichever order the files arrive in: a
sub-agent can start on the far side of midnight from the session that asked for
it, so its own first timestamp is only used when nothing else is on offer.

## Where the money went, and who spent it

The `where it went` block splits the total by token category and covers
EVERYTHING PASSED IN, not each row of the table above it. Hand it one
transcript and it is that session broken down; hand it a directory and it is
the whole set broken down, which answers a different question and cannot be
read back onto any one session in the table.

`who spent it` splits the same money by who ran the request and on which model,
and it answers what `where it went` cannot: handing a task to a weaker model is
one of the few levers there is, and whether it paid is invisible while the
sub-agent's spend is merged into the session that asked for it. A Haiku
sub-agent beside an Opus main chain is two rows, and the saving is the
difference between them. The search charge rides with the request that made it,
so the rows add up to the session total rather than to a slightly smaller
number nobody can account for. The block is SILENT when there is nothing to
compare — one model and no sub-agent makes a single row restating the total,
and a block that always prints is a block that stops being read.

The session table shows the AGENT COUNT and not the sub-agent request count:
what a reader can act on is how many were spawned. Columns are ranged left or
right by position, because numbers only line up when they are ranged the same
way as the header that names them.

`--selftest` proves the arithmetic against inputs chosen to be wrong in the
ways it could be wrong — including the measured fallback pair above — and runs
at build time, so a wrong price stops the build rather than printing for a
month in the shape a right one uses. See docs/verify.md.

`| head` is how anybody reads a 394-row table, and Python's default is to raise
`BrokenPipeError` at exit and print a traceback UNDER the output that was
correct, which reads as the tool having failed. Restoring `SIGPIPE`'s default
disposition makes the process die silently on the closed pipe, the way every
other command here does. The usage examples are repeated into `--help` and not
kept only in the module docstring: a session reaches for `--help` first, and a
path it has to invent is a path it invents wrong.

## The test twin

`just test-env` runs the same image with the same environment and the same
hardening as a real session; the only difference is that the service has no
volume, so the agent's home is the image's own and goes away with the
container. That is what makes it honest: a rehearsal against a home that
already holds a key and a login proves nothing about the morning the volume is
gone.

Nothing runs the agent in there. It is for the questions that come before a
session — does the container start, can the login be restored without a
browser, can the key be restored without adding a new one to the account.

The entrypoint stops at exit 78 on an empty home, which is the correct answer
and also an unhelpful one when you want to look around: prefixing
`AGENT_SKIP_CLONE=1` makes it report what it found and hand over anyway.

It always runs the candidate, because testing runs what is built and not what
is live. It takes neither the session lock — it spends no budget and touches no
shared state, so a rehearsal must not stand a real session down — nor a pass
through collection, since its transcripts die with it. It parses its own
`--build` rather than taking a declared flag, because everything after that
flag is the command to run in the container, with options of its own, and
`just` would refuse `just test-container bash -l` as an unknown `-l`.
`just chat` parses its own flags for the same class of reason: the message is
free text that must survive verbatim, including a leading dash.

## Where `just status` gets its answers

The container is the evidence that a session is running, and the lock
deliberately is not: there is no way to test a `flock` without taking it, and a
`just run` starting in that instant would find it held and stand down. A status
command that can stop a session is worse than none.

Every other number is asked of the one implementation that owns it rather than
recomputed: the budget gate for the budget, `collect.sh --held` for
what the review gate is holding, `just deploy --state` for what is live, and
`just schedule --state` for whether a session will start on its own. A second
rendering of any of them is the copy that drifts, and the copy that drifts is
the one nobody runs by hand.

A missing line is NOT a zero, anywhere in that output. No docker, no
credential, no archive to read the ledger from, a gate that could not start —
reporting "none waiting" or "no limits" for any of those is the mechanism
failing silently. So each case says the gate did not answer and names what to
run to find out why. The budget block redirects stderr into stdout because the
two halves go to different places on purpose — the numbers to stdout, the one
line it writes when it cannot tell to stderr — and here both are worth showing.

"No session is running" reads the same on a machine that runs one every hour
and on one where the schedule was paused a fortnight ago and forgotten, so
`session_absent_line` carries the scheduling clause with it. It is one sentence
in one implementation because two things say it: `just status`, and the end of
a `just listen` that read a session which has finished. Two recipes answering
"is anything running?" differently is a bug you only find by holding them side
by side. `just listen` asks again at the end rather than assuming the answer
from its own branch, because a session can start between choosing to read and
finishing the read, and "No session is running" printed underneath a session
that just began is exactly the kind of sentence nobody re-checks.

Enabled-but-nothing-to-fire-it is the failure worth its own clause: the crontab
reads the same either way. Scheduling is asked of `just schedule --state`
rather than read out of the crontab, because what counts as paused is a prefix
that recipe writes and a second reader would go on believing the old spelling.
The hour and the cooldown stay there too; repeating them would be the second
copy that goes stale.

`host/release/check-agent-settings.sh` runs from `status` rather than from
`verify` because it is a fact about the volume and not about the image: verify
proves the candidate on a twin with no volume and would answer this about a
world nobody lives in. It reports and never refuses — a settings edit that
stood a session down would let the agent lock itself out of its own container.

Reading the budget also renews the container's access token, which is why
looking at status once a week keeps the unattended path alive on a schedule
that has been paused.
