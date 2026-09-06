#!/usr/bin/env python3
"""What `just sessions`, `just read`, `just tools` and `just cost` print today,
rendered from the sealed records alone.

    records-render.py rows                       the table archive_rows builds
    records-render.py sessions --ref REF         `just sessions --all`
    records-render.py read ID [--footer|--subagent K]  `just read ID` — its header,
                                                       its sub-agent listing, or one
                                                       sub-agent's own header
    records-render.py tools [-d N] [TOOL...]     `just tools`
    records-render.py cost [--by-day] [-d N] [ID...]   `just cost`

THIS RENDERS NOTHING FOR ANYBODY TO READ. It exists so that the store's
sufficiency is proved rather than asserted: `just records --prove` runs each of
these beside the command it imitates and diffs the two, byte for byte, over the
whole archive. A field missing from a record would otherwise be discovered
halfway through rewriting a command, months later, with the store published and
its shape awkward to change.

It reads the records and nothing else — no transcript, no jq filter, no volume.
The one thing it is given is which ref the listing names, because that is a fact
about the archive clone and not about any session.

When the commands are normalised onto the store, this file is what they become
and it goes away as a separate thing. Until then it is the executable statement
of what the store has to carry, and a field struck from a record shows up here
as a diff rather than as a surprise later.

see docs/monitor.md#the-sufficiency-proof
"""

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TAB = "\t"


def load(name, where):
    spec = importlib.util.spec_from_file_location(name, os.path.join(CHECKOUT, where))
    if spec is None or spec.loader is None:
        sys.exit("Could not load %s" % where)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COST = load("session_cost", "image/session-cost.py")


def records(root):
    """Every sealed record, by session id."""
    found = {}
    for base, _dirs, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".json"):
                continue
            with open(os.path.join(base, name)) as handle:
                record = json.load(handle)
            found[record["id"]] = record
    return found


# --------------------------------------------------------------------------
# The table `just sessions` prints and `just read` heads a transcript with
# --------------------------------------------------------------------------
# host/lib/archive.sh builds one row per session — the transcript's path, then
# host/archive/session-meta.jq's fourteen fields — and both commands are a pure
# function of it. Reproducing the row is therefore what proves both.


def human_duration(seconds):
    if seconds >= 3600:
        return "%dh%dm" % (seconds // 3600, (seconds % 3600) // 60)
    if seconds >= 60:
        return "%dm" % (seconds // 60)
    return "%ds" % seconds


def totals(record):
    """Output and thinking over the session AND everything it delegated to.

    session-meta.jq cumulates a sub-agent's requests into its session's, so the
    figures on a listing row are the pair. Its CONTEXT is not cumulated, and
    that is not an oversight: every agent has a context of its own.
    """
    rows = list(record["usage"])
    subrequests = 0
    for sub in record["subagents"]:
        rows += sub["usage"]
        subrequests += sub["requests"]
    # output_reported and not output: the row is what session-meta.jq computes,
    # and it reads the top-level usage.  see docs/monitor.md#the-two-output-figures
    return (
        sum(row["output_reported"] for row in rows),
        sum(row["thinking"] for row in rows),
        subrequests,
    )


def row(record):
    start = record["start"]
    when = time.localtime(start) if start is not None else None
    output, thinking, subrequests = totals(record)
    # The transcript's span, which is what `just sessions` shows and what
    # `session-meta.jq` computes. NOT stored: on a resumed transcript it is not
    # a duration at all, and a stored one is the field a reader takes for the
    # answer.  see docs/monitor.md#one-file-is-not-always-one-run
    elapsed = 0 if start is None else record["end"] - start
    return [
        record["path"],
        record["local_day"] or "",
        time.strftime("%H:%M", when) if when else "",
        human_duration(elapsed),
        str(record["messages"]),
        record["kind"],
        str(record["requests"]),
        str(subrequests),
        str(len(record["subagents"])),
        str(output),
        str(thinking),
        str(record["end_context"]),
        str(elapsed),
        "" if record["generating"] is None else str(record["generating"]),
        record["title"] or "(untitled)",
    ]


def ordered_rows(root):
    """Newest first, through the sort host/lib/archive.sh uses.

    Its own `sort`, not a comparison written here: the last-resort ordering of
    equal keys is a whole-line byte comparison under the caller's locale, and a
    second implementation of that is a difference nobody would find.
    """
    lines = [TAB.join(row(r)) for r in records(root).values()]
    sorted_out = subprocess.run(
        ["sort", "-r", "-t", TAB, "-k2,2", "-k3,3"],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in sorted_out.split("\n") if line]


# --------------------------------------------------------------------------
# just sessions --all
# --------------------------------------------------------------------------


def sessions(root, ref):
    lines = ordered_rows(root)
    fields = [line.split(TAB) for line in lines]
    out = ["%s — %d session(s), newest first" % (ref, len(fields))]

    undated = sum(1 for f in fields if f[0].startswith("transcripts/undated/"))
    if undated:
        out.append("  %d transcript(s) carry no timestamp and are filed under undated/" % undated)

    # The "collection(s) not pushed" footnote is deliberately absent: it counts
    # commits on the local `sessions` branch that origin does not have, and a
    # record is only sealed against origin. `just records --prove` refuses to
    # run while the two differ, so the footnote can never be on screen.

    shifted = 0
    for f in fields:
        parts = f[0].split("/")
        if "%s-%s" % (parts[1], parts[2]) != f[1]:
            shifted += 1
    if shifted:
        out.append(
            "  %d started on a different UTC day than the local one shown"
            " — the path beside a read says which" % shifted
        )

    table = []
    for n, f in enumerate(fields, 1):
        mark = "+%s" % f[8] if int(f[8]) > 0 else ""
        table.append(
            "  %3d  %s %s  %5s  %4s msg  %-3s %-4s  %s"
            % (n, f[1], f[2], f[3], f[4], mark, f[5], f[14])
        )

    if any("msg  +" in line for line in table):
        out.append("  +N marks subagents — 'just read <number> --agent K' reads one")

    out.append("")
    out += table
    out.append("")
    out.append("Read one:  just read <number>   or  just read <id>")
    return "\n".join(out)


# --------------------------------------------------------------------------
# just read ID
# --------------------------------------------------------------------------


def toks(n):
    # +0.5 because %d truncates and the branch below it rounds; two
    # implementations disagreeing about one session is the bug.
    if n < 1000:
        return "%d" % n
    if n < 10000:
        return "%.1fk" % (n / 1000)
    if n < 1000000:
        return "%dk" % (n / 1000 + 0.5)
    return "%.1fM" % (n / 1000000)


def clock(seconds):
    t = int(seconds + 0.5)
    if t >= 3600:
        return "%dh%02dm" % (t // 3600, (t % 3600) // 60)
    if t >= 60:
        return "%dm%02ds" % (t // 60, t % 60)
    return "%ds" % t


def read_header(record, ref, subagent=None):
    f = row(record)
    name = os.path.basename(f[0])

    if subagent is not None:
        sub = record["subagents"][subagent - 1]
        return "subagent %s\n  of session %s %s\n  %s\n" % (
            sub["id"],
            f[1],
            f[2],
            os.path.basename(sub["path"]),
        )

    across = ""
    if int(f[8]) > 0:
        across = " (+%s across %s agent%s)" % (f[7], f[8], "s" if int(f[8]) > 1 else "")
    worked = ", %s generating" % clock(int(f[13])) if f[13] != "" else ""
    return (
        "session %s %s  (%s msg, %s)\n  %s\n  %s\n" % (f[1], f[2], f[4], f[5], f[14], name)
        + "  git show %s:%s\n" % (ref, f[0])
        + "\n%s requests%s · %s output, %s thinking\n%s end context · %s elapsed%s\n"
        % (
            f[6],
            across,
            toks(int(f[9])),
            toks(int(f[10])),
            toks(int(f[11])),
            clock(int(f[12])),
            worked,
        )
    )


def read_footer(record, typed):
    if not record["subagents"]:
        return ""
    lines = [
        "  just read %s --subagent %d   (%s)" % (typed, n, sub["id"])
        for n, sub in enumerate(record["subagents"], 1)
    ]
    return "\n" + "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# just tools
# --------------------------------------------------------------------------
# Counted from each call's own UTC day, so a session running past midnight lands
# on both sides — which is why the store buckets by day rather than keeping one
# flat count per session. A sub-agent's calls are its own in the store and are
# summed back in here, because `just tools` reads every file in a day's
# directory and does not tell them apart.


def day_directories(found):
    return sorted({record["path"].split("/", 2)[1].rsplit("/", 1)[0] for record in found.values()})


def tool_counts(found, directories):
    counts = {}
    for record in found.values():
        where = record["path"].split("/", 2)[1].rsplit("/", 1)[0]
        if where not in directories:
            continue
        for source in [record] + record["subagents"]:
            for day, names in source["tools"].items():
                for name, n in names.items():
                    counts[(name, day)] = counts.get((name, day), 0) + n
    return counts


def columned(lines):
    """Through `column -t -s\\t`, the one the recipes pipe into."""
    return subprocess.run(
        ["column", "-t", "-s", TAB],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
        check=True,
    ).stdout.rstrip("\n")


def tools(root, days, names):
    found = records(root)
    directories = day_directories(found)[-(days + 1) :]
    counts = tool_counts(found, directories)
    keep = sorted({day for _name, day in counts})[-days:]
    if not keep:
        return "No tool calls in the last %d day(s) the archive holds." % days

    if not names:
        totals_by_tool = {}
        for (name, day), n in counts.items():
            if day in keep:
                totals_by_tool[name] = totals_by_tool.get(name, 0) + n
        header = "tool" + "".join(TAB + day[5:] for day in keep) + TAB + "total"
        body = [
            name + "".join(TAB + str(counts.get((name, day), 0)) for day in keep) + TAB + str(total)
            for name, total in totals_by_tool.items()
        ]
        # The same sort the recipe runs: numeric descending on the total column,
        # ties settled by the whole line, reversed with it.
        column = len(keep) + 2
        body = subprocess.run(
            ["sort", "-t", TAB, "-k%d,%d" % (column, column), "-rn"],
            input="\n".join(body) + "\n",
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split("\n")
        body = [line for line in body if line]
        grand = sum(totals_by_tool.values())
        footer = (
            "total"
            + "".join(
                TAB + str(sum(n for (_t, d), n in counts.items() if d == day)) for day in keep
            )
            + TAB
            + str(grand)
        )
        return columned([header] + body + [footer])

    header = "day" + "".join(TAB + name for name in names) + TAB + "total"
    body = []
    for day in keep:
        cells = [counts.get((name, day), 0) for name in names]
        body.append(day[5:] + "".join(TAB + str(c) for c in cells) + TAB + str(sum(cells)))
    columns = [sum(counts.get((name, day), 0) for day in keep) for name in names]
    footer = "total" + "".join(TAB + str(c) for c in columns) + TAB + str(sum(columns))
    return columned([header] + body + [footer])


# --------------------------------------------------------------------------
# just cost
# --------------------------------------------------------------------------
# Fed straight into session-cost.py's own printing rather than into a second
# copy of it: what this proves is that the store carries everything that file
# needs, which is the whole question. The rates come from the record, which took
# them from that same file when it sealed.


def as_priced(record):
    """One record as the Session object session-cost.py builds from transcripts."""
    session = COST.Session(record["id"])
    session.day = record["day"]
    session.agents = {sub["id"] for sub in record["subagents"]}

    for source, role in [(record, "main chain")] + [
        (sub, "sub-agent") for sub in record["subagents"]
    ]:
        for entry in source["usage"]:
            model = entry["model"]
            # The placeholder records carry no priceable model and every count
            # zero. Skipped and NOT priced at zero, exactly as `read` skips
            # them: counting one inflates the request count and names a price
            # that is not missing.
            if model == COST.SYNTHETIC:
                continue
            session.requests += entry["requests"]
            session.models.add(COST.normalise(model or "unknown"))
            counted = {
                "input": entry["input"],
                "write1h": entry["cache_write_1h"],
                "write5m": entry["cache_write_5m"],
                "read": entry["cache_read"],
                "output": entry["output"],
            }
            for name in COST.CATEGORIES:
                session.tokens[name] += counted[name]
            session.thinking += entry["thinking"]
            session.searches += entry["searches"]
            session.search_cost += entry["searches"] * COST.WEB_SEARCH

            if entry["rates"] is None:
                # A model the table refuses: its requests and its tokens count,
                # its cost does not, and it is named at the end. Dropped
                # instead, an unpriced session would look like a cheap one.
                session.unpriced[model] = session.unpriced.get(model, 0) + entry["requests"]
                continue
            priced = COST.dollars(counted, model, entry["speed"], entry["geo"])
            for name in COST.CATEGORIES:
                session.cost[name] += priced[name]
            spent = session.spend.setdefault((role, COST.normalise(model or "unknown")), [0, 0.0])
            spent[0] += entry["requests"]
            spent[1] += sum(priced.values()) + entry["searches"] * COST.WEB_SEARCH

    return session


def cost(root, ref, days, by_day, ids):
    found = records(root)
    if ids:
        chosen = {}
        for wanted in ids:
            hits = [i for i in found if i.startswith(wanted)]
            if len(hits) != 1:
                sys.exit("'%s' matches %d records." % (wanted, len(hits)))
            chosen[hits[0]] = found[hits[0]]
        scope = "session %s" % " ".join(ids)
    else:
        directories = day_directories(found)[-days:]
        chosen = {
            i: r
            for i, r in found.items()
            if r["path"].split("/", 2)[1].rsplit("/", 1)[0] in directories
        }
        scope = "the last %d day(s) the archive holds" % days

    files = sum(1 + len(r["subagents"]) for r in chosen.values())
    priced = {i: as_priced(r) for i, r in chosen.items()}
    if not priced:
        sys.exit("The transcripts hold no assistant messages — nothing to price.")
    text, _incomplete = COST.report(priced, by_day)
    return "%d transcript(s) from %s — %s\n\n%s" % (files, ref, scope, text)


# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("what", choices=["rows", "sessions", "read", "tools", "cost"])
    parser.add_argument("ids", nargs="*")
    parser.add_argument("--ref", default="sessions", help="which ref the listing names")
    parser.add_argument("--subagent", type=int, help="the K-th sub-agent's header instead")
    parser.add_argument(
        "--footer", action="store_true", help="the sub-agent listing that follows a read"
    )
    parser.add_argument("--by-day", action="store_true")
    parser.add_argument("-d", "--days", type=int, default=1)
    args = parser.parse_args()

    root = os.environ.get("RUNNER_RECORDS_DIR") or ""
    if not root:
        sys.exit("Run this through 'just records --prove', which computes where the store is.")

    if args.what == "rows":
        print("\n".join(ordered_rows(root)))
    elif args.what == "sessions":
        print(sessions(root, args.ref))
    elif args.what == "read":
        found = records(root)
        hits = [i for i in found if i.startswith(args.ids[0])]
        if len(hits) != 1:
            sys.exit("'%s' matches %d records." % (args.ids[0], len(hits)))
        record = found[hits[0]]
        if args.footer:
            sys.stdout.write(read_footer(record, args.ids[0]))
        elif args.subagent is not None:
            if not 1 <= args.subagent <= len(record["subagents"]):
                return 1
            sys.stdout.write(read_header(record, args.ref, args.subagent))
        else:
            sys.stdout.write(read_header(record, args.ref))
    elif args.what == "tools":
        print(tools(root, args.days, args.ids))
    else:
        print(cost(root, args.ref, args.days, args.by_day, args.ids))
    return 0


if __name__ == "__main__":
    sys.exit(main())
