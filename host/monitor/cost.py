#!/usr/bin/env python3
"""What the archived sessions cost, priced from their sealed records.

    cost.py [--by-day] [-d N] [-- ID...]

Runs on the host, under `just cost`, which says where the records are. The report is
image/session-cost.py's own, fed from the records rather than from transcripts: one price table,
one way of printing it.

see docs/monitor.md#what-the-archive-cost
"""

import argparse
import importlib.util
import json
import os
import re
import signal
import sys

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(CHECKOUT, path))
    if spec is None or spec.loader is None:
        sys.exit("Could not load %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COST = load_module("image/session-cost.py", "session_cost")


def records(root):
    # Every record, probes included — unlike host/lib/screen.py's load: what a probe spent was spent.
    found = []
    for base, _dirs, names in os.walk(root):
        for name in names:
            if name.endswith(".json"):
                with open(os.path.join(base, name)) as handle:
                    found.append(json.load(handle))
    return sorted(found, key=lambda record: record["path"])


def directory(record):
    # The archive's day directory: `transcripts/2026/09-06/<id>.jsonl` is `2026/09-06`.
    return record["path"].split("/", 1)[1].rsplit("/", 1)[0]


def as_priced(record):
    """One record as the Session session-cost.py builds from a session's transcripts."""
    session = COST.Session(record["id"])
    session.day = record["day"]
    session.agents = {sub["id"] for sub in record["subagents"]}

    sources = [(record, "main chain")] + [(sub, "sub-agent") for sub in record["subagents"]]
    for source, role in sources:
        for entry in source["usage"]:
            model = entry["model"]
            # Skipped and not priced at zero, as session-cost.py skips it: counting the placeholder
            # inflates the request count and names a price that is not missing.
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

            # A model the table refuses counts its requests and tokens, and is named at the end:
            # dropped instead, an unpriced session would look like a cheap one.
            if entry["rates"] is None:
                session.unpriced[model] = session.unpriced.get(model, 0) + entry["requests"]
                continue

            priced = COST.dollars(counted, model, entry["speed"], entry["geo"])
            for name in COST.CATEGORIES:
                session.cost[name] += priced[name]
            spent = session.spend.setdefault((role, COST.normalise(model or "unknown")), [0, 0.0])
            spent[0] += entry["requests"]
            spent[1] += sum(priced.values()) + entry["searches"] * COST.WEB_SEARCH

    return session


def by_ids(found, ids):
    """The sessions the ids name, or an exit status and nothing.

    A prefix that lands on two sessions stops and names them: priced under one heading, two
    sessions read as one expensive one.
    """
    chosen = []
    for wanted in ids:
        if not re.fullmatch(r"[0-9a-fA-F-]+", wanted):
            print("'%s' is not a session id." % wanted, file=sys.stderr)
            return None, 2

        hits = [record for record in found if record["id"].startswith(wanted)]
        if not hits:
            print("No session starting '%s' in the records." % wanted, file=sys.stderr)
            return None, 1
        if len(hits) > 1:
            print("'%s' matches %d sessions:" % (wanted, len(hits)), file=sys.stderr)
            for record in hits:
                print("  %s" % record["id"], file=sys.stderr)
            return None, 2

        chosen.append(hits[0])
    return chosen, 0


def main():
    # `| head` is how a long table is read, and a traceback under correct output reads as a failure.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("ids", nargs="*", metavar="ID")
    parser.add_argument("--by-day", action="store_true")
    parser.add_argument("-d", "--days", type=int, default=0)
    args = parser.parse_args()

    root = os.environ.get("RUNNER_RECORDS_DIR") or ""
    if not root:
        sys.exit("Run this through 'just cost', which says where the records are.")

    found = records(root)
    if not found:
        sys.exit(
            "No sealed records under %s.\n"
            "Every session end seals its own; 'just records' seals what is waiting." % root
        )

    if args.ids:
        chosen, status = by_ids(found, args.ids)
        if chosen is None:
            return status
        scope = "session %s" % " ".join(args.ids)
    else:
        # One day per session line and ten by day, because a day is one row there and a screenful here.
        days = args.days or (10 if args.by_day else 1)
        window = sorted({directory(record) for record in found})[-days:]
        chosen = [record for record in found if directory(record) in window]
        scope = "the last %d day(s) the archive holds" % days

    files = sum(1 + len(record["subagents"]) for record in chosen)
    text, incomplete = COST.report(
        {record["id"]: as_priced(record) for record in chosen}, args.by_day
    )

    print("%d transcript(s) from the sealed records — %s\n" % (files, scope))
    print(text)
    return 3 if incomplete else 0


if __name__ == "__main__":
    sys.exit(main())
