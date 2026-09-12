#!/usr/bin/env python3
"""The agent's journal cut into its entries, each with the session that wrote it.

    journal.py --clone DIR [--at WHERE]             the entries, plain, on stdout
    journal.py --clone DIR [--at WHERE] --out DIR   one file per entry; prints how many, and which first
    journal.py --selftest                           prove the cutting and the attribution, and stop

Runs on the host, under `just journal`, over JOURNAL.md on the clone's source/main and the sealed
records in RUNNER_RECORDS_DIR. It writes nothing but the files --out names.

An entry belongs to the session that made most of its lines. Not the one that made its
heading, which is rewritten long after, nor the one that made its oldest line, which can be a single
line blame matches to an older entry.  see docs/monitor.md#which-session-wrote-an-entry
"""

import argparse
import collections
import datetime
import importlib.util
import os
import re
import subprocess
import sys

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# A dated heading opens an entry; `## Next` and the other second-level headings inside one do not.
HEADING = re.compile(r"## \d{4}-\d{2}-\d{2}\b")
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
SESSION_ID = re.compile(r"[0-9a-f]{4,}")
# Bold and underlined, a shape and not a colour: the operator is deutan colourblind.
HEADING_ON, HEADING_OFF = "\033[1;4m", "\033[0m"
WHERE = "Where to open is a day, 2026-09-03, or a session id: hex, four characters or more."


def load_module(path, name):
    """A host script beside this one, loaded by path: these run from a checkout
    and are not an installed package."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(CHECKOUT, path))
    if spec is None or spec.loader is None:
        sys.exit("Could not load %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The screens' grammar and the store's reader.  see host/lib/screen.py
screen = load_module("host/lib/screen.py", "screen")


# --------------------------------------------------------------------------
# the journal
# --------------------------------------------------------------------------


def blame(clone):
    """Every line of JOURNAL.md on source/main, with the commit that made it."""
    try:
        out = subprocess.run(
            ["git", "-C", clone, "blame", "--line-porcelain", "source/main", "--", "JOURNAL.md"],
            capture_output=True,
            timeout=300,
        )
    except (OSError, subprocess.SubprocessError) as err:
        sys.exit("Could not run git blame in %s: %s" % (clone, err))
    if out.returncode:
        sys.exit(
            "Could not read JOURNAL.md on source/main in %s:\n%s"
            % (clone, out.stderr.decode("utf-8", "replace").strip())
        )
    return parse_blame(out.stdout.decode("utf-8", "replace"))


def parse_blame(porcelain):
    """(text, commit) per line: a line's text follows a tab, after the headers naming its commit."""
    lines: list[tuple[str, str]] = []
    sha = ""
    for row in porcelain.split("\n"):
        if row.startswith("\t"):
            lines.append((row[1:], sha))
        elif re.match(r"[0-9a-f]{40} ", row):
            sha = row[:40]
    return lines


def cut(lines):
    """The entries in file order, newest first, each its lines from its heading on. What comes
    before the first dated heading is the file's preamble, not an entry."""
    entries: list[list[tuple[str, str]]] = []
    for line in lines:
        if HEADING.match(line[0]):
            entries.append([])
        if entries:
            entries[-1].append(line)
    return entries


def written_by(entry, by_commit):
    """The run that made most of the entry's lines, or None when no record holds any of them."""
    made = collections.Counter(by_commit[sha] for _text, sha in entry if sha in by_commit)
    return made.most_common(1)[0][0] if made else None


# --------------------------------------------------------------------------
# the sessions
# --------------------------------------------------------------------------


class Sessions:
    """Every run the records hold, in start order, and the run each commit was made in.

    A run and not a record: `chat --continue` appends a second run to the transcript it resumes,
    and a commit falls in exactly one run's window.  see docs/monitor.md#attributing-a-commit
    """

    def __init__(self, records):
        self.runs = sorted(
            ((record, run) for record in records for run in record["runs"]),
            key=lambda pair: pair[1]["from"],
        )
        self.by_commit = {
            sha: n for n, (_record, run) in enumerate(self.runs) for sha in run.get("commits") or []
        }


def render(entries, sessions, styled=False):
    """Each entry's text with the block about its session under the heading, and which run
    wrote each entry."""
    owners = [written_by(entry, sessions.by_commit) for entry in entries]
    wrote: dict[int, list[int]] = collections.defaultdict(list)
    for position, run in enumerate(owners):
        if run is not None:
            wrote[run].append(position)

    texts = []
    for position, (entry, run) in enumerate(zip(entries, owners, strict=True)):
        heading = entry[0][0]
        if styled:
            heading = HEADING_ON + heading + HEADING_OFF
        rest = [text for text, _sha in entry[1:]]
        if rest and rest[0].strip():
            rest.insert(0, "")
        block = screen.fact([("session", about(sessions, run, wrote[run], position))])
        texts.append("\n".join([heading, *block, *rest]))
    return texts, owners


def about(sessions, run, mine, position):
    """The lines under an entry's heading: when its session ran, what it was, how to read it."""
    if run is None:
        return [
            "no sealed record holds the commit that wrote it — 'just records' seals what is waiting"
        ]

    record, span = sessions.runs[run]
    start, end = span["from"], span["to"]
    if screen.local_day(start) == screen.local_day(end):
        until = datetime.datetime.fromtimestamp(end).strftime("%H:%M")
    else:
        until = screen.when(end)
    commits = len(span.get("commits") or [])
    lines = [
        "%s → %s · %s · %s · %d commit%s"
        % (
            screen.when(start),
            until,
            "unattended" if record["kind"] == "auto" else "conversation",
            screen.duration(end - start),
            commits,
            "" if commits == 1 else "s",
        ),
        "just read %s" % record["id"][:8],
    ]

    if len(mine) > 1:
        lines.append("entry %d of %d from this session" % (mine.index(position) + 1, len(mine)))
    return lines


def locate(at, entries, sessions, owners):
    """The position `at` names, or None and the sentence saying why."""
    if not at:
        return 0, None

    if DAY.fullmatch(at):
        for position, entry in enumerate(entries):
            if entry[0][0].startswith("## " + at):
                return position, None
        return None, "No entry is dated %s." % at

    ids = sorted({record["id"] for record, _run in sessions.runs if record["id"].startswith(at)})
    if not ids:
        return None, "No sealed record has an id starting %s." % at
    if len(ids) > 1:
        return None, "'%s' matches %d sessions: %s. Give more of the id." % (
            at,
            len(ids),
            ", ".join(found[:8] for found in ids),
        )
    for position, run in enumerate(owners):
        if run is not None and sessions.runs[run][0]["id"] == ids[0]:
            return position, None
    return None, "Session %s wrote no entry in the journal as fetched." % ids[0][:8]


# --------------------------------------------------------------------------
# --selftest: the parts that are wrong in ways nothing on screen would show
# --------------------------------------------------------------------------


def selftest():
    failures, ran = [], []

    def check(name, got, want):
        ran.append(name)
        if got != want:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    def porcelain(rows):
        """What --line-porcelain prints for (commit letter, text) rows."""
        out = []
        for n, (letter, text) in enumerate(rows, 1):
            out += [
                "%s %d %d 1" % (letter * 40, n, n),
                "author someone",
                "committer-time %d" % n,
                "summary a subject",
                "filename JOURNAL.md",
                "\t" + text,
            ]
        return "\n".join(out) + "\n"

    # Newest first, with what fooled the rules that were struck, both seen in the real journal:
    # the first heading rewritten by a later commit, and a stray line blamed on an older one.
    lines = parse_blame(
        porcelain(
            [
                ("a", "# Journal"),
                ("a", ""),
                ("e", "## 2026-09-03 (third) — c"),
                ("a", ""),
                ("c", "body c"),
                ("c", "## Next"),
                ("c", "more c"),
                ("b", "---"),
                ("e", "## 2026-09-02 — b, second"),
                ("b", "body b2"),
                ("b", "## 2026-09-02 — b, first"),
                ("b", "body b1"),
                ("a", "## 2026-09-01 — a"),
                ("a", "body a"),
            ]
        )
    )
    entries = cut(lines)
    check("the preamble is not an entry, and ## Next is not a boundary", len(entries), 4)
    check("an entry keeps its ## Next", [text for text, _sha in entries[0]][3], "## Next")

    def record(ident, kind, start, commits):
        return {
            "id": ident,
            "kind": kind,
            "started_by": "runner",
            "runs": [{"from": start, "to": start + 600, "commits": [c * 40 for c in commits]}],
        }

    sessions = Sessions(
        [
            record("cccc0001-0000", "chat", 280, "c"),
            record("bbbb0001-0000", "auto", 150, "b"),
            record("dddd0001-0000", "auto", 260, ""),
            record("dddd0002-0000", "auto", 270, ""),
        ]
    )
    check(
        "most lines decide, not the heading or one stray line",
        written_by(entries[0], sessions.by_commit),
        3,
    )
    texts, owners = render(entries, sessions)
    check(
        "each entry goes to its run, and a commit no record holds to none", owners, [3, 0, 0, None]
    )
    check("the session's id is there to read", "just read cccc0001" in texts[0], True)
    check("a conversation is named as one", "· conversation ·" in texts[0], True)
    check(
        "a session's first entry says which of two",
        "entry 1 of 2 from this session" in texts[1],
        True,
    )
    check("a session's other entry says which", "entry 2 of 2 from this session" in texts[2], True)
    check("an entry with no record says so", "no sealed record holds" in texts[3], True)
    check("the body is set off from the block", texts[1].split("\n")[4], "")
    check(
        "styled headings are bold",
        render(entries, sessions, styled=True)[0][0].startswith(HEADING_ON),
        True,
    )

    def at(where):
        return locate(where, entries, sessions, owners)

    check("nothing asked opens the newest", at(""), (0, None))
    check("a day opens its newest entry", at("2026-09-02"), (1, None))
    check("a day with no entry says so", at("2026-08-01")[0], None)
    check("an id prefix opens the entry its session wrote", at("bbbb"), (1, None))
    check("an ambiguous prefix names both", "matches 2 sessions" in at("dddd")[1], True)
    check("a session that wrote nothing says so", "wrote no entry" in at("dddd0001")[1], True)
    check("an id no record has says so", "No sealed record" in at("ffff")[1], True)

    if failures:
        print("journal --selftest FAILED (%d of %d)" % (len(failures), len(ran)))
        for line in failures:
            print("  " + line)
        return 1
    print("journal --selftest ok (%d cases)" % len(ran))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--clone", help="the bare clone of the agent's repository")
    parser.add_argument(
        "--at", default="", help="a day, 2026-09-03, or a session id, or enough of one"
    )
    parser.add_argument(
        "--out", help="write one file per entry here; print how many, and which first"
    )
    parser.add_argument(
        "--selftest", action="store_true", help="prove the cutting and the attribution, and stop"
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    if args.at and not (DAY.fullmatch(args.at) or SESSION_ID.fullmatch(args.at)):
        print(WHERE, file=sys.stderr)
        return 2

    root = os.environ.get("RUNNER_RECORDS_DIR") or ""
    if not root or not args.clone:
        sys.exit("Run this through 'just journal', which fetches the clone and finds the records.")

    entries = cut(blame(args.clone))
    if not entries:
        sys.exit("JOURNAL.md on source/main in %s holds no dated entry." % args.clone)
    sessions = Sessions(screen.load(root))
    texts, owners = render(entries, sessions, styled=bool(args.out))

    first, why = locate(args.at, entries, sessions, owners)
    if first is None:
        print(why, file=sys.stderr)
        return 1

    if args.out:
        for number, text in enumerate(texts, 1):
            with open(os.path.join(args.out, str(number)), "w") as handle:
                handle.write(text + "\n")
        print(len(texts), first + 1)
        return 0

    try:
        print("\n\n".join(texts[first : first + 1] if args.at else texts))
        sys.stdout.flush()
    except BrokenPipeError:
        # A reader that stops early, `head` most often, is not a failure.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


if __name__ == "__main__":
    sys.exit(main())
