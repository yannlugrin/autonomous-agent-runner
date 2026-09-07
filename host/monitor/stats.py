#!/usr/bin/env python3
"""What the agent has been doing, and whether that is changing — one screen.

    stats.py [-d N] [--all]   the screen
    stats.py --selftest       prove the arithmetic and stop

Runs on the host, under `just stats`. It reads the sealed records in
RUNNER_RECORDS_DIR and nothing else — no transcript, no jq filter, no volume —
and two facts from outside them: which build is live, from `just deploy
--state`, and the agent's newest journal heading, from this host's clone of its
repository. Both are read, never written, and neither is required.

Three traps, each of which produces a plausible wrong number and no symptom:

  A SESSION IS A RUN. `chat --continue` appends to the transcript it resumes, so
  one archived file holds two runs today. Durations are `to - from` per run and
  never `end - start`: that transcript spans 8h 34m for 3h 25m of work, with
  fifteen unattended sessions inside the gap.

  TWO DENOMINATORS LIVE IN ONE RECORD. `runs` is per run; `messages`,
  `end_context`, `usage` and `subagents` are per TRANSCRIPT. A per-transcript
  mean is taken over the count of transcripts, never of runs, and the two differ
  by one today.

  A PROBE IS NOT A SESSION, and `started_by` is the only thing that separates
  them.

Everything else — the periods, the shape of the screen, and the figures that
were struck — is docs/monitor.md#the-stats-screen.
"""

import argparse
import collections
import datetime
import importlib.util
import json
import math
import os
import statistics
import subprocess
import sys
import time

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The 7-day chart and the "longest gap" window. Seven rows forever: a block that
# gains a row a day is the fault the weekly table's cap exists to avoid, faster.
RECENT = 7
# Weeks in the table when nobody asked for more. Four, and it does not grow on
# its own; -d N is how a reader reaches further back.
WEEKS = 4
# The busiest day's bar. Length carries the value and hue carries nothing — the
# operator is deutan colourblind, and this is not a preference.
BAR = 22
# Above this a session ended with its context more than three quarters full.
FULL = 150_000

# What a session nobody was in is called, on screen and in this repository's own
# prose — 115 uses across docs/ and AUTO-MODE.md. The distinction it names is
# attendance and not autonomy: a chat session is no less the agent's own. The
# stored field is still `kind: auto`, which is what `just sessions` and
# `session-meta.jq` speak; this is the label, and only the label.
#
# Clipped to SHORT where the full word would set a column eight characters wider
# than the two-digit numbers under it.
UNATTENDED = "unattended"
SHORT = "unatt."
LABEL = "%s time" % SHORT


def load_cost():
    """image/session-cost.py, the only price table there is."""
    spec = importlib.util.spec_from_file_location(
        "session_cost", os.path.join(CHECKOUT, "image/session-cost.py")
    )
    if spec is None or spec.loader is None:
        sys.exit("Could not load image/session-cost.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------
# Spelling a count the way the agent spells it
# --------------------------------------------------------------------------
# The opening line prints our count in words, and the agent's own journal
# headings carry the same number in the same idiom — so the two agreeing is a
# check that costs nothing and needs no parser.
#
# COMPARE BY RENDERING, NEVER BY PARSING. There is no words-to-integer parser
# here on purpose: the comparison cannot then drift from the string printed on
# the line above, and a renumbering shows up as a plain mismatch rather than as
# a number nobody can source.

ONES = (
    "", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen",
)  # fmt: skip
TENS = ("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
ORDINAL = {"one": "first", "two": "second", "three": "third", "five": "fifth",
           "eight": "eighth", "nine": "ninth", "twelve": "twelfth"}  # fmt: skip


def cardinal(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("-" + ONES[n % 10] if n % 10 else "")
    if n < 1000:
        head = ONES[n // 100] + "-hundred"
        return head + ("-and-" + cardinal(n % 100) if n % 100 else "")
    head = cardinal(n // 1000) + "-thousand"
    rest = n % 1000
    if not rest:
        return head
    # "and" joins a remainder below a hundred and nothing else: one-thousand-and-
    # twenty-first, but one-thousand-one-hundredth.
    return head + ("-and-" if rest < 100 else "-") + cardinal(rest)


def ordinal_words(n):
    """`567` -> `five-hundred-and-sixty-seventh`."""
    head, _, last = cardinal(n).rpartition("-")
    if last in ORDINAL:
        last = ORDINAL[last]
    elif last.endswith("y"):
        last = last[:-1] + "ieth"
    else:
        last += "th"
    return (head + "-" + last) if head else last


def spellings(n):
    """Ours first, then the other one that is also correct English.

    The agent drops the leading `one` below a thousand — `hundred-and-first`,
    never `one-hundred-and-first` — so that is the form printed beside its own.
    Both are accepted when comparing, because which it reaches for above a
    thousand is its choice and a false alarm is an alarm nobody reads.
    see docs/monitor.md#the-count-spelled-out
    """
    standard = ordinal_words(n)
    for prefix in ("one-hundred", "one-thousand"):
        if standard.startswith(prefix):
            return (standard[len("one-") :], standard)
    return (standard, standard)


# --------------------------------------------------------------------------
# The store
# --------------------------------------------------------------------------


def load(root):
    """Every sealed record that describes a real session."""
    found = []
    for base, _dirs, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".json"):
                continue
            with open(os.path.join(base, name)) as handle:
                record = json.load(handle)
            # A probe is not a session, and no care about a window fixes a
            # denominator.  see docs/monitor.md#a-probe-is-not-a-session
            #
            # A record with no runs has no timestamps at all — an undated
            # transcript — so there is no day to place it on and nothing here
            # could count it either way.
            if record.get("started_by") and record["runs"]:
                found.append(record)
    return found


def local_day(ts):
    return datetime.date.fromtimestamp(ts)


class Window:
    """The records and the runs the screen reports on, and the days they sit in.

    Days are counted back from the newest run's local day with date arithmetic
    rather than by dividing seconds, so an hour lost to a clock change does not
    move a session into the day before.
    """

    def __init__(self, records, days=None, every=False):
        runs = [(r, run) for r in records for run in r["runs"]]
        today = datetime.date.today()
        yesterday = today - datetime.timedelta(days=1)

        # `-d N` IS N COMPLETE DAYS AND TODAY IS NOT ONE OF THEM. Counting back
        # from today spends one of the N on however many hours today has lived,
        # so `-d 14` covered thirteen days and a morning and the week-by-week
        # table could show one row where two were asked for.
        # Today's own sessions, kept whatever the window is. Its row sits below
        # the break as an addendum and belongs to no period, so `-d 14` must
        # keep it out of the totals and the weeks without taking it off screen.
        self.today = [p for p in runs if local_day(p[1]["from"]) == today]
        self.today_records = [r for r in records if local_day(r["start"]) == today]

        if days:
            self.until, self.since = yesterday, yesterday - datetime.timedelta(days=days - 1)
            runs = [p for p in runs if self.since <= local_day(p[1]["from"]) <= self.until]
            records = [r for r in records if self.since <= local_day(r["start"]) <= self.until]
        self.runs = sorted(runs, key=lambda p: p[1]["from"])
        self.records = records
        if not self.runs:
            return
        if not days:
            # Everything the records hold, and the window runs to TODAY rather
            # than to the last day a session ran: a day the agent did not wake
            # is still a day, and following the newest session instead would
            # make an outage disappear off the end of the daily table exactly
            # when it matters.
            self.until = today
            self.since = min(local_day(run["from"]) for _r, run in self.runs)

        # The span, and the one denominator every "per day" on the screen uses:
        # a rate over the days the window covers, idle ones included, and not
        # over the days that happen to carry a session.
        self.days = (self.until - self.since).days + 1

        # The daily table's own period: complete days, ending yesterday, never
        # reaching past the window. `just stats -d 3` must not print four empty
        # days and call them a week.
        self.last_full = min(yesterday, self.until)
        span = (self.last_full - self.since).days + 1
        # RECENT rows unless asked for every one. The cap is on what the screen
        # does BY ITSELF — a block that gains a row a day as the archive ages is
        # the fault `--all` is not, because `--all` is a reader asking.
        self.full = max(0, span if every else min(RECENT, span))
        self.first_full = self.last_full - datetime.timedelta(days=self.full - 1)

    def auto(self):
        return [run for record, run in self.runs if record["kind"] == "auto"]

    def transcripts(self, kind=None):
        return [r for r in self.records if kind is None or r["kind"] == kind]


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


WIDTH = 78


def rule(title):
    """A section heading, and the screen's only structure.

    A rule and not colour, and not bold: the operator is deutan colourblind, and
    a pipe or a file has to carry the same structure a terminal does.
    """
    head = "── %s " % title.upper()
    return ["", head + "─" * max(0, WIDTH - len(head)), ""]


def fact(rows):
    """A headline number, then what it is made of, on the same line.

    Everything after the gap belongs to the figure before it, so what relates to
    what needs no explaining, and a section opening every line with a number and
    a noun is scanned rather than read.
    see docs/monitor.md#the-shape-of-the-screen
    """
    width = max(len(head) for head, _detail in rows)
    out = []
    for head, detail in rows:
        first, *rest = detail
        out.append(("   " + head.ljust(width) + "   " + first).rstrip())
        out += ["   " + " " * width + "   " + more for more in rest]
    return out


def duration(seconds):
    """`115h 40m`, with the space: at a terminal's stroke weight `h` and `4` are
    the same mark, and `115h40m` has to be parsed rather than read."""
    if seconds >= 3600:
        return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)
    return "%dm" % (seconds // 60)


def when(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M")


def usd_of(record, cost, reprice=False):
    """What one session cost, including everything it delegated to.

    The record deliberately stores no total: "what a session cost" means either
    the main chain or the main chain plus its sub-agents, and a stored total
    picks one silently. This is the second, said here rather than assumed.

    `reprice` puts every session on today's table instead of the one that priced
    it. Each record carries the rates it was priced under, so a column comparing
    one week with another across a rate change is otherwise two rulers under one
    heading.
    """
    rows = list(record["usage"]) + [u for s in record["subagents"] for u in s["usage"]]
    if not reprice:
        return sum(row["usd"] or 0.0 for row in rows)
    total = 0.0
    for row in rows:
        counts = {
            "input": row["input"],
            "write5m": row["cache_write_5m"],
            "write1h": row["cache_write_1h"],
            "read": row["cache_read"],
            "output": row["output"],
        }
        try:
            total += sum(cost.dollars(counts, row["model"], row["speed"], row["geo"]).values())
        except cost.Unpriceable:
            # A model the table does not hold is never priced as zero. It keeps
            # its stored figure, which was computed when the table did hold it.
            total += row["usd"] or 0.0
    return total


def opening(lifetime, name, heading):
    """The count in words, and the agent's own heading as a check on it.

    OVER THE WHOLE STORE, never the window: this says how many sessions the agent
    has ever run, which is the number its heading carries.

    OURS IS THE COUNT; ITS HEADING IS A LABEL IT MAINTAINS. Silent when they
    agree.  see docs/monitor.md#the-count-spelled-out
    """
    ours, alternate = spellings(len(lifetime.runs))
    out = ["%s stands at its %s session." % (name, ours)]
    text, why = heading
    if why:
        out.append("  Its journal was not read, so the count was not checked: %s" % why)
    elif not any(form in text for form in (ours, alternate)):
        out.append("  Its own newest journal heading says otherwise:")
        out.append("    %s" % text[3:].split(" — ")[0])
        out.append("  The count above is ours, from the records. That is a label it maintains.")
    return out


def summary(window, cost):
    """How much of what, over what span, at what weight."""
    return "%d sessions   %s → %s   %d days   $%.0f at list rates" % (
        len(window.runs),
        window.since,
        window.until,
        window.days,
        sum(usd_of(r, cost) for r in window.records),
    )


def awake_of(runs):
    """Wall-clock time inside a session, of whatever kind."""
    return sum(run["to"] - run["from"] for _record, run in runs)


def awake_split(window, runs=None):
    """`awake` split on kind, because the word carried two denominators.

    Every `awake` is every run; the detail names the two parts, so the split is
    on the line rather than in a convention a reader has to know.
    see docs/monitor.md#what-every-number-counts
    """
    runs = window.runs if runs is None else runs
    auto = [pair for pair in runs if pair[0]["kind"] == "auto"]
    chat = [pair for pair in runs if pair[0]["kind"] != "auto"]
    if not chat:
        return "all of it %s" % UNATTENDED
    return "%s %s, %s chat" % (duration(awake_of(auto)), UNATTENDED, duration(awake_of(chat)))


def whole(window, cost):
    """Section one: everything the window holds, one fact to a line.

    Ordered by what a person opens this to find out — how much ran, how long it
    took, what it produced, what it cost — and then the three that are detail
    rather than headline.
    """
    auto = window.auto()
    lengths = [run["to"] - run["from"] for run in auto]
    longest = max(auto, key=lambda run: run["to"] - run["from"])
    commits = sum(len(run["commits"]) for _r, run in window.runs)
    rows = [
        (
            "%d sessions" % len(window.runs),
            ["%d %s, %d chat" % (len(auto), UNATTENDED, len(window.runs) - len(auto))],
        ),
        (
            "%s awake" % duration(awake_of(window.runs)),
            [awake_split(window)],
        ),
        (
            "%.1fm a session" % (statistics.mean(lengths) / 60),
            [
                "%s; the longest was %s on %s"
                % (UNATTENDED, duration(longest["to"] - longest["from"]), when(longest["from"]))
            ],
        ),
        (
            "%d commits" % commits,
            ["%.1f a session, %.0f a day" % (commits / len(auto), commits / window.days)],
        ),
        (
            "$%.0f at list rates" % sum(usd_of(r, cost) for r in window.records),
            ["what this traffic would cost per token — weight, never money spent"],
        ),
    ]
    return fact(rows + detail(window))


def detail(window):
    """The three that are a breakdown rather than a headline.

    Each is skipped rather than printed as a zero: a window that delegated
    nothing has nothing to say about delegation, and a row of noughts is a line
    the eye has to read to learn that.
    """
    rows = []

    ended = [r["end_context"] for r in window.transcripts("auto") if r["end_context"]]
    if ended:
        rows.append(
            (
                "%.0fk context" % (statistics.mean(ended) / 1000),
                [
                    "on average; %.0fk at most, %.0f%% of sessions ended above %dk"
                    % (
                        max(ended) / 1000,
                        100 * sum(1 for c in ended if c > FULL) / len(ended),
                        FULL / 1000,
                    )
                ],
            )
        )

    kinds = collections.Counter()
    for record in window.records:
        for sub in record["subagents"]:
            kinds[sub["type"]] += 1
    if kinds:
        rows.append(
            (
                "%d sub-agents" % sum(kinds.values()),
                wrap(["%d %s" % (v, k) for k, v in kinds.most_common()]),
            )
        )
    return rows


def wrap(items, width=52):
    """A breakdown as prose, broken where it has to be and never mid-item."""
    lines, line = [], ""
    for item in items:
        candidate = item if not line else line + ", " + item
        if len(candidate) > width and line:
            lines.append(line + ",")
            line = item
        else:
            line = candidate
    return lines + [line]


def recent(window, cost):
    """Section two: what the last seven days looked like, day by day.

    A table because the rows are compared with each other. `mean` and `ctx+out`
    are over the UNATTENDED runs of that day, as every time and context figure on
    the screen is, so a conversation cannot swing a column on the days one
    happened.  see docs/monitor.md#what-every-number-counts
    """
    counts = collections.Counter()
    lengths = collections.defaultdict(list)
    # Today's runs are folded in whatever the window is: its row is an addendum
    # below the break and belongs to no period, so `-d 14` keeps it out of the
    # totals without taking it off screen.
    #
    # ADDED ONLY WHEN THE WINDOW STOPS SHORT OF TODAY, which is only when one was
    # asked for. With no `-d`, `runs` was never filtered and already holds today,
    # so adding it again drew every one of today's sessions twice -- the count
    # and the awake column and the bar, while `mean` and `ctx+out` survived
    # because doubling a list does not move its mean. That is what made the row
    # read as plausible: the only witness on screen was the section above, whose
    # total is three sessions larger than the sixteen day rows and was six.
    addendum = window.today if window.until < datetime.date.today() else []
    for record, run in window.runs + addendum:
        day = local_day(run["from"])
        counts[(day, record["kind"])] += 1
        if record["kind"] == "auto":
            lengths[day].append(run["to"] - run["from"])
    context = collections.defaultdict(list)
    today_records = window.today_records if window.until < datetime.date.today() else []
    for record in window.transcripts("auto") + [r for r in today_records if r["kind"] == "auto"]:
        context[local_day(record["start"])].append(
            record["end_context"] + sum(u["output"] for u in record["usage"])
        )

    # The complete days, oldest first, and then today on its own below them.
    # Today is a few hours old and the days above it are twenty-four: on one
    # list they read as comparable and the newest is always the low bar.
    days = [window.first_full + datetime.timedelta(days=n) for n in range(window.full)]
    # Always, and a row of noughts when nothing has run: a day missing from the
    # table is indistinguishable from a day nothing happened on, and the second
    # is the one worth seeing.
    partial = datetime.date.today()
    # THE BAR IS TIME AWAKE, NOT A COUNT OF SESSIONS. How often it woke is mostly
    # `--cooldown`; how long it worked is the work. Two days here ran 35 sessions
    # each and one of them was two and a half hours busier, which a count cannot
    # show. The bars sum to the `unattended` half of the awake figure below.
    peak = max(sum(lengths[d]) for d in days) or 1

    def row(day):
        chat = counts[(day, "chat")]
        return [
            "   " + day.strftime("%m-%d"),
            str(counts[(day, "auto")]),
            # Blank and not a nought: a column of noughts is a line the eye has
            # to read to learn that nothing happened in it.
            str(chat) if chat else "",
            duration(sum(lengths[day])) if lengths[day] else "—",
            "%.1fm" % (statistics.mean(lengths[day]) / 60) if lengths[day] else "—",
            "%.0fk" % (statistics.mean(context[day]) / 1000) if context[day] else "—",
        ]

    rows = [row(day) for day in days] + ([row(partial)] if partial else [])
    lines = cost.table(rows, ["", SHORT, "chat", "awake", "mean", "ctx+out"])

    # The bars share a left edge, so they hang off a padded table rather than
    # being a column of it: a column would range them right and grow each one
    # leftward from its own end.
    width = max(len(line) for line in lines)

    def drawn(line, day):
        worked = sum(lengths[day])
        bar = "█" * max(1, round(worked * BAR / peak)) if worked else ""
        return (line.ljust(width) + "  " + bar).rstrip()

    out = [lines[0]] + [
        drawn(line, day) for line, day in zip(lines[1 : 1 + len(days)], days, strict=False)
    ]
    if partial:
        # A blank line and a label, because the row cannot be read against the
        # ones above it: today's bar is short because today is short.
        out += ["", drawn(lines[-1], partial) + "   today, up to %s" % time.strftime("%H:%M")]
    slept = sleep(window)
    return out + ([""] + fact(slept) if slept else [])


def weekly(window, cost, weeks):
    """Section three: is any of this changing? Whole weeks, newest first.

    EVERY ROW IS SEVEN COMPLETE DAYS OR IT IS NOT A ROW. The table is read down a
    column, so rows of different length cannot sit under one heading: today goes
    to the daily table above, and a week the archive does not cover in full is
    dropped rather than shown short.

    `sessions` counts RUNS. Every other column is a mean over the TRANSCRIPTS
    that started in the same week — never one column divided by another.
    see docs/monitor.md#the-periods
    """
    last = window.last_full

    rows = []
    for w in range(weeks):
        end = last - datetime.timedelta(days=w * 7)
        start = end - datetime.timedelta(days=6)
        if start < window.since:
            break
        runs = [
            run
            for record, run in window.runs
            if record["kind"] == "auto" and start <= local_day(run["from"]) <= end
        ]
        seen = [r for r in window.transcripts("auto") if start <= local_day(r["start"]) <= end]
        if not runs or not seen:
            continue
        lengths = [run["to"] - run["from"] for run in runs]
        context = [r["end_context"] + sum(u["output"] for u in r["usage"]) for r in seen]
        rows.append(
            [
                "   %s → %s" % (start.strftime("%m-%d"), end.strftime("%m-%d")),
                str(len(runs)),
                "%.1fm" % (statistics.mean(lengths) / 60),
                duration(max(lengths)),
                "%.0f" % statistics.mean([r["messages"] for r in seen]),
                "%.0fk" % (statistics.mean(context) / 1000),
                "$%.2f" % statistics.mean([usd_of(r, cost, reprice=True) for r in seen]),
            ]
        )
    if not rows:
        return []
    headers = ["", "sessions", "mean", "longest", "msgs", "ctx+out", "$/session"]
    return cost.table(rows, headers)


def sleep(window):
    """How the window's complete days divided into working and sleeping.

    NOTHING HERE IS MEASURED AGAINST A SETTING. `--cooldown` decides how long the
    agent waits and it is config, not a measurement: a median gap is that setting
    read back off the screen, and a percentage against today's value compares
    history to a number read a second ago. The share awake falls when sessions
    stop running whatever the cooldown is.

    `awake` and `asleep` close on the period exactly, so the pair can be checked
    against a clock, which makes this the one place a conversation's time is
    counted — a gap has a session on each side of it whatever kind they are.
    see docs/monitor.md#nothing-is-measured-against-a-setting
    """
    if not window.full:
        return []

    # THE PERIOD IS WHOLE DAYS, AND THE TWO FIGURES CLOSE ON IT EXACTLY. Midnight
    # to midnight over the complete days the table above shows, so seven days is
    # 168 hours and not "168 minus however much of today has not happened yet".
    # Today is out of it entirely and has a row of its own: its few hours would
    # otherwise enter as sleep that never happened.
    #
    # `asleep` is everything in the period that is not a session, not the sum of
    # the gaps between sessions. Those are different by the time before the first
    # session and after the last, and that difference was how a seven-day period
    # printed itself as 146 hours.
    began = datetime.datetime.combine(window.first_full, datetime.time()).timestamp()
    ended = datetime.datetime.combine(
        window.last_full + datetime.timedelta(days=1), datetime.time()
    ).timestamp()
    period = ended - began

    # Clipped to the period, so a session running across midnight counts on each
    # side only for the part that fell there and the arithmetic still closes.
    inside = [
        (record, max(run["from"], began), min(run["to"], ended))
        for record, run in window.runs
        if run["to"] > began and run["from"] < ended
    ]
    if not inside:
        return []
    awake = sum(to - frm for _record, frm, to in inside)

    # The time before the first session and after the last are sleep like any
    # other, and the second is what a schedule stopped yesterday looks like.
    edges = [(inside[0][1] - began, began), (ended - inside[-1][2], inside[-1][2])]
    between = [
        (inside[i + 1][1] - inside[i][2], inside[i][2])
        for i in range(len(inside) - 1)
        if inside[i + 1][1] >= inside[i][2]
    ]
    longest, at = max(edges + between)

    return [
        (
            "%s awake" % duration(awake),
            [
                "%s — %.0f%% of the %dh, %s to %s"
                % (
                    awake_split(window, [(r, {"to": to, "from": frm}) for r, frm, to in inside]),
                    100 * awake / period,
                    round(period / 3600),
                    window.first_full.strftime("%m-%d"),
                    window.last_full.strftime("%m-%d"),
                )
            ],
        ),
        (
            "%s asleep" % duration(period - awake),
            # Said as what it is rather than as a noun the reader has to unpack:
            # "the longest stretch" names nothing on its own, and it sits under
            # a total, which is the one place a bare superlative is ambiguous.
            [
                "the longest it went without a session was %s, from %s"
                % (duration(longest), when(at))
            ],
        ),
    ]


def deploy(window, live):
    """Section four: how many sessions each build has carried.

    A null `runner_commit` is correct rather than missing: `deploy.deployed`
    appears in the status snapshots only from 2026-08-28, because before that a
    build WAS a deploy and there was nothing to attribute to. It has a clause of
    its own, and the clause goes once those runs age out of the window.
    """
    counts = collections.Counter()
    first = {}
    for _record, run in window.runs:
        commit = run.get("runner_commit")
        counts[commit] += 1
        if commit and commit not in first:
            first[commit] = run["from"]
    order = sorted(first, key=lambda c: first[c])
    if not order:
        return []

    def carried(n):
        return "%d session%s" % (n, "" if n == 1 else "s")

    # The live build is what `deploy --state` says and not the newest one seen:
    # a build that just went live has carried nothing yet, and naming the newest
    # build seen would name the wrong one for as long as that is true. With no
    # answer from `deploy` the newest seen is the best that can be said, and it
    # is not called live.
    current = live or order[-1]
    said = ["%s%s, %s" % (current, " is live" if live else "", carried(counts[current]))]
    rest = [c for c in order if c != current]
    if rest:
        said.append("%s had %s before it" % (rest[-1], carried(counts[rest[-1]])))
    if counts[None]:
        said.append("%s ran before there was a deploy process" % carried(counts[None]))

    return fact(
        [
            (
                "%d deploy%s" % (len(order), "" if len(order) == 1 else "s"),
                ["since %s" % local_day(first[order[0]]).strftime("%m-%d")] + said,
            )
        ]
    )


# --------------------------------------------------------------------------
# The two things read from outside the store
# --------------------------------------------------------------------------


def live_commit():
    """Which runner build is live, from the one command that decides it."""
    try:
        out = subprocess.run(
            ["just", "deploy", "--state"], cwd=CHECKOUT, capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode:
        return None
    for line in out.stdout.splitlines():
        if line.startswith("deployed: ") and line[10:] != "-":
            return line[10:].strip()
    return None


def newest_heading(monitor):
    """The agent's own newest journal heading, or why there is none to compare.

    Read from this host's clone of its repository — the one `just records`
    fetches at every session end, so it is current — and read is all this does.
    A mirror that cannot be read is not agreement: nothing missing is zero.
    """
    if not monitor:
        return None, "RUNNER_MONITOR is not set"
    clone = os.path.join(monitor, "memory")
    if not os.path.isdir(clone):
        return None, "there is no clone of its repository here yet"
    try:
        out = subprocess.run(
            ["git", "-C", clone, "show", "source/main:JOURNAL.md"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None, "the clone of its repository could not be read"
    if out.returncode:
        return None, "the clone holds no JOURNAL.md on source/main"
    for line in out.stdout.splitlines():
        if line.startswith("## "):
            return line, None
    return None, "its journal carries no heading"


# --------------------------------------------------------------------------


def screen(records, name, monitor, days, cost, every=False):
    """Four titled sections, in the order someone opens this to read them.

    What it has done in all, what the last week looked like, whether that is
    changing, and what it ran on. Everything covers the window in the first
    heading; the second section names its own days, and the third its own weeks.
    see docs/monitor.md#the-shape-of-the-screen
    """
    lifetime = Window(records)
    window = Window(records, days, every) if days or every else lifetime
    out = opening(lifetime, name, newest_heading(monitor))
    out += rule(
        "all %d sessions · %s → %s · %d days"
        % (len(window.runs), window.since, window.until, window.days)
    )
    out += whole(window, cost)

    out += rule("the last %d full days" % window.full)
    out += recent(window, cost)

    weeks = weekly(window, cost, math.ceil(days / 7) if days else WEEKS)
    if weeks:
        out += rule("week by week, %s sessions" % UNATTENDED)
        out += weeks

    built = deploy(window, live_commit())
    if built:
        out += rule("what it ran on")
        out += built
    return "\n".join(out)


# --------------------------------------------------------------------------
# --selftest: the parts that are wrong in ways nothing on screen would show
# --------------------------------------------------------------------------


def selftest():
    failures, ran = [], []

    def check(name, got, want):
        ran.append(name)
        if got != want:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def flat(lines):
        """One line, single-spaced: the assertions are about what a block says,
        not about the column it happened to land in."""
        return " ".join(" ".join(lines).split())

    cost = load_cost()
    yesterday = datetime.date.today() - datetime.timedelta(days=1)

    def on(day, minutes=60, kind="auto"):
        """One session, at noon on that day, of that length."""
        start = datetime.datetime.combine(day, datetime.time(12)).timestamp()
        return {
            "started_by": "runner",
            "kind": kind,
            "start": start,
            "messages": 100,
            "end_context": 100_000,
            "usage": [],
            "subagents": [],
            "runs": [{"from": start, "to": start + minutes * 60, "commits": []}],
        }

    # The speller, against the idiom it has to match. Every one of these is a
    # spelling the agent has written in its own journal.
    for n, word in (
        (1, "first"), (2, "second"), (3, "third"), (5, "fifth"), (8, "eighth"),
        (9, "ninth"), (12, "twelfth"), (20, "twentieth"), (21, "twenty-first"),
        (50, "fiftieth"), (88, "eighty-eighth"), (100, "hundredth"),
        (101, "hundred-and-first"), (180, "hundred-and-eightieth"),
        (418, "four-hundred-and-eighteenth"), (500, "five-hundredth"),
        (567, "five-hundred-and-sixty-seventh"),
    ):  # fmt: skip
        check("%d spells out" % n, spellings(n)[0], word)

    check("a thousand keeps its one", spellings(1000), ("thousandth", "one-thousandth"))
    check(
        "and joins a remainder under a hundred",
        spellings(1021)[1],
        "one-thousand-and-twenty-first",
    )
    check(
        "and does not join a hundreds remainder", spellings(1100)[1], "one-thousand-one-hundredth"
    )

    # The day arithmetic, over a clock change: 2026-10-25 is when Europe leaves
    # summer time, and a day there is 25 hours. Dividing seconds puts the run
    # before it on the wrong day, and the whole screen buckets on this.
    def at(text):
        return datetime.datetime.strptime(text, "%Y-%m-%d %H:%M").timestamp()

    check("a clock change does not move a day", local_day(at("2026-10-24 23:30")).day, 24)
    check("nor the day after it", local_day(at("2026-10-26 00:30")).day, 26)

    # `-d N` IS N COMPLETE DAYS AND TODAY IS NOT ONE OF THEM. Counting back from
    # today spent one of the N on however many hours today had lived, so `-d 14`
    # covered thirteen days and a morning and the week-by-week table below could
    # show one row where two were asked for.
    span = [on(yesterday - datetime.timedelta(days=n)) for n in range(20)]
    span.append(on(datetime.date.today()))
    asked = Window(span, days=14)
    check("the window ends yesterday", asked.until, yesterday)
    check("and reaches back exactly N days", asked.since, yesterday - datetime.timedelta(days=13))
    check("today is not in it", len(asked.runs), 14)
    check("today is off the totals but not off the screen", len(asked.today), 1)
    check(
        "and its row is still drawn",
        sum(1 for line in recent(asked, cost) if "today, up to" in line),
        1,
    )
    check(
        "and -d 14 is two whole weeks in the table",
        len(weekly(asked, cost, math.ceil(14 / 7))) - 1,
        2,
    )

    # THE SAME ROW ON THE PATH THAT IS NOT NARROWED, which is the default screen
    # and `--all`. Every check above builds its window with `days=14`, where the
    # filter has already taken today out of `runs` and adding it back is right.
    # With no `-d` nothing was filtered, today was added to a list it was in, and
    # one session read as two for as long as this file has existed. The fixtures
    # that could have caught it are here -- `Window(span)` appears twice below --
    # and neither puts a run on today, so the branch had no case rather than a
    # failing one.
    def today_row(window):
        return [line for line in recent(window, cost) if "today, up to" in line][0].split()

    check("the default screen counts today once", today_row(Window(span))[1], "1")
    check("and does not double its awake column", " ".join(today_row(Window(span))[2:4]), "1h 00m")
    check("--all counts today once too", today_row(Window(span, every=True))[1], "1")
    # The negative control: the narrowed path was always right and stays right.
    check("and so does -d 14, as it always did", today_row(asked)[1], "1")

    # `--all` gives every day of the window a row. The seven-row cap is on what
    # the screen does BY ITSELF, which is the fault it exists for; a reader
    # asking for more is not that.
    check("seven rows unless asked", Window(span, days=14).full, RECENT)
    check("and every day when asked", Window(span, days=14, every=True).full, 14)
    check("--all alone takes the whole record", Window(span, every=True).full, 20)

    # `to - from` per run and never `end - start`: the resumed transcript in the
    # archive spans 8h34m for 3h25m of work.
    check("a duration is the sum of the runs", duration(20 * 60), "20m")
    # The space is the point: `1h00m` runs the letters into the digits, and at a
    # terminal's stroke weight `h` and `4` are the same mark.
    check("an hour reads as an hour", duration(3600 + 59), "1h 00m")
    check("a long gap keeps its minutes", duration(6 * 3600 + 5 * 60), "6h 05m")

    # The weekly table over a schedule that was paused for a week. A row missing
    # from the middle would read as the archive not reaching that far back, and
    # every row below it would then be labelled a week early.
    def session(day, minutes=10):
        start = at("2026-10-%02d 12:00" % day)
        return {
            "started_by": "runner",
            "kind": "auto",
            "start": start,
            "messages": 100,
            "end_context": 100_000,
            "usage": [],
            "subagents": [],
            "runs": [{"from": start, "to": start + minutes * 60, "commits": []}],
        }

    # EVERY ROW IS SEVEN COMPLETE DAYS OR IT IS NOT A ROW: the table is read down
    # a column, so two rows covering different spans cannot be compared and must
    # not sit under one heading. It compared 6 days and 2 hours against a full
    # week against the 3 days the archive started with, and the newest row read
    # 209 sessions where seven whole days held 242.
    fortnight = [on(yesterday - datetime.timedelta(days=n)) for n in range(14)]
    rows = weekly(Window(fortnight), cost, 4)
    check("two whole weeks are two rows", len(rows) - 1, 2)
    check("the newest row ends yesterday", rows[1].split()[2], yesterday.strftime("%m-%d"))
    check(
        "and reaches back exactly seven days",
        rows[1].split()[0],
        (yesterday - datetime.timedelta(days=6)).strftime("%m-%d"),
    )
    check("with every day of it counted", rows[1].split()[3], "7")

    # Today is left to the daily table, where a partial day belongs: the hours
    # it has not lived yet must not read as a fall in sessions.
    today = weekly(Window(fortnight + [on(datetime.date.today())]), cost, 4)
    check("today is not in the newest week", today[1].split()[3], "7")
    check(
        "and the newest week still ends yesterday", today[1].split()[2], yesterday.strftime("%m-%d")
    )

    # A week the archive does not cover in full is dropped, never shown short.
    check("a short week is not a row", len(weekly(Window(fortnight[:10]), cost, 4)) - 1, 1)

    # The live build is what `deploy --state` says. Right after a deploy it has
    # carried nothing, and a block that showed the newest build seen would name
    # the wrong one for as long as that is true.
    built = Window([session(20)])
    built.runs[0][1]["runner_commit"] = "aaaaaaa"
    check(
        "a fresh deploy carries nothing yet",
        "bbbbbbb is live, 0 sessions" in flat(deploy(built, "bbbbbbb")),
        True,
    )
    check(
        "and the build before it keeps its own count",
        "aaaaaaa had 1 session before it" in flat(deploy(built, "bbbbbbb")),
        True,
    )
    check(
        "with no answer from deploy, nothing is called live",
        "is live" in flat(deploy(built, None)),
        False,
    )
    check("one deploy is not 1 deploys", "1 deploy since" in flat(deploy(built, None)), True)

    # The cadence is the last seven days and not the archive's life: the
    # `--cooldown` on the crontab line has changed, and the older setting
    # outvotes the present one over a long enough history.
    # Seven complete days ending yesterday, one hour of session at noon each.
    # The period is midnight to midnight over those days — 168 hours exactly, of
    # which 7 are awake and 161 are not — and the longest it goes without a
    # session is the 23 hours between two noons.
    week = [on(yesterday - datetime.timedelta(days=n)) for n in range(7)]
    told = flat(fact(sleep(Window(week))))
    check("awake is the runs", "7h 00m awake" in told, True)
    check("asleep is everything else", "161h 00m asleep" in told, True)
    check("seven whole days are 168 hours", "of the 168h" in told, True)
    check("and the period is named by its dates", yesterday.strftime("%m-%d") in told, True)
    check("the longest sleep is the longest", "without a session was 23h 00m" in told, True)

    # The daily bar is time awake and not a count of sessions: how often it woke
    # is mostly `--cooldown`, how long it worked is the work. Two days that ran
    # the same number of sessions must not draw the same bar.
    busy = [on(yesterday, minutes=120), on(yesterday - datetime.timedelta(days=1), minutes=20)]
    quiet_day, busy_day = recent(Window(busy), cost)[1:3]
    check("equal counts do not draw equal bars", quiet_day.count("█") == busy_day.count("█"), False)
    check("the busier day has the longer bar", busy_day.count("█") > quiet_day.count("█"), True)
    check("and the awake column says the same", "2h 00m" in busy_day, True)
    check("while the session counts are equal", quiet_day.split()[1], busy_day.split()[1])

    # A day the agent did not wake on is a row of noughts, not a row that is not
    # there: the two are indistinguishable on screen and only one is worth
    # seeing. The table anchors on yesterday whether or not anything has run
    # since.
    idle = recent(Window([on(yesterday - datetime.timedelta(days=n)) for n in range(3, 7)]), cost)
    quiet = [line for line in idle if line.startswith("   " + yesterday.strftime("%m-%d"))]
    check("a day with nothing on it still has a row", len(quiet), 1)
    check("and the row says nought", quiet[0].split()[1], "0")
    check("today always has a row", sum(1 for line in idle if "today, up to" in line), 1)
    check(
        "and the outage is the longest sleep",
        "without a session was 83h 00m" in flat(idle),
        True,
    )

    # Today is out of the period entirely: its few hours would otherwise enter
    # as sleep that never happened, and 168 would stop being 168.
    check(
        "today does not enter the period",
        flat(fact(sleep(Window(week + [on(datetime.date.today())])))),
        told,
    )

    # `awake` was two different figures under one word — unattended runs in one
    # section, every run in another, neither said. Every awake is every run now,
    # and the detail names the two parts.
    mixed = [session(20), session(20)]
    mixed[1]["kind"] = "chat"
    mixed[1]["runs"][0]["from"] += 3600
    mixed[1]["runs"][0]["to"] += 3600
    check(
        "a chat's time is named, not folded in",
        awake_split(Window(mixed)),
        "10m unattended, 10m chat",
    )
    check(
        "and a window with no chat says so",
        awake_split(Window([session(20)])),
        "all of it unattended",
    )

    # A breakdown breaks between items and never inside one.
    check(
        "a long breakdown wraps whole",
        wrap(["167 automode-blocked", "105 user-rejected", "59 permission-rule"], width=42),
        ["167 automode-blocked, 105 user-rejected,", "59 permission-rule"],
    )

    if failures:
        print("stats --selftest FAILED (%d of %d)" % (len(failures), len(ran)))
        for line in failures:
            print("  " + line)
        return 1
    print("stats --selftest ok (%d cases)" % len(ran))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "-d", "--days", type=int, default=0, help="how many whole days back to report on"
    )
    parser.add_argument(
        "--all", action="store_true", help="a row for every day of the window, not the last seven"
    )
    parser.add_argument("--selftest", action="store_true", help="prove the arithmetic and stop")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    root = os.environ.get("RUNNER_RECORDS_DIR") or ""
    if not root:
        sys.exit("Run this through 'just stats', which computes where the records are.")

    records = load(root)
    if not records:
        sys.exit(
            "No sealed records under %s.\n"
            "Every session end seals its own; 'just records' seals what is waiting." % root
        )

    print(
        screen(
            records,
            os.environ.get("AGENT_NAME") or "The agent",
            os.environ.get("RUNNER_MONITOR") or "",
            args.days,
            load_cost(),
            args.all,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
