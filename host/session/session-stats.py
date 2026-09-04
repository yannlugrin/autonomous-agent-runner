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
import subprocess
import sys
from pathlib import Path


# Required, not defaulted: a fallback naming some other agent's volume reads
# as "no sessions yet" rather than as a mistake.
def _required(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit(f"{name} not set — run this through 'just', which derives it")
    return value


VOLUME = _required("AGENT_VOLUME")
IMAGE = os.environ.get("RUNNER_EXTRACT_IMAGE", "alpine:3")

# Claude Code files a transcript under the working directory it was started in,
# encoded. `run` and `chat` both pass -w into the agent's repository, so a
# session lands here and nothing else does: a `claude` someone typed inside
# `just shell` files under `-home-agent`, and `just verify`'s probes run with a
# HOME of their own so their transcripts never reach the volume. Those are
# deliberately not sessions, and the archive filters on the same directory for
# the same reason.
# see docs/verify.md#a-probe-does-not-file-in-the-agents-directory
# see docs/sessions.md#which-transcripts-are-a-sessions
PROJECT = _required("AGENT_PROJECT_DIR")

# The boundary file, relative to this script: `host/` and `image/` are siblings
# under the checkout, and every host script runs from that root anyway.
ROOT = Path(__file__).resolve().parent.parent.parent
SETTINGS = ROOT / "image" / "managed-settings.json"

# The newest transcript, plus the sub-agent files that belong to it. The glob is
# one level deep on purpose: sub-agent transcripts sit a directory further down
# and would otherwise be candidates for "newest" themselves.
#
# --since is what stops a session that wrote no transcript at all from being
# reported with the previous session's numbers: a container that dies during
# bootstrap leaves the transcript before it as the newest file in the volume.
READER = r"""
f=$(ls -t "/vol/.claude/projects/$PROJECT"/*.jsonl 2>/dev/null | head -1)
[ -n "$f" ] || exit 3
[ "$(stat -c %Y "$f")" -ge "$SINCE" ] || exit 4
cat "$f"
for s in "${f%.jsonl}"/subagents/*.jsonl; do
    [ -f "$s" ] && cat "$s"
done
exit 0
"""


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
    proc = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "-v",
            f"{VOLUME}:/vol:ro",
            "-e",
            f"SINCE={since}",
            "-e",
            f"PROJECT={PROJECT}",
            IMAGE,
            "sh",
            "-c",
            READER,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 3:
        sys.exit(f"No session transcript under {PROJECT} in the volume yet.")
    if proc.returncode == 4:
        sys.exit("No transcript newer than this session's start — nothing to summarise.")
    if proc.returncode != 0:
        sys.exit(f"Could not read the transcript: {proc.stderr.strip()}")
    return proc.stdout


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
