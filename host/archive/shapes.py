#!/usr/bin/env python3
"""Long unbroken runs described rather than printed.

Runs on the host, inside `just collect`'s held-back report. As a filter it
reads text on stdin and writes it to stdout with every run of twenty or more
base64 characters replaced by `<N chars: first6…last4>`; imported by
`passages.py`, which needs the same shaping and the run bounds behind it.

The run is described, not erased: how long it is, and a little from each end.
Masking it outright hides exactly the evidence being asked for, because "a body
of gibberish" is a run of twenty-plus base64 characters — the mask and the
criterion are the same shape. Length alone usually settles a key body, and the
ends are where the word `fake` tends to be. It still never prints a whole body.
see docs/archive.md#describing-a-run-instead-of-erasing-it
"""

import re
import sys

# Not starting immediately after a backslash: in a JSONL transcript a newline is
# the two characters \ and n, and `n`, `t` and `r` are all base64 characters — so
# a run introduced by `\n` swallows the escape's letter and is described as one
# character longer than it is.
#   see docs/archive.md#not-starting-immediately-after-a-backslash
#
# `-` and `_` are in the alphabet, because base64URL exists and half the tokens
# written down here are in it; without them a token is three runs and the pieces
# under the floor are printed in clear into a report that is pushed. The cost is
# real: a merely long hyphenated identifier is elided too, so a uuid reads
# `<36 chars: 5fec40…9a78f>`. That is the right way round — a value this prints
# cannot be taken back.  see docs/archive.md#base64url-is-in-the-alphabet
RUNS = re.compile(r"(?<!\\)[A-Za-z0-9+/_-]{20,}")


# --- describing one run ---


def describe_run(run):
    """`<N chars: first6…last4>` — the length, and a little from each end."""
    return f"<{len(run)} chars: {run[:6]}…{run[-4:]}>"


def _describe(match):
    return describe_run(match.group(0))


def shape_runs(text):
    """Every run in `text` replaced by its description."""
    return RUNS.sub(_describe, text)


# --- where a run begins and ends ---


def run_at(text, at):
    """The run covering `at`, as (start, end), or None if none does.

    A window cut around the position of a hit is entirely inside the run when
    the hit is a long base64 one, and the mask then eats the whole passage — a
    report saying "there is a long run of base64 here", to an operator who
    already knew that and needs to know what it was doing there. Knowing where
    the run ends is what lets the window skip over it and quote the words on
    either side instead.
    see docs/archive.md#never-cut-a-run-and-never-quote-from-inside-one
    """
    for match in RUNS.finditer(text):
        if match.start() <= at < match.end():
            return match.start(), match.end()
        if match.start() > at:
            break
    return None


if __name__ == "__main__":
    for line in sys.stdin:
        sys.stdout.write(shape_runs(line))
