#!/usr/bin/env python3
"""Where a held transcript's credential-shaped content appears, in words.

Runs on the host, inside `just collect`'s held-back report, once per held
transcript. Reads the staged transcript, the shape patterns, gitleaks' JSON
report and the spots file check.py wrote, and prints at most three passages
on stdout — who said it, when, and the text around it with the objection
marked.

    passages.py <staged transcript> <patterns> <gitleaks report> <spots file>

Telling the operator to read a JSONL file is not asking for a review, it is
asking them to be a parser. This prints the sentence instead, which is what
makes "this is prose about a key, not a key" a judgement anyone can make in a
glance. Every long run is described rather than printed, by shapes.py.

EMPHASIS=ansi marks the objection in colour; anything else uses guillemets,
which survive a `cat`. AGENT_NAME and OPERATOR_NAME name who spoke.
see docs/archive.md#one-passage-per-place
"""

import json
import os
import re
import sys
import textwrap

from needles import read_transcript
from shapes import run_at, shape_runs

# Whose name goes over a message. Lowercased: it sits in a column beside
# `operator/tool`, not in a sentence.
AGENT = os.environ.get("AGENT_NAME", "agent").lower()
OPERATOR = os.environ.get("OPERATOR_NAME", "operator").lower()

AROUND = 240  # characters quoted either side of an objection
ESCAPES = (("\\n", " "), ("\\t", " "), ("\\r", " "), ('\\"', '"'), ("\\\\", "\\"))

# Which part objected, marked out of the rest: a passage is 500 characters of
# JSON and the thing being ruled on is one token inside it.
#
# Marked with two characters that cannot occur in a transcript and rendered at
# the very end, after the wrapping. Escape codes inserted before `textwrap` are
# counted as width and the lines come out short by exactly their length,
# invisibly, since the text still looks wrapped.
#
# ANSI only when someone is watching; the log gets guillemets, which say the
# same thing and survive a `cat`. NO_COLOR is honoured, in the caller that sets
# EMPHASIS.  see docs/archive.md#marks-and-where-they-are-placed
ON, OFF = "\x01", "\x02"
RENDER = {"ansi": ("\033[1;33m", "\033[0m")}.get(os.environ.get("EMPHASIS", ""), ("»", "«"))


# --- where each objector says it found something ---


def gitleaks_span(number, line, finding):
    """Where gitleaks' finding sits in `line`, as (start, end), or None.

    Without this nothing is marked when gitleaks is the objector, which is most
    of the time — it reads shapes the floor does not — and the passage is then
    74 columns of JSON with the thing being ruled on somewhere in it.

    Its columns are off by one on every line but the first: the newline that
    ended the previous line is counted, so `StartColumn` is one past where the
    match begins. That is a quirk of a build and not a promise, so nothing here
    rests on it — the offset is a first guess and the match is then anchored on
    the part `--redact` did not blank. A column disagreeing with that literal is
    a version spelling it differently, which must read as "do not mark": a
    highlight over the wrong characters is worse than none, because it is read
    as the objection.
    see docs/archive.md#where-gitleaks-finding-sits
    """
    try:
        start, end = int(finding["StartColumn"]) - 1, int(finding["EndColumn"])
    except (KeyError, TypeError, ValueError):
        return None

    width = end - start
    if width <= 0:
        return None
    if number > 1:
        start -= 1

    lead = str(finding.get("Match", "")).split("REDACTED")[0]
    if lead:
        for candidate in (start, start - 1, start + 1):
            if candidate >= 0 and line.startswith(lead, candidate):
                start = candidate
                break
        else:
            start = line.find(lead, max(0, start - AROUND), start + AROUND)
            if start < 0:
                return None

    if not 0 <= start < len(line):
        return None
    return start, min(len(line), start + width)


def objections(lines, pattern, path, report_path, spots_path):
    """Every place an objector named, as {(line, position): its extent or None}.

    One entry per objection, not per line: a transcript line is a whole JSON
    record, and four findings on it are four different places.

    All three objectors are read, and must be: the verbatim layer describes no
    shape at all, so when it is the only one objecting the other two have
    nothing to report.
    """
    spots = {}

    for number, line in enumerate(lines, 1):
        found = pattern.search(line)
        if found:
            spots.setdefault((number, found.start()), None)

    try:
        for finding in json.load(open(report_path)):
            if finding.get("File") != path:
                continue
            number = int(finding.get("StartLine") or 0)
            if not 1 <= number <= len(lines):
                continue
            reach = gitleaks_span(number, lines[number - 1], finding)
            at = reach[0] if reach else max(0, int(finding.get("StartColumn") or 1) - 1)
            spots.setdefault((number, at), reach)
    except Exception:
        pass

    try:
        for record in open(spots_path):
            number, column = (int(n) for n in record.split())
            if 1 <= number <= len(lines):
                spots.setdefault((number, max(0, column - 1)), None)
    except Exception:
        pass

    return spots


# --- what to mark, and how wide ---


def extent(pattern, line, at, reported):
    """What to mark for one objection, as (start, end), or None.

    Never cut a run, and never quote from inside one. Both failures print a
    number that is not the length of anything: the mask ends up describing the
    window rather than the value. So the bounds are snapped outward to whole
    runs, and the shaping happens once over the result. What decides the
    question is never inside the gibberish anyway — it is the command that
    produced it, the JSON key it is the value of, the sentence that introduces it.

    The objector's own extent comes first where there is one: gitleaks' match is
    the field name, the separator, the quotes and the value, which is the whole
    of what is being ruled on. Where nothing reported one and the hit is in no
    run, it is the pattern floor's own match, re-found at the position it
    reported — and where nothing can be placed exactly, nothing is marked rather
    than a guess at a length.
    see docs/archive.md#never-cut-a-run-and-never-quote-from-inside-one
    """
    span = reported or run_at(line, at)
    if not span:
        found = pattern.match(line, at)
        return (found.start(), found.end()) if found else None

    edge = run_at(line, span[0])
    first = edge[0] if edge else span[0]
    edge = run_at(line, span[1] - 1) if span[1] > 0 else None
    return first, (edge[1] if edge else span[1])


# --- the passages ---


def show(lines, pattern, spots):
    """At most three passages, printed.

    One passage per place, not one per objection and not one per line: keyed
    by the line, findings collapse into one; keyed by each finding, two of them
    forty characters apart print nearly the same text twice. So a passage is
    taken, and every objection inside its window is marked in it and struck
    off.  see docs/archive.md#one-passage-per-place
    """
    waiting = sorted(spots.items())
    quoted, shown = set(), 0

    while waiting and shown < 3:
        (number, at), reported = waiting.pop(0)
        line = lines[number - 1]

        who, when = "?", ""
        try:
            record = json.loads(line)
            who = {"assistant": AGENT, "user": OPERATOR + "/tool"}.get(record.get("type"), "?")
            when = (record.get("timestamp") or "")[11:16]
        except ValueError:
            pass

        span = extent(pattern, line, at, reported)
        if span:
            lo, hi = max(0, span[0] - AROUND), min(len(line), span[1] + AROUND)
        else:
            lo, hi = max(0, at - AROUND), min(len(line), at + AROUND + 20)

        # Neither edge of the window may land inside a run either: a run cut by
        # the edge is described with the length of the piece that survived the
        # cut, a number that is not the length of anything and reads exactly
        # like the real one.
        edge = run_at(line, lo)
        if edge:
            lo = edge[0]
        edge = run_at(line, hi - 1) if hi > 0 else None
        if edge:
            hi = edge[1]

        marks, keep = ([span] if span else []), []
        for key, other in waiting:
            if key[0] == number and lo <= key[1] < hi:
                reach = extent(pattern, line, key[1], other)
                if reach:
                    marks.append(reach)
            else:
                keep.append((key, other))
        waiting = keep

        # Marked in the raw slice and outside the run, never inside it: a mark
        # between two base64 characters splits the run in half and the pieces
        # are described as two shorter values. Right to left, so placing one
        # does not move the next one's bounds, and an overlapping mark is
        # dropped rather than nested: two crossing pairs render as neither.
        piece, placed = line[lo:hi], []
        for first, last in sorted(set(marks), reverse=True):
            a, b = max(lo, first) - lo, min(hi, last) - lo
            if b <= a or any(a < y and x < b for x, y in placed):
                continue
            placed.append((a, b))
            piece = piece[:a] + ON + piece[a:b] + OFF + piece[b:]

        window = shape_runs(piece)
        for escape, plain in ESCAPES:
            window = window.replace(escape, plain)
        body = textwrap.fill(
            f"...{' '.join(window.split())}...",
            74,
            initial_indent="      ",
            subsequent_indent="      ",
        )
        body = body.replace(ON, RENDER[0]).replace(OFF, RENDER[1])

        # Not the same paragraph twice: a record carries a tool's output twice,
        # in the message content and under `toolUseResult`, so two objections
        # far apart on one line can quote identical text. What is there is what
        # is being ruled on, not where it is.
        if body in quoted:
            continue
        quoted.add(body)
        print(f"    [{who} {when}  line {number}]\n{body}\n")
        shown += 1


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("usage: passages.py <staged transcript> <patterns> <gitleaks report> <spots>")

    # The raw line is searched, not the decoded record, because that is what
    # grep matched: json.loads turns the two characters \ and n into a real
    # newline. Decoding happens after, for reading only.
    transcript, patterns, report_path, spots_path = sys.argv[1:5]
    lines = read_transcript(transcript).split("\n")
    pattern = re.compile(patterns)

    show(lines, pattern, objections(lines, pattern, transcript, report_path, spots_path))
