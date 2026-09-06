#!/usr/bin/env python3
"""What a session cost, and which model answered it, in one short summary.

RUNS ON THE HOST. The transcript is read out of the volume through a
throwaway container, exactly as host/archive/read-volume.sh reads it, and for the
same reason: nothing here should depend on anything the agent can execute.
Nothing is added to the session to make this work, so it costs the session
nothing and cannot perturb it.

    87 requests (+173 across 8 agents) · 526k output, 316k thinking
    408k end context · 23h47m elapsed, 2h27m generating
    claude-opus-5 answered · opus requested

Three lines, always in that shape — the clauses that have nothing to say
disappear, the rest do not move. The third is the one that changes its
shape: it starts with MODEL MISMATCH or MODEL UNPINNED when it has something
to say, because it is the line an unattended log is grepped for, and the
status page carries it verbatim.

What is counted is not always the obvious thing: requests are deduplicated by
requestId, output already includes thinking, end context is the main chain's
last request and is never cumulated, sub-agent work is cumulated into the
session that asked for it, and cache reads are deliberately absent. Which model
answered is read from the transcript against the `model` key of managed
settings, main chain only.
see docs/sessions.md#what-a-session-cost-and-which-model-answered
"""

import argparse
import json
import os
import sys
from pathlib import Path

# Reading one transcript out of the volume is `volume.py`, beside this file and
# shared with session-recovery.py: two spellings of which directory a session
# files under do not fail, they answer "no sessions yet".
import volume

# The boundary file, relative to this script: `host/` and `image/` are siblings
# under the checkout, and every host script runs from that root anyway.
ROOT = Path(__file__).resolve().parent.parent.parent
SETTINGS = ROOT / "image" / "managed-settings.json"


def stamp(text):
    """Whole seconds, from an ISO timestamp with a Z on the end.

    Truncated to the second deliberately: the archive computes the same elapsed
    time from the same transcript with jq, which parses whole seconds and
    nothing finer, and two implementations disagreeing about one fact is the
    bug. The explicit offset costs nothing and keeps this readable on an older
    interpreter, where the failure would be a stack trace after a finished
    session.
    """
    from datetime import datetime

    return datetime.fromisoformat(text[:19] + "+00:00").timestamp()


def tokens(n):
    if n < 1000:
        return str(n)
    if n < 10_000:
        return f"{n / 1000:.1f}k"
    if n < 1_000_000:
        return f"{n / 1000:.0f}k"
    return f"{n / 1_000_000:.1f}M"


def duration(seconds):
    s = int(round(seconds))
    if s >= 3600:
        return f"{s // 3600}h{(s % 3600) // 60:02d}m"
    if s >= 60:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s}s"


def requested_model():
    """The model the installation asks for, or None when none is set.

    AGENT_MODEL, exported by `just` from .env, is the value the build renders
    into managed settings; the committed file carries only the placeholder.
    The file is read only when the variable is absent, and a placeholder read
    from it counts as none. None is not an error to raise on: the summary
    still has two lines worth printing, and the third is where "no model is
    pinned" gets said.
    """
    value = os.environ.get("AGENT_MODEL", "").strip()
    if value:
        return value
    try:
        with open(SETTINGS) as f:
            value = json.load(f).get("model") or ""
    except (OSError, ValueError):
        return None
    return None if not value or "{{" in value else value


def model_line(served, requested):
    """The third line. Capitals at the front when it disagrees, so the grep
    that finds it is the grep that finds COLLECT_FAILED."""
    answered = ", ".join(sorted(served)) if served else "no model"
    if not requested:
        return (
            f"MODEL UNPINNED — {answered} answered, and managed settings ask for "
            f"none: the credential decided"
        )

    def fits(m):
        return m == requested or requested.lower() in m.lower()

    if served and all(fits(m) for m in served):
        return f"{answered} answered · {requested} requested"
    return f"MODEL MISMATCH — {answered} answered, configuration asks for {requested}"


def read_transcript(since):
    try:
        return volume.read(since).text
    except volume.NoTranscript as why:
        if why.reason == "absent":
            sys.exit(f"No session transcript under {volume.PROJECT} in the volume yet.")
        sys.exit("No transcript newer than this session's start — nothing to summarise.")


def summarise(text):
    # Keyed by requestId so the streaming snapshots collapse to one entry,
    # and last-writer-wins because the last snapshot is the complete one.
    usage = {}
    agents = set()
    models = set()
    generating = 0.0
    turns = False
    first = last = None
    end_context = 0
    end_at = ""

    for line in text.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue

        sidechain = bool(record.get("isSidechain"))
        when = record.get("timestamp")

        # Elapsed is the main chain's own span: a sub-agent runs inside it, so
        # it can only widen the window by the rounding of a timestamp.
        if when and not sidechain:
            if first is None or when < first:
                first = when
            if last is None or when > last:
                last = when

        if record.get("subtype") == "turn_duration":
            turns = True
            generating += record.get("durationMs", 0) / 1000
            continue

        if record.get("type") != "assistant":
            continue

        if sidechain and record.get("agentId"):
            agents.add(record["agentId"])

        used = record.get("message", {}).get("usage") or {}
        if not sidechain and record.get("message", {}).get("model"):
            models.add(record["message"]["model"])
        request = record.get("requestId")
        if request:
            usage[request] = (sidechain, used)

        if not sidechain and when and when >= end_at:
            end_at = when
            end_context = (
                used.get("input_tokens", 0)
                + used.get("cache_creation_input_tokens", 0)
                + used.get("cache_read_input_tokens", 0)
            )

    if not usage:
        sys.exit("The transcript holds no assistant messages — nothing to summarise.")

    main = sum(1 for sidechain, _ in usage.values() if not sidechain)
    sub = len(usage) - main
    output = sum(u.get("output_tokens", 0) for _, u in usage.values())
    thinking = sum(
        (u.get("output_tokens_details") or {}).get("thinking_tokens", 0) for _, u in usage.values()
    )
    elapsed = stamp(last) - stamp(first) if first and last else 0

    across = ""
    if agents:
        across = f" (+{sub} across {len(agents)} agent{'s' if len(agents) > 1 else ''})"
    worked = f", {duration(generating)} generating" if turns else ""

    return (
        f"{main} requests{across} · {tokens(output)} output, {tokens(thinking)} thinking\n"
        f"{tokens(end_context)} end context · {duration(elapsed)} elapsed{worked}\n"
        f"{model_line(models, requested_model())}"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--since",
        type=int,
        default=0,
        metavar="EPOCH",
        help="ignore a transcript older than this — the session's own start",
    )
    args = parser.parse_args()
    print(summarise(read_transcript(args.since)))


if __name__ == "__main__":
    main()
