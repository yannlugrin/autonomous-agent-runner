#!/usr/bin/env python3
r"""Where each staged transcript belongs in the archive.

Prints `<staging path>\t<archive path>` for every transcript under the
staging directory, the archive path being relative to `transcripts/` on the
`sessions` branch. One definition of the layout, read by three things that
must agree about it: the pruner that decides a file is already archived, the
copy that places it, and — through the first — the count the run reports.

The layout, and why it is not the volume's own:

  transcripts/2026/08-26/<session-id>.jsonl
  transcripts/2026/08-26/<session-id>--agent-<agent-id>.jsonl

The volume files everything by the mangled cwd — one directory of every
transcript there has ever been, named by uuid, in no order. A day is roughly ten
of them and the date is what a person navigates by, so the day is the directory.

A subagent sits beside its session rather than in a folder under it. The volume
nests it at `<session-id>/subagents/agent-<id>.jsonl`, which reads as a
directory among files and cannot be opened as a peer; the compound name says
which session it belongs to without needing the nesting to say it.

The date is the transcript's own, read from the first entry that carries a
timestamp — never the file's mtime, which is the moment this run copied it out
of the volume and is therefore today for every transcript ever written. A
transcript with no timestamp at all goes to `undated/`, because a date invented
here would sort correctly and be wrong.

Usage:  archive-layout.py <staging-dir>

see docs/archive.md#the-layout-on-disk
"""

import json
import os
import sys

SUFFIX = ".jsonl"
SUBAGENTS = "subagents"


def first_timestamp(path):
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                stamp = json.loads(line).get("timestamp")
            except ValueError:
                continue
            if isinstance(stamp, str) and len(stamp) >= 10:
                return stamp[:10]
    return None


def archive_path(staging, rel):
    """<year>/<month-day>/<name>, or undated/<name>."""
    day = first_timestamp(os.path.join(staging, rel))
    where = f"{day[:4]}/{day[5:7]}-{day[8:10]}" if day else "undated"
    parts = rel.split(os.sep)
    # A subagent is `<project>/<session-id>/subagents/agent-<id>.jsonl`, and
    # what identifies it is the pair — the agent id alone says nothing about
    # which session asked for the work.
    if len(parts) >= 3 and parts[-2] == SUBAGENTS:
        name = f"{parts[-3]}--{parts[-1]}"
    else:
        name = parts[-1]
    return f"{where}/{name}"


def main(staging):
    for root, _, names in os.walk(staging):
        for name in sorted(names):
            if not name.endswith(SUFFIX):
                continue
            rel = os.path.relpath(os.path.join(root, name), staging)
            print(f"{rel}\t{archive_path(staging, rel)}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: archive-layout.py <staging-dir>")
    main(sys.argv[1])
