#!/usr/bin/env python3
"""Rewrite the credentials out of one transcript, in place.

Runs on the host, inside `just collect`, for a transcript ruled `redact`.
Reads the volume stream on stdin, takes the staged transcript's path and the
shape patterns as arguments, rewrites that file where it stands, and prints
the number of occurrences replaced.

    redact.py <staged transcript> <patterns>   (volume stream on stdin)

It replaces from the same `values()` the gate compares against, and then what
the shape rules match — which is how a credential the volume no longer holds
still goes: a rotated token, a key from a session that ended. The armour of a
PEM survives both passes on purpose: it is boilerplate, and leaving it makes
the redaction legible to a later reader.

The staged copy is the only thing rewritten. The volume keeps the original,
deliberately, so every later collection recognises the ruling and redacts it
again on its own.  see docs/archive.md#the-third-ending
"""

import re
import sys

from needles import compared, exempted, read_sections, read_transcript, values

# The one fixed section, and the two families that name themselves. A marker
# reading "the ssh private key" over a volume holding three of them says the
# wrong thing about two, and the marker is all a reader of the archive ever
# gets.
CREDENTIALS = ("credentials", "the Claude Code login")
FAMILIES = (("ssh:", "the ssh private key "), ("vault:", "the vault secret "))


# --- what a redaction leaves behind ---


def marker(label):
    """What replaces a credential, saying which one it was."""
    # No quote and no backslash: this lands inside a JSON string in a JSONL
    # record, and either would leave the line unparseable for everything that
    # reads a transcript afterwards.
    #
    # And no date. Redaction is re-applied on every later collection, so a date
    # here would be today's rather than the ruling's, and the file would be
    # rewritten at every UTC midnight saying something untrue. When it happened
    # is in the commit and the ledger line, which travel together.
    # see docs/archive.md#the-marker
    return f"[redacted: {label} — collect.sh]"


def label_for(name):
    """What the marker calls the secret one section of the volume holds."""
    if name == CREDENTIALS[0]:
        return CREDENTIALS[1]

    for prefix, said in FAMILIES:
        if name.startswith(prefix):
            return said + name[len(prefix) :]

    return name


# --- the rewrite ---


def redact(path, patterns, stream):
    """Rewrite `path` in place; return how many occurrences went."""
    text = read_transcript(path)
    sections = read_sections(stream)
    exempt = exempted(sections)

    targets = []
    for name, lines in sections.items():
        if compared(name, exempt):
            label = label_for(name)
            targets.extend((value, label) for value in values("\n".join(lines)))

    # Longest first across every section, so a key body goes before the lines it
    # is made of and nothing is replaced inside a marker already written.
    targets.sort(key=lambda pair: len(pair[0]), reverse=True)

    count = 0
    for value, label in targets:
        if value and value in text:
            count += text.count(value)
            text = text.replace(value, marker(label))

    text, shaped = re.subn(patterns, lambda _: marker("credential-shaped"), text)
    count += shaped

    with open(path, "w") as handle:
        handle.write(text)
    return count


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: redact.py <staged transcript> <patterns>  (volume stream on stdin)")
    print(redact(sys.argv[1], sys.argv[2], sys.stdin.read()))
