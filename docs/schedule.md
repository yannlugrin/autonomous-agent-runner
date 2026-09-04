# Schedule

## What it is, and what to set

An agent that only runs when you type `just run` is not autonomous. The
schedule is what makes it wake on its own: **one crontab line**, and
`just schedule` is the only thing that writes it.

| handle | what it does |
| --- | --- |
| `just schedule` | what is scheduled right now — the hour, the cooldown, the line itself, and whether cron is even running to read it |
| `just schedule --enable` | install the entry, or bring a paused one back exactly as it stood. Takes `--cron "M H D M W"` and `--cooldown N` |
| `just schedule --pause` | comment the entry out **where it stands**, so the crontab stays the only copy of it |
| `just schedule --disable` | remove the entry altogether |
| `just schedule --relocate` | point the installed entry at the deployed checkout, and refresh the `PATH` it carries |
| `just schedule --state` | the same facts as parseable fields, for other scripts |
| `RUNNER_WEDGE_MINUTES` | minutes an **unattended** session may run before the host says so on the desktop. `120` unless set; an explicit `0` turns it off |

**The rule: `--cooldown` turns the cron expression into a floor rather than a
clock.** Cron wakes on the expression; `just run` then decides whether enough
time has passed **since the last session ended**, and a wake-up it declines
costs a file read. So the pair to write is a frequent expression and a
cooldown that carries the real cadence:

    just schedule --enable --cron "* * * * *" --cooldown 60

is *one session an hour after the previous one finished*, wherever that falls —
not one at a fixed minute past the hour that collides with a session still
running. Change the number to change the cadence: `--cooldown 120` is every two
hours, `--cooldown 15` a quarter of an hour. Start long: every session spends
your account's allowance, and a cooldown of fifteen minutes is a working day of
sessions by lunchtime.

**The cadence is not the ceiling.** What caps how much of your week the agent
may take is the budget guard, and it is set separately: `ACCOUNT_BUDGET_GUARD`
in `.env`, exactly the word `true`, and `ACCOUNT_BUDGET_WEEKLY_CAP` as a
percentage of the account's whole 7-day Claude allowance, yours and the
agent's together — a quarter of the week is `25`. The allowance
climbs to that cap across the week rather than sitting flat at it, which is
what `ACCOUNT_BUDGET_WEEKLY_START` is for, and the whole of it is in
[`docs/budget.md`](budget.md).

**What the line contains.** A marker comment, then a command that does `cd`
into the **deployed** checkout, sets a `PATH` (cron's own is `/usr/bin:/bin`,
which finds neither `just` nor `docker`), and runs `just run`. `--enable` and
`--relocate` rewrite that `PATH`, because a `just` upgraded into another
directory is one an installed line goes on not finding. A `%` in the schedule
or the cooldown is refused rather than written: to cron a `%` is a newline, and
one would cut the line in half.

**What you see.** A declined wake-up exits **75** and prints nothing, so the
run log stays a record of sessions rather than of ticks. A run that ends in any
status but 0, 2 and 75 raises a toast on the Windows desktop — and so does an
unattended session still running after `RUNNER_WEDGE_MINUTES`, which is the one
failure that produces no exit status at all, because it never ends. One toast
per wedge, not one a minute.

**What it refuses.** No `flock` on the line and no timeout: `just run` takes
the lock itself, so the lock binds a run typed by hand as well as the scheduled
one, and wrapping the cron line too would deadlock. A session takes as long as
it takes; the price is that a wedged one holds the lock until `just run
--force`, which asks first. And the entry always names the deployed checkout,
never this one — cron reads whatever tree it is pointed at, committed or not.

## How it is built

The unattended session runs from cron, and `host/schedule/schedule.sh` is the
only thing that writes that crontab entry: it reports by default, and
`--enable`, `--pause`, `--disable` and `--relocate` change it, while `--state`
answers other scripts in parseable fields. `host/schedule/notify.sh` is how a
run nobody is watching reaches the operator — one toast on the Windows desktop
this WSL host lives inside. The recipe and its declared flags are in
`justfile`; the entry names the deployed checkout; `host/lib/session-env.sh`
and `host/lib/session-lock.sh` ask `--state` rather than reading the crontab
themselves; `host/verify/host-tools.sh` checks that the installed line's own
PATH still resolves a new-enough `just`.

## The entry and its marker

The entry is a pair of lines: a marker comment, then the command. `scan()` in
`schedule.sh` finds the pair by the marker's **shape** — the line starts with
`# <project>:` and contains `installed by just schedule` — and not by its exact
text.

That is a repair. The marker said "the hourly unattended session" until the
schedule stopped being hourly. An exact match would have left that entry
installed and unreachable: `--disable` would not have found it, and a
re-install would have sat beside it, two sessions an hour apart from each
other. A wording change must not be able to orphan a line that runs the agent.

The paused prefix `#PAUSED ` is constrained by the same scan: it must not
itself look like the marker, or the scan would take it for the start of a pair
and drop the unrelated entry that followed.

`rest` (the crontab without our pair) and `entry` (the command line out of it)
come from one `awk` invocation with a `want` argument rather than two, so what
counts as our marker is written down exactly once. Two copies of that test is
the shape where one is edited and the other goes on matching the old wording,
silently.

## The deployed checkout in the line

The installed line does `cd $RUNNER_DEPLOYED`, the deployed checkout, and not
this one.

**2026-08-28.** Until then the line named the working tree, and cron reads
whatever tree it is pointed at, committed or not — so an edit to a recipe was
live on the next scheduled session, and so was an image rebuilt merely to
verify it. The deployed checkout was introduced on that date and `--relocate`
with it, called by `just deploy` once the checkout exists. The wider deploy
story is in `docs/release.md`.

`RUNNER_DEPLOYED` resolves to the same sibling path from either checkout, so
the deployed copy's own `schedule --state` recognises the line too — which is
what `host/lib/session-env.sh` relies on when it tells a session its cadence.

`--relocate` moves the directory and the PATH and nothing else: the expression,
the cooldown, the log and whether the entry is paused all stay as they stand,
because a deploy is not a decision about any of those. A paused entry stays
paused — relocating must never be the way a pause ends.

## The PATH the entry carries

cron's own PATH is `/usr/bin:/bin` and nothing else. Two things need more than
that:

- `just run` calls `just collect` by name. From cron without a PATH the recipe
  would not find `just` itself, and every scheduled session would end in
  `COLLECT_FAILED`.
- `just` may not live in `/usr/bin` at all.

`cron_path()` builds `PATH=<dir of the just on this shell's PATH>:/usr/local/bin:/usr/bin:/bin`
and sets it **on the command**, not as a crontab `PATH=` line — a crontab
assignment would silently apply to every entry added below ours.

**2026-09-02.** The PATH is rebuilt on every write and never copied forward,
because an upgraded `just` installed somewhere else is one an installed line
goes on not finding. Measured that day: the entry still named `/usr/bin` after
`just` 1.58.0 landed in `~/.local/bin`, and every scheduled run died at parse
time — on `set minimum-version` in the justfile, before reaching a recipe.
`with_current_path()` is what refreshes it, and every path in `schedule.sh`
that writes a line goes through it: `--enable` on a paused or already-live
entry, `--relocate`, and a freshly built line.

The matching check is in `host/verify/host-tools.sh`, which resolves `just` on
the installed line's PATH and compares its version against the `set
minimum-version` the justfile declares — deliberately not the `just` you type
with, because that is the one that is fine.

## Cron cannot reach an ssh key held by an agent

An unattended session commits and then pushes — the transcript to the archive,
the status snapshot beside it — and cron starts with almost no environment at
all. If the ssh key is held by an **agent** rather than sitting in `~/.ssh` as
a file, cron cannot reach it: the commit succeeds, the push fails with
`Permission denied (publickey)`, and the record piles up on one disk.

**Measured 2026-08-24**, with the key in Bitwarden's ssh agent: origin's newest
transcript was six hours and nineteen collections behind the machine's, and
every failure had gone to cron's own mail, which nobody reads.

The fix is an assignment on its own line in the crontab, above the entry:

    SSH_AUTH_SOCK=/home/<you>/.ssh/bitwarden-agent.sock

**Its own line**, and not spliced into the entry: `just schedule` inherits only
from a line it wrote itself, and a five-field expression read off a line with
an assignment in front of it is five fields of whatever the line says — so the
next `--enable` would lose the cron expression it meant to keep. This is the
one exception to *the crontab is the only copy and `schedule.sh` is its only
writer*, and it is written by hand for that reason.

It then works while the agent is running and unlocked, and fails again when it
is not — which the status page shows, as a snapshot age that climbs.


## What enable inherits

`just schedule --enable` with neither `--cron` nor `--cooldown` means "on" and
nothing more: a paused entry comes back exactly as it stands, a live one is
left alone, both with a current PATH. Rebuilding the whole line from the
defaults this invocation happens to carry would turn `just schedule --enable` a
fortnight after `--cron "*/20 * * * *"` into a silent move back to the hour.

With something to build, what was not said is inherited from the entry that is
there — `--enable --cooldown 15` moves the cooldown and leaves the hour where
it was — and the defaults (`17 * * * *`, no cooldown) apply only when there is
nothing to inherit.

Inheritance happens **only from a line this recipe built** (`ours=yes`, tested
on `cd $here && PATH=`). Five fields cut off the front of an arbitrary line are
five fields whatever that line says: `0 * * * cd /repo && just run` yields
`0 * * * cd`, which passes the field-count check and splices into an entry cron
reads as an hour nobody chose. It is refused rather than guessed, and the
refusal names the flag that settles it (`--cron "M H D M W"`).

The field count is checked here rather than discovered by cron at the next
tick: a crontab is parsed when it is installed, but a wrong field count lands
as a valid line meaning something else entirely, and the symptom is sessions at
times nobody chose. Inherited values are checked too — they come from a file a
person can edit.

`--cron` and `--cooldown` describe an entry rather than install one, so they
are refused without `--enable`: a flag that quietly turned the report into an
install is how a schedule nobody meant to touch gets replaced. Neither carries
a `just` pattern on the recipe, because `just` checks a pattern against the
DEFAULT as well and both defaults are empty — which is how "not said" is told
from a value. `schedule.sh` checks the digits itself.

## Percent is a newline to cron

A `%` in a crontab command means a newline unless it is escaped, so one in the
schedule or the cooldown would cut the line in half and leave the remainder as
input to a command that never asked for any. `--enable` refuses it rather than
writing it.

## The cooldown is a floor

`--cooldown N` makes the schedule a floor rather than a clock: cron wakes on
the expression, `just run` decides whether enough time has passed since the
last session **ended**, and a wake-up it declines costs a file read and prints
nothing. `--cron "* * * * *" --cooldown 15` is the shape that buys — a session
a quarter of an hour after the previous one finished, wherever that falls,
rather than at a fixed minute past whichever hour.

A declined wake-up exits 75 and writes nothing, so the log stays a record of
sessions rather than of ticks. Nothing rotates that log.

## No flock and no timeout on the line

The crontab line does **not** wrap `just run` in `flock`, and that is the point
rather than an omission. `just run` takes the lock itself, so the lock binds a
run typed by hand as well as the scheduled one; wrapping the cron line too
would deadlock, cron holding the lock while the `just run` underneath it waited
for a lock its own parent already had. The lock's own record is in
`docs/sessions.md`.

There is no timeout either, deliberately: a session takes as long as it takes.
The price is that a wedged one holds the lock for as long as it hangs, and
every wake-up in the meantime skips. `just run --force` is the way past that,
and it asks first.

## Pausing in place

`--pause` comments the installed line out where it stands rather than
remembering it somewhere else: the crontab is the only copy, so there is no
second place to fall out of step with it. `--enable` puts it back exactly as it
was, with a current PATH.

Installing a freshly built line over a paused entry is how a pause ends by
accident, so that case is reported as the resumption it is ("Replaced the
paused entry — it is live again") rather than as a replacement like any other.

`replace()` only ever removes our own two lines; everything else in the crontab
belongs to someone else. Called with no argument it writes the crontab without
them, which is what `--disable` is. Its `if` rather than a bare `printf` is
there so an empty crontab comes out empty instead of holding one blank line.

## Why state is a verb

`--state` prints one prefixed field per line — `state:`, `daemon:`, `cron:`,
`cooldown:` — so a reader takes what it knows and ignores the rest, and a field
this cannot answer is absent rather than guessed. `state:` is the one that must
always be there.

It lives in `schedule.sh` rather than being re-derived by its callers because
what counts as paused is this script's `#PAUSED ` prefix: a second reader of
the crontab would answer differently the first time that spelling changed.
`host/lib/session-lock.sh` renders the word for `just status`, and
`host/lib/session-env.sh` tells the session its cadence from the same answer.
The hour and the cooldown stay here, where they are read off the installed line
— a second rendering of them is the copy that goes stale.

`cron:` is the expression and `daemon:` is what would fire it. They are named
apart because they are different facts, and the reader that confuses them
reports a schedule that cannot run as one that will. Both are read off the
installed line either way, so a paused entry still says when it would go, which
is what a session asking about its own cadence needs.

Three states are not two. No `crontab` command on the machine is **unknown**,
not absent: an entry may be installed on a machine this cannot ask. A stopped
cron daemon is not "nothing scheduled" either — an entry cron never reads looks
exactly like one that has simply not come round yet, which is why the report
ends by saying whether cron is running, and says `unknown` where there is no
`systemctl` to ask.

Everything the report prints about the entry — the expression, the cooldown,
the log path — is read out of the installed line and never rebuilt from this
invocation's defaults. A hand-edited hour or log path is exactly what the
person reading a report needs to be told, and a line naming another checkout
still runs, and runs that one; the report says so.

## The wedge alarm

A session that hangs produces no exit status at all, so nothing a trap can see
reports it. `host/session/run.sh` covers that from the *next* wake-up: when a
lock is held by an `auto` session that began more than `RUNNER_WEDGE_MINUTES`
ago (default 120), it raises a toast naming how long it has been up and
offering `just run --force`. The threshold's measurement, and why an attended
`chat` is excluded, are in `docs/sessions.md`.

One toast per wedge, not one a minute: the run record (`RUNNER_LAST_RUN`, in
`~/.cache/<agent>/`, declared in the justfile) holds that session's start time
under `wedged=`, which is what makes the next session a new one without
anything having to clear it. It is stamped **before** the alert rather than
after, so a notifier that hangs cannot become a toast a minute for as long as
the wedge lasts.

This was a file of its own, `RUNNER_WEDGE_NOTIFIED`, until 2026-09-04. It held
one run's start time; so does the run record, which already exists for that
run — and two files keyed on one moment is the second one going stale.

The other half of the alarm is the exit trap in `run.sh`: any status but 0, 2
and 75 raises a toast. 0 worked; 2 is a usage error, which only a terminal can
produce; 75 is the routine stand-down — cooldown, held lock, over budget, a
window with nothing left —
which happens dozens of times a day, and toasting it would teach anyone to
dismiss the toast without reading it.

## Why a toast

**2026-08-31.** Three alternatives were measured, and each fails for its own
reason.

- **A GitHub issue is not a notification.** It is only seen by someone who goes
  looking.
- **A Claude scheduled routine cannot push at all.** Notifications exist only
  for Remote Control on a local session, never for an unattended cloud run —
  and a routine would spend the same subscription quota `ACCOUNT_BUDGET_GUARD`
  rations for the agent, to watch the agent (see `docs/budget.md`).
- **An off-host dead-man's switch on the status snapshot would cry wolf every
  night.** Over 300 commits on the archive's `status` branch, the host went
  quiet 8h32, 6h00 and 4h56 on successive nights, because the machine is turned
  off. Silence is normal here, so it cannot mean broken.

What is left is the desktop that is by definition awake whenever a session
could be failing.

`notify.sh` is silent on a terminal — the caller has already printed the reason
there and a toast on top of it is noise. It is the rule `publish-status.sh`'s
`say` follows, turned the other way up (see `docs/archive.md`). `--force` is
for proving it by hand.

## Never failing its caller

`notify.sh` exits 0 whatever happens, `--check` aside. An alert that could not
be delivered must not turn a session that merely failed into a run that also
crashed on the way out; `run.sh` wraps it in `|| true` as well.

The delivery itself ends on a screen and cannot be probed, so what `--check`
probes is the one part that breaks silently — which `powershell.exe` would be
used, and a refusal when there is none. Ask it the way cron would:

    env -i host/schedule/notify.sh --check

The title falls back to `agent` when `AGENT_NAME` is unset. Every other script
here refuses to run on an unset variable; this one deliberately does not,
because the alternative to a vague title is no alert at all, and that is the
failure this file exists to prevent.

## The PowerShell path under cron

`PS_EXE` is spelled out as
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`, and that is
the whole reason this is a script rather than a one-line `powershell.exe` call
at the point of need.

Cron's environment is not a login shell. The crontab line sets its own PATH and
WSL's Windows interop path is appended by the profile, so `command -v
powershell.exe` finds nothing under cron and finds it perfectly when you try it
by hand. That failure is invisible from the terminal you would test in.
`command -v` is still the fallback, for a host where the literal path is not
where it is here; where neither answers, the host is not WSL with Windows
behind it, and there is nothing to say and nothing wrong.

## A reminder toast, not a banner

The XML uses `scenario="reminder"` with an `<actions>` element rather than a
plain toast. Measured: a plain one is a banner for a few seconds and then lives
only in the notification centre, where it went unnoticed. A reminder stays on
screen until it is dismissed, which is the point — it must survive the operator
being in another window when a session dies.

The AppId is PowerShell's own
(`{1AC14E77-...}\WindowsPowerShell\v1.0\powershell.exe`), registered under
`HKCU\...\Notifications\Settings` the first time anything posts through it.
Registering an AppId of our own would mean writing to the Windows registry from
here, for a nicer name on a toast.

Newlines are stripped from the message before it is XML-escaped. A toast is one
line anyway, and stripping them is also what keeps a message from closing the
PowerShell here-string: its terminator only counts at the start of a line, and
after the strip there is only one line, indented.

## EncodedCommand, not Command dash

**2026-08-31.** `-Command -`, reading the script from stdin, was written first
— it needs neither a temporary file on a path Windows can see nor quoting
through two shells — and it is **wrong in a way that shows nothing**. Measured
that day: `-Command -` consumes stdin the way a prompt does, one line at a
time, so a plain three-line script runs but a multi-line here-string never
completes. PowerShell then exits 0, prints no error, and posts no toast.

`-EncodedCommand` wants base64 of UTF-16LE. `iconv` and `base64` are both in
`/usr/bin`, which cron's PATH holds.

`timeout 30` wraps the call because WSL interop can hang, and a wedged notifier
inside a cron run that wakes every minute would be a worse fault than the one
it came to report.
