#!/usr/bin/env python3
"""How heavy a session was, priced from its own transcript.

    session-cost PATH ...             one line per session
    session-cost --by-day PATH ...    one line per day instead
    session-cost --selftest           prove the arithmetic and stop

A path is required and nothing is guessed: there is no default transcript and
no "the last one". Each PATH is either a `.jsonl` transcript or a directory,
which is walked for every transcript under it. Both shapes end with where the
money went across everything read, which is the part worth reading.

Claude Code files transcripts under `~/.claude/projects/<working directory,
every / turned into a ->/`, one `<session-id>.jsonl` per session with that
session's sub-agents beside it in `<session-id>/subagents/`. So, from inside
the checkout:

    d=~/.claude/projects/$(pwd | tr / -)

    session-cost "$(ls -t "$d"/*.jsonl | head -1)"   the session running now
    session-cost "$d"                                every session still kept
    session-cost --by-day "$d"                       the same, by day

That encoding is observed rather than documented; if the directory is not
there, `ls ~/.claude/projects/` says what the spelling actually is. The newest
file is the session running now only because one session runs at a time here,
and it is being appended to while it is read.

It is the agent's own number, which the account percentage cannot be:
`claude-usage` answers for the ACCOUNT — one login shared with the operator's
own sessions and chats. Every assistant record carries the usage of the request
that produced it, in that session's own file, where no other session can
contaminate it. The two answer different questions and neither substitutes for
the other.

Dollars rather than tokens, because tokens are not comparable: an Opus output
token costs five times a Sonnet one, a cache read a tenth of a fresh input
token, and a 1-hour cache write twice one.

THE FIGURE IS NOT MONEY THAT WAS SPENT, AND IT DOES NOT CONVERT INTO THE
SUBSCRIPTION'S ALLOWANCE. Nothing here was invoiced: it is what the same
traffic WOULD have cost at published per-token API rates, and how a
subscription turns usage into the percentages `claude-usage` reads is not
published anywhere. A session priced at twice another has not been shown to
consume twice the window. What it is for is comparing sessions against each
other in one unit, and seeing which PART of a session weighs — a comparison
that holds whatever the subscription does with it.

Baked into the image and root-owned, for the same reason as `claude-usage`:
a price table the agent can edit is a price table that says what the agent
would like it to say.

What is counted, and why it is not the obvious thing:

  iterations  Summed, never read from the top level: a request that fell back
              carries an `iterations` array whose first attempt was really
              consumed and which the top-level `usage` leaves out. Records with
              no `iterations` are the only ones the top level answers for.

  requests    Assistant records are streaming snapshots, several per request,
              all under one `requestId`, with a usage that GROWS across them.
              The last is the complete one; counting records rather than
              requestIds inflates everything by more than two.

  models      Priced per request from the record's own `model`, since a
              sub-agent runs on the model its definition names. An optional
              eight-digit date suffix is normalised away. An id the table does
              not know is named and the exit is non-zero: a model silently
              priced at zero looks exactly like a cheap session.

  sub-agents  Cumulated into the session that asked for the work, in both
              layouts this file ever sees: the volume's
              `<session-id>/subagents/agent-<id>.jsonl` and the archive's
              `<session-id>--agent-<id>.jsonl`. Cumulated but not hidden — the
              `who spent it` block splits the same money by who ran the request
              and on which model.

  thinking    Reported under output, never added to it: thinking tokens are a
              SUBSET of output and already counted there. Shown because effort
              is one of the few levers there is, and its whole weight is in
              that line.

PRICES are Anthropic list, $/MTok: input, 5-minute cache write, 1-hour cache
write, cache read, output. They are written out rather than computed from the
1.25x, 2x and 0.1x multipliers, so that one wrong price is one wrong number
rather than a wrong column. Re-read them when a model is added or a session
starts answering on an id this table does not hold; a stale price prints in
exactly the same shape as a current one.

see docs/sessions.md#pricing-a-session
see docs/sessions.md#what-the-corpus-measured
"""

import argparse
import json
import os
import signal
import sys

# $/MTok: input, 5m cache write, 1h cache write, cache read, output.
PRICES = {
    # Fable 5.1 reads cache at 0.025x base, not the 0.1x every other row uses.
    "claude-fable-5-1": (10.00, 12.50, 20.00, 0.25, 50.00),
    "claude-fable-5": (10.00, 12.50, 20.00, 1.00, 50.00),
    "claude-opus-5": (5.00, 6.25, 10.00, 0.50, 25.00),
    "claude-opus-4-8": (5.00, 6.25, 10.00, 0.50, 25.00),
    "claude-opus-4-7": (5.00, 6.25, 10.00, 0.50, 25.00),
    "claude-opus-4-6": (5.00, 6.25, 10.00, 0.50, 25.00),
    "claude-opus-4-5": (5.00, 6.25, 10.00, 0.50, 25.00),
    "claude-sonnet-5": (2.00, 2.50, 4.00, 0.20, 10.00),
    "claude-sonnet-4-6": (3.00, 3.75, 6.00, 0.30, 15.00),
    "claude-sonnet-4-5": (3.00, 3.75, 6.00, 0.30, 15.00),
    "claude-haiku-4-5": (1.00, 1.25, 2.00, 0.10, 5.00),
}

# Fast mode is a different price for the same model, Opus 5 and 4.8 only, and
# the cache multipliers apply on top of it. `usage.speed` says which ran.
FAST = {
    "claude-opus-5": (10.00, 12.50, 20.00, 1.00, 50.00),
    "claude-opus-4-8": (10.00, 12.50, 20.00, 1.00, 50.00),
}

# Web search bills $10 per 1000 on top of tokens; web fetch is free. Priced
# from the published rate and never exercised against real data.
WEB_SEARCH = 10.00 / 1000

# US-pinned inference bills 1.1x on every category. Priced from the page too,
# and likewise unexercised.
US_MULTIPLIER = 1.1

CATEGORIES = ("input", "write1h", "write5m", "read", "output")
SUFFIX = ".jsonl"

# Claude Code's own placeholder assistant records carry this instead of a model
# id, with every token count zero — measured across the corpus, never anything
# else. No request produced one, so counting it inflates the request count and
# names a price that is not missing. Skipped, NOT priced at zero: the table
# refusing an id it does not hold is what makes a real gap visible.
SYNTHETIC = "<synthetic>"


class Unpriceable(Exception):
    """A model id the table does not hold. Never priced as zero."""


def normalise(model):
    """`claude-haiku-4-5-20251001` -> `claude-haiku-4-5`."""
    head, _, tail = model.rpartition("-")
    return head if len(tail) == 8 and tail.isdigit() else model


def rates(model, speed):
    key = normalise(model or "")
    table = FAST if speed == "fast" and key in FAST else PRICES
    if key not in table:
        raise Unpriceable(model)
    return table[key]


def tokens_of(usage):
    """The five priced token counts of one request, summed over iterations."""
    counts = dict.fromkeys(CATEGORIES, 0)
    for step in usage.get("iterations") or [usage]:
        counts["input"] += step.get("input_tokens", 0)
        counts["read"] += step.get("cache_read_input_tokens", 0)
        counts["output"] += step.get("output_tokens", 0)
        written = step.get("cache_creation")
        if written:
            counts["write5m"] += written.get("ephemeral_5m_input_tokens", 0)
            counts["write1h"] += written.get("ephemeral_1h_input_tokens", 0)
        else:
            # A record with no TTL split is charged at the dearer rate:
            # under-reporting a cost is the failure that goes unnoticed.
            counts["write1h"] += step.get("cache_creation_input_tokens", 0)
    return counts


def dollars(counts, model, speed, geo):
    base = rates(model, speed)
    price = dict(zip(("input", "write5m", "write1h", "read", "output"), base, strict=False))
    scale = US_MULTIPLIER if geo == "us" else 1.0
    return {k: counts[k] / 1e6 * price[k] * scale for k in CATEGORIES}


def session_of(path):
    """Which session a transcript belongs to, in either layout.

    The volume nests a sub-agent under the session directory; the archive
    flattens it to `<session>--agent-<id>.jsonl`. Both say the same thing and
    neither may be read as a session of its own.
    """
    holder = os.path.basename(os.path.dirname(path))
    if holder == "subagents":
        return os.path.basename(os.path.dirname(os.path.dirname(path)))
    name = os.path.basename(path)
    if name.endswith(SUFFIX):
        name = name[: -len(SUFFIX)]
    return name.split("--", 1)[0]


def is_subagent(path):
    return os.path.basename(os.path.dirname(path)) == "subagents" or "--" in os.path.basename(path)


class Session:
    def __init__(self, key):
        self.key = key
        self.day = None
        self.tokens = dict.fromkeys(CATEGORIES, 0)
        self.cost = dict.fromkeys(CATEGORIES, 0.0)
        self.searches = 0
        self.search_cost = 0.0
        self.thinking = 0
        self.requests = 0
        self.agents = set()
        self.models = set()
        self.unpriced = {}
        # (who did the work, which model) -> [requests, dollars]. Kept apart
        # from `cost` above, which splits the same money by token category:
        # only this one says whether handing a task to a weaker model saved
        # anything.
        self.spend = {}

    @property
    def total(self):
        return sum(self.cost.values()) + self.search_cost


def read(path, sessions):
    """One transcript into its session. Keyed by requestId so the streaming
    snapshots collapse, last-writer-wins because the last is the complete one."""
    key = session_of(path)
    session = sessions.setdefault(key, Session(key))
    latest = {}
    day = None

    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            when = record.get("timestamp")
            if day is None and isinstance(when, str) and len(when) >= 10:
                day = when[:10]
            if record.get("type") != "assistant":
                continue
            request = record.get("requestId")
            if request:
                latest[request] = record

    # The main chain dates a session, whichever order the files arrive in: a
    # sub-agent can start on the far side of midnight from the session that
    # asked for it, so its own first timestamp is a last resort.
    if day:
        if not is_subagent(path):
            session.day = day
        elif session.day is None:
            session.day = day

    # Read from the path, not from the record: `isSidechain` marks the records
    # inside a sub-agent file, but which file a request came out of is what
    # says who ran it, and that is known here without trusting a field.
    role = "sub-agent" if is_subagent(path) else "main chain"

    for _request, record in latest.items():
        message = record.get("message") or {}
        usage = message.get("usage") or {}
        model = message.get("model")
        if model == SYNTHETIC:
            continue
        session.requests += 1
        session.models.add(normalise(model or "unknown"))
        if record.get("agentId"):
            session.agents.add(record["agentId"])

        counts = tokens_of(usage)
        for name in CATEGORIES:
            session.tokens[name] += counts[name]
        session.thinking += (usage.get("output_tokens_details") or {}).get("thinking_tokens", 0)
        searches = (usage.get("server_tool_use") or {}).get("web_search_requests", 0) or 0
        session.searches += searches
        session.search_cost += searches * WEB_SEARCH

        try:
            priced = dollars(counts, model, usage.get("speed"), usage.get("inference_geo"))
        except Unpriceable as unknown:
            session.unpriced[str(unknown)] = session.unpriced.get(str(unknown), 0) + 1
            continue
        for name in CATEGORIES:
            session.cost[name] += priced[name]
        # The search charge rides with the request that made it, so the rows
        # of `who spent it` add up to the session total rather than to a
        # slightly smaller number nobody can account for.
        entry = session.spend.setdefault((role, normalise(model or "unknown")), [0, 0.0])
        entry[0] += 1
        entry[1] += sum(priced.values()) + searches * WEB_SEARCH


def transcripts(paths):
    found = []
    for path in paths:
        if os.path.isdir(path):
            for root, _, names in os.walk(path):
                found += [os.path.join(root, n) for n in sorted(names) if n.endswith(SUFFIX)]
        elif path.endswith(SUFFIX):
            found.append(path)
        else:
            sys.exit("Not a transcript or a directory: %s" % path)
    return sorted(found)


# --------------------------------------------------------------------------
# Printing
# --------------------------------------------------------------------------


def tokens(n):
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        return "%.0fk" % (n / 1000)
    return "%.1fM" % (n / 1_000_000)


def money(x):
    return "$%.2f" % x if x >= 0.005 or x == 0 else "<$0.01"


def short(model):
    return model[len("claude-") :] if model.startswith("claude-") else model


def table(rows, headers, left=1):
    """`left` columns ranged left, the rest right — numbers only line up when
    they are ranged the same way as the header that names them."""
    widths = [max(len(str(r[i])) for r in [headers] + rows) for i in range(len(headers))]

    def align(cell, i, w):
        return str(cell).ljust(w) if i < left else str(cell).rjust(w)

    lines = [
        "  ".join(
            align(h, i, w) for i, (h, w) in enumerate(zip(headers, widths, strict=False))
        ).rstrip()
    ]
    for row in rows:
        lines.append(
            "  ".join(
                align(c, i, w) for i, (c, w) in enumerate(zip(row, widths, strict=False))
            ).rstrip()
        )
    return lines


def breakdown(sessions):
    """Where the money went, over everything read. This is the whole point of
    the tool: a total says a session was expensive, this says what made it."""
    tally = dict.fromkeys(CATEGORIES, 0)
    spend = dict.fromkeys(CATEGORIES, 0.0)
    searches = search_cost = thinking = output = 0
    for session in sessions:
        for name in CATEGORIES:
            tally[name] += session.tokens[name]
            spend[name] += session.cost[name]
        searches += session.searches
        search_cost += session.search_cost
        thinking += session.thinking
        output += session.tokens["output"]

    total = sum(spend.values()) + search_cost
    labels = {
        "read": "cache read",
        "write1h": "cache write 1h",
        "write5m": "cache write 5m",
        "output": "output",
        "input": "input",
    }
    rows = []
    for name in sorted(CATEGORIES, key=lambda n: -spend[n]):
        share = 100 * spend[name] / total if total else 0
        rows.append([labels[name], tokens(tally[name]), money(spend[name]), "%2.0f%%" % share])
    if searches:
        share = 100 * search_cost / total if total else 0
        rows.append(["web search", "%d" % searches, money(search_cost), "%2.0f%%" % share])

    lines = ["", "where it went"] + [
        "  " + line for line in table(rows, ["", "tokens", "cost", ""])
    ]
    if output:
        lines.append(
            "  (of the output, %s was thinking — %.0f%%)"
            % (tokens(thinking), 100 * thinking / output)
        )
    return lines


def who_spent(sessions):
    """The same money split by who did the work and on which model.

    It answers what `where it went` cannot: whether handing a task to a weaker
    model paid is invisible while the sub-agent's spend is merged into the
    session that asked for it. A Haiku sub-agent beside an Opus main chain is
    two rows, and the saving is the difference between them.

    Silent when there is nothing to compare — one model and no sub-agent makes
    a single row restating the total, and a block that always prints is a block
    that stops being read.
    see docs/sessions.md#where-the-money-went-and-who-spent-it
    """
    pairs = {}
    for session in sessions:
        for key, (requests, cost) in session.spend.items():
            entry = pairs.setdefault(key, [0, 0.0])
            entry[0] += requests
            entry[1] += cost
    if len(pairs) < 2:
        return []

    total = sum(cost for _, cost in pairs.values())
    rows = []
    for (role, model), (requests, cost) in sorted(pairs.items(), key=lambda kv: -kv[1][1]):
        share = 100 * cost / total if total else 0
        rows.append([role, short(model), str(requests), money(cost), "%2.0f%%" % share])
    return ["", "who spent it"] + [
        "  " + line for line in table(rows, ["", "model", "requests", "cost", ""], left=2)
    ]


def by_session(sessions):
    rows = []
    for session in sessions:
        # The agent count, not the sub-agent request count: what a reader can
        # act on is how many were spawned.
        agents = " +%d" % len(session.agents) if session.agents else ""
        rows.append(
            [
                session.day or "undated",
                session.key[:8],
                ", ".join(sorted(short(m) for m in session.models)),
                "%d%s" % (session.requests, agents),
                money(session.total),
            ]
        )
    return table(rows, ["date", "session", "models", "requests", "cost"], left=3)


def by_day(sessions):
    days = {}
    for session in sessions:
        day = days.setdefault(session.day or "undated", [0, 0, 0.0])
        day[0] += 1
        day[1] += session.requests
        day[2] += session.total
    rows = [
        [day, str(n), str(requests), money(cost)]
        for day, (n, requests, cost) in sorted(days.items())
    ]
    return table(rows, ["day", "sessions", "requests", "cost"])


def report(sessions, daily):
    ordered = sorted(sessions.values(), key=lambda s: (s.day or "9999", s.key))
    lines = by_day(ordered) if daily else by_session(ordered)
    total = sum(s.total for s in ordered)
    lines.append("")
    lines.append(
        "%d session%s  %s" % (len(ordered), "" if len(ordered) == 1 else "s", money(total))
    )
    lines += breakdown(ordered)
    lines += who_spent(ordered)

    unpriced = {}
    for session in ordered:
        for model, n in session.unpriced.items():
            unpriced[model] = unpriced.get(model, 0) + n
    if unpriced:
        lines.append("")
        for model, n in sorted(unpriced.items()):
            lines.append(
                "NOT PRICED — no rate for %r, %d request(s) left out of every "
                "figure above" % (model, n)
            )
    return "\n".join(lines), bool(unpriced)


# --------------------------------------------------------------------------
# --selftest: the arithmetic against inputs chosen to be wrong in the ways it
# could be wrong. Run at build time, so a wrong price stops the build rather
# than printing for a month in the shape a right one uses.
# --------------------------------------------------------------------------


def selftest():
    failures, ran = [], []

    def near(name, got, want):
        ran.append(name)
        if abs(got - want) > 1e-9:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def check(name, got, want):
        ran.append(name)
        if got != want:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def cost_of(usage, model="claude-opus-5", speed="standard", geo=None):
        return sum(dollars(tokens_of(usage), model, speed, geo).values())

    # A date suffix is not a different model.
    check("dated id normalises", normalise("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
    check("undated id untouched", normalise("claude-opus-5"), "claude-opus-5")
    # Eight digits, not any tail: a real id ending in a number must survive.
    check("short tail untouched", normalise("claude-opus-4-5"), "claude-opus-4-5")

    # Each category at its own rate, one at a time, so a swapped column shows.
    near("input at base", cost_of({"input_tokens": 1_000_000}), 5.00)
    near("output at output rate", cost_of({"output_tokens": 1_000_000}), 25.00)
    near("cache read at a tenth", cost_of({"cache_read_input_tokens": 1_000_000}), 0.50)
    near(
        "1h write at twice base",
        cost_of({"cache_creation": {"ephemeral_1h_input_tokens": 1_000_000}}),
        10.00,
    )
    near(
        "5m write at 1.25x base",
        cost_of({"cache_creation": {"ephemeral_5m_input_tokens": 1_000_000}}),
        6.25,
    )

    # A model is priced from its own rates, not the session's.
    near(
        "haiku output",
        cost_of({"output_tokens": 1_000_000}, model="claude-haiku-4-5-20251001"),
        5.00,
    )
    near("sonnet input", cost_of({"input_tokens": 1_000_000}, model="claude-sonnet-5"), 2.00)
    # The one rate that does not follow its column's multiplier, so the one a
    # reader is most likely to "correct" back to 1.00.
    near(
        "fable 5.1 cache read",
        cost_of({"cache_read_input_tokens": 1_000_000}, model="claude-fable-5-1"),
        0.25,
    )
    near(
        "fable 5.1 is not fable 5",
        cost_of({"cache_read_input_tokens": 1_000_000}, model="claude-fable-5"),
        1.00,
    )

    # Fast mode is a price, not a model, and only on the two that offer it.
    near("fast opus output", cost_of({"output_tokens": 1_000_000}, speed="fast"), 50.00)
    near(
        "fast sonnet is standard",
        cost_of({"output_tokens": 1_000_000}, model="claude-sonnet-5", speed="fast"),
        10.00,
    )

    # US-pinned inference multiplies every category.
    near("us geo multiplies", cost_of({"output_tokens": 1_000_000}, geo="us"), 27.50)

    # A fallback pair bills both attempts and the top level reports only the
    # second; summing the iterations is the whole difference. Taken verbatim
    # from a real record.  see docs/sessions.md#what-the-corpus-measured
    fallback = {
        "output_tokens": 1442,
        "input_tokens": 2,
        "cache_read_input_tokens": 71095,
        "iterations": [
            {
                "output_tokens": 1452,
                "input_tokens": 2,
                "cache_read_input_tokens": 75412,
                "cache_creation": {
                    "ephemeral_5m_input_tokens": 0,
                    "ephemeral_1h_input_tokens": 3977,
                },
            },
            {
                "output_tokens": 1442,
                "input_tokens": 2,
                "cache_read_input_tokens": 71095,
                "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0},
            },
        ],
    }
    check("both attempts counted", tokens_of(fallback)["output"], 2894)
    check("the dropped write is found", tokens_of(fallback)["write1h"], 3977)
    # And a record with no iterations still answers, from the top level.
    check("no iterations falls back", tokens_of({"output_tokens": 100})["output"], 100)
    # A missing TTL split is charged at the dearer rate rather than dropped.
    check(
        "unsplit write is not lost", tokens_of({"cache_creation_input_tokens": 500})["write1h"], 500
    )

    # An unknown model is named, never priced at zero.
    ran.append("unknown model refused")
    try:
        rates("claude-something-9", "standard")
        failures.append("unknown model refused: priced something it does not know")
    except Unpriceable:
        pass

    # The placeholder records are dropped by `read`, and the table must go on
    # refusing the id: pricing it at zero here would make a real gap silent.
    ran.append("synthetic refused, not priced")
    try:
        rates(SYNTHETIC, "standard")
        failures.append("synthetic refused, not priced: the table holds a rate for it")
    except Unpriceable:
        pass

    # Both sub-agent layouts belong to their session, and neither is one.
    check(
        "volume layout", session_of("/vol/projects/p/abc-123/subagents/agent-xyz.jsonl"), "abc-123"
    )
    check("archive layout", session_of("/a/2026/09-01/abc-123--agent-xyz.jsonl"), "abc-123")
    check("a session is itself", session_of("/a/2026/09-01/abc-123.jsonl"), "abc-123")
    check("volume sub-agent detected", is_subagent("/vol/p/abc/subagents/agent-x.jsonl"), True)
    check("archive sub-agent detected", is_subagent("/a/abc--agent-x.jsonl"), True)
    check("a session is not a sub-agent", is_subagent("/a/abc.jsonl"), False)

    # `who spent it` — the rows must keep the roles apart and add up to the
    # whole, because a sub-agent's spend quietly landing on the main chain is
    # the failure that makes delegation look free.
    mixed = Session("s")
    mixed.spend = {
        ("main chain", "claude-opus-5"): [51, 9.00],
        ("sub-agent", "claude-haiku-4-5"): [6, 1.00],
    }
    rows = who_spent([mixed])
    check("both roles are shown", len([r for r in rows if "chain" in r or "agent" in r]), 2)
    check(
        "the weaker model's share",
        any("sub-agent" in r and "haiku-4-5" in r and "10%" in r for r in rows),
        True,
    )
    check(
        "the main chain's share",
        any("main chain" in r and "opus-5" in r and "90%" in r for r in rows),
        True,
    )
    # Two sessions on the same pair are one row, not two.
    twin = Session("t")
    twin.spend = {("main chain", "claude-opus-5"): [10, 1.00]}
    check("same pair collapses", len([r for r in who_spent([mixed, twin]) if "opus-5" in r]), 1)
    # Nothing to compare, nothing said.
    alone = Session("a")
    alone.spend = {("main chain", "claude-opus-5"): [4, 1.00]}
    check("one pair says nothing", who_spent([alone]), [])

    if failures:
        print("session-cost --selftest FAILED (%d of %d)" % (len(failures), len(ran)))
        for line in failures:
            print("  " + line)
        return 1
    print("session-cost --selftest ok (%d cases)" % len(ran))
    return 0


def main():
    # `| head` is how anybody reads a long table, and Python's default is to
    # raise BrokenPipeError at exit and print a traceback UNDER the output that
    # was correct, which reads as the tool having failed. The default
    # disposition dies silently on the closed pipe instead.
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    # The examples belong in --help and not only in this file: a session
    # reaches for --help first, and a path it has to invent is invented wrong.
    parser = argparse.ArgumentParser(
        # Hand-wrapped: this formatter leaves the description raw too, so a
        # paragraph written as one string prints as one very long line.
        description=__doc__.splitlines()[0]
        + """
NOT money that was spent. API list rates for the same traffic, which is not
how a subscription is billed and does not convert into its allowance — it
compares sessions against each other, and says which part of one weighs.""",
        epilog="""transcripts live under ~/.claude/projects/<cwd with each / turned into a ->/
  d=~/.claude/projects/$(pwd | tr / -)
  %(prog)s "$(ls -t "$d"/*.jsonl | head -1)"   the session running now
  %(prog)s "$d"                                every session still kept
  %(prog)s --by-day "$d"                       the same, by day

every report ends with `where it went`, covering EVERYTHING passed in — so one
file is that session broken down, a directory is the whole set broken down""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "paths",
        nargs="*",
        metavar="PATH",
        help="a .jsonl transcript, or a directory walked for them; required, there is no default",
    )
    parser.add_argument(
        "--by-day", action="store_true", help="one line per day instead of one per session"
    )
    parser.add_argument("--selftest", action="store_true", help="prove the arithmetic and stop")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if not args.paths:
        parser.error("give a transcript or a directory holding some")

    files = transcripts(args.paths)
    if not files:
        sys.exit("No .jsonl transcripts under: %s" % ", ".join(args.paths))

    sessions = {}
    for path in files:
        read(path, sessions)
    if not sessions:
        sys.exit("The transcripts hold no assistant messages — nothing to price.")

    text, incomplete = report(sessions, args.by_day)
    print(text)
    return 3 if incomplete else 0


if __name__ == "__main__":
    sys.exit(main())
