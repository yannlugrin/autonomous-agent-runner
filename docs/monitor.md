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
| `just cost` | what the archived sessions cost, priced from their own transcripts. `--by-day`, `-d N`, or session ids. API list rates: weight, not an invoice |
| `just tools` | how many times each tool was called, per day, in the archived transcripts. Name tools to get one line per day instead; `-d N` for the window |
| `just records` | one durable record per archived session — what it was, what it spent, what it committed, which runner built it — sealed once and published to the archive's `cache` branch. Nothing reads them yet |
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
volume outside the repository, and anything the hourly mirror did not catch
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
    monitor/memory/              the agent's repository itself, bare, fetched by
                                 `just records`; see below for why they are two
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

`just cost` prices the archive's `sessions` branch: one line per session over
the last day, `--by-day` for one line per day over the last ten, `-d N` to
widen either, or session ids to price those wherever they sit.

## just tools

`just tools` counts tool calls in the same transcripts, from each call's own
timestamp in UTC: one line per tool and one column per day, heaviest tool
first, over the last five days that carry a call. Name tools, `just tools Bash
Edit`, and the table transposes to one line per day and one column per named
tool over the last ten; `-d N` sets the window in either shape, and a named
tool that was never called in the days read is said so on stderr rather than
shown as a column of zeros in silence. It reads one day's directory beyond the
window because a session filed under one day can hold calls stamped the next.
It came from the monitoring repository this directory replaced, where it was
the one recipe the folding of 2026-09-02 missed; brought over 2026-09-04.

It calls `image/session-cost.py` and carries no rates of its own. That is the
whole of the overlap rule with `just status`, which prices the one session that
just ran out of the volume: two questions, two commands, one price table. A
second copy of the table drifts the day rates change, and both copies go on
printing numbers that look equally right.

The figure is what the same traffic would have cost at published per-token API
rates. Nothing here was invoiced — this account is a subscription, which is not
billed per token and has no published conversion into its allowance. It is
weight, for comparing sessions against each other in one unit, never an
invoice.

The day is the archive's, which is UTC: a transcript is filed under the UTC day
of its own first timestamp and the pricing tool dates a session the same way,
so a day directory holds exactly one day of sessions. `just sessions` is where
the local day lives, and it says so when the two differ.

Sessions are staged as files rather than piped, because a sub-agent is priced
into the session that asked for the work and the archive says which one that is
in the filename — `<session>--agent-<id>.jsonl`. A stream of concatenated
transcripts loses exactly that.


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
| `just records --prove` | run the four commands that will one day read the store, render the same output from the records alone, and diff |
| `just records --no-publish` | write them here and push nothing. For looking at the store without touching the archive |
| `RUNNER_RECORDS_DIR` | where they live — `~/.cache/<agent>/records/` unless set |

Nothing reads them yet. `just sessions`, `just read`, `just tools` and `just
cost` still derive everything from the raw transcripts on every call, and each
becomes a renderer over this store in a later, separate piece of work; `just
stats` is a third piece again. Until then the store's one obligation is that it
will be **enough** when that happens, which is what `--prove` is for.

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
| every run's `commits` and `commit_stat` | the agent's repository was **fetched later than** the transcript's `end` |
| `runner_commit`, `runner_image` | a `status` snapshot exists with `generated_at` **later than** the session's `start` |

**All three hold the moment a session ends**, which is why the session end is
where this is called and not a schedule of its own. `just collect --push` has
put the transcript on origin; the container's exit hook has pushed the memory
and `sync_memory` fetches it; `publish-status --now` has just written a
snapshot. Nothing is waited for.

The last two are exact rather than a wait. A fetch that happened after a session
ended has every commit that session made, whether or not the agent has committed
since — which is the whole reason the source is the repository and not a copy of
it. And once a snapshot exists after a session's start, the latest snapshot at
or before that start can no longer change.

**What holds a record back is named, never counted.** `just records` prints
which condition each waiting session is on and when that source was last read,
because a store that quietly stopped sealing looks exactly like one with nothing
left to do.

`~/.cache/<agent>/records-state.json` records what the sealing was done
against: the three sources, and when the agent's repository was last read. It
stays on this host and is not published — the branch is written once per file,
and this is the one file that would change on every run.

### The commits come from the agent's repository

Not from the archive's mirror of it, and this is the difference between a record
that is current and one that is as current as a workflow managed to be. The
mirror is refreshed by an hourly GitHub Action on a best-effort schedule: on
2026-09-06 it had been failing since the 3rd, was 245 commits behind, and a
third of the archive could not seal against it. `sync_memory` in
`host/monitor/clone.sh` keeps a bare clone at `monitor/memory/` and fetches the
agent's repository directly, at the moment the record is written. Read and never
written — rule 2 is about writing, and `just drift-audit` already reads the same
remote.

That also simplifies the sealing rule. **The condition is that the fetch
happened after the session ended**, taken from `FETCH_HEAD`'s mtime, and it is
exact: everything that session committed is then present whether or not the
agent has committed since. Against a mirror the only answerable question was the
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

An earlier attempt using the time `just sessions` displays left 141 commits
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
shortness is not a rule. `cwd` looks like a discriminator and is not: its two
values are `/home/cairnfield/cairnfield` and `/home/cairn/cairn`, which is the
agent's earlier name and a real session either way.

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
is the sum of `to - from` over the runs. `just sessions` and `just read` still
show the transcript's span, which is what they have always shown; they compute
it, and it is not stored where something else could take it for a session's
length.

`day` and `local_day` are the transcript's for the same reason `elapsed` is not
stored at all: they are what `just sessions` buckets on and they are not what a
rollup over runs should bucket on. A run inside a transcript that began the
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
it is the stronger identity — it would catch a `just build --deployed` that
moved the image without moving the branch.

The Claude Code version comes from the transcript's own `version` field and not
from the snapshot's copy: the transcript's is exact and is what actually ran. It
is what a run IS — see "One file is not always one run" — so it sits on the run
rather than on the record, and `runner_commit` sits there with it, because two
runs of one transcript can have started on two images.

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
`session-meta.jq` reads and therefore what `just sessions` and `just read` show
today.

They differ on **2 of 579 sessions** in the archive on 2026-09-06, by 1452 and
672 tokens — the only two requests that have ever fallen back. Keeping one of
them would have made either `just cost` or the two listings unreproducible from
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
sat there for sixteen hours. `just cost` and `just tools` read every file in a
day's directory and so count it as a session of its own; the store has no record
for it, because it is not a session, until its session lands.

### Tool calls are bucketed by the call's own UTC day

`host/monitor/tools.sh` counts a tool call on the day it happened, and a session
running past midnight lands on both sides. A flat `{name: count}` per session
would put every call on the session's start day and `just tools` could then never
be a renderer over these records without changing what it reports. Measured on
2026-09-06: **9 of 579 sessions have tool calls on more than one UTC day** — so
nearly every session is a single bucket, and this costs one nesting level and
nothing else.

`denials` counts `toolDenialKind`. Over the whole archive on 2026-09-06:
`automode-blocked` 167, `user-rejected` 96, `permission-rule` 59, and
**`automode-unavailable` 2** — the last being the auto-mode classifier failing
open, which nothing else on this machine counts.

### The sufficiency proof

`just records --prove` is the one obligation of the store while no command reads
it. It runs each command as it stands, has `host/monitor/records-render.py`
render the same output from the records alone, and diffs the two byte for byte
over the whole archive:

| what is diffed | what it proves |
| --- | --- |
| `archive_rows` in `host/lib/archive.sh` | every field of the table both listings are a pure function of. Proved first, because a difference here names the field where a difference below names a column |
| `just sessions --all` | the rows, the numbering, and every footnote |
| `just read <id>` | the header block over a transcript, the sub-agent listing `--subagent K` indexes into, and each sub-agent's own header |
| `just tools` and `just tools <name>...` | both table shapes, over every day the archive holds |
| `just cost`, `--by-day`, and by session id | fed into `image/session-cost.py`'s own printing, so what it proves is that the store carries everything that file needs |

The renderer is not a second implementation of the commands kept in step by
hand: the ordering goes through the same `sort`, the columns through the same
`column -t`, and the cost report through `session-cost.py` itself. What it
supplies is only the numbers, which is the question.

It refuses to run rather than report a difference it would have caused itself:
while the local `sessions` branch and `origin/sessions` differ, while any
session is without a record, or while a sub-agent sits on the branch without its
session. Each of those makes the command and the store read different archives.

`just read` is proved by a hex fragment of an id rather than by a listing
position — a full uuid has dashes in it and that recipe takes hex — and the
position is the ordering the `sessions` diff already proves.
