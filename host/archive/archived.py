#!/usr/bin/env python3
r"""Which staged transcripts the archive already holds the answer for.

Reads `<object id>\t<path>` lines on stdin — `git ls-tree -r` output with
its mode and type stripped — and prints, one per line, the staging path of
every transcript this run would archive exactly as the archive already has
it. `scan.sh` removes those before it reads anything: a transcript
whose result is already on `sessions` is past the gate and past origin, and
reading it again cannot un-archive anything.

Where each staged file belongs is read from the map `archive-layout.py`
writes, so the pruner and the copy cannot disagree about a path.

Two ways a file can be settled, and the second is not a special case:

  * Its bytes are already there. A git object name is the sha1 of
    `blob <length>\0<contents>`, so the archive already records the bytes of
    everything it holds and this keeps no second copy of anything.

  * It was ruled `redact`, and the rewrite is already there. The volume keeps
    the original of a redacted transcript, deliberately, so its bytes can never
    equal the archived copy and the first test can never settle it. A `redact`
    ruling keyed on the sha256 of exactly these bytes, whose archive path is
    present, settles the file instead: the ruling is keyed on the volume's copy
    and that copy never changes again, so the rewrite already archived is the
    rewrite this run would produce — under the same gate, which is what the
    caller's fingerprint guarantees.

A path that is not in the listing, or is there under a different object, or
has no ruling, is simply not printed — an unreadable or absent archive, an
unreadable ledger and a missing ruling all prune nothing, which is the
direction a mistake here has to fall.

Usage:  git ls-tree -r sessions --name-only ... | sed 's/^[0-7]* blob //' \
            | archived.py <staging-dir> <layout-map> [<redact-rulings>]

<layout-map> is `archive-layout.py`'s output: `<staging path>\t<archive
path>` lines. <redact-rulings> is a file of `<staging path>\t<sha256>` lines,
one per `redact` entry in the ledger — the path as the ledger writes it,
which is the transcript's path inside the volume. Path first in both, and
not hash first as the ledger writes it: two transcripts with identical bytes
is not far-fetched here, and a map keyed on the hash keeps one of them and
silently drops the other's ruling.

see docs/archive.md#it-agrees-with-gits-own-object-id
"""

import hashlib
import os
import sys

PREFIX = "transcripts/"


def blob_id(path):
    with open(path, "rb") as handle:
        return hashlib.sha1(b"blob %d\0" % os.path.getsize(path) + handle.read()).hexdigest()


def content_id(path):
    """The sha256 the ledger keys a ruling on — of the volume's copy."""
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def read_pairs(path):
    """`<key>\tvalue` lines, or nothing at all if it cannot be read."""
    pairs = {}
    if not path:
        return pairs
    try:
        with open(path) as handle:
            for line in handle:
                left, tab, right = line.rstrip("\n").partition("\t")
                if tab and left:
                    pairs[left] = right
    except OSError:
        pass
    return pairs


def main(staging, layout, rulings, lines):
    archived = {}
    for line in lines:
        # Partition on the tab ls-tree puts before the path and nothing else:
        # splitting on whitespace would lose a path with a space in it.
        name, tab, path = line.rstrip("\n").partition("\t")
        if tab and path.startswith(PREFIX):
            archived[path[len(PREFIX) :]] = name
    for rel, where in layout.items():
        full = os.path.join(staging, rel)
        if where not in archived or not os.path.exists(full):
            continue
        if archived[where] == blob_id(full):
            print(rel)
        elif rel in rulings and rulings[rel] == content_id(full):
            print(rel)


if __name__ == "__main__":
    if not 3 <= len(sys.argv) <= 4:
        sys.exit(
            "usage: archived.py <staging-dir> <layout-map> [<redact-rulings>]"
            "  (ls-tree lines on stdin)"
        )
    main(
        sys.argv[1],
        read_pairs(sys.argv[2]),
        read_pairs(sys.argv[3] if len(sys.argv) == 4 else None),
        sys.stdin,
    )
