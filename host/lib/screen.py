#!/usr/bin/env python3
"""The grammar the host's screens are written in, and the store they read.

Two screens use it — `just stats` and `just status` — and it is here so they
cannot drift apart. A heading, a headline number with its detail beside it, a
duration, a timestamp: a reader who has learnt one screen has learnt the other,
and a second copy of `fact` would be the one that starts wrapping differently.

Imported through importlib by both, the way stats.py loads the price table:
these are host scripts run from a checkout, not an installed package.
see docs/monitor.md#the-shape-of-the-screen
"""

import datetime
import json
import os

WIDTH = 78


def rule(title):
    """A section heading, and the screen's only structure.

    A rule and not colour, and not bold: the operator is deutan colourblind, and
    a pipe or a file has to carry the same structure a terminal does.
    """
    head = "── %s " % title.upper()
    return ["", head + "─" * max(0, WIDTH - len(head)), ""]


def fact(rows, indent="   "):
    """A headline number, then what it is made of, on the same line.

    Everything after the gap belongs to the figure before it, so what relates to
    what needs no explaining, and a section opening every line with a number and
    a noun is scanned rather than read.
    """
    width = max(len(head) for head, _detail in rows)
    out = []
    for head, detail in rows:
        first, *rest = detail
        out.append((indent + head.ljust(width) + "   " + first).rstrip())
        out += [indent + " " * width + "   " + more for more in rest]
    return out


def duration(seconds):
    """`115h 40m`, with the space: at a terminal's stroke weight `h` and `4` are
    the same mark, and `115h40m` has to be parsed rather than read."""
    if seconds >= 3600:
        return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)
    return "%dm" % (seconds // 60)


def when(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M")


def local_day(ts):
    return datetime.date.fromtimestamp(ts)


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
