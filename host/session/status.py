#!/usr/bin/env python3
"""Is everything right — one screen.

    status.py            the screen, with the live facts on stdin
    status.py --part ended|settled --began EPOCH --seen EPOCH --findings FILE
                         one half of what `just listen` shows when a session ends
    status.py --selftest prove the arithmetic and stop

Runs on the host, under `just status`. Everything a shell has to answer arrives
on stdin as `key: value` lines from host/session/status.sh — whether a session
is running, when the next one may start, what the schedule is — because those
answers live in host/lib/*.sh and are shared with `run`, `chat` and `listen`.
Everything else it asks of the one implementation that owns it: the budget gate
for the budget, `mirror.sh --state` for the backup, `just deploy --state` for
what is live, the sealed records for what has run. It restates no rule and
recomputes no number.

A MISSING LINE IS NOT A ZERO. No docker, no credential, no archive, a gate that
could not start: reporting "none waiting", "no limits" or "the backup is
running" for any of those is the mechanism failing silently. Every section says
when it was not answered, and names what to run to find out why.

THE VERDICT AT THE TOP IS THE SCREEN'S POINT. Six sections of prose leave the
reader to know which words are bad; the first line says whether anything needs
attention, and every section below decides its own share of that. Nothing on
this screen judges by hue — the operator is deutan colourblind.

see docs/sessions.md#where-just-status-gets-its-answers
"""

import argparse
import datetime
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import time

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_module(path, name):
    """A host script beside this one, loaded by path: these run from a checkout
    and are not an installed package."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(CHECKOUT, path))
    if spec is None or spec.loader is None:
        sys.exit("Could not load %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The same grammar `just stats` is written in, from the same file, so a reader
# who has learnt one screen has learnt this one.  see host/lib/screen.py
screen = load_module("host/lib/screen.py", "screen")
rule, fact, duration, local_day = screen.rule, screen.fact, screen.duration, screen.local_day

# What the machine was doing, from the reader the records use.  see host/lib/sysstat.py
sysstat = load_module("host/lib/sysstat.py", "sysstat")

# The two weights a finding has. A problem is something that has stopped or
# will refuse; a watch is something a person should know and nobody has to act
# on tonight. Words and position, never hue.
PROBLEM, WATCH = "problem", "watch"

# What counts as close enough to the budget line to be said out loud. Percent OF
# THE ALLOWANCE and not of the account: the allowance is what the gate compares
# against and it climbs through the window, so 31% used can be 98% spent.
# see docs/budget.md
NEARLY_SPENT = 90


# --------------------------------------------------------------------------
# Reading
# --------------------------------------------------------------------------


def block(text):
    """`key: value` lines into a dict of lists, in the order they were printed.

    A list and not a value because two of the readers repeat a key — a problem
    for every problem — and a dict that kept the last would report one fault
    where there were three.
    """
    out = {}
    for line in (text or "").splitlines():
        key, sep, value = line.partition(": ")
        if sep:
            out.setdefault(key, []).append(value.strip())
    return out


def one(fields, key, default=""):
    return fields.get(key, [default])[0]


def number(value):
    """An integer, or None. Everything read here comes from another process, and
    a field that did not arrive must not become a zero on the way in."""
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def ask(cmd, timeout=90, env=None):
    """(stdout, exit status), or (None, None) when the command could not run."""
    try:
        out = subprocess.run(
            cmd, cwd=CHECKOUT, capture_output=True, text=True, timeout=timeout, env=env
        )
    except (OSError, subprocess.SubprocessError):
        return None, None
    return out.stdout, out.returncode


# --------------------------------------------------------------------------
# Clocks
# --------------------------------------------------------------------------
# Local time everywhere, because a person reads this and asks "when was that,
# for me". An instant is always said with its distance from now: `resets 01:00`
# alone leaves the arithmetic to the reader, and the reader is the one who has
# to notice it is three minutes away.


def clock(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M")


def stamp(ts, now):
    """`19:44 today`, or `09-06 11:00` for anything older."""
    if local_day(ts) == local_day(now):
        return "%s today" % clock(ts)
    return datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M")


def span(seconds):
    """`42s`, `16m`, `2h 34m`, `5d 5h`. Seconds only below a minute, where a
    duration of `0m` is what a session that has just started would print."""
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 86400:
        return duration(seconds)
    return "%dd %dh" % (seconds // 86400, (seconds % 86400) // 3600)


# --------------------------------------------------------------------------
# The verdict
# --------------------------------------------------------------------------


class Verdict:
    """What the sections found, and the one line at the top that says it.

    A section reports its own trouble as it renders, which is what keeps the
    top line from being a second judgement that can disagree with the section
    under it.
    """

    def __init__(self):
        self.found = []

    def problem(self, text):
        self.found.append((PROBLEM, text))

    def watch(self, text):
        self.found.append((WATCH, text))

    def line(self, shown=False):
        """`shown` for a screen that is part of this one: its silence covers only
        the rows it printed, and must not read as the whole machine's."""
        problems = [t for level, t in self.found if level == PROBLEM]
        watching = [t for level, t in self.found if level == WATCH]
        if problems:
            said = "NEEDS ATTENTION: " + "; ".join(problems) + "."
            if watching:
                said += " Also to watch: " + "; ".join(watching) + "."
            return said
        if watching:
            head = "Nothing shown here is broken" if shown else "Nothing is broken"
            return head + ". To watch: " + "; ".join(watching) + "."
        return "Nothing shown here needs attention." if shown else "Nothing here needs attention."

    def save(self, path):
        with open(path, "w") as handle:
            handle.writelines("%s\t%s\n" % found for found in self.found)

    def load(self, path):
        """What the half before this one found, so the one line after both
        judges both."""
        try:
            with open(path) as handle:
                for line in handle:
                    level, sep, text = line.rstrip("\n").partition("\t")
                    if sep and level in (PROBLEM, WATCH):
                        self.found.append((level, text))
        except OSError:
            pass


# --------------------------------------------------------------------------
# Now
# --------------------------------------------------------------------------


def now_section(facts, records, verdict, now, pressure=("clear", None, None)):
    """What is running, when the next one starts, and what today has held.

    The two clauses that used to be two lines are one: `started 20:09, up
    16m31s` and docker's own `Up 16 minutes` are the same fact from two clocks,
    and only the container's name was unique to the second.
    """
    rows = []
    running = one(facts, "running") == "yes"
    started = number(one(facts, "started"))

    if running:
        kind = "%s session" % ("unattended" if one(facts, "kind") == "auto" else "conversation")
        if started:
            head, detail = kind, "started %s, up %s" % (clock(started), span(now - started))
        else:
            # docker answered `ps` and not `inspect`: say the half that is
            # known rather than nothing.
            head, detail = kind, "running, for how long could not be read"
        container = one(facts, "container")
        rows.append((head, ["%s   %s" % (detail, container) if container else detail]))
        rows += live_session(started, verdict)
    else:
        idle = number(one(facts, "idle"))
        if idle is None or idle >= 999999:
            rows.append(("no session", ["and none has ended since this machine last forgot"]))
        else:
            rows.append(("no session", ["the last one ended %s ago" % span(idle * 60)]))
        rows += last_session(records, now)

    rows.append(("next", [next_line(facts, verdict, running, now, pressure)]))
    rows += stopped_rows(facts, verdict)

    # A shell or a probe is not a session and holds no lock, but "nothing is
    # running" while you are sitting in a container is a misleading answer.
    other = one(facts, "other")
    if other:
        rows.append(("also up", ["%s — a container that is not a session" % other]))

    rows += today_row(records, now)
    return rows


def stopped_rows(facts, verdict):
    """A stop nobody has been told about yet, which is the state worth seeing:
    it may sit for hours while wake-ups stand down on the same limit that caused
    it.  see docs/sessions.md#recovering-a-session-that-was-stopped"""
    last = one(facts, "last_run")
    if not last.startswith("stopped"):
        return []
    verdict.watch("the last run was stopped (%s)" % last[len("stopped ") :])
    return [
        (
            "last run",
            ["stopped (%s) — the next session opens with what it was doing" % last[8:]],
        )
    ]


def read_stats(started):
    """session-stats.py's lines for the session since `started`, or None when it
    could not say."""
    out, code = ask(
        [os.path.join(CHECKOUT, "host/session/session-stats.py"), "--since", str(started or 0)]
    )
    if out is None or code:
        return None
    return [line.strip() for line in out.splitlines() if line.strip()]


def live_session(started, verdict):
    """What the running session has spent, from the reader that owns it.

    Only while one is running: a session that has ended has a sealed record, and
    reading its transcript back out of the volume would be a container start for
    an answer already on disk.  see docs/monitor.md#one-record-per-session

    Its last line starts with MODEL MISMATCH or MODEL UNPINNED when it has
    something to say, and that is a fault about what is running right now — so
    it is carried into the verdict rather than left as a line the reader has to
    recognise.  see docs/sessions.md#what-a-session-cost-and-which-model-answered
    """
    lines = read_stats(started)
    where = sysstat.directory()
    sampled = None
    if started and where and os.path.isdir(where):
        sampled = sysstat.summarise(where, started, time.time(), sysstat.docker_root())
    so_far = [("machine so far", machine(sampled))]
    if lines is None:
        return [("so far", ["could not be read — 'just cost' says why"])] + so_far
    fault = model_fault(lines)
    if fault:
        verdict.problem(fault)
    return ([("so far", lines)] if lines else []) + so_far


def model_fault(lines):
    """The clause of a MODEL MISMATCH / MODEL UNPINNED line that names the fault.

    The rest of that line is the evidence, which stays on screen where it was
    printed; the verdict wants the claim and not the sentence.
    """
    for line in lines:
        if line.startswith("MODEL "):
            return line.split(" — ")[0].split(". ")[0].strip().lower()
    return None


def last_session(records, now):
    """The last session that ran, out of the records rather than the volume."""
    if not records:
        return []
    record = max(records, key=lambda r: r["end"])
    usd = sum(u["usd"] for u in record["usage"]) + sum(
        u["usd"] for s in record["subagents"] for u in s["usage"]
    )
    awake = sum(run["to"] - run["from"] for run in record["runs"])
    # Its own ending and not only its numbers: the row above reads a stamp that
    # counts conversations too, and the newest record is not always the session
    # that stamp is about — a chat whose record has not sealed yet leaves the
    # two describing different sessions, and only the instants say so.
    return [
        (
            "last session",
            [
                "ended %s ago · ran %s · %d requests · %s end context · $%.2f"
                % (
                    span(now - record["end"]),
                    duration(awake),
                    record["requests"],
                    thousands(record["end_context"]),
                    usd,
                )
            ],
        ),
        ("machine", machine(record["runs"][-1].get("system"))),
    ]


def thousands(n):
    return "%dk" % round(n / 1000) if n >= 1000 else str(n)


def machine(system):
    """A run's `system` summary as lines, or that there is none.

    Numbers only, and nothing here judges them: what normal is on this machine has not
    been measured yet.  see docs/monitor.md#the-machine-a-run-ran-on
    """
    if not system:
        return ["not measured"]
    first = ["cpu %.0f%%" % system["cpu_busy_mean"]]
    if system.get("load1_p95") is not None:
        first.append("load p95 %.1f on %s CPU" % (system["load1_p95"], system.get("cpus") or "?"))
    first.append("iowait p95 %.0f%%" % system["iowait_p95"])

    free = []
    if system.get("avail_min_mb") is not None:
        free.append("%d MB memory" % system["avail_min_mb"])
    if system.get("filesystem"):
        free.append("%d MB disk" % system["filesystem"]["free_min_mb"])
    second = ["lowest free " + ", ".join(free)] if free else []
    if system.get("swap_out_mb") is not None:
        second.append("swap out %.0f MB" % system["swap_out_mb"])
    return [" · ".join(first)] + ([" · ".join(second)] if second else [])


def next_line(facts, verdict, running, now, pressure=("clear", None, None)):
    """When the next unattended session starts, in the words `run` uses.

    The wait itself is `wake_state` in host/lib/wake-request.sh, computed by the
    shell that owns it and handed here: a screen that recomputed it would be the
    copy that drifts, and it is the copy nobody runs by hand.

    A WAIT THAT HAS ELAPSED IS NOT THE SAME AS A SESSION THAT STARTED. `run` is
    fired by cron and stands itself down; nothing on the way in reports a
    wake-up that never happened, and "now — the default wait is 30m" is what
    this screen said for half an hour while a defect kept every one of them from
    starting. So the elapsed case is measured: past due, plus one firing of the
    crontab line, plus a minute, and a session that has still not started is a
    problem. The budget refusing one is not that — it is the gate working, and
    it says so in its own section.
    """
    scheduling = one(facts, "scheduling")
    bounds = ""
    if one(facts, "wake_armed") == "yes":
        bounds = " (it may ask for %s–%sm)" % (one(facts, "wake_min"), one(facts, "wake_max"))

    if scheduling == "paused":
        verdict.watch("scheduling is paused, so nothing starts on its own")
        said = "nothing starts on its own — scheduling is paused"
    elif scheduling == "absent":
        verdict.watch("scheduling is off, so nothing starts on its own")
        said = "nothing starts on its own — scheduling is off"
    elif scheduling == "enabled" and one(facts, "daemon") == "stopped":
        verdict.problem("scheduling is enabled but cron is not running")
        said = "nothing starts on its own — cron is not running"
    elif running:
        said = "when this one ends, +%sm unless it asks otherwise%s" % (
            one(facts, "wake_default"),
            bounds,
        )
    else:
        left = number(one(facts, "wake_left"))
        why = one(facts, "wake_why")
        if left is None:
            said = "unknown — the wait could not be read"
        elif left > 0:
            due = number(one(facts, "wake_due"))
            when = "%s, in %s" % (stamp(due, now), span(left * 60)) if due else "in %dm" % left
            said = "%s — %s" % (when, why)
        elif pressure[0] == "over":
            # Refused rather than missing: the budget section carries the
            # numbers, and calling this late would be an alarm about a gate
            # doing exactly what it is for.
            said = "due — %s, and the budget gate is refusing it" % why
        else:
            due = number(one(facts, "wake_due"))
            every = number(one(facts, "cron_every"))
            allowed = None if not due or every is None else due + (every + 1) * 60
            if allowed is None or now <= allowed:
                said = "now — %s, and the next wake-up starts one" % why
            elif pressure[0] == "near":
                # Shown, and not called a fault: at this ratio the allowance
                # line is crossing and re-crossing the usage, so wake-ups are
                # being refused and admitted minute by minute.
                # The number is the budget row's to report, and it does:
                # saying it in both halves of one verdict line is one fact
                # twice.
                verdict.watch("nothing has started since %s, held back by the budget" % clock(due))
                said = (
                    "DUE SINCE %s — nothing in %s, and the %s budget is at %d%% of its allowance"
                    % (
                        clock(due),
                        span(now - due),
                        pressure[1],
                        pressure[2],
                    )
                )
            else:
                verdict.problem("a session has been due since %s and none has started" % clock(due))
                said = (
                    "DUE SINCE %s — nothing has started in %s, and the schedule fires every %dm"
                    % (
                        clock(due),
                        span(now - due),
                        every,
                    )
                )
    if scheduling == "unknown":
        verdict.watch("what the schedule is doing could not be read")
    return said


def today_row(records, now):
    """What today has held, from the sealed records.

    Sessions, not transcripts, and awake time rather than the span between the
    first and the last: a resumed conversation covers hours it was not running
    in.  see docs/monitor.md#one-file-is-not-always-one-run
    """
    today = local_day(now)
    mine = [r for r in records if local_day(r["start"]) == today]
    if not mine:
        return [("today", ["nothing has run yet"])]
    runs = [run for r in mine for run in r["runs"]]
    awake = sum(run["to"] - run["from"] for run in runs)
    usd = sum(u["usd"] for r in mine for u in r["usage"]) + sum(
        u["usd"] for r in mine for s in r["subagents"] for u in s["usage"]
    )
    return [
        (
            "today",
            [
                "%d session%s · %s awake · $%.2f at list rates"
                % (len(runs), "" if len(runs) == 1 else "s", duration(awake), usd)
            ],
        )
    ]


# --------------------------------------------------------------------------
# Budget
# --------------------------------------------------------------------------
# Asked of the gate itself rather than recomputed here: it is the only place the
# arithmetic lives, and reading it also renews the container's access token,
# which is why looking at status once a week keeps the unattended path alive on
# a schedule that has been paused.  see docs/budget.md
#
# --env and not the prose, because this screen sets the numbers in its own
# columns; the gate's own sentence is what `just verify` and the session read.

LABELS = {"SESSION": "session", "WEEKLY": "week"}


def read_budget(guarded, reading=None, fresh_since=None):
    """The gate's own `--env` block, parsed.

    Read before the screen is composed, because whether it refuses decides what
    the line above it may claim: a wake-up the budget is holding back has not
    gone missing. `fresh_since` refuses a cached reading taken before it.
    """
    if reading is None:
        cmd = [sys.executable, os.path.join(CHECKOUT, "image/claude-usage.py"), "--env"]
        if not guarded:
            cmd.append("--advisory")
        env = None
        minutes = None if fresh_since is None else fresh_cache_minutes(fresh_since, time.time())
        if minutes is not None:
            env = dict(os.environ, ACCOUNT_BUDGET_CACHE_MINUTES="%.4f" % minutes)
        out, _code = ask(cmd, env=env)
        reading = out
    fields = {}
    for line in (reading or "").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields.setdefault(key, []).append(value)
    return fields


def over_budget(fields):
    return one(fields, "VERDICT").startswith("over budget")


def budget_pressure(fields):
    """`over`, `near` or `clear`, and the window that decides it.

    THE ALLOWANCE CLIMBS THROUGH THE WINDOW, so a session refused at 21:06 can be
    admitted at 21:30 with nothing having changed but the clock. A screen that
    read only "is it over the line right now" would therefore call a wake-up the
    gate held back half an hour ago a missing session — which is what happened
    on 2026-09-07, on a week sitting at 97% of its allowance. Near the line is
    its own answer for exactly that reason.  see docs/budget.md
    """
    worst = ("clear", None, None)
    for name, label in LABELS.items():
        value = one(fields, "ACCOUNT_USAGE_%s" % name)
        parts = dict(part.split("=", 1) for part in value.split(" ") if "=" in part)
        ratio = number(parts.get("ratio"))
        if ratio is None or (worst[2] is not None and ratio <= worst[2]):
            continue
        worst = ("near" if ratio >= NEARLY_SPENT else "clear", label, ratio)
    if over_budget(fields):
        return ("over", worst[1], worst[2])
    return worst


def budget_section(fields, guarded, verdict, now):
    rows = []
    verdict_text = one(fields, "VERDICT")
    for name, label in LABELS.items():
        value = one(fields, "ACCOUNT_USAGE_%s" % name)
        if not value or value == "unknown":
            continue
        parts = dict(part.split("=", 1) for part in value.split(" ") if "=" in part)
        detail = "of its allowance · %s%% used, %s%% allowed now" % (
            parts.get("used", "?"),
            parts.get("allowed", "?"),
        )
        resets = reset_text(parts.get("resets", ""), now)
        if resets:
            detail += " · resets %s" % resets
        # Close to the line is worth saying before it refuses: the gate stands
        # a session down at 100% of the allowance, and nothing else on this
        # screen would say the week is nearly spent. Past the line it says
        # nothing new — the over-budget problem below carries the same window
        # and the same number, and the top line would print both.
        ratio = number(parts.get("ratio"))
        if ratio is not None and NEARLY_SPENT <= ratio < 100:
            verdict.watch("the %s budget is at %d%% of its allowance" % (label, ratio))
        # The label and the ratio in fixed columns, so the deciding number is
        # under the deciding number and not wherever the word before it ended.
        rows.append(("%-8s %3s%%" % (label, parts.get("ratio", "?")), [detail]))

    if not rows:
        verdict.problem("the budget could not be read")
        rows.append(("budget", ["the reading did not answer — run 'just verify' to see why"]))
    elif over_budget(fields):
        verdict.problem("over budget — no unattended session starts")
        rows.append(("over budget", [verdict_text[len("over budget: ") :]]))

    scoped = one(fields, "ACCOUNT_USAGE_SCOPED")
    if scoped:
        rows.append(("also", [scoped]))
    spent = one(fields, "EXHAUSTED")
    if spent:
        rows.append(("nothing left in", [spent]))

    age = number(one(fields, "READING_AGE"))
    guard = (
        "on — a session over the line is refused"
        if guarded
        else "OFF — nothing here refuses a session on budget"
    )
    if age is not None:
        guard += " · from a reading %s old" % span(age)
    rows.append(("guard", [guard]))
    if not guarded:
        verdict.watch("the budget guard is off")
    return rows


def reset_text(iso, now):
    """`01:00, in 2h 34m` — the instant a person can act on, and the distance
    that says whether they have to."""
    if not iso:
        return ""
    try:
        at = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso
    ts = at.timestamp()
    return "%s, in %s" % (stamp(ts, now), span(ts - now))


# --------------------------------------------------------------------------
# Backup
# --------------------------------------------------------------------------
# The verdict and the instants from `mirror.sh --state`, which is the recipe
# that decides them. Said here because a mirror that has stopped looks exactly
# like one that is idle, and this screen is where the operator looks when they
# look at all — it was three days dead in September 2026 with every other line
# on this page green.  see docs/archive.md#the-key-goes-on-before-the-secret-goes-in


def backup_section(fields, code, verdict, now):
    rows = []
    last = number(one(fields, "last_run"))
    due = number(one(fields, "due"))
    conclusion = one(fields, "conclusion")

    if code is None or not fields:
        verdict.watch("the backup could not be read")
        return [("mirror", ["could not be read — 'just mirror-status' says why"])]

    if last is None:
        said = "never run"
    else:
        said = "last run %s, %s" % (stamp(last, now), conclusion or "?")
    rows.append(("mirror", [said]))

    # A run that is due and has not happened is NOT late: nothing is on a clock
    # here, and what runs the mirror is a session ending. mirror.sh decides
    # whether that has happened and this only says so.
    if one(fields, "late") == "yes":
        rows.append(("LATE", ["a session ended after it was due and no run followed"]))
    elif due is not None:
        rows.append(
            (
                "next",
                [
                    "at the next session end after %s%s"
                    % (clock(due), "" if due > now else " — due since then")
                ],
            )
        )

    written = number(one(fields, "tip_written"))
    if written is not None:
        rows.append(
            (
                "memory",
                [
                    "last written %s · %s commits"
                    % (stamp(written, now), one(fields, "tip_commits") or "?")
                ],
            )
        )

    if code == 1:
        verdict.problem("THE MIRROR IS NOT RUNNING — the memory is not being archived")
    elif code == 2:
        verdict.watch("the backup is neither proven running nor proven stopped")
    for text in fields.get("problem", []) + fields.get("unproven", []):
        rows.append(("", [text]))
    if code:
        rows.append(("", ["'just mirror-status' has the detail"]))
    return rows


# --------------------------------------------------------------------------
# Credentials
# --------------------------------------------------------------------------
# Two of them stop everything and neither says so on the way out: the Claude
# setup-token every session runs on, and the GitHub token `gh` runs on, which is
# how the agent reads and opens an issue. Both are in the container, so
# host/session/credentials.sh reads them at the end of every session and this
# shows what it wrote. The thresholds are here and the reading is there, so no
# date is compared in two places.
#
# The third row is this host's own Claude login. It is shown and never judged —
# the operator ruled that the two above are what matter, and a screen that
# alarms on everything alarms on nothing.
# see docs/vault.md#when-a-credential-expires

EXPIRY_PROBLEM, EXPIRY_WATCH = 7, 21

# A reading older than this is a reader that has stopped, not a quiet week: at
# a dozen sessions a day the file is rewritten hourly, and the failure it
# catches is the one where the dates on screen are simply no longer true.
READING_STALE = 3


def day_end(text):
    """The end of the `YYYY-MM-DD` at the start of `text`, local, or None.

    The end and not the start: a date alone says nothing about the hour, and
    counting from midnight would report a credential dead a day early.
    """
    match = re.match(r"\s*(\d{4})-(\d{2})-(\d{2})", text or "")
    if not match:
        return None
    try:
        day = datetime.date(*(int(part) for part in match.groups()))
    except ValueError:
        return None
    midnight = datetime.datetime.combine(day + datetime.timedelta(days=1), datetime.time())
    return midnight.timestamp()


def note_date(note):
    """The `expires YYYY-MM-DD` a vault note carries, as it is written, or None.

    The string and not an instant, because the screen shows the day somebody
    typed: `day_end` counts to the end of it so nothing expires early, and a
    row printing that instant would answer 2027-09-09 to a note saying
    2027-09-08.  see docs/vault.md#the-note-on-claude-oauth-token-carries-the-date
    """
    match = re.search(r"expires\s+(\d{4}-\d{2}-\d{2})", note or "")
    return match.group(1) if match else None


def header_expiry(value):
    """The instant GitHub's expiration header names, or None.

    Measured 2026-09-08: it sends `2026-11-21 23:40:12 UTC`. The named zone is
    rewritten as an offset rather than parsed as one, because strptime accepts
    `%Z` for `UTC` and then hands back a naive time — which `.timestamp()`
    reads as local, putting the instant an hour or two out in the direction
    nobody would check. The date alone is the fallback, so a header that
    changes shape still answers to the day rather than to nothing.
    """
    value = re.sub(r"\s+(?:UTC|GMT)$", " +0000", (value or "").strip())
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%d %H:%M:%S %z").timestamp()
    except ValueError:
        return day_end(value)


def far_stamp(ts, now):
    """`11-22 00:40` inside this year, `2027-09-08 00:40` beyond it. stamp()
    drops the year, which on a credential a year out reads as next week."""
    if datetime.date.fromtimestamp(ts).year == datetime.date.fromtimestamp(now).year:
        return stamp(ts, now)
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def until(when, now):
    """`in 74d 20h`, or `expired 3d 4h ago`. span() floors at zero, which on a
    date that has passed would read as expiring this second."""
    left = when - now
    return "in %s" % span(left) if left > 0 else "expired %s ago" % span(-left)


def credentials_section(fields, host_login, verdict, now):
    """When each credential dies, and which of them is worth an alarm."""
    rows = []

    def say(head, when, shown, about, alarm):
        rows.append((head, ["%s · %s — %s" % (until(when, now), shown, about)]))
        left = when - now
        if left <= 0:
            verdict.problem("%s HAS EXPIRED" % alarm)
        elif left < EXPIRY_PROBLEM * 86400:
            verdict.problem("%s expires in %s" % (alarm, span(left)))
        elif left < EXPIRY_WATCH * 86400:
            verdict.watch("%s expires in %s" % (alarm, span(left)))

    if not fields:
        verdict.watch("nothing is known about when the agent's credentials expire")
        rows.append(("credentials", ["never read — 'just credentials' reads them now"]))
    else:
        # A note with no date in it is not an absent reading: the row was found
        # and nobody wrote the one thing it exists to carry, which is a
        # different fault and has a different fix.
        written = note_date(one(fields, "claude_note"))
        if written:
            say(
                "claude",
                day_end(written),
                written,
                "the setup-token every session runs on",
                "the Claude setup-token",
            )
        elif "claude_note" in fields:
            verdict.watch("no expiry is recorded for the Claude setup-token")
            rows.append(
                (
                    "claude",
                    ["not recorded — put 'expires YYYY-MM-DD' in the note on claude-oauth-token"],
                )
            )

        # No header is a real answer and not a failure: a personal access token
        # can be issued without an expiry, and one that never dies is exactly
        # what this section must not report as unknown.
        github = header_expiry(one(fields, "github_expiry"))
        who = one(fields, "github_login")
        about = "%s, what gh runs on" % (("@" + who) if who else "what gh runs on")
        if github is not None:
            say("github", github, far_stamp(github, now), about, "the agent's GitHub token")
        elif who:
            rows.append(("github", ["no expiry set on it · %s" % about]))

        for text in fields.get("problem", []):
            verdict.problem(text)
            rows.append(("", [text]))

    if host_login is not None:
        rows.append(
            (
                "here",
                [
                    "%s · %s — this host's own login, what the budget gate reads"
                    % (until(host_login, now), far_stamp(host_login, now))
                ],
            )
        )

    if fields:
        read_at = number(one(fields, "read_at"))
        if read_at is None:
            verdict.watch("the credential reading does not say when it was taken")
            rows.append(("reading", ["of an unknown age"]))
        else:
            rows.append(
                ("reading", ["%s old — refreshed at every session end" % span(now - read_at)])
            )
            if now - read_at > READING_STALE * 86400:
                verdict.watch("the credential reading is %s old" % span(now - read_at))
    return rows


def host_login_expiry():
    """When this host's own Claude login dies, or None.

    Asked of image/claude-usage.py, which owns both the path and the shape and
    is the thing that reads and rewrites that file — a second copy of either
    here would be the one that goes stale. `refreshTokenExpiresAt` and not
    `expiresAt`: the access token is refreshed on every reading and says
    nothing, the refresh token is what eventually runs out. Anything at all
    going wrong is no row, because this is the credential nothing here judges
    and it must not be able to take the screen down.
    """
    try:
        usage = load_module("image/claude-usage.py", "claude_usage")
        _whole, oauth = usage.load_credentials()
        return int(oauth["refreshTokenExpiresAt"]) / 1000
    except Exception:  # noqa: BLE001 - a row that cannot be read is a row that is not shown
        return None


# --------------------------------------------------------------------------
# The gate
# --------------------------------------------------------------------------


def gate_section(held, records, verdict, now, pending=None):
    """What is held back from the archive, what is sealed, and what is unpushed.

    The held count is read from what `collect` wrote at the last session end
    rather than counted again: counting means a container against the volume and
    a scan of every transcript in it, for a number that changes only when a
    session ends.  see docs/archive.md#the-count-without-the-collection
    """
    rows = []
    count = number(one(held, "count"))
    at = number(one(held, "at"))
    if count is None:
        verdict.watch("what the review gate is holding has not been counted here")
        rows.append(
            ("transcripts", ["not counted since this cache was cleared — 'just collect --held'"])
        )
    elif count == 0:
        rows.append(
            ("transcripts", ["none waiting%s" % (", counted %s" % stamp(at, now) if at else "")])
        )
    else:
        verdict.watch("%d transcript(s) waiting on review" % count)
        rows.append(
            (
                "transcripts",
                [
                    "%d waiting on review, held out of the archive%s"
                    % (count, ", counted %s" % stamp(at, now) if at else ""),
                    "'just collect' prints what and why",
                ],
            )
        )

    if pending is None:
        out, code = ask(
            [os.path.join(CHECKOUT, "host/monitor/session-records.py"), "--pending"], timeout=60
        )
        pending = None if (out is None or code) else number(out)
    if pending is None:
        verdict.watch("how many sessions are waiting to be recorded could not be read")
        rows.append(
            ("records", ["%d sealed · how many are waiting could not be read" % len(records)])
        )
    elif pending:
        verdict.watch("%d session(s) have no record yet" % pending)
        rows.append(
            (
                "records",
                ["%d sealed · %d waiting — 'just records' seals them" % (len(records), pending)],
            )
        )
    else:
        rows.append(("records", ["%d sealed, none waiting" % len(records)]))
    return rows


def unpushed_rows(archive, verdict):
    """Branches the archive holds that origin does not.

    A push that failed leaves a commit here and nothing on GitHub, and every
    writer here is best-effort by design: the failure says so once, on stderr,
    into a log nobody reads.
    """
    if not archive or not os.path.isdir(archive):
        return []
    behind = []
    for branch in ("sessions", "cache", "status"):
        out, code = ask(
            ["git", "-C", archive, "rev-list", "--count", "origin/%s..%s" % (branch, branch)],
            timeout=30,
        )
        if out is None or code:
            continue
        n = number(out)
        if n:
            behind.append("%s by %d" % (branch, n))
    if not behind:
        return [("archive", ["everything committed here is on origin"])]
    verdict.problem("the archive has commits that never reached origin (%s)" % ", ".join(behind))
    return [
        ("archive", ["AHEAD OF ORIGIN: %s — 'just collect --push' retries" % ", ".join(behind)])
    ]


# --------------------------------------------------------------------------
# Deployed
# --------------------------------------------------------------------------


def deployed_section(fields, records, verdict, now, named=False):
    """What cron runs, since when, how much has run on it, and how far it is
    behind what it is compared against.

    Since when is the reflog of the branch `deploy` resets, and how much is the
    records' own count of the build each run carried — a build that just went
    live and a build nothing ever ran on read identically without it. `against`
    is `origin/<branch>` where the machine runs the agent and its checkout is the
    live commit itself; absent, it is the checkout `deploy` was run from.
    see docs/release.md#behind-origin-is-asked-of-origin

    `named` heads the first row with the word rather than the commit, for a
    screen where it sits among rows that are not about the deploy.
    """
    if not fields:
        verdict.watch("what is live could not be read")
        return [("deployed", ["unknown — 'just deploy --state' did not answer"])]
    if one(fields, "worktree") == "absent":
        return [("deployed", ["nothing yet — 'just deploy' creates the checkout on its first run"])]
    against = one(fields, "against") or "main"

    live = one(fields, "deployed")
    at = number(one(fields, "deployed_at"))
    carried = sum(
        1
        for record in records
        for run in record["runs"]
        if live and (run.get("runner_commit") or "").startswith(live[:7])
    )
    said = []
    if at:
        said.append("live since %s" % stamp(at, now))
    said.append(
        "no session has run on it yet"
        if not carried
        else "%d session%s on it" % (carried, "" if carried == 1 else "s")
    )
    image = one(fields, "image_deployed")
    said.append("no image tagged deployed" if image == "-" else "image %s" % image[:7])
    if named:
        rows = [("deployed", [" · ".join([live or "-"] + said)])]
    else:
        rows = [(live or "-", [" · ".join(said)])]

    ahead = number(one(fields, "ahead"))
    if one(fields, "live_missing") == "yes":
        verdict.problem("the live commit %s is not on %s" % (live or "-", against))
        rows.append(("", ["THE LIVE COMMIT IS NOT ON %s" % against.upper()]))
    elif ahead is None and one(fields, "against"):
        verdict.watch("how far the live build is behind %s could not be read" % against)
        why = one(fields, "compare_error") or "no reason given"
        rows.append(("", ["how far behind %s could not be read — %s" % (against, why)]))
    elif ahead is None:
        rows.append(("", ["no deployed branch"]))
    elif ahead == 0:
        rows.append(("", ["up to date with %s" % against]))
    else:
        # The subjects and not only the count: this is where a person decides
        # whether a deploy is worth doing. Uncapped on purpose — a backlog long
        # enough to scroll is the thing worth seeing.
        rows.append(("", ["%d commit(s) behind %s" % (ahead, against)]))
        rows += [("", ["  " + subject]) for subject in fields.get("commit", [])]

    # Subjects where the checkout holds them, a count where only origin does.
    dropped = fields.get("dropped_commit", [])
    count = len(dropped) or number(one(fields, "dropped")) or 0
    if count:
        verdict.problem("%d commit(s) are live and not in %s" % (count, against))
        rows.append(
            (
                "",
                [
                    "LIVE AND NOT IN %s — a deploy would drop %s"
                    % (against.upper(), "these:" if dropped else "%d commit(s)" % count)
                ],
            )
        )
        rows += [("", ["  " + subject]) for subject in dropped]
    return rows


# --------------------------------------------------------------------------
# The end of a session
# --------------------------------------------------------------------------
# What `just listen` shows when the session it followed ends, in two halves:
# what is known the moment the container goes, and what the session's
# bookkeeping leaves once the runner that started it has finished. Printed
# before that, the second half describes the session before.
# see docs/sessions.md#what-listen-shows-when-a-session-ends

MEMORY_STATE = "memory.state"


def session_end(facts, began, seen):
    """When the followed session ended: the stamp `run` and `chat` write as its
    container goes, or failing that the moment `listen` saw it gone."""
    stamped = number(one(facts, "session_ended"))
    return stamped if stamped and began and stamped >= began else seen


def fresh_cache_minutes(since, now, environ=None):
    """The budget cache's lifetime for a reading that must postdate `since`, or
    None to leave it alone.

    Shorter than the time since then, so a reading taken before is a miss and is
    fetched again; above zero, so the fresh one is stored and the status page
    published seconds later reuses it instead of asking again. A lifetime set
    lower is kept, a cache turned off stays off, and a value claude-usage.py
    refuses is left for it to say so.
    """
    usage = load_module("image/claude-usage.py", "claude_usage")
    try:
        configured = usage.cache_minutes(os.environ if environ is None else environ)
    except usage.CannotTell:
        return None
    if configured <= 0:
        return None
    return min(configured, max(1.0, now - since) / 60)


def ended_section(facts, verdict, now, end, stats, pressure=("clear", None, None)):
    """What the session spent, and when the next one starts.

    Out of the transcript and not the records: the record is sealed by the
    bookkeeping still running, so the newest one is the session before.
    """
    if stats is None:
        spent = ["what it spent could not be read — 'just cost' says why"]
    else:
        spent = stats
        fault = model_fault(stats)
        if fault:
            verdict.problem(fault)
    running = one(facts, "running") == "yes"
    rows = [
        ("last session", ["ended %s" % stamp(end, now)] + spent),
        ("next", [next_line(facts, verdict, running, now, pressure)]),
    ]
    return rows + stopped_rows(facts, verdict)


def session_run(records, began):
    """The followed session's run among the sealed records, or None. Every run
    of the session before it had ended by the time its container started."""
    runs = [run for record in records for run in record["runs"] if run["to"] >= began]
    return max(runs, key=lambda run: run["to"]) if runs else None


def printable(text):
    """Another process's text with its control characters removed: the push
    report comes out of a file the agent can write, and this is a terminal."""
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)


def memory_rows(state, read_at, run, end, verdict):
    """What the session committed, and whether its push reached origin.

    `state` is what sync_push_state in host/monitor/clone.sh read out of the
    checkout, at `read_at`. Only a successful push moves the checkout's
    `refs/remotes/origin/*`, so `unpushed` is the proof. ERROR_ON_PUSH is the
    hook's own report of why, and its absence proves nothing: a hook killed by
    its timeout writes none.  see docs/backup.md#the-host-reads-the-flag-too
    """
    if not read_at or read_at < end:
        verdict.watch("whether the memory reached origin was not read after the session ended")
        if run is None:
            said = "not sealed yet, and its push not read since it ended — 'just records' does both"
        else:
            said = (
                "%d commit(s) this session · its push not read since it ended — 'just records'"
                % (len(run["commits"]))
            )
        return [("memory", [said])]

    if run is None:
        said = ["not sealed yet — 'just records' seals it"]
    else:
        n = len(run["commits"])
        said = ["%d commit%s this session" % (n, "" if n == 1 else "s")]

    reason = one(state, "push_reason")
    unpushed = number(one(state, "unpushed"))
    if unpushed is None:
        verdict.watch("whether the memory reached origin could not be read")
        said.append("what reached origin could not be read")
    elif unpushed == 0:
        said.append("all on origin")
    else:
        said.append("%d NOT ON ORIGIN" % unpushed)
        if not reason:
            verdict.problem(
                "%d memory commit(s) are not on origin, and the push left no report" % unpushed
            )

    uncommitted = number(one(state, "uncommitted"))
    if uncommitted is None:
        verdict.watch("the agent's working tree could not be read")
        said.append("working tree unread")
    elif uncommitted == 0:
        said.append("working tree clean")
    else:
        verdict.watch("%d uncommitted change(s) in the agent's checkout" % uncommitted)
        said.append("%d uncommitted change(s)" % uncommitted)

    rows = [" · ".join(said)]
    if reason:
        verdict.problem("the memory push failed (%s)" % reason)
        rows.append(
            "PUSH FAILED: %s, %s in a row" % (reason, one(state, "push_consecutive") or "?")
        )
        detail = one(state, "push_detail")
        if detail:
            rows.append(detail)
    return [("memory", rows)]


def render_part(
    part,
    facts,
    records,
    now,
    began,
    seen,
    findings="",
    budget=None,
    stats=None,
    deploy=None,
    held=None,
    pending=None,
    archive="",
    memory_state=None,
    memory_read_at=None,
):
    """One half. The first leaves what it found in `findings` for the second,
    whose last line judges both."""
    verdict = Verdict()
    end = session_end(facts, began, seen)
    if part == "ended":
        guarded = one(facts, "budget_guard") == "on"
        spent = read_budget(guarded, budget, fresh_since=end)
        sections = [
            ("session", ended_section(facts, verdict, now, end, stats, budget_pressure(spent))),
            ("budget", budget_section(spent, guarded, verdict, now)),
        ]
        if findings:
            verdict.save(findings)
        return "\n".join(compose(facts, records, sections))

    if findings:
        verdict.load(findings)
    rows = (
        memory_rows(memory_state or {}, memory_read_at, session_run(records, began), end, verdict)
        + gate_section(held or {}, records, verdict, now, pending)
        + unpushed_rows(archive, verdict)
        + deployed_section(deploy or {}, records, verdict, now, named=True)
    )
    return "\n".join(compose(facts, records, [("after it", rows)]) + ["", verdict.line(shown=True)])


# --------------------------------------------------------------------------
# The screen
# --------------------------------------------------------------------------


def compose(facts, records, sections):
    """The verdict first, then the sections, in the order they are read."""
    out = []
    for title, rows in sections:
        if rows:
            out += rule(title) + fact(rows)
    return out


def render(
    facts,
    records,
    now,
    budget=None,
    mirror=(None, None),
    deploy=None,
    held=None,
    pending=None,
    archive="",
    credentials=None,
    host_login=None,
):
    verdict = Verdict()
    guarded = one(facts, "budget_guard") == "on"
    mirror_fields, mirror_code = mirror
    spent = read_budget(guarded, budget)
    sections = [
        ("now", now_section(facts, records, verdict, now, budget_pressure(spent))),
        ("budget", budget_section(spent, guarded, verdict, now)),
        ("backup", backup_section(mirror_fields or {}, mirror_code, verdict, now)),
        (
            "credentials",
            credentials_section(credentials or {}, host_login, verdict, now),
        ),
        (
            "the gate",
            gate_section(held or {}, records, verdict, now, pending)
            + unpushed_rows(archive, verdict),
        ),
        ("deployed", deployed_section(deploy or {}, records, verdict, now)),
    ]
    return "\n".join([verdict.line()] + compose(facts, records, sections))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--selftest", action="store_true", help="prove the arithmetic and stop")
    parser.add_argument(
        "--part",
        choices=("ended", "settled"),
        help="one half of what `just listen` shows when a session ends",
    )
    parser.add_argument(
        "--began", type=int, default=0, metavar="EPOCH", help="when its container started"
    )
    parser.add_argument(
        "--seen", type=int, default=0, metavar="EPOCH", help="when `listen` saw it gone"
    )
    parser.add_argument(
        "--findings", default="", metavar="FILE", help="what the first half found, for the second"
    )
    args = parser.parse_args()
    if args.selftest:
        return selftest()

    facts = block(sys.stdin.read() if not sys.stdin.isatty() else "")
    if not facts:
        sys.exit("Run this through 'just status', which reads the live facts first.")

    records = []
    root = os.environ.get("RUNNER_RECORDS_DIR") or ""
    if root and os.path.isdir(root):
        records = screen.load(root)

    if args.part == "ended":
        print(
            render_part(
                "ended",
                facts,
                records,
                time.time(),
                args.began,
                args.seen,
                findings=args.findings,
                stats=read_stats(args.began),
            )
        )
        return 0

    held = {}
    cache = os.environ.get("RUNNER_REVIEW_HELD") or ""
    if cache and os.path.exists(cache):
        with open(cache) as handle:
            held = block(handle.read().replace("=", ": "))

    deploy_out, deploy_code = ask(["just", "deploy", "--state"], timeout=60)
    deploy = block(deploy_out) if deploy_out is not None and not deploy_code else {}

    if args.part == "settled":
        state, state_at = {}, None
        monitor = os.environ.get("RUNNER_MONITOR") or ""
        path = os.path.join(monitor, MEMORY_STATE)
        if monitor and os.path.exists(path):
            with open(path, errors="replace") as handle:
                state = block(printable(handle.read()))
            state_at = int(os.path.getmtime(path))
        print(
            render_part(
                "settled",
                facts,
                records,
                time.time(),
                args.began,
                args.seen,
                findings=args.findings,
                deploy=deploy,
                held=held,
                archive=os.environ.get("AGENT_ARCHIVE") or "",
                memory_state=state,
                memory_read_at=state_at,
            )
        )
        return 0

    credentials = {}
    store = os.environ.get("RUNNER_CREDENTIALS") or ""
    if store and os.path.exists(store):
        with open(store) as handle:
            credentials = block(handle.read())

    mirror_out, mirror_code = ask(
        [os.path.join(CHECKOUT, "host/archive/mirror.sh"), "--state", one(facts, "session_ended")]
    )

    print(
        render(
            facts,
            records,
            time.time(),
            mirror=(block(mirror_out) if mirror_out is not None else None, mirror_code),
            deploy=deploy,
            held=held,
            archive=os.environ.get("AGENT_ARCHIVE") or "",
            credentials=credentials,
            host_login=host_login_expiry(),
        )
    )
    return 0


# --------------------------------------------------------------------------
# --selftest: the parts that are wrong in ways nothing on screen would show
# --------------------------------------------------------------------------


def selftest():
    # `now` is naive and reset_text is handed a UTC instant, so the cases below
    # that cross midnight only hold in a fixed zone: unpinned, they pass here
    # and fail in CI.  see docs/release.md#each-side-is-proved-on-its-own-interpreter
    os.environ["TZ"] = "Europe/Zurich"
    time.tzset()
    failures = []
    now = datetime.datetime(2026, 9, 7, 20, 26).timestamp()

    def check(name, got, want):
        if got != want:
            failures.append("%s\n      got:  %r\n      want: %r" % (name, got, want))

    def has(name, text, needle):
        if needle not in text:
            failures.append("%s\n      %r is not in:\n%s" % (name, needle, text))

    def hasnt(name, text, needle):
        if needle in text:
            failures.append("%s\n      %r should not be in:\n%s" % (name, needle, text))

    # --- reading ---
    check(
        "a repeated key keeps every value",
        block("problem: one\nproblem: two\nlate: no"),
        {"problem": ["one", "two"], "late": ["no"]},
    )
    check("a line with no separator is not a field", block("nonsense"), {})
    check("a field that did not arrive is not a zero", number(""), None)
    check("a count of zero is a zero", number("0"), 0)

    # --- clocks ---
    check("under a minute is said in seconds", span(42), "42s")
    check("a minute is said in minutes", span(60), "1m")
    check("hours carry their minutes", span(9207), "2h 33m")
    check("days carry their hours", span(451800), "5d 5h")
    check("today is said as today", stamp(now - 2600, now), "19:42 today")
    check("an older instant carries its date", stamp(now - 90000, now), "09-06 19:26")
    check(
        "a reset is an instant and a distance",
        reset_text("2026-09-07T23:00:00Z", now),
        "09-08 01:00, in 4h 34m",
    )
    check("an unreadable reset is passed through", reset_text("soon", now), "soon")

    # --- the verdict ---
    v = Verdict()
    check("silence is not an alarm", v.line(), "Nothing here needs attention.")
    v.watch("the budget guard is off")
    check(
        "a watch is not a problem",
        v.line(),
        "Nothing is broken. To watch: the budget guard is off.",
    )
    v.problem("the backup has stopped")
    has("a problem leads the line", v.line(), "NEEDS ATTENTION: the backup has stopped.")
    has("a problem does not hide a watch", v.line(), "Also to watch: the budget guard is off.")

    # --- the mirror is not on a clock ---
    v = Verdict()
    rows = backup_section(
        block(
            "verdict: running\nlast_run: %d\nconclusion: success\ndue: %d\nlate: no\n"
            % (now - 3000, now + 600)
        ),
        0,
        v,
        now,
    )
    has(
        "a run not yet due says when it may come",
        "\n".join(fact(rows)),
        "at the next session end after 20:36",
    )
    check("a run not yet due is not a fault", v.found, [])

    v = Verdict()
    rows = backup_section(
        block(
            "verdict: running\nlast_run: %d\nconclusion: success\ndue: %d\nlate: no\n"
            % (now - 7200, now - 3600)
        ),
        0,
        v,
        now,
    )
    has(
        "a due run with no session since is merely waiting", "\n".join(fact(rows)), "due since then"
    )
    check("waiting for a session end is not a fault", v.found, [])

    v = Verdict()
    rows = backup_section(
        block(
            "verdict: stopped\nlast_run: %d\nconclusion: success\ndue: %d\nlate: yes\n"
            "problem: a session ended 30m ago and no mirror run followed it\n"
            % (now - 7200, now - 3600)
        ),
        1,
        v,
        now,
    )
    check(
        "a session that ended without a run is one problem, not two",
        [level for level, _ in v.found],
        [PROBLEM],
    )
    has("and it says which way it is late", "\n".join(fact(rows)), "LATE")

    v = Verdict()
    rows = backup_section({}, None, v, now)
    check(
        "a reading that failed is not a working backup",
        v.found,
        [(WATCH, "the backup could not be read")],
    )

    v = Verdict()
    backup_section(block("verdict: stopped\nproblem: no run for 9 hours\n"), 1, v, now)
    check("a stopped mirror is a problem", [level for level, _ in v.found], [PROBLEM])

    # --- credentials ---
    check("a date is read to the end of its day", day_end("2026-09-07") - now, 12840.0)
    check("a note with no date carries no date", note_date("rotated by hand"), None)
    check(
        "the note is read for one shape and nothing else",
        note_date("setup-token, rotated 2026-09-08, expires 2027-09-08"),
        "2027-09-08",
    )
    check(
        "a year away keeps its year on screen",
        far_stamp(day_end("2027-09-08"), now),
        "2027-09-09 00:00",
    )
    check("this year does not", far_stamp(now + 86400, now), "09-08 20:26")
    check(
        "the header keeps its hour and its offset",
        header_expiry("2026-11-22 08:19:24 +0100"),
        datetime.datetime(
            2026, 11, 22, 8, 19, 24, tzinfo=datetime.timezone(datetime.timedelta(hours=1))
        ).timestamp(),
    )
    # The shape GitHub actually sends. Parsed as local time it is an hour or
    # two out, in a number nothing on screen would contradict.
    check(
        "a named zone is not read as local time",
        header_expiry("2026-11-21 23:40:12 UTC"),
        datetime.datetime(2026, 11, 21, 23, 40, 12, tzinfo=datetime.UTC).timestamp(),
    )
    check(
        "a header of another shape still answers to the day",
        header_expiry("2026-11-22"),
        day_end("2026-11-22"),
    )
    check("a header that is nothing is not a date", header_expiry(""), None)

    v = Verdict()
    rows = credentials_section({}, None, v, now)
    check(
        "no reading is not a clean screen",
        v.found,
        [(WATCH, "nothing is known about when the agent's credentials expire")],
    )
    has("and it says what to run", "\n".join(fact(rows)), "just credentials")

    v = Verdict()
    rows = credentials_section(
        block("read_at: %d\nclaude_note: the login, expires 2027-09-08\n" % now), None, v, now
    )
    check("a credential a year out is not a finding", v.found, [])
    has("and the row shows the day the note carries", "\n".join(fact(rows)), "2027-09-08 —")

    v = Verdict()
    credentials_section(block("read_at: %d\nclaude_note: expires 2026-09-22\n" % now), None, v, now)
    check("inside three weeks is a watch", [level for level, _ in v.found], [WATCH])

    v = Verdict()
    credentials_section(block("read_at: %d\nclaude_note: expires 2026-09-10\n" % now), None, v, now)
    check("inside a week is a problem", [level for level, _ in v.found], [PROBLEM])

    v = Verdict()
    rows = credentials_section(
        block("read_at: %d\nclaude_note: expires 2026-09-01\n" % now), None, v, now
    )
    has("a date that has passed says so", "\n".join(fact(rows)), "expired 5d 20h ago")
    check("and it is a problem", [level for level, _ in v.found], [PROBLEM])

    # A note that was never given a date reads on screen exactly like a token
    # with years left, and that is the failure this row exists to prevent.
    v = Verdict()
    rows = credentials_section(block("read_at: %d\nclaude_note: the login\n" % now), None, v, now)
    check(
        "a note with no date is a watch, not an expiry",
        v.found,
        [(WATCH, "no expiry is recorded for the Claude setup-token")],
    )
    has("and it says what to write", "\n".join(fact(rows)), "expires YYYY-MM-DD")

    v = Verdict()
    rows = credentials_section(block("read_at: %d\ngithub_login: agent\n" % now), None, v, now)
    has("a token with no expiry is answered, not unknown", "\n".join(fact(rows)), "no expiry set")
    check("and a token that never dies is not a finding", v.found, [])

    v = Verdict()
    rows = credentials_section(block("read_at: %d\n" % now), now + 3600, v, now)
    has("this host's login is shown", "\n".join(fact(rows)), "this host's own login")
    check("and never judged, however close", v.found, [])

    v = Verdict()
    credentials_section(block("read_at: %d\n" % (now - 5 * 86400)), None, v, now)
    check(
        "a reading nobody refreshed is a watch",
        v.found,
        [(WATCH, "the credential reading is 5d 0h old")],
    )

    v = Verdict()
    rows = credentials_section(
        block("read_at: %d\nproblem: gh refused the token\n" % now), None, v, now
    )
    check("what the reader could not do is a problem", v.found, [(PROBLEM, "gh refused the token")])

    # --- what is live ---
    records = [
        {
            "start": now - 3600,
            "end": now - 3000,
            "requests": 62,
            "end_context": 170403,
            "usage": [{"usd": 6.98}],
            "subagents": [],
            "runs": [{"from": now - 3600, "to": now - 3000, "runner_commit": "5a7f69a"}],
        },
        {
            "start": now - 7200,
            "end": now - 6600,
            "requests": 10,
            "end_context": 900,
            "usage": [{"usd": 1.0}],
            "subagents": [{"usage": [{"usd": 0.5}]}],
            "runs": [{"from": now - 7200, "to": now - 6600, "runner_commit": "17abcfd"}],
        },
    ]
    v = Verdict()
    rows = deployed_section(
        block(
            "worktree: present\ndeployed: 17abcfd\nahead: 0\ndeployed_at: %d\n"
            "image_deployed: 1e866213dec6\n" % (now - 2400)
        ),
        records,
        v,
        now,
    )
    text = "\n".join(fact(rows))
    has("the live build says since when", text, "live since 19:46 today")
    has("and how much has run on it", text, "1 session on it")
    has("the image is named, not compared", text, "image 1e86621")
    has("up to date is said plainly", text, "up to date with main")

    v = Verdict()
    rows = deployed_section(
        block(
            "worktree: present\ndeployed: 0000000\nahead: 2\ndeployed_at: %d\n"
            "image_deployed: -\ncommit: aaa a subject\ncommit: bbb another\n" % (now - 2400)
        ),
        records,
        v,
        now,
    )
    text = "\n".join(fact(rows))
    has("a build nothing has run on says so", text, "no session has run on it yet")
    has("the backlog carries its subjects", text, "aaa a subject")
    check("being behind main is not a fault", v.found, [])

    v = Verdict()
    deployed_section(
        block("worktree: present\ndeployed: 0000000\nahead: 0\ndropped_commit: ccc gone\n"),
        records,
        v,
        now,
    )
    check("a commit live and not in main is a problem", [level for level, _ in v.found], [PROBLEM])

    # --- the gate ---
    v = Verdict()
    rows = gate_section(block("count: 0\nat: %d\n" % (now - 3000)), records, v, now, pending=0)
    has(
        "a counted zero says when it was counted",
        "\n".join(fact(rows)),
        "none waiting, counted 19:36 today",
    )
    check("nothing waiting is nothing to report", v.found, [])

    v = Verdict()
    rows = gate_section({}, records, v, now, pending=0)
    check("a missing count is not a zero", [level for level, _ in v.found], [WATCH])
    has("and it says what to run", "\n".join(fact(rows)), "just collect --held")

    v = Verdict()
    gate_section(block("count: 3\nat: %d\n" % now), records, v, now, pending=0)
    check("held transcripts are worth watching", [level for level, _ in v.found], [WATCH])

    v = Verdict()
    gate_section(block("count: 0\n"), records, v, now, pending=None)
    check(
        "records that could not be counted are not zero waiting",
        [level for level, _ in v.found],
        [WATCH],
    )

    # --- the budget ---
    v = Verdict()
    reading = (
        "ACCOUNT_USAGE_SESSION=used=3.0 allowed=25.3 ratio=12 budget=20-80 window=5h "
        "resets=2026-09-07T23:00:00Z\n"
        "ACCOUNT_USAGE_WEEKLY=used=30.0 allowed=31.5 ratio=95 budget=10-95 window=7d "
        "resets=2026-09-13T00:00:00Z\n"
        "ACCOUNT_USAGE_SCOPED=Fable (weekly, not gated) 6% used\n"
        "EXHAUSTED=\nREADING_AGE=43\nVERDICT=within budget: session at 12% of its allowance\n"
    )
    rows = budget_section(read_budget(True, reading), True, v, now)
    text = "\n".join(fact(rows))
    has("the deciding number leads the row", text, "session   12%")
    has("the parts follow it", text, "3.0% used, 25.3% allowed now")
    has("the reset is local and relative", text, "resets 09-08 01:00, in 4h 34m")
    has("a scoped limit is carried whole", text, "Fable (weekly, not gated) 6% used")
    has("the age of a cached reading is said", text, "from a reading 43s old")
    check(
        "a week nearly spent is said before it refuses",
        v.found,
        [(WATCH, "the week budget is at 95% of its allowance")],
    )

    v = Verdict()
    budget_section(read_budget(True, reading.replace("ratio=95", "ratio=40")), True, v, now)
    check("a budget with room left is not a fault", v.found, [])

    v = Verdict()
    rows = budget_section(
        read_budget(True, "ACCOUNT_USAGE_SESSION=unknown\nVERDICT=cannot tell: no login\n"),
        True,
        v,
        now,
    )
    check("a budget that cannot be read is a problem", [level for level, _ in v.found], [PROBLEM])
    has("and says what to run", "\n".join(fact(rows)), "just verify")

    v = Verdict()
    budget_section(read_budget(False, reading), False, v, now)
    check(
        "the guard being off is worth watching",
        [text for _l, text in v.found][-1:],
        ["the budget guard is off"],
    )

    v = Verdict()
    over = (
        "ACCOUNT_USAGE_WEEKLY=used=96.0 allowed=31.5 ratio=305 budget=10-95 window=7d "
        "resets=2026-09-13T00:00:00Z\nVERDICT=over budget: weekly_all 96.0% used against 31.5% allowed\n"
    )
    check("over budget is read as over budget", over_budget(read_budget(True, over)), True)
    check(
        "and over is the pressure whatever the ratios say",
        budget_pressure(read_budget(True, over))[0],
        "over",
    )
    check(
        "a week at 95% is near the line",
        budget_pressure(read_budget(True, reading)),
        ("near", "week", 95),
    )
    check(
        "with room left it is clear",
        budget_pressure(read_budget(True, reading.replace("ratio=95", "ratio=40")))[0],
        "clear",
    )
    budget_section(read_budget(True, over), True, v, now)
    check(
        "over budget is a problem, and not also a watch saying it again",
        v.found,
        [(PROBLEM, "over budget — no unattended session starts")],
    )

    # --- what is running now ---
    check(
        "an ordinary model line is not a fault",
        model_fault(["claude-opus-5 answered · opus[1m] requested"]),
        None,
    )
    check(
        "a mismatch is the claim, not the evidence",
        model_fault(["MODEL MISMATCH — sonnet answered, opus was asked for. See docs."]),
        "model mismatch",
    )
    check(
        "an unpinned model is a fault too",
        model_fault(["MODEL UNPINNED. The account decides which model answers."]),
        "model unpinned",
    )

    # --- now ---
    v = Verdict()
    facts = block(
        "running: no\nidle: 12\nscheduling: enabled\ndaemon: running\n"
        "wake_left: 18\nwake_from: session\nwake_why: the last session asked to be woken in 30m\n"
        "wake_default: 30\nwake_min: 15\nwake_max: 180\nwake_armed: yes\nlast_run: clean\n"
    )
    text = "\n".join(fact(now_section(facts, records, v, now)))
    has("the wait is said in the words run uses", text, "in 18m — the last session asked")
    has("the last session comes out of its record", text, "ended 50m ago · ran 10m · 62 requests")
    has("today is counted in sessions and awake time", text, "2 sessions · 20m awake · $8.48")
    check("a quiet machine is not a fault", v.found, [])
    has("a run with no summary says it was not measured", text, "not measured")

    # --- the machine ---
    sampled = {
        "samples": 361,
        "cpus": 1,
        "cpu_busy_mean": 29.84,
        "load1_p95": 3.92,
        "iowait_p95": 17.28,
        "avail_min_mb": 1156,
        "swap_out_mb": 185.0,
        "filesystem": {"mount": "/", "size_mb": 18687, "free_start_mb": 7014, "free_min_mb": 7000},
    }
    check(
        "the machine in two lines",
        machine(sampled),
        [
            "cpu 30% · load p95 3.9 on 1 CPU · iowait p95 17%",
            "lowest free 1156 MB memory, 7000 MB disk · swap out 185 MB",
        ],
    )
    check(
        "a run before filesystems were sampled leaves the disk out",
        machine(dict(sampled, filesystem=None))[1],
        "lowest free 1156 MB memory · swap out 185 MB",
    )
    check("no summary is not a row of zeros", machine(None), ["not measured"])

    # A wake-up that never happened. The wait elapsed, cron fires every minute,
    # and nothing started — which is what the screen said nothing about while a
    # defect in the wake feature kept every session from starting on 2026-09-07.
    elapsed = (
        "running: no\nidle: 40\nscheduling: enabled\ndaemon: running\ncron_every: 1\n"
        "wake_left: 0\nwake_from: none\nwake_why: the default wait is 30m\n"
        "wake_default: 30\nwake_armed: no\nlast_run: clean\nwake_due: %d\n"
    )
    v = Verdict()
    text = "\n".join(fact(now_section(block(elapsed % (now - 60)), records, v, now)))
    has("a wait that has just elapsed is not late", text, "now — the default wait is 30m")
    check("and it is not a fault", v.found, [])

    v = Verdict()
    text = "\n".join(fact(now_section(block(elapsed % (now - 1500)), records, v, now)))
    has("a session 25m overdue says so", text, "DUE SINCE 20:01")
    has("with how long it has been missing", text, "nothing has started in 25m")
    has("and how often something should have tried", text, "fires every 1m")
    check("and it is a problem", [level for level, _ in v.found], [PROBLEM])

    v = Verdict()
    text = "\n".join(
        fact(
            now_section(
                block(elapsed.replace("cron_every: 1", "cron_every: 5") % (now - 300)),
                records,
                v,
                now,
            )
        )
    )
    has("a five-minute line is given five minutes", text, "now — the default wait is 30m")
    check("and it is not a fault", v.found, [])

    v = Verdict()
    text = "\n".join(
        fact(
            now_section(
                block(elapsed.replace("cron_every: 1", "cron_every: unknown") % (now - 9000)),
                records,
                v,
                now,
            )
        )
    )
    has("a line this repository did not write is not judged", text, "now — the default")
    check("and it is not a fault", v.found, [])

    v = Verdict()
    text = "\n".join(
        fact(now_section(block(elapsed % (now - 1500)), records, v, now, ("over", "week", 305)))
    )
    has(
        "a wake-up the budget is holding back is not missing",
        text,
        "the budget gate is refusing it",
    )
    check("and it is not a second alarm", v.found, [])

    # The allowance climbs through the window, so a session refused twenty
    # minutes ago is admitted now with nothing changed but the clock.
    v = Verdict()
    text = "\n".join(
        fact(now_section(block(elapsed % (now - 1500)), records, v, now, ("near", "week", 97)))
    )
    has(
        "a near-line budget is shown as the reason",
        text,
        "the week budget is at 97% of its allowance",
    )
    has(
        "and the verdict does not repeat the number the budget row carries",
        "; ".join(t for _l, t in v.found),
        "held back by the budget",
    )
    has("and the wait is still shown as overdue", text, "DUE SINCE 20:01")
    check("but it is a watch and not a broken mechanism", [level for level, _ in v.found], [WATCH])

    v = Verdict()
    facts = block(
        "running: no\nidle: 12\nscheduling: paused\ndaemon: running\nwake_left: 0\n"
        "wake_why: the default wait is 30m\nwake_default: 30\nwake_armed: no\nlast_run: clean\n"
    )
    text = "\n".join(fact(now_section(facts, records, v, now)))
    has("a paused schedule says nothing starts", text, "nothing starts on its own")
    check("and it is worth watching", [level for level, _ in v.found], [WATCH])

    v = Verdict()
    facts = block(
        "running: no\nidle: 12\nscheduling: enabled\ndaemon: stopped\nwake_left: 0\n"
        "wake_why: the default wait is 30m\nwake_default: 30\nwake_armed: no\nlast_run: clean\n"
    )
    now_section(facts, records, v, now)
    check("enabled with no daemon is a problem", [level for level, _ in v.found], [PROBLEM])

    v = Verdict()
    facts = block(
        "running: no\nidle: 12\nscheduling: enabled\ndaemon: running\nwake_left: 0\n"
        "wake_why: the default wait is 30m\nwake_default: 30\nwake_armed: no\n"
        "last_run: stopped limit\n"
    )
    text = "\n".join(fact(now_section(facts, records, v, now)))
    has("a stop nobody has been told about is said", text, "stopped (limit)")
    check("and it is worth watching", [level for level, _ in v.found], [WATCH])

    v = Verdict()
    facts = block(
        "running: yes\nkind: auto\ncontainer: agent-session-1\nstarted: %d\n"
        "scheduling: enabled\ndaemon: running\nwake_default: 30\nwake_min: 15\n"
        "wake_max: 180\nwake_armed: yes\nlast_run: running\n" % (now - 991)
    )
    text = "\n".join(fact(now_section(facts, [], v, now)))
    has("a running session is one line with its container", text, "started 20:09, up 16m")
    has("and the next one waits for it", text, "when this one ends, +30m unless it asks otherwise")
    has("the bounds it may ask inside are said", text, "(it may ask for 15–180m)")
    hasnt("docker's own uptime is not repeated", text, "Up 16 minutes")

    # --- the end of a session ---
    waiting = block(
        "running: no\nidle: 1\nscheduling: enabled\ndaemon: running\nwake_left: 18\n"
        "wake_due: %d\nwake_why: the last session asked to be woken in 30m\n"
        "wake_default: 30\nwake_min: 15\nwake_max: 180\nwake_armed: yes\nlast_run: clean\n"
        % (now + 18 * 60)
    )
    has(
        "the wait carries its clock time",
        next_line(waiting, Verdict(), False, now),
        "20:44 today, in 18m — the last session asked",
    )

    check("a reading must postdate the end", fresh_cache_minutes(now - 30, now, {}), 0.5)
    check(
        "long after the end, the configured lifetime", fresh_cache_minutes(now - 3600, now, {}), 5.0
    )
    check(
        "a cache turned off stays off",
        fresh_cache_minutes(now - 30, now, {"ACCOUNT_BUDGET_CACHE_MINUTES": "0"}),
        None,
    )
    check(
        "a lifetime claude-usage refuses is left for it to say so",
        fresh_cache_minutes(now - 30, now, {"ACCOUNT_BUDGET_CACHE_MINUTES": "soon"}),
        None,
    )
    check(
        "an end still ahead refuses every reading", fresh_cache_minutes(now + 10, now, {}), 1 / 60
    )

    check(
        "the host's own stamp is the end",
        session_end(block("session_ended: %d\n" % (now - 40)), now - 900, now - 30),
        now - 40,
    )
    check(
        "a stamp from before the session began is not its end",
        session_end(block("session_ended: %d\n" % (now - 1000)), now - 900, now - 30),
        now - 30,
    )

    stats = [
        "122 requests · 87k output, 39k thinking",
        "234k end context · 52m17s elapsed",
        "claude-opus-5 answered · opus[1m] requested",
    ]
    v = Verdict()
    text = "\n".join(fact(ended_section(waiting, v, now, now - 60, stats)))
    has("the end is said as an instant", text, "ended 20:25 today")
    has("what it spent is the transcript's", text, "122 requests")
    has("and the next start follows it", text, "20:44 today, in 18m")
    check("a quiet end is not a fault", v.found, [])

    v = Verdict()
    ended_section(
        waiting, v, now, now - 60, ["MODEL MISMATCH — sonnet answered, opus was asked for."]
    )
    check("a model mismatch reaches the verdict", v.found, [(PROBLEM, "model mismatch")])

    v = Verdict()
    has(
        "a summary that could not be read says so",
        "\n".join(fact(ended_section(waiting, v, now, now - 60, None))),
        "could not be read",
    )

    check(
        "the session's run is the one still going when it began",
        (session_run(records, now - 3500) or {}).get("runner_commit"),
        "5a7f69a",
    )
    check("a session not sealed has no run", session_run(records, now - 60), None)

    ran = {"commits": ["a", "b", "c"]}
    v = Verdict()
    rows = memory_rows(block("unpushed: 0\nuncommitted: 0\n"), now, ran, now - 60, v)
    has(
        "a pushed, clean session is said plainly",
        "\n".join(fact(rows)),
        "3 commits this session · all on origin · working tree clean",
    )
    check("and is not a finding", v.found, [])

    v = Verdict()
    rows = memory_rows(
        block(
            "unpushed: 2\nuncommitted: 0\npush_reason: push-failed: HEAD\npush_consecutive: 2\n"
            "push_detail: git@github.com: Permission denied (publickey).\n"
        ),
        now,
        ran,
        now - 60,
        v,
    )
    text = "\n".join(fact(rows))
    has("a failed push names its reason", text, "PUSH FAILED: push-failed: HEAD, 2 in a row")
    has("and git's own words", text, "Permission denied (publickey)")
    check(
        "and is one problem, not one per symptom",
        v.found,
        [(PROBLEM, "the memory push failed (push-failed: HEAD)")],
    )

    v = Verdict()
    memory_rows(block("unpushed: 2\nuncommitted: 0\n"), now, ran, now - 60, v)
    check(
        "commits not on origin with no report are a problem",
        [level for level, _ in v.found],
        [PROBLEM],
    )

    v = Verdict()
    memory_rows(block("unpushed: 0\nuncommitted: 4\n"), now, ran, now - 60, v)
    check(
        "uncommitted work is a watch",
        v.found,
        [(WATCH, "4 uncommitted change(s) in the agent's checkout")],
    )

    v = Verdict()
    memory_rows(block("unpushed: -\nuncommitted: -\n"), now, ran, now - 60, v)
    check(
        "a checkout that could not be read is not a clean one",
        [level for level, _ in v.found],
        [WATCH, WATCH],
    )

    v = Verdict()
    text = "\n".join(
        fact(memory_rows(block("unpushed: 0\nuncommitted: 0\n"), now - 120, None, now - 60, v))
    )
    has("a record not sealed says so", text, "not sealed yet")
    has("a reading from before the end is not this session's", text, "not read since")
    check("and is worth watching", [level for level, _ in v.found], [WATCH])

    check(
        "the reader's own count comes before anything the flag carries",
        one(block("unpushed: 0\npush_detail: x\nunpushed: 9\n"), "unpushed"),
        "0",
    )
    check("control characters do not reach the terminal", printable("a\x1b[2Jb\n"), "a[2Jb\n")

    v = Verdict()
    check("a part says what it covers", v.line(shown=True), "Nothing shown here needs attention.")
    v.watch("x")
    check("and so does its watch", v.line(shown=True), "Nothing shown here is broken. To watch: x.")

    v = Verdict()
    text = "\n".join(
        fact(
            deployed_section(
                block(
                    "worktree: present\ndeployed: 1b8aaef\nagainst: origin/main\nahead: 3\n"
                    "dropped: 0\ncommit: 49f160a newest\ncommit: 3e4129b oldest\n"
                ),
                records,
                v,
                now,
            )
        )
    )
    has("behind origin says which origin", text, "3 commit(s) behind origin/main")
    has("with the subjects origin gave", text, "49f160a newest")
    check("and is not a fault", v.found, [])

    v = Verdict()
    text = "\n".join(
        fact(
            deployed_section(
                block(
                    "worktree: present\ndeployed: 1b8aaef\nagainst: origin\nahead: -\n"
                    "dropped: -\ncompare_error: gh here cannot read it\n"
                ),
                records,
                v,
                now,
            )
        )
    )
    has(
        "an origin that did not answer is not up to date",
        text,
        "how far behind origin could not be read — gh here cannot read it",
    )
    check("and is worth watching", [level for level, _ in v.found], [WATCH])

    v = Verdict()
    deployed_section(
        block(
            "worktree: present\ndeployed: 1b8aaef\nagainst: origin/main\nahead: -\n"
            "dropped: -\nlive_missing: yes\n"
        ),
        records,
        v,
        now,
    )
    check(
        "a live commit origin lacks is one problem",
        v.found,
        [(PROBLEM, "the live commit 1b8aaef is not on origin/main")],
    )

    v = Verdict()
    text = "\n".join(
        fact(
            deployed_section(
                block(
                    "worktree: present\ndeployed: 1b8aaef\nagainst: origin/main\nahead: 0\n"
                    "dropped: 2\n"
                ),
                records,
                v,
                now,
            )
        )
    )
    has("a count with no subjects still says what a deploy drops", text, "would drop 2 commit(s)")
    check("and is a problem", [level for level, _ in v.found], [PROBLEM])

    handle, carried = tempfile.mkstemp()
    os.close(handle)
    try:
        text = render_part(
            "ended",
            waiting,
            records,
            now,
            now - 900,
            now - 60,
            findings=carried,
            budget=over,
            stats=stats,
        )
        has("the first half is the session", text, "── SESSION")
        has("and the budget", text, "── BUDGET")
        text = render_part(
            "settled",
            waiting,
            records,
            now,
            now - 900,
            now - 60,
            findings=carried,
            deploy=block(
                "worktree: present\ndeployed: 17abcfd\nagainst: origin/main\nahead: 0\ndropped: 0\n"
            ),
            held=block("count: 0\n"),
            pending=0,
            memory_state=block("unpushed: 0\nuncommitted: 0\n"),
            memory_read_at=now,
        )
        has("the second half is what the bookkeeping left", text, "── AFTER IT")
        has("its deploy row is named", text, "deployed      17abcfd · ")
        has(
            "and its last line judges both halves",
            text.splitlines()[-1],
            "NEEDS ATTENTION: over budget",
        )
    finally:
        os.unlink(carried)

    if failures:
        for failure in failures:
            print("FAIL %s" % failure, file=sys.stderr)
        print("status --selftest FAILED (%d)" % len(failures), file=sys.stderr)
        return 1
    print("status --selftest ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
