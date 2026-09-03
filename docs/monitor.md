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

    monitor/mirror/              the audit clone
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
