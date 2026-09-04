#!/usr/bin/env python3
"""What a stopped session was doing, in a few kilobytes, for the next one.

RUNS ON THE HOST, and printed into the opening message `host/session/run.sh`
composes when the run record says the previous run did not end cleanly. The
transcript is read out of the volume through a throwaway container, exactly as
`session-stats.py` reads it and through the same `volume.py`.

    Previous session (stopped: api_error) began 2026-09-04T09:14:02Z, ran 21m.
    Its transcript, in the container: ~/.claude/projects/<project>/<id>.jsonl

    Its last words:
      Committing the journal entry, then I will look at issue 12.

    Files it wrote: JOURNAL.md, tools/recover.py
    Commits it ran: 2
    Tools that failed: Bash ×2 — fatal: could not read Username for 'https://…

Measured against the three largest transcripts in the archive, 1.5 MB each,
this renders between 1.0 and 1.4 KB.

Why a projection and not "read the transcript yourself": the median transcript
in this volume is 608 KB, 457 of 482 are past the 256 KB a bare Read returns,
and `cat` through Bash writes the result to a file with a 2 KB preview that
reads exactly like a successful read. A session told to recover from that
recovers confidently from a fraction of a percent of the record.

Everything here is QUOTED, never followed. The transcript holds web pages,
issue bodies and forum posts beside the agent's own reasoning, in one
undifferentiated record; an instruction sitting in an old tool result must not
arrive looking like a decision the agent made. The framing that says so is in
the message run.sh composes — this file's part is to indent every quoted line
and strip what could end the quoting.
see docs/sessions.md#recovering-a-session-that-was-stopped
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime

import volume

# What the whole projection may cost, and what any one quoted passage may. The
# cap is in BYTES and not in turns: one assistant turn can be longer than every
# other turn together, so a budget counted in turns has no upper bound at all.
DEFAULT_BYTES = 4096
PASSAGE_BYTES = 700

# The tools whose use is a fact about the world rather than about the session:
# what it wrote, and what it ran that changed something.
WROTE = ("Write", "Edit", "NotebookEdit", "MultiEdit")

# The checkout the agent works in, so a file reads as `JOURNAL.md` rather than
# as `/home/<agent>/<agent>/JOURNAL.md` four times over. Absent is fine — the
# path is then quoted whole, which is long and still true.
REPO = os.environ.get("AGENT_REPO_DIR", "").rstrip("/")

# The marker `run.sh` puts in front of its own opening message. What the runner
# said is not news to the runner, and quoting it back costs a third of the
# budget on every unattended recovery. A message without it — the operator's, or
# one from a session started some other way — is worth carrying.
RUNNER_SAYS = os.environ.get("RUNNER_SAYS", "")

# Control characters have no business in a quoted passage: they reach a
# terminal, a transcript renderer and a prompt, and the only reason for one to
# be here is that something upstream put it there.
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def text_of(message):
    """The plain text of a message, whichever shape it arrived in."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return " ".join(
        part.get("text", "")
        for part in content
        if isinstance(part, dict) and part.get("type") == "text"
    )


def blocks_of(message, kind):
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [p for p in content if isinstance(p, dict) and p.get("type") == kind]


def quote(text, cap=PASSAGE_BYTES):
    """One passage, indented, trimmed and stripped of control characters."""
    text = CONTROL.sub("", text).strip()
    if not text:
        return ""
    raw = text.encode("utf-8")
    if len(raw) > cap:
        text = raw[:cap].decode("utf-8", "ignore").rstrip() + " […]"
    return "\n".join("  " + line for line in text.splitlines() if line.strip())


def shorten(path):
    """A file under the agent's checkout, named the way the agent names it."""
    if REPO and path.startswith(REPO + "/"):
        return path[len(REPO) + 1 :]
    return path


def stamp(text):
    try:
        return datetime.fromisoformat(text[:19] + "+00:00")
    except (ValueError, TypeError):
        return None


def elapsed(first, last):
    if not first or not last:
        return ""
    seconds = int((last - first).total_seconds())
    if seconds >= 3600:
        return f", ran {seconds // 3600}h{(seconds % 3600) // 60:02d}m"
    if seconds >= 60:
        return f", ran {seconds // 60}m"
    return f", ran {seconds}s"


def read_records(text):
    """The main chain only. A sub-agent's turns are its own conversation, and
    quoting them beside the session's reads as the session having said them."""
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get("isSidechain") is not True:
            yield record


def gather(records):
    """Everything the projection reports, in one pass over the transcript."""
    found = {
        "told": "",
        "said": [],
        "wrote": [],
        "commits": 0,
        "failed": [],
        "first": None,
        "last": None,
    }
    names = {}

    for record in records:
        when = stamp(record.get("timestamp", ""))
        if when:
            found["first"] = found["first"] or when
            found["last"] = when
        message = record.get("message") or {}
        kind = record.get("type")

        if kind == "user":
            # A tool result arrives as a user record too. What the session was
            # told is the text somebody wrote, not what a tool handed back.
            results = blocks_of(message, "tool_result")
            for block in results:
                if block.get("is_error"):
                    name = names.get(block.get("tool_use_id"), "a tool")
                    detail = block.get("content")
                    if isinstance(detail, list):
                        detail = " ".join(p.get("text", "") for p in detail if isinstance(p, dict))
                    found["failed"].append((name, str(detail or "")))
            if not results:
                said = text_of(message)
                # A slash command's own output arrives as a user turn and is
                # nobody's words; the runner's opening message is the runner's.
                if RUNNER_SAYS and said.startswith(RUNNER_SAYS):
                    continue
                if said.strip() and not said.lstrip().startswith("<local-command"):
                    found["told"] = said

        elif kind == "assistant" and record.get("isApiErrorMessage") is not True:
            said = text_of(message)
            if said.strip():
                found["said"].append(said)
            for block in blocks_of(message, "tool_use"):
                names[block.get("id")] = block.get("name", "a tool")
                inputs = block.get("input") or {}
                if block.get("name") in WROTE:
                    path = inputs.get("file_path") or inputs.get("notebook_path")
                    if path and path not in found["wrote"]:
                        found["wrote"].append(str(path))
                elif block.get("name") == "Bash":
                    command = str(inputs.get("command") or "")
                    if re.search(r"\bgit\s+commit\b", command):
                        found["commits"] += 1

    return found


def render(found, reason, transcript, cap):
    """The projection, assembled most useful first so a trim loses the least."""
    began = found["first"]
    head = "Previous session"
    head += f" (stopped: {reason})" if reason else " (stopped)"
    if began:
        head += f" began {began.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    head += elapsed(found["first"], found["last"]) + "."

    lines = [head]
    if transcript:
        lines.append(f"Its transcript, in the container: {transcript}")

    def listing(label, items, limit=4):
        if not items:
            return
        shown = ", ".join(items[:limit])
        more = f" (and {len(items) - limit} more)" if len(items) > limit else ""
        lines.append(f"{label}: {shown}{more}")

    if found["said"]:
        passage = quote(found["said"][-1])
        if passage:
            lines.append("")
            lines.append("Its last words:")
            lines.append(passage)

    listing("Files it wrote", [shorten(path) for path in found["wrote"]])
    if found["commits"]:
        # A count and not the command lines: `git commit -q -F - <<'MSG'` says
        # nothing a reader wants and a `-m` message runs to hundreds of
        # characters. What was committed is in `git log`, which is an artifact
        # the session can re-verify — which is what it is being told to prefer.
        lines.append(f"Commits it ran: {found['commits']}")

    if found["failed"]:
        # Named with a count, because the same tool failing eleven times and
        # eleven tools failing once are different situations and the list on
        # its own reads the same either way.
        tally = {}
        for name, detail in found["failed"]:
            tally.setdefault(name, [0, detail])
            tally[name][0] += 1
        parts = []
        for name, (count, detail) in list(tally.items())[:3]:
            first_line = CONTROL.sub("", str(detail)).strip().splitlines()
            snippet = first_line[0][:90] if first_line else ""
            parts.append(f"{name} ×{count}" + (f" — {snippet}" if snippet else ""))
        lines.append("Tools that failed: " + "; ".join(parts))

    if found["told"]:
        passage = quote(found["told"], cap=PASSAGE_BYTES // 2)
        if passage:
            lines.append("")
            lines.append("It was last told:")
            lines.append(passage)

    return trim("\n".join(lines), cap)


def trim(text, cap):
    """The whole projection to its ceiling, on a line boundary, saying so."""
    raw = text.encode("utf-8")
    if len(raw) <= cap:
        return text
    kept = raw[:cap].decode("utf-8", "ignore")
    kept = kept[: kept.rfind("\n")] if "\n" in kept else kept
    return kept + "\n[…the rest is in the transcript]"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", type=int, required=True, help="epoch the stopped run started")
    parser.add_argument("--session", default="", help="its session id, when the envelope named one")
    parser.add_argument("--reason", default="", help="the run record's terminal_reason")
    parser.add_argument("--bytes", type=int, default=DEFAULT_BYTES, dest="cap")
    args = parser.parse_args(argv)

    reason = CONTROL.sub("", args.reason)[:40]
    try:
        transcript = volume.read(args.since, session=args.session, subagents=False)
    except volume.NoTranscript:
        # Not a failure to report: a container that died during bootstrap wrote
        # no transcript, and saying so is the whole of what is known.
        print(f"Previous session (stopped: {reason or 'unknown'}) left no transcript.")
        return 0

    print(render(gather(read_records(transcript.text)), reason, transcript.path, args.cap))
    return 0


if __name__ == "__main__":
    sys.exit(main())
