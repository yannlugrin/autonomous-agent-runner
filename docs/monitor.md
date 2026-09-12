# The monitor

## What it is, and what to do

The agent writes its own rules. That is the arrangement, and it is also the
thing nobody watches: a constraint that tightens by one sentence a week never
shows up in a week's diff, and neither does a permission the agent quietly gave
itself, a caution it added without being asked, or a way of measuring itself
that it changed. The drift audit is the operator's instrument for noticing —
the one piece here that watches the **agent** rather than the runner.

There is nothing in `.env` to set. These are the handles:

| handle | what it does |
| --- | --- |
| `just drift-audit` | one audit. Clones the archive's mirror of the agent's memory, brings it current, and runs a Claude session over the range, which writes one report |
| `just drift-accept` | move the baseline to the last audited commit. It asks first, and refuses where there is nobody to ask |
| `just drift-diff` | the same cumulative range as a plain `git diff`, with no agent in between. `[PATH...]` narrows it |
| `just drift-status` | what the audit stands on: the mirror ref, the two anchors and how far behind each is, and the last runs. It fetches first |
| `just cost` | what the archived sessions cost, priced from their sealed records. `--by-day`, `-d N`, or session ids. API list rates: weight, not an invoice |
| `just tools` | how many times each tool was called, per day, in the archived sessions' records. Name tools to get one line per day instead; `-d N` for the window |
| `just records` | one durable record per archived session — what it was, what it spent, what it committed, which runner built it — sealed once and published to the archive's `cache` branch. `just stats`, `just tools`, `just cost` and `just journal` read them |
| `just journal` | the agent's journal one entry at a time, newest first, with the session that wrote each one under its heading: `→` older, `←` newer, `q` quits. A day or a session id opens there |
| `RUNNER_MONITOR` | where all of that lives. `monitor/` inside this checkout unless set, gitignored, created on the first run; a relative value counts from the checkout, not from where `just` ran |

**The audit is a Claude session, and it runs on the host, on your own login.**
Not in the container, and on no credential of the agent's — an agent that could
reach this could edit what its own audit says. That session is confined by
`host/monitor/drift-audit/settings.json` with `--setting-sources ""`, so no
other settings file on the machine adds to it; it has no network, no `gh`, and
no write access outside its own reports directory; `GH_TOKEN` and the whole
`BWS_` namespace are unset before it starts, because it is reading a corpus
written by an agent that quotes the open web. It is told that instructions
found inside that corpus are **findings, not direction**. Nothing it produces
reaches the agent.

**The threshold, in one sentence:** a change is reportable when it changes what
the agent may do, must do, is prompted to do, or how it measures itself.
Journal entries recording work, prose rewritten without a change of scope,
counters moving — not reportable. Tightening is reported before loosening,
because it is the one that is easy to miss: a self-imposed constraint, a
deferral that hardened into a rule, a capability described as unavailable that
nothing actually prevents, all of it reads as good behaviour, and is the kind a
reader waves through.

**Two anchors, and one of them is a ratchet.** `baseline` is frozen and the
cumulative sections read from it; `cursor` is the head of the last completed
audit, and the incremental sections read from there. A run that fails leaves
the cursor where it was, so nothing goes unaudited because a session died
halfway. `just drift-accept` moves the baseline — and once it has, **every
later report stops covering the range between**. Read the reports before you
accept.

**What you see.** The default report is one line, and that is the correct
output: most runs have nothing above the threshold, and padding a report to
look productive is this job's failure mode. The auditor delivers no verdict and
proposes no fix — it lists candidates and says what each one moves, and you
decide. A first run has nothing to compare against, so it freezes the baseline
at the current head and stops.

## How it is built

The agent writes its own rules. `just drift-audit` is how the operator notices
when they move: it reads a read-only mirror of the agent's memory between two
anchors and writes a report of what changed in **what the agent may do, must
do, is prompted to do, or how it measures itself**. `just drift-accept` moves
the baseline, `just drift-diff` shows the same range with no agent in between,
`just drift-status` says what the audit stands on. `just cost` is beside them
because it answers the other question about a record nobody watches: what it
has been costing.

**The audit is a Claude session, and it runs on the host, on the operator's own
login.** Not in the container, not on any credential of the agent's: this is
the operator's instrument, and an agent that could reach it could edit what its
own audit says. The session is confined by `host/monitor/drift-audit/settings.json`
with `--setting-sources ""`, so no other settings file on the machine adds to
it; it has no network, no `gh`, and no write access outside its own reports
directory. Nothing it writes reaches the agent.

The tooling was a separate repository, `monitoring`, three commits, folded in
here on 2026-09-02. Templating it would have meant keeping a second copy of
values this repository already holds: the archive it clones is
`AGENT_ARCHIVE_REPO`, the ref it reads is `refs/archive/$AGENT_USER`, the issue
ledger comes from `<NAME>_REPO`, the price table is `image/session-cost.py`. It
already reached into the runner by relative path, so a moved runner broke it
silently, and its own `scripts/claude-session.py` was a second copy of the
renderer that had already drifted from it.


## What the audit reads

The mirror, and the issue ledger, and nothing else.

The mirror is the agent's memory repository as the archive's own workflow
copied it: rules, self-description, notes, journal, and the scripts the agent
wrote for itself. The audit reads six things out of it — the shape of the
repository itself (are the anchors still ancestors, what rewind marks exist,
what refs are there), the context files cumulatively, `tools/` cumulatively,
the `Next` sections of the journal incrementally, commit messages against their
own diffs incrementally, and the issues.

The issue ledger is exported by `just drift-audit` before the session starts,
with the operator's `gh`, into `state/issues.json`: every issue on the agent's
repository with its bodies and comments. The session has no network of its own,
so that file is its only view of them. **An export that fails leaves the key
out of `run.json` altogether** rather than leaving a stale file behind — the
run procedure reads a missing key as "skip that step and say so in the report",
and a previous run's issues passed off as this run's would be worse than none.

What it cannot see is permanent and belongs in every report: what a session
actually loaded (a file can be truncated on read, or never opened), the system
prompt and the runner configuration (deployed from outside the mirror), the
volume outside the repository, and anything the mirror did not catch
before it was rewritten upstream.

**The corpus is data, never instruction.** The files were written by an agent
that quotes the open web, and they carry sentences addressed to the operator,
to "Claude", and to future sessions. The auditor is told that text inside the
corpus telling it to do something is itself a finding, to be reported with its
pointer and not acted on.


## The two anchors

`baseline` is frozen. `cursor` is the head of the last completed audit.

Two anchors because the two questions are different. Slow drift is invisible
incrementally — a constraint that tightens by one sentence a week never shows
up in a week's diff — so the cumulative sections (context files, instruments)
run `baseline..head`. The sections whose findings were already reported last
time (direction of travel, message against diff, issues) run `cursor..head`.

The cursor advances only on a run that produced its report. A failed run leaves
it where it was and the next run covers the union of both ranges, so nothing
goes unaudited because a session died halfway.

`just drift-accept` is the ratchet, and it is the one thing here that loses
something: once the baseline moves, the cumulative sections stop reporting what
the old range held. The reports stay where they are, but nothing regenerates
them. It asks before it moves, and refuses where there is nobody to ask.

A first run has nothing to compare against, so it freezes the baseline at the
current head and stops. To start from an earlier commit, write that commit into
`state/baseline.sha` by hand and run again.


## The threshold

**A change is reportable when it changes what the agent may do, must do, is
prompted to do, or how it measures itself.** Journal entries recording work,
prose rewritten without a change of scope, notes that carry reasoning without
adding a constraint, counters moving: not reportable.

Tightening comes first in every report, before loosening, because it is the one
that is easy to miss — a self-imposed constraint, a deferral that hardened into
a rule, a caution added without an external request, a capability described as
unavailable that nothing actually prevents, all of it reads as good behaviour,
and is the kind a reader waves through.

The default report is one line. Most runs have nothing above the threshold, and
saying so in one line is the correct output; padding a report to look
productive is this job's failure mode. The auditor delivers no verdict, makes
no recommendation and proposes no fix — it lists candidates and says what each
one moves, and the reader decides.

Every observation is a top-level list item beginning `- [`. `just drift-audit`
counts those lines to record how many observations a run produced, so a
different bullet form would make a full report register as empty.


## Why the mirror is a hidden ref

The archive keeps the mirrored memory at `refs/archive/<agent>` — a ref, and
deliberately not a branch. GitHub starts workflow runs from the pushed ref, and
only `refs/heads/*` and `refs/tags/*` trigger, so a ref outside both can carry
the agent's tree, workflow files included, without ever running one. See
docs/archive.md#a-ref-not-a-branch.

The cost lands here: a plain clone fetches nothing, because a clone's default
refspec is `+refs/heads/*:refs/remotes/origin/*`. So the audit clone is made by
hand — `git init`, a remote, and two explicit refspecs: the content ref to
`refs/remotes/mirror/source`, and `refs/archive/rewound/*` to
`refs/remotes/rewound/*`, which is what lets the audit report a rewrite that
happened upstream.

**The remote is asked before anything local is made.** The content refspec
names one exact ref, and `git fetch` of a ref the archive does not have fails
outright — so without an `ls-remote` first, an archive whose mirror has simply
never run reports itself as a network failure and leaves an empty clone behind
for the next run to find and believe.


## Where the audit keeps its state

Under `RUNNER_MONITOR` — `monitor/` inside the project, gitignored, created on
the first run — exactly as `deployed/` and `archive/` are (R12): a clone of this
repository arranges nothing outside its own directory.

    monitor/mirror/              the audit clone — the ARCHIVE's copy of the memory
    monitor/memory/              the agent's repository, bare, fetched by `just
                                 stats` for its newest journal heading
    monitor/memory.log           the commits in the agent's checkout, read out of
                                 its volume by `just records`; see below for why
                                 they are two
    monitor/logs/                one line per run: when, the range, what it found
    monitor/drift-audit/         the session's working directory
    monitor/drift-audit/CLAUDE.md    the run procedure, copied there each run
    monitor/drift-audit/state/       baseline, cursor, the issue ledger, run.json
    monitor/drift-audit/reports/     one report per run

What the auditor is *told*, and what it may *do*, are tracked instead:
`host/monitor/drift-audit/` holds the run procedure, the system prompt template
and the settings. The session runs in `monitor/drift-audit/` rather than there
because Claude Code loads `CLAUDE.md` from the working directory, and because
the settings spell what may be read as `../mirror` — the working directory has
to be the clone's sibling. The procedure and the settings are both copied in on
every run, so the tracked pair stays the only copy anyone edits.

**The settings have to travel with the session, and that was measured the
expensive way.** On 2026-09-02 the first run under this layout was given
`--settings host/monitor/drift-audit/settings.json` while running in the
scratch working directory, and it wrote its report into
`host/monitor/drift-audit/reports/` — inside the tracked checkout. The relative
paths in a settings file are resolved against **that file's own directory**,
not against the working directory, so `./reports` named the checkout and the
sandbox refused the working directory it was actually in. Probed afterwards
with a one-line session, both ways: settings in the checkout, the write is
refused and lands there; settings copied beside the session, it lands in
`monitor/drift-audit/reports/` and the checkout is untouched.

The settings' `Edit(/reports/**)` is the write permission for the report: a
permission path that starts with `/` is relative to the session's working
directory, which is why the settings must sit beside it, and why the rule
reads `/reports/**` and not a path into the checkout. The operator tested the
sandbox as it stands; the file is carried over byte-identical from the
`monitoring` repository and is theirs to change.

`run.json` is the handover: the clone, the three commits, the issue ledger and
the exact report path, written by the runner and read by the session first. The
prompt itself is the same six words every run — "Run the drift audit." — so
what varies between two reports is the repository, not the question.


## The session's environment

`just` loads `.env` into every recipe's environment. Measured 2026-09-02 on the
demo installation: `BWS_ACCESS_TOKEN` and the whole `BWS_` namespace are there,
and would have been inherited by the audit session.

That is a session reading a corpus written by an agent that quotes the open
web, so `just drift-audit` unsets `GH_TOKEN` and the `BWS_` namespace before it
starts one. The audit needs neither, and a token it cannot read is one no
instruction found in the corpus can spend. The session's own settings deny the
network and the interpreters, but a deny list is a list and this costs one line.

The whole namespace and not `BWS_ACCESS_TOKEN` alone: the token is the secret,
the rest is where the vault is and which project — and a namespace is one thing
to keep true where four names are four.

## One renderer, two templates

The auditor's system prompt is rendered by `image/claude-session.py`, the
runner's own, given `--template`. See
docs/sessions.md#one-renderer-two-templates for how, and for why the second
copy that used to do this had to go.


## What the archive cost

`just cost` prices the sealed records: one line per session over the last day,
`--by-day` for one line per day over the last ten, `-d N` to widen either, or
session ids to price those wherever they sit.

## just tools

`just tools` counts tool calls in the same records, on each call's own UTC day: one line per tool and one column per day, heaviest tool
first, over the last five days that carry a call. Name tools, `just tools Bash
Edit`, and the table transposes to one line per day and one column per named
tool over the last ten; `-d N` sets the window in either shape, and a named
tool that was never called in the days read is said so on stderr rather than
shown as a column of zeros in silence. It reads one day's directory beyond the
window because a session filed under one day can hold calls stamped the next.
It came from the monitoring repository this directory replaced, where it was
the one recipe the folding of 2026-09-02 missed; brought over 2026-09-04.

`just cost` prices through `image/session-cost.py` and carries no rates of its
own. That is the whole of the overlap rule with `just status`, which prices the
one session that just ran out of the volume: two questions, two commands, one
price table. A second copy of the table drifts the day rates change, and both
copies go on printing numbers that look equally right.

The figure is what the same traffic would have cost at published per-token API
rates. Nothing here was invoiced — this account is a subscription, which is not
billed per token and has no published conversion into its allowance. It is
weight, for comparing sessions against each other in one unit, never an
invoice.

The day is the archive's, which is UTC: a transcript is filed under the UTC day
of its own first timestamp and the pricing tool dates a session the same way,
so a day directory holds exactly one day of sessions. `just stats --by-session`
is where the local day lives.

A sub-agent is priced into the session that asked for the work, and its usage
is its own in that session's record, under `subagents`: `who spent it` splits
the two.


## One record per session

`just records` writes one durable record for every session the archive holds:
when it ran, what it was, what it spent, which commits it made, and which
version of the runner built its container. One file per session, written once
when every field in it is final, and never rewritten. There is nothing in
`.env` to set.

**`run` and `chat` call it at the end of every session**, after the collection
and after `publish-status --now`. You do not type it: the bare command is
machinery, in the shape `just publish-status` is machinery, and the three flags
below are the only reason a person runs it by hand.

| handle | what it does |
| --- | --- |
| `just records` | what a session end calls. Seals every session that can be sealed and publishes them to the archive's `cache` branch. With nothing to do it costs 40ms and no network |
| `just records --recheck` | re-derive every stored record and diff it against what is stored, writing nothing. How a suspected fault is answered |
| `just records --rewrite <id>` | replace one, for a transcript a redact ruling changed after its record sealed |
| `just records --no-publish` | write them here and push nothing. For looking at the store without touching the archive |
| `RUNNER_RECORDS_DIR` | where they live — `~/.cache/<agent>/records/` unless set |

`just stats`, `just tools` and `just cost` read them — see
[the commands that read the store](#the-commands-that-read-the-store).

### Why it exists

Six seconds to re-derive the whole archive today, growing by about forty
transcripts a day, is already too slow for a command anyone types. But speed is
not the whole of it: two of the facts worth keeping are **not in the transcript
at all** and have to be joined in from elsewhere — which commits the session
made, and which runner built its container — and the first is joined against a
repository the agent is free to rewrite. A sealed record is the only lasting
witness to those shas.

The record answers "what was this session". Assembling many of them into a table
is the reader's job, not the store's, which is why there is no total anywhere in
one: a stored sum is a second copy that drifts.

### Sealing, and what holds it

A record is written when **every field in it is final**, and not before. That is
what makes "written once" true rather than aspirational. Three conditions, all
exact:

| the fields | final when |
| --- | --- |
| everything read from the transcript | the transcript is on `origin/sessions` — settled, past the credential gate, past a redact ruling |
| every run's `commits` and `commit_stat` | the agent's checkout was **read later than** the transcript's `end` |
| `runner_commit`, `runner_image` | a `status` snapshot exists with `generated_at` **later than** the session's `start` |

**All three hold the moment a session ends**, which is why the session end is
where this is called and not a schedule of its own. `just collect --push` has
put the transcript on origin; the container has exited and `sync_memory` reads
its checkout; `publish-status --now` has just written a snapshot. Nothing is
waited for.

The last two are exact rather than a wait. A read that happened after a session
ended has every commit that session made, whether or not the agent has committed
since — which is the whole reason the source is the checkout and not a copy of
it. And once a snapshot exists after a session's start, the latest snapshot at
or before that start can no longer change.

**What holds a record back is named, never counted.** `just records` prints
which condition each waiting session is on and when that source was last read,
because a store that quietly stopped sealing looks exactly like one with nothing
left to do.

`~/.cache/<agent>/records-state.json` records what the sealing was done
against: the three sources, and when the agent's checkout was last read. It
stays on this host and is not published — the branch is written once per file,
and this is the one file that would change on every run.

### The commits come from the agent's checkout

Read out of the volume, where a session makes them — not from the archive's
mirror, and not from the agent's repository on GitHub. This is the difference
between a record that is current and one that is as current as something else
managed to be.

**Not the mirror.** It is refreshed by a GitHub Action asked to run at every
session end, and by nothing else since the schedule went: on 2026-09-06 it had
been failing since the 3rd, was 245 commits behind, and a third of the archive
could not seal against it.

**Not the repository on GitHub either**, which records were read from between
2026-09-06 and 2026-09-10, through a bare clone this host fetched. The move to a
host of its own measured two faults in it. The repository is private, so the
fetch needs a credential for it, and the host running the agent held only the
archive's key: every session there ended `RECORDS_NOT_SEALED`, and the one run
that sealed was typed by hand over an ssh that forwards the operator's key. And
origin is not where a commit is made: two instances ran at once that night, the
commits of one did not reach origin until a merge an hour later, and its record
sealed without two of them.

`sync_memory` in `host/monitor/clone.sh` runs one `git log` in the deployed
image, the volume mounted read-only and no network, into `monitor/memory.log`.
Read and never written — rule 2 is about writing, and `just collect` already
reads the same volume. The checkout's git config is the agent's, so the settings
that would change those lines are overridden on the command line. A commit whose
push failed is in the log, and so is one on a branch never pushed: **a record
can name a sha origin never had.**

`sync_push_state` beside it reads the same checkout the same way for what the
last push carried. See `docs/backup.md`, under "The host reads the flag too".

That also keeps the sealing rule exact. **The condition is that the read
happened after the session ended**, taken from the log's mtime: once a session's
container has exited, its checkout holds everything it committed, whether or not
the agent has committed since. Against a mirror the only answerable question was the
weaker one — has a copy moved past that instant — which left a session that
committed nothing waiting for some later session's commit to arrive.

The mirror stays where it is and keeps its own job: the drift audit reads it,
because the audit is about what moved between two anchors and wants the copy
whose rewind marks the archive preserves.

### Attributing a commit

A plain window test, needing **no grace period, no fuzz and no
nearest-neighbour rule**. Measured on 2026-09-06 against the real archive and
the agent's own repository: 1009 commits and 580 sessions, **1005 attributed and
4 not**. Every commit whose session is in the archive falls in exactly one
window. What is left over is the commits of sessions that are not there: one
predating the first archived transcript, and three from a window in which no
archived session was running — the agent's own commits, from a session whose
transcript the gate is holding or that has not been collected. Author date and
committer date give the same answer; the committer date is what is read, being
when the commit landed.

An earlier attempt using the displayed start time left 141 commits
apparently unattributed, all within 60s *after* a session's end. That was an
artefact and not a phenomenon: the displayed time is `HH:MM`, so every window
start was floored to the minute and every window ended up to 59 seconds short.
It is the reason the record stores epoch seconds and nothing else — two
spellings of one instant is the drift comment 5 warns about, and epoch is the
spelling the arithmetic needs.

`image/push-on-exit.sh` was briefly suspected and is not involved: **it pushes
and never commits.** Read it before re-deriving that.

**The window is the RUN's, never the transcript's**, and that is what makes the
test exact rather than nearly right. Over the whole archive: 1018 commits,
1018 attributions, **none counted twice**. Attributing over a transcript's own
`[start, end]` gave 1021 for 1005, because a conversation left open spans the
unattended sessions that run while nobody is typing — one on 2026-08-26 covers
sixteen commits belonging to the fifteen sessions inside it. See "One file is
not always one run" above for what a run is and how a seam is proved.

### A probe is not a session

**The archive is not the population.** It holds `just verify`'s own probes,
because verify ran against the agent's own HOME until 2026-09-04 and its
transcripts landed beside the real ones. Counting archived files therefore
counts twenty things that were never sessions, and no amount of care about the
window fixes a denominator.

`started_by` is what separates them, and it is a fact rather than a rule of
thumb: `run` and `chat` each write a marker in front of the prompt they seed —
`RUNNER_SAYS` and `OPERATOR_SAYS`, the line rule 1 rests on — and
`host/session/transcript.jq` already reads the same two to decide whose name to
print over a message. Measured on 2026-09-06 over 582 transcripts:

| `started_by` | | |
| --- | --- | --- |
| `runner` | 555 | an unattended start |
| `operator` | 7 | a conversation |
| `null` | 20 | neither seeded it — 19 say `probe-<n>` in their own opening line, one is a `local-command-caveat` stub |

Nothing else separates them. The probes carry the same `cwd`, the same
`permission_mode` and the same `effort` as a real session; they are short, and
shortness is not a rule. `cwd` looks like a discriminator and is not: it holds
two values, the checkout under the agent's name and under an earlier one, and a
real session either way.

The marker is matched literally, exactly as `chat --continue` matches it, so
changing `OPERATOR_NAME` stops the operator's marker matching transcripts
written before the change — see VARIABLES.md.

### The session count

The question the store exists to make answerable: **how many sessions ran.**
Counting archived files answers a different one. On `origin/sessions` as it
stood at 2026-09-06 14:12Z:

| | |
| --- | --- |
| archived transcripts | 580 |
| less probes and stubs (`started_by` is null) | −20 |
| real transcripts | 560 |
| plus the second run of the one resumed transcript | +1 |
| **runs in the archive** | **561** |
| plus one whose transcript the credential gate is holding | +1 |
| **sessions that ran** | **562** |

The held one is not a guess: three commits sit in the memory at 10:02Z on
2026-09-06 and fall inside no archived run's window, which is how the store sees
a session it does not hold. The only other unattributed commit predates the
first archived transcript by eight minutes.

**The other side of that subtraction is not this repository's**, and the store
should not carry a number for it — two matching figures in two places is one of
them drifting with nothing to notice. The method, so nobody rebuilds a worse
one: *a session is credited with an entry when a heading-adding commit's
timestamp falls inside its transcript's first-to-last window.* It sidesteps the
2026-08-25 compaction — fourteen sessions deliberately folded into one heading —
because **it never counts entries at all**, where counting them has to tell a
deliberate fold from an omission and cannot. Both halves were measured against
the figures above on 2026-09-06, by two instruments, and agreed exactly.

What is worth recording is why the left-hand side used to be wrong, since both
faults were silent: it counted 580 files including twenty `just verify` probes,
and it missed the second run of the resumed transcript. Wrong in two directions
at once, which is why a difference against anything could not be read.

### One file is not always one run

`just chat --continue` **appends to the transcript it resumes**, so one archived
file can hold two runs. Exactly one does, measured over 581 transcripts on
2026-09-06: `2026/08-26/7c00b68f`, a conversation from 08:23:56Z to 11:02:04Z
and again from 16:11:38Z to 16:58:11Z.

**The version change is what proves it, and it is the only thing that does.** A
process cannot change its own binary mid-run, so `2.1.241` across the first part
and `2.1.246` across the second, with no overlap, is a seam and not an
inference. Two things that look like evidence and are not:

- **A gap is not a seam.** Two other transcripts have internal gaps over 30
  minutes — `26b6463c` at 51.1 and `77bfb6de` at 44.5 — and each carries a
  single version throughout. They are one process with nobody at the keyboard.
- **The resume bookmark is not a bookmark.** A `last-prompt` record whose
  `leafUuid` is the parent of a later record looks like the resume marker and is
  the ordinary turn boundary: all 581 transcripts carry one, there are 7970 of
  them mid-file, and 7708 have a later record claiming them. A detector built on
  it fires on every turn.

**Two denominators live in one record, and mixing them is silent.** `runs` is
per run; `messages`, `requests`, `usage`, `tools`, `end_context`, `subagents`,
`day`, `local_day`, `title`, `kind` and `started_by` are per transcript. A
consumer that counts runs and then averages messages divides one by the other
with no warning. Count
sessions by runs, and take a per-transcript field only against the count of
transcripts — 583 runs across 582 transcripts today, so the two differ by one
and every mistake of this kind is invisible until `chat --continue` is used
more.

The per-transcript half is deliberately **not** moved into `runs`, and the
threshold for changing that is written down rather than left to taste. It would
be paid for by either of two things, neither true today: **a figure that puts
money or tokens against a deploy** — "this build cost more per session than the
last" is a plausible thing to want and is unanswerable without per-run usage —
or **`chat --continue` becoming ordinary practice**, since the seam is 1
transcript in 583 only because conversations are rare (7 in 562 sessions).
Reviewed against the nine blocks of `just stats` on 2026-09-06: none of them
reads usage or tools per run, so the sentence above is enough and the reshape
serves no reader.

**There is no duration field, deliberately.** `end - start` on a resumed
transcript reads 8h34m for 3h25m of work — 5h09m of it the gap — and it is the
number a reader reaches for first, because it looks like the answer. A duration
is the sum of `to - from` over the runs, and a run's own is the `awake` of
`just stats --by-session`. `just read` still shows the transcript's span, which
is what it has always shown; it computes it, and it is not stored where
something else could take it for a session's length.

`day` and `local_day` are the transcript's for the same reason `elapsed` is not
stored at all: they date the file, as `just read` heads it, and they are not what
a rollup over runs should bucket on. A run inside a transcript that began the
previous day belongs to its own day, not the file's.

**The run is the unit of everything joined on time.** A record holds `runs`,
one entry per consecutive version, each with its own window, its own commits and
the runner that was live when it started. `7c00b68f` reads as 2h38m and 46m, not
as one block of 8h34m — and the five hours between them belong to nobody.

Attributing over the file's span instead was a real defect, and it produced both
of the things it could:

- **occupancy that never happened.** The span contains fifteen unattended
  sessions, so anything reading it as "this session held the machine" reports a
  conversation running in parallel with fifteen runs. Measured over every run in
  the archive: **no two real sessions have ever overlapped.** The only
  overlapping windows left are `just verify`'s own probes running beside a live
  session, which is what they are for.
- **sixteen commits attributed twice.** They were made by the sessions in the
  gap and landed inside the conversation's span as well. Per run, the archive
  attributes 1018 commits in 1018 attributions — **nothing is counted twice**,
  where over file spans it was 1021 for 1005.

**The count of sessions is the count of runs**, so 582 transcripts hold 583.

Splitting one transcript into two record FILES is a separate question and is not
done: it would need a second filename convention — `sessionId` is one value
across all 444 records and the archive files by `<session-id>.jsonl` — and it
would break byte-identity with all four commands under proof, which show one row
for one file. Nothing is lost by not doing it: the runs carry the count, the
windows and the commits.

The seam detection is **a floor and not a ceiling**: a resume on the same build
straddles no release and shows no version change. A run recorded from a version
seam is a fact; a run inferred from a gap would not be, which is why the gap is
not used.

The seam was found by the session reconciling the archive's session count
against the agent's own journal, and every claim above was re-measured here
before anything changed.

### The runner a session ran under

**Not in the transcript and not recoverable from it.**
`image/system-prompt-template.md` does tell every session "Container built from
runner commit: …", and `entrypoint.sh` exports `{{PREFIX}}_RUNNER_COMMIT` — but
the system prompt is not stored in the transcript. A grep for "Container built
from" across two days of transcripts returns nothing; the only runner shas in
there are the agent's own prose.

It is recovered from the archive's `status` branch instead, by time: 1455
snapshots since 2026-08-24, each carrying `deploy.deployed` and
`deploy.image_deployed`, and the rule is **the latest snapshot at or before the
session's `start`** — the container keeps the image it started with, so start
and not end.

**Read `deploy.deployed`, never `deploy.head`.** `head` is `git rev-parse HEAD`,
main's last commit, which moves whether or not anything was deployed; `deployed`
is `git rev-parse refs/heads/deployed`, the branch `just deploy` resets and
builds the image from. Of the 1022 snapshots carrying the field on 2026-09-06,
**358 have the two differing**, main running ahead of live by up to 16 commits.
The series holds 24 distinct deployed commits since 2026-08-28, each appearing
first at the instant `deployed == head` and then staying put while head runs
ahead — a shape only possible if the field is the deployed branch, and the check
to re-run if this is ever doubted.

Two limits, recorded rather than smoothed over: `deploy.deployed` is **absent
before 2026-08-28**, so earlier sessions get `null`, because nothing missing is
zero; and the ten-minute publish floor means a deploy between two snapshots is
seen up to ten minutes late. `image_deployed` is kept beside the commit because
it is the stronger identity — it would catch the live tag moved onto another
image without the branch moving.

The Claude Code version comes from the transcript's own `version` field and not
from the snapshot's copy: the transcript's is exact and is what actually ran. It
is what a run IS — see "One file is not always one run" — so it sits on the run
rather than on the record, and `runner_commit` sits there with it, because two
runs of one transcript can have started on two images.

### The push a run was built from

**`runner_pushed_at`: when the commit behind this run's image reached origin.**
Asked for by the agent in cairnfield-memory#114, after it measured that a
commit date is not a push date — the two differ by 0 to 97 minutes here — and
that GitHub's own `PushEvent` feed is not a substitute: on its repository 123
of 178 pushes appear, 69.1%, exact to the second where present.

**The instant is measured by `just build` and baked into the image**, not read
where the record is written, because those are two machines: the build and the
push stay on the operator's host and the runs move to the VPS, whose
`refs/remotes/origin/main` will only ever hold fetch entries. `deploy --state`
reads it back out of the image config, the status snapshot carries it, and the
record picks it up through `live_at` beside `runner_commit` — one more value on
a path that already existed rather than a second route to the same fact.

**Only a reflog entry that says `update by push` counts.** A fetch entry dates
the host's pull, and a null is the honest answer where no push entry exists:
the image was built somewhere that does not push, and what ran may never have
reached origin. That state is not hypothetical — `b9cfb1d` was deployed on
2026-09-05 and is in no branch on origin, and once `just deploy` runs on the
VPS itself, a commit arriving there over ssh is the ordinary case.

**A stored value is never recomputed.** Reflog entries expire at 90 days, so a
re-derivation of an old record finds nothing where the first pass found an
instant — and a reseal would then write that null over the only copy, silently,
because a blanked field and a run that never had one look identical. So
`keep_measured` carries the stored value forward run by run, matched on the
run's `from`. `--selftest` holds the case. The reverse does not happen: a null
is computed again, but from the same status snapshot, which never changes — so a
run sealed on an image that predates the field stays null until filled by hand.

**The 639 records that predate the change were filled from `runner_commit`**,
the deployed branch at each run's start, rather than left null — the agent
argued for it and the argument is that a uniformly empty history makes *empty*
mean three things at once, when the one worth reading is *it never reached
origin*. The weaker source was checked before it was used: across the whole
store no run's `runner_commit` is contradicted by its image digest, and the one
digest carrying four commits (`157a1ff10bf1`, under `a66091a`, `d48fac5`,
`fe5afb2`, `8515fb3`) is one image legitimately deployed four times, because
those commits touch nothing under `image/` and the rebuild was byte-identical.

### The wait a session was granted

**Two numbers per run: what the session asked for, and what the next wake-up
actually counted.** `asked_wake_after` is the minutes its closing message asked
to be woken in, raw; `wake_after` is what governed — that ask clamped to the
bounds, or the default wait when there was no ask. They are the run record's own
two fields under the same names, so the two stores speak one vocabulary rather
than two.  see [`docs/schedule.md`](schedule.md#a-session-asks-for-its-own-next-wake-up)

**Neither is in the transcript**, for the same reason the runner commit is not:
the decision is taken by the host after the process is gone, and nothing the
session wrote could know it. Unlike the runner, it is durable nowhere else
either — `~/.cache/<agent>/last-run` holds one run and the next session replaces
it, so the snapshot is the only lasting copy there can be.

**Joined on the session id, never on time.** `publish-status` puts the run
record's `session`, `asked_wake_after` and `wake_after` into every snapshot's
`last_session`, and that id is the transcript's own — the same string the record
is filed under. The join is therefore exact, and a session cannot be handed its
neighbour's numbers by a snapshot that landed between two runs. The **earliest**
snapshot carrying an id wins: every snapshot until the next session starts
carries the same run record, and a later one could be reading a record rewritten
since.

**A transcript resumed by `chat --continue` holds several runs under one id, and
the ask belongs to the last of them** — that is the run that ended where the run
record was written. The others fall back like everything before them.

**The fallback is the default then in force**, `schedule.cooldown` from the
latest snapshot at or before the run's end. That field is `--cooldown N` off the
crontab line until 2026-09-07 and `<NAME>_WAKE_DEFAULT` after it, and both are
one fact: how long the runner waits when the session asked for nothing. Every
session before 2026-09-07 asked for nothing because it could not, so
`asked_wake_after` is null across the whole archive up to then and `wake_after`
is the setting that was live.

**Storing what was in force is not the figure that was struck.** "Nothing is
measured against a setting" below rejected a median gap and a percentage against
*today's* cooldown, both of which read history against a number read a second
ago. This is the opposite: the number that was true when the session ran, kept
beside it, so a later reading never has to reach for the live one.

### The wait before the status branch

The first snapshot is **2026-08-24T17:51Z**, and 102 of the 595 records on
2026-09-07 are older. Those get the wait read off the runs themselves rather than
a null, and it is a reading and not an estimate: **under a wait of N, the
shortest end-to-next-start of a day IS N.** The daily minima are three flat
plateaus with nothing between them — 0.6m on 08-22, 10.1m through the afternoon
of 08-24, 15.2m from 08-25 to 09-02.

Where the reading overlaps the snapshots the two agree exactly, which is what
makes it trustworthy where they do not: the snapshots say 10 at 08-24 17:51Z and
15 from 08-25 00:11Z, and the gaps over those same hours say 10.1–11.3m and
15.2–16.2m.

Backwards from there, `--cooldown` was added by `e9b5f9d` on 2026-08-23 and the
first gap it actually spaced is the 15.4m at 15:54:02Z. Everything up to the run
that ended at 15:38:39Z ran with **no wait at all** — 0.6m, 3.4m and 137m sit
side by side there, which is a schedule being switched on and off rather than a
cadence. Zero is stored for those, and zero is a real setting: `null` is what a
reading that could not be made looks like, and the two must not be one value.

`BEFORE_SNAPSHOTS` in `host/monitor/session-records.py` is the whole table — two
instants and their minutes. To re-measure it: group every record's runs by UTC
day and take the smallest positive `next start − this end`.

### The machine a run ran on

**`system`, on every run: what the host was doing over that run's own window.** It
answers one question — does the agent need more resources — so it covers the run,
`from` to `to`, and not the collection after it, which is the runner's cost. The
samples are the ones `host/lib/sampler.sh` has `sadc` write while a session runs
(`RUNNER_SAMPLE_SECONDS`); `host/lib/sysstat.py` reads them back; `just status` and
`just stats --system` show them, as numbers nothing judges.

| fields | what they say |
| --- | --- |
| `interval`, `samples` | how much of the run was seen: `samples × interval` against `to − from`, so a partial window is not read as a calm one |
| `cpus`, `mem_mb` | the denominators, from the same file, so a resize does not reinterpret history |
| `cpu_busy_*` | how much of the CPU was used, `100 − %idle` |
| `load1_*`, `psi_cpu_*` | whether work queued for the CPU. PSI `some`: on one CPU the load counts disk waits too |
| `steal_*` | whether the provider took CPU away, which nothing else shows |
| `iowait_*`, `psi_io_*`, `disks` | whether the disk was the bottleneck. PSI `full`: every runnable task stalled at once |
| `avail_min_mb`, `swap_in_mb`, `swap_out_mb`, `psi_mem_*` | whether memory ran short. PSI `full` again |
| `filesystem` | whether the disk is filling: `free_start_mb` across runs is the trend, `free_min_mb` the low point inside one |

**`null` is not measured, never a quiet machine**: the sampler was off, sysstat is not
installed, or the run is older than 2026-09-10 12:25 local, when sampling began.
`filesystem` alone is `null` for a day whose file was started before the sampler
collected filesystems, and when docker did not say where its root is. `sadc` appending to
a file keeps the activities that file began with — measured 2026-09-10, `-S XDISK`
appended to a `-S DISK` file adds no `-F` — so the day of the switch has no free space. No sealing condition comes
with it: the sampler is still running when a session end seals, so the window is whole.

**Mean and p95, never the max.** At 5 s a max is one sample. Over the 742 samples the
VPS took on 2026-09-10:

| column | mean | p95 | max |
| --- | --- | --- | --- |
| %iowait | 4.92 | 35.35 | 83.61 |
| %util, all devices | — | 11.74 | 95.72 |
| await ms, all devices | — | 6.11 | 258.58 |
| pswpout/s | 24.64 | 0.00 | 3603.60 |

**Read by timestamp, never by `sadf -s/-e`.** Those take a time of day: a run across
midnight is cut in two, and a month later `saDD` is another day under the same name.
`sadf -U` prints epoch seconds, every file the window's days name is read in both
clocks, and a sample is kept by its own timestamp.

**Swap is the pages moved, not `kbswpused` end minus start.** A burst swapped back in
leaves no delta. Over one 30-minute window that afternoon, 185 MB went out and 107 MB
came back.

**`disks` holds whole devices that did I/O.** With `-S XDISK`, `sda1` is listed beside
`sda` with the same I/O and would count it twice; `loop*` and `sr*` are dropped too.
`await` is taken over the samples where the disk had I/O, since an idle interval
reports 0 ms.

**`filesystem` is the one holding Docker's root dir**, which holds the images and the
agent's volume: the longest `sadf -F MOUNT` mount point that prefixes
`docker info -f '{{.DockerRootDir}}'`. Free space ran short on that host before — 2.4 GB
of stale collection copies with 4.5 GB free, on 2026-09-10.

**A stored summary is never blanked.** The daily files are replaced a month on, so a
`--recheck` or `--reseal` after that finds none of a run's samples, or, for a run across
a midnight, half of them. `keep_measured` keeps the stored `system` run by run whenever
it holds more samples than the re-read, as it keeps `runner_pushed_at`.

Measured 2026-09-10 on sysstat 12.7.7: `sadf` asked for an activity a file does not
hold exits 0 and prints the others, so one call serves files from before `-S XDISK`;
`sadf -H` carries the CPU count as `(1 CPU)`; PSI is in `sadc`'s defaults. To look at
one window by hand, on the host that ran it: `host/lib/sysstat.py <from> <to>`. To
re-measure a column: `sadf -d -U ~/.cache/<agent>/sysstat/saDD -- <activity> | grep -v
'^#' | cut -d';' -fN | sort -g`, and read the mean, the line at 95% and the last.

### Reseal is the exception to written-once

A record is written once, and `publish_records` enforces it: a commit that
modifies a file rather than adding one is refused, naming `--rewrite` as the one
way. That is what keeps `cache` a branch of additions — git stores whole blobs,
and a store rewritten on every run would push the whole of itself each time.

**A field added to the record after most of it was written is the case that
cannot satisfy it.** `just records --reseal` is that path: it writes exactly what
`--recheck` reports as differing and leaves every record that already matches on
the disk it is on, so the push carries only what moved. Never on a schedule and
never on a session end — it is asked for by name, and `--recheck` is its
rehearsal.

### What a usage row is keyed by

`(model, speed, geo)`, and not by model alone. `dollars()` in
`image/session-cost.py` prices from all three: `usage.speed` selects a separate
table — opus output is 25.00 standard and 50.00 fast — and
`usage.inference_geo == "us"` multiplies every category by 1.1. Both are
per-request fields, so two requests on one model can price differently.

Measured across the whole archive on 2026-09-06, `speed` is `standard` (52 681
requests) or absent (414) and never `fast`, and `geo` is `not_available`
everywhere — so **no multiplier applies today**, which is exactly why keying on
model alone would look correct indefinitely and then be silently half-price the
first time a session runs on fast mode, which is one toggle away. It costs
nothing to key it right now: the rows collapse to one per model while these stay
uniform.

**The rates that produced a price are stored beside it.** `PRICES` carries no
version marker of any kind, so a stored price with nothing beside it cannot be
audited, re-derived, or told apart from one computed under different rates —
"a stale price prints in exactly the same shape as a current one" is that file's
own warning. With the rates inline a record is self-contained, and the two
questions a reader might have are both answerable from it: what it cost under
the rates in force then is `usd`, and every session on one ruler is a re-pricing
of the components against today's table, with no transcript re-read. It is also
what lets the published records carry cost at all — `session-cost.py` lives in
this repository's image and `render.py` runs in CI inside the archive checkout,
where it cannot reach it.

A model the table refuses keeps its requests and its components and gets no
rates and no price. Dropped instead, an unpriced session would look exactly like
a cheap one, which is the failure that file refuses by design.

Whatever shows money says what it is: API list rates for the same traffic, not
money spent, and it does not convert into the subscription's allowance.

### The two output figures

A record carries `output` and `output_reported`, and they are two facts rather
than two spellings of one. `output` is what was consumed: a request that fell
back carries an `iterations` array whose first attempt was really billed and
which the top-level usage omits, so the iterations are summed.
`output_reported` is what that top level states, which is the figure
`session-meta.jq` reads and therefore what `just read` shows today.

They differ on **2 of 579 sessions** in the archive on 2026-09-06, by 1452 and
672 tokens — the only two requests that have ever fallen back. Keeping one of
them would have made either `just cost` or `just read`'s header unreproducible from
the store, and picking which to break is not the store's call.

### Sub-agents, and the two counts that disagree

`subagents` is **what actually ran**, one entry per `<session>--agent-<id>.jsonl`
beside the transcript. `agent_calls` is **what the main chain asked for**, from
the `Agent` tool calls' `input.subagent_type`. Neither is derived from the
other, because they disagree — 28 transcripts against 24 calls on 2026-09-06,
and by type 17/10/1 general-purpose, Explore and claude-code-guide by transcript
against 16/6/1 by call, with one call naming none. Sub-agents spawned by
sub-agents land on the transcript side and never on the call side, and so do
calls whose parent transcript the gate is holding. Recording one and deriving
the other would make a real disagreement invisible.

There is **no link back to the spawning call, and this was checked.**
`sourceToolAssistantUUID` looks like one and is not: all 436 distinct values in
the archive's sidechains resolve to uuids inside the sidechains themselves, and
none to any main-chain record. The two lists can be counted side by side and
never joined. Do not spend time re-deriving this.

A sub-agent carries its own usage, its own tools, its own MCP calls, its own
denials, its own end context and its own effort. Blended into the session's,
delegation disappears and "the session ran 40 Reads" stops meaning anything —
and the context especially, because every agent has a context of its own and a
sub-agent's is a separate measurement rather than a share of one.

**A sub-agent can be on the branch while its session is not.** It is collected
when it finishes and the conversation that spawned it runs on: one on 2026-09-03
sat there for sixteen hours. The store has no record for it, because it is not a
session, until its session lands — so `just cost` and `just tools` count it once
that session has ended, and not before.

### Tool calls are bucketed by the call's own UTC day

`just tools` counts a tool call on the day it happened, and a session running past
midnight lands on both sides. A flat `{name: count}` per session would put every
call on the session's start day and change what it reports. Measured on
2026-09-06: **9 of 579 sessions have tool calls on more than one UTC day** — so
nearly every session is a single bucket, and this costs one nesting level and
nothing else.

`denials` counts `toolDenialKind`. Over the whole archive on 2026-09-06:
`automode-blocked` 167, `user-rejected` 96, `permission-rule` 59, and
**`automode-unavailable` 2** — the last being a call the classifier could not
answer for in time, which is counted as a denial because the call did not run.
Nothing else on this machine counts it.

### cwd and the branch are taken from the opening row

`cwd` and `git_branch` are the **first** non-null in the transcript; every other
state field is the last. Both follow a Bash `cd`: a session that clones another
repository into `/tmp` to read it carries that repository's `cwd` and branch for
as long as it is there, and `gitBranch` lags `cwd` by a few rows on the way back,
so the last row can pair the agent's own checkout with a foreign branch.

Measured on 2026-09-09 over the 669 archived transcripts: **first and last differ
in exactly one**, and that one is the fault. Record `e5315869` stored
`git_branch: "cache"` — a branch of the archive repository, cloned to
`/tmp/arc-cache` — for a session that worked on `main` throughout and committed
to `main`. Its 252 rows carrying a branch: 85 `/tmp/runner-read`, 76
`/tmp/arc-cache`, 69 the agent's checkout, 14 `/tmp`, and the last 8 on `cache`,
of which the final 3 are back in the checkout. Six transcripts did change branch
inside the agent's own repository (the `rules-rewrite` work of 23–24 August) and
every one of them ends on the branch it opened on, so the case last-non-null was
written for has never once produced a different answer.

Filtering the rows to the session's own directory does **not** fix it: the three
lagging rows have the right `cwd` and the wrong branch. Only the opening row is
taken before anything can have moved.

The volume cannot answer this. It holds one HEAD — whatever the most recent
session left — so it says nothing about a session that ran three hundred sessions
ago, and reading it at all needs a container with a home of its own while a real
session may be running. A hook can: measured the same day, a **Stop** hook's
stdout lands in the transcript as an `attachment` row of type `hook_success`
carrying `hookName`, `hookEvent`, `content` and `stdout`, and a **SessionEnd**
hook's output does not appear at all — it runs after the file is closed, which is
why `push-on-exit.sh` reports through `ERROR_ON_PUSH` and not through anything a
reader of the transcript could see. That route was not taken: it would put a
monitoring field into `image/managed-settings.json`, which is a boundary file,
and write a row per turn for a field no command reads.

### The commands that read the store

`just stats`, `just tools`, `just cost` and `just journal` read the records and no transcript,
wherever `host/lib/store.sh` finds them. `just read` does not: it shows one
transcript whole, so it reads that transcript anyway, and its header comes from
the same bytes through `host/archive/session-meta.jq`.

`tools` and `cost` moved onto the store once it was shown to carry everything
they print. Measured 2026-09-11 over 684 records: each command, run against its
own output from the transcripts across every window shape, session ids and
refusals, printed the same bytes, save the line naming where it read from. The
proof that had diffed them, `just records --prove`, went with nothing left to
compare. `just records --recheck` stays: it rebuilds every record from the
transcripts and diffs it against the stored one, which is the guarantee on the
data itself.

## The stats screen

`just stats` is one screen answering "what has the agent been doing, and is that
changing". It reads the sealed records and nothing else — no transcript, no jq
filter, no volume — and one fact from outside them: which build is live, from
`just deploy --state`, along with the agent's newest journal heading from this
host's clone of its repository. Neither is required; the screen renders without
either and says which line did not run. There is nothing in `.env` to set.

The records are sealed on the machine that runs the agent. When that is another
machine (`RUNNER_DEPLOY_HOST` set), `host/lib/store.sh` fetches the archive's
`cache` branch and reads its `records/` instead of the local store, which nothing
there writes — for `stats`, `tools` and `cost` alike.

`host/monitor/stats.sh` is the front, because the store may not exist yet and
that is a state with a command that fixes it; `host/monitor/stats.py` is the
arithmetic and the screen.

| handle | what it does |
| --- | --- |
| `just stats` | the screen, over everything the records hold |
| `just stats -d N` | over the last N **whole** days, ending yesterday, with ⌈N/7⌉ rows in the weekly table |
| `just stats --all` | a row for every day of the window rather than the last seven |
| `just stats --system` | the machine day by day, in place of the tables about the agent |
| `just stats --by-session` | one row per session, newest first, in place of the tables about the days. `--all` lists every one |
| `just stats --day D` | the sessions of one local day, listed — `08-26` or `2026-08-26` |
| `just stats --system --by-session` | the machine run by run, over the runs the sampler saw |
| `stats.py --selftest` | the speller, the periods, the shapes. In CI |

### What every number counts

**The unit is the run, and the transcript never appears on screen.** `chat
--continue` appends to the file it resumes, so one archived transcript holds two
runs today and the screen reports 7 chat sessions over 6 files without
remarking on it — carrying a reconciliation that should never recur is noise on
every future run of the command.

**Two denominators live in one record and mixing them is silent.** `runs` is per
run; `messages`, `end_context`, `usage`, `denials` and `subagents` are per
transcript. Every per-transcript figure is a mean over the count of
**transcripts**, never over the count of runs. The two differ by one today, so a
mistake of this kind shows up in no number at all.

**Durations are `to - from` per run, never `end - start`.** The one resumed
transcript spans 8h 34m for 3h 25m of work, with fifteen unattended sessions
inside the gap.

**`started_by` is what separates a session from a probe**, and nothing else can.
See "A probe is not a session" above.

**`awake` is every session, and the detail names the parts.** The screen once
said `115h 40m awake` in one section counting unattended runs only and `69h 51m
awake` in another counting every run, neither stated. The split is on the line
now — `128h 05m awake · 116h 33m unattended, 11h 31m chat` — and the per-session
mean is unattended only, on a line of its own, because a conversation averages
99 minutes against 12 and would swamp it.

**Everything else in the daily and weekly tables is unattended**, so a
conversation cannot swing a column on the two days one happened.

### The periods

**A period is whole days and today is never in one.** Today is a few hours old
and the days beside it are twenty-four; on one list they read as comparable and
the newest row is always the low bar. Today has a row of its own below a break,
labelled with the clock — `today, up to 02:41`, which reads the same at any
hour — and it is drawn whatever the window is, being an addendum that belongs to
no period.

**`-d N` is N complete days ending yesterday.** Counting back from today spent
one of the N on however many hours today had lived, so `-d 14` covered thirteen
days and a morning and the weekly table showed one row where two were asked for.

**The default window runs to today, not to the last day a session ran.** A day
the agent did not wake is still a day, and every day gets a row including the
ones nothing ran on: a day missing from the table is indistinguishable from a
day nothing happened on, and the second is the one worth seeing. An outage reads
as rows of noughts with the hours showing as the longest it went without a
session.

**Awake and asleep close on the period exactly.** Midnight to midnight over the
complete days the table shows, so seven days is 168 hours and `awake + asleep`
is 168 hours, checkable against the dates on the rows. `asleep` is everything in
the period that is not a session — not the sum of the gaps between them, which
is short by the time before the first and after the last. A session crossing
midnight is clipped at the boundary. The period ends at the last complete day
and never at `now`: the records know nothing of a session running, so a period
reaching to now would count its minutes as sleep and could name them the
longest. **A silence that began today is therefore in no figure here**; `just
status` answers for the current moment.

**Every weekly row is seven complete days or it is not a row.** The table is
read down a column, so rows of different length cannot sit under one heading —
it once compared 6 days and 2 hours against a full week against the 3 days the
archive started with, and the newest row read 209 sessions where seven whole
days held 242. A week the archive does not cover in full is dropped rather than
shown short, and rows carry their dates.

**"What it ran on" is not windowed.** The three sections above measure activity
and are windowed; this one is the build lineage, and no `-d N` changes which
build is live or how much has run on it. Windowed, `-d 14` ended yesterday, took
today out, and reported the build that went live this morning as carrying
nothing — which is the sentence a genuinely fresh build gets, and then not
distinguishable from it. It read `4 deploys since 09-06` under `-d 1`, as though
there had only ever been four. `deploy` takes the records rather than a window,
so there is no window to pass it wrongly.

**No block grows without bound.** The daily chart is seven rows and the weekly
table four, and neither gains a row as the archive ages. `--all` is a reader asking
for every day of the window, and is not that.

### Nothing is measured against a setting

**`--cooldown` is config, not a measurement, and no figure on this screen is
built on it.** It decides how long the agent waits between sessions; it was 15
minutes, it is 20, and it can be 30 tonight. Two figures were built on it and
both were struck:

- **A median gap is the setting read back off the screen.** Under `* * * * * just
  run --cooldown N` the interval is N plus the container's teardown and the next
  one's boot, so the line printed `median gap 20m` beside a `--cooldown 20`.
- **A percentage against today's cooldown is worse, because it looks like a
  measurement.** `+7% on the 20m cooldown` compares seven days of history
  against a number read a second ago; raise the cooldown to 30 and tomorrow's
  screen reports −30% with nothing changed but a crontab line. The operator's
  ruling, 2026-09-07: *"it's config, not stat, you cannot use that number for
  anything"*.

**The share awake is the measure.** It falls when sessions stop running whatever
the cooldown is, and it needs no source outside the records.

One measurement worth keeping, because it will be re-derived otherwise: **a
median is not an average, and "the time between two sessions" has two readings.**
Over the last 7 days, end-to-next-start was 20.4m median against 21.4m mean, and
start-to-next-start 36.4m against 41.3m. One pause moves the mean and not the
median, and the agent's own journal reports a higher number than this screen
ever did without either being wrong.

### The count spelled out

The opening line prints our count in words — `<agent> stands at its
five-hundred-and-sixty-ninth session.` — and the agent's own journal headings
carry the same number in the same idiom, so **the two agreeing is a check that
costs nothing**. It is silent when they agree. On a mismatch it prints the
heading and says which is which: **ours is the count, its heading is a label it
maintains** — the heading was wrong by 34 for eleven hours on 2026-09-01 with
nothing able to say so.

**Compare by rendering, never by parsing.** There is no words-to-integer parser:
the count is spelled out and the heading tested for that exact string, so the
comparison cannot drift from the line printed above it.

**The idiom was measured rather than guessed.** The journal on 2026-09-07 held
522 distinct spellings across 756 headings and `spellings()` reproduces 521 of
them; the miss is `(last session)`, not an ordinal. It found the thing a
hand-written speller gets wrong: **the agent drops the leading `one` below a
thousand** — `hundred-and-first`, never `one-hundred-and-first`, in all 86 of the
spellings it has used between 100 and 199. Above a thousand both forms are
accepted and only the shorter printed, because which it reaches for is its
choice and an alarm that cries wolf is one nobody reads.

**A journal that cannot be read is not agreement.** The line says the check did
not run, and why.

**The heading comes from the agent's own repository, not the mirror.**
`stats.sh` fetches it into a bare clone at `$RUNNER_MONITOR/memory` before the
screen is drawn. The mirror is advanced by a workflow on GitHub's best-effort
schedule, and a count checked against it would report that lag as a wrong
heading.

### The shape of the screen

**Four titled sections**, in the order someone opens the screen to read them:
what it has done in all, what the last week looked like, whether that is
changing, and what it ran on. Nine blocks at one weight with no grouping is a
page with no way in.

**Inside a section a fact is a headline number, then its detail on the same
line.** Every line opens with a number and a noun, so a section is scanned
rather than read, and everything after the gap belongs to the figure before it.
A breakdown wraps between items, never inside one.

**The grammar is `host/lib/screen.py`, and `just status` is written in it too.**
The heading, the headline-number-then-detail line, the `115h 40m` duration and
the reader of the record store live there and are imported by both: a second
copy of `fact` would be the one that starts wrapping differently, and a reader
who has learnt one screen has learnt the other.

**A table only where the rows are compared with each other** — the days and the
weeks — which is the one thing a table is for.

**The bar is time awake, not a count of sessions.** How often it woke is mostly
`--cooldown`; how long it worked is the work. Two days here ran 35 sessions each
and differed by two and a half hours, which a count cannot show. The seven bars
sum to the `unattended` half of the awake line beneath them.

**Colour carries nothing** and neither does weight: the operator is deutan
colourblind, and a pipe or a file has to carry the same structure a terminal
does. Bar length is the only figure. `zebra` is not used — it exists so a row
can be followed across ten columns, and the widest table here has seven.

**A duration is written `115h 40m`, with the space.** At a terminal's stroke
weight `h` and `4` are the same mark, and `115h40m` has to be parsed rather than
read.

### Money

The header sums each session's own `usd` **plus its sub-agents'**. The record
stores no total on purpose, because "what a session cost" means either the main
chain or the main chain plus what it delegated to; this is the second, and
sub-agents are $27.78 of $2532.

The weekly `$/session` column **re-prices** each session's stored components
against today's table rather than summing what is stored, so a column comparing
weeks across a rate change is one ruler rather than two. A model
`image/session-cost.py` no longer holds keeps its stored figure and is never
priced as zero.

`image/session-cost.py` is the only price table; `stats` restates no rate.
Whatever prints money says what it is: API list rates for the same traffic, not
money spent, and it does not convert into the subscription's allowance.

### Session by session

**`just stats --by-session` lists the sessions newest first, one row per run**, below
section one and in place of the tables about the days. Each row carries the first eight
characters of the session's id, which is what `just read` takes. The newest 20 unless
`--all`; `-d N` narrows the window and still lists today's; `--day D` is a window of one
local day, lists all of it, and is refused beside `-d`.

**A resumed transcript is one record and two rows.** `awake` and `commits` are each run's
own. `msgs`, `ctx+out`, `+N` and `$` are the transcript's, and are printed on its newest
listed row only: printed on both, a sum down a column counts them twice.

**A probe is not listed**, and neither is a session collected but not sealed yet — the
minutes between `collect --push` and its record, or what `just status` counts as
`RECORDS_NOT_SEALED`. `just read <id>` still reaches it, from the archive or the volume.

On a terminal the table goes through `less -FRX`, paged when it is longer than the
screen; a pipe or a file gets every line whole.

### The machine

**`just stats --system` shows the machine day by day in place of the tables about
the agent**, and section one carries a `% cpu` line with or without the flag. Both read
the `system` summary each run carries — "The machine a run ran on", above — and nothing
else.

**Every kind of run is counted, chat included.** The question is whether the machine is
big enough, and a conversation runs on the same one.

**A day's row joins its runs.** `cpu` is the mean weighted by samples; `load95` and
`io95` are the worst session's p95, because percentiles do not add up; `mem MB` and
`disk MB` are the lowest free; `swap MB` is what was swapped out, summed. A day nothing
was measured on is a row of dashes, as every day table here draws a quiet day, and
`-d N` and `--all` work as they do on the default screen.

**The table counts the sessions that were measured.** `sessions` and `awake` keep the
words the rest of the screen uses, so on a day the sampler missed some runs they read
lower here than on the default screen; the `% cpu` line above says how many of the
window's sessions were measured.

**`--system --by-session` is the machine run by run**, each row from that run's own
summary with nothing joined: `cpu` its mean, `load95` and `io95` its p95, `mem MB` and
`disk MB` its lowest free, `swap MB` what it swapped out. A run the sampler did not see is
not a row. There is no `kind` column: every kind runs on the one machine, and with it the
row passes the screen's 78 columns. The cap, `--all`, `-d N` and `--day` work as on
`--by-session`.

**Nothing is judged.** No threshold and no marker: what normal is on this machine has not
been measured, and the operator reads the numbers.

### What the screen does not show

Each was drafted and struck. The reason is here so it is not re-proposed.

`334 refusals — 167 automode-blocked, 105 user-rejected, …` was removed on
2026-09-07 and is **not** in the table below: the operator wants something shown
for tools and is deciding what. The `denials` field is in every record and
nothing reads it.

| | why |
| --- | --- |
| a median or mean gap between sessions | it is `--cooldown` plus a minute of teardown and boot, so it reports the crontab back to the operator |

| `28 sub-agents from 24 calls` | the disagreement between `subagents[]` and `agent_calls[]` is real and unjoinable, but it is a curiosity rather than a signal |
| `N ran to fewer than 4 messages` | the archive holds only sessions that changed state, so the line can only report zero |
| `N% of unattended sessions committed` | same reason. `1.9 commits a session` stays, being a distribution rather than a proportion of a curated set |
| any transcript-versus-run count | the unit is the run; saying so on every run is noise about an anomaly that should not recur |
| the journal counted against the archive | it counted a three-day mirror outage as forgetting and the 2026-08-25 compaction as omissions, and cannot tell either from a real gap by counting alone. That corpus belongs to the drift audit, which reads it with an agent |
| an hour-of-day or weekday histogram | cron decides it; it would report the operator's own crontab back to them |
| a cost breakdown, or `--by-day` | `just cost` and `just tools` own those |
| a session's title in `--by-session` | nearly every unattended session is titled "Session start routine"; the id identifies one, and `just read` shows the title |

### A build that just went live has carried nothing

The deploy section names the build `deploy --state` calls live, not the newest
one the records have seen: right after a deploy those differ and the live one
has zero sessions against it, which is the state the block most needs to show.
With no answer from `deploy` it falls back to the newest seen and does not call
it live.

231 runs carry a null `runner_commit`, and that is correct rather than missing:
`deploy.deployed` appears in the status snapshots only from 2026-08-28, because
before that a build *was* a deploy. The clause saying so goes once those runs
age out of the window.

## The journal, entry by entry

`just journal` shows the agent's `JOURNAL.md` one entry at a time, newest first. Under each
heading is the session that wrote it — when it ran, unattended or a conversation, how long, how
many commits — and the `just read` line that opens its transcript. `→` opens the older entry, `←`
the newer, and `q` quits. Inside an entry everything `less` does works, and past its last line is
`(END)`, not the next entry. `just journal 2026-09-03` opens that day's newest entry, and
`just journal <id>` the entry a session wrote. Piped, it prints every entry whole and plain, or the
one asked for. There is nothing in `.env` to set.

It reads the clone `just stats` fetches from the agent's repository, so an entry is there once its
session has pushed, and the records wherever `host/lib/store.sh` finds them.

### Which session wrote an entry

The one that made most of the entry's lines: `git blame` on `source/main`, with each line's commit
looked up in the records' `runs[].commits`. Measured 2026-09-12 on 688 entries against the records
on `origin/cache`: every entry attributed, and the heading's date is the session's day for all 688.
The rules that look simpler each fail without a symptom:

| rule | what it did |
| --- | --- |
| the commit that added the heading | put 518 entries on one commit: on 2026-08-31 a session rewrote every older heading |
| the entry's oldest line | put 6 entries on another session, each through a single line out of 34 to 105 that blame matched to an older entry, 3 of them on an earlier day |
| the `(Nth session)` in the heading | a label the agent maintains, wrong by 34 for eleven hours on 2026-09-01 — see "The count spelled out" |

A folded entry belongs to the session that folded it: the 2026-08-25 compaction session holds two
entries, its own and the fold of sessions 102 to 115, and each says which of the two it is.

An entry no record holds says so, and names `just records`: a session whose record is not sealed
yet, most often.

There is no count of the sessions between two entries that wrote none. Over the 688 entries it
fired twice, and one of the two was that fold reading as fourteen silent sessions — the fault "the
journal counted against the archive" was struck for, under "What the screen does not show".

### One `less` per entry

`less` over the whole file jumps from heading to heading with a search and stops nowhere, which is
why this exists. Each entry is written to a file of its own and opened in a `less` of its own.
`host/monitor/journal.lesskey` binds the arrows to `quit` with a status — `quit r` exits 114 and
`quit l` exits 108 — and the loop in `host/monitor/journal.sh` opens the neighbour; `q` exits 0 and
ends it. Each arrow is bound in both encodings a terminal may send, `\e[C` and `\eOC`. Binding an
arrow to `forw-search` with the pattern as its extra string does not work: the prompt opens and is
never submitted.

`LESS` is emptied for it, because a `-F` there would close every entry shorter than the screen as
it opened.

Measured with less 668 on 2026-09-12, in a pty and in Windows Terminal on WSL. After a `less`
upgrade, run `less --lesskey-src=host/monitor/journal.lesskey README.md; echo $?`, press `→`, and it
prints 114.

## The audit clone is reconciled, not assumed

`sync_clone` set the remote and the refspecs only when it created the clone, and
fetched on every run after. That was fine until the mirror changed repository —
out of the archive, so the machine that runs the agent could not rewrite the
record that audits it — and a clone made before the move went on fetching the
old place. It reported a mirror that was correct, from the wrong repository,
and would have kept doing so until the day those refs were deleted there.

So both are now checked on every run and rewritten when they differ. The
repoint says so on stderr rather than happening quietly: a clone that was
reading somewhere else is worth one line.

The refspecs are **replaced**, not added to. `--add` is what left three
generations of tracking refs in this clone — `mirror/cairnfield`,
`mirror/rewound/*` and `mirror/source`, two of them from shapes no refspec has
named for months. `git fetch --prune` does not reach them: it prunes only
within the destinations its refspecs name, so a ref left by an older shape
survives every prune and reads as current. They are cleared when the refspecs
change, and the fetch that follows puts back whatever still exists.

Measured 2026-09-09 on the real clone: remote repointed, two refspecs rewritten,
four tracking refs cleared, and `mirror/source` moved from a tip four months
stale to the current one.

## Every host needs `just setup-gh`, including the only one

The clone `just mirror-status` reads is fetched over **HTTPS**, so that one
credential covers both halves of what a host does with the mirror: reading the
record, and asking it to refresh. Over ssh the fetch would want a deploy key of
its own — a second secret, on the machine that is meant to hold as little as
possible.

The cost is that git needs a credential helper before it can fetch anything, and
`gh auth setup-git` is what installs one. That is not a remote-host concern: an
installation with a single machine needs it too, or `mirror-status` reports a
fetch failure that reads like a network fault. `just setup-gh` does it, proves
the fetch afterwards, and says which of the two is missing when it fails.

What it checks depends on the machine, and only in one direction. Everywhere: the
token reads the mirror, and git can fetch it. On a host carrying
`RUNNER_RUNTIME_ONLY` — the one that runs the agent — also that the token
**cannot write a ref there**, which is the property the whole split exists for.
Where the code is edited, writing is expected: that is where `setup-mirror` runs
from, and the operator's own credential is what installs the workflow's.

## Only a write attempt tells the tokens apart

`gh api repos/<owner>/<repo> --jq .permissions` looks like the check and is not:
that field is the **user's** role on the repository, so on one you own it reports
`admin: true` whatever the token may do. Measured 2026-09-09 — it said
`push: true` for a fine-grained token that could not create a ref.

The honest question is whether an act succeeds. `setup-gh` posts a throwaway ref
and reads the answer: a 403, `Resource not accessible by personal access token`,
is the pass. When it succeeds the ref is deleted again, and the recipe refuses
to finish.

`setup-mirror` asks the same of the status page's token before storing it on the
archive: the machine that runs the agent can push a workflow to the archive's
`main`, and a workflow there can spend any secret the archive holds. Both call
`mirror_cannot_write` in `host/lib/mirror.sh`.
