#!/usr/bin/env python3
"""Whether a held transcript holds a real credential, or only a shape.

Runs on the host, inside `just collect`'s held-back report, once per held
transcript. Reads the volume stream on stdin and prints the operator's table
— one row per credential the volume holds, and the judgement under it — on
stdout.

    check.py <staged transcript> <spots file> <verdict file>

`<spots file>` gets `<line> <column>` for each place a hit landed, for
passages.py to quote; it hands over a position, never a value. `<verdict
file>` gets one tab-separated line, `<kind>\t<what was found>\t<redactable>`,
which the shell turns into the default note on the ruling commands — so what
the ledger records is the evidence rather than a sentence typed from memory
an hour later.

The shape says "this looks like a key" and cannot say whether it is one,
which is the entire question being put to the operator. Asking someone to
rule on that from a passage of base64 is asking them to be a cryptanalyst;
the machine can simply check, so it does — and it names which credential.
see docs/archive.md#one-report-per-held-file
"""

import sys

from needles import (
    exempted,
    needles,
    publishable,
    read_sections,
    read_transcript,
    values,
    winnow,
)

# The one fixed section, beside the two families the volume discovers for
# itself. Emitted on every read of the volume, so a section that did not arrive
# is reported missing rather than empty: an answer that is absent is not an
# answer of no.  see docs/archive.md#a-missing-section-is-not-an-empty-one
CREDENTIALS = ("credentials", "credentials.json")
MISSING = "NOT COMPARED — the volume section never arrived"


# --- reading one transcript against the volume ---


def examine(transcript, sections):
    """The rows, whether to alarm, whether --redact could work, and where.

    `spots` is a list of (line, column) — one per credential found, for the
    passage display.
    """
    exempt = exempted(sections)
    public = publishable(sections)
    rows, spots = [], []
    alarm = redactable = False

    def note_spot(needle):
        at = transcript.find(needle)
        if at < 0:
            return
        line = transcript.count("\n", 0, at) + 1
        column = at - (transcript.rfind("\n", 0, at) + 1) + 1
        spots.append((line, column))

    def missing(label):
        nonlocal alarm
        rows.append((label, MISSING))
        alarm = True

    def look(label, raw):
        # `found` is unwinnowed on purpose: it answers "was there anything to
        # compare against", which stays true of a key whose only fragment here
        # is publishable. Only the hits are narrowed.
        nonlocal alarm, redactable
        found = needles(raw)
        hits = [n for n in winnow(found, public) if n in transcript]

        # Whether --redact could do anything, computed from the same values()
        # the redactor replaces from rather than from the needles. The two
        # differ when only a windowed match is present: there is no whole form
        # to replace, so the rewrite is a no-op and the file is held again. The
        # report must not print a command that cannot work.
        #   see docs/archive.md#offering-redaction-only-when-it-can-work
        if any(v and v in transcript for v in values(raw)):
            redactable = True

        if not found:
            rows.append((label, "nothing in the volume to compare against"))
        elif hits:
            rows.append((label, "*** THE REAL VALUE IS IN THIS TRANSCRIPT ***"))
            note_spot(hits[0])
            alarm = True
        else:
            rows.append((label, "absent"))

    # Every private key the volume's .ssh holds, discovered the way the vault
    # block below is. First, because it is the credential this gate was built
    # around and the operator reads the table from the top.
    ssh_keys = sorted(k[len("ssh:") :] for k in sections if k.startswith("ssh:"))
    if "ssh-keys" not in sections:
        missing("ssh")
    elif not ssh_keys:
        rows.append(("ssh", "no private key in the volume to compare against"))
    for key in ssh_keys:
        look("ssh " + key, "\n".join(sections["ssh:" + key]))

    # The Claude Code login, the one section named here rather than discovered.
    name, label = CREDENTIALS
    if name not in sections:
        missing(label)
    else:
        look(label, "\n".join(sections[name]))

    # Everything the vault has been asked for in this volume, discovered rather
    # than listed — the keys are not known here — one section per cached secret,
    # named `vault:<key>`. Without it the scanner would report "no secret from
    # the volume appears in this file" while holding none of them to compare.
    #
    # The guard covers the same directory for commits. This is the archive's
    # half: a secret that never reaches a commit can still reach a transcript,
    # and the transcript is pushed to origin.  see docs/vault.md
    vault_keys = sorted(k[len("vault:") :] for k in sections if k.startswith("vault:"))
    if "vault-cache" not in sections:
        missing("vault")
    elif not vault_keys:
        rows.append(("vault", "nothing fetched into this volume to compare against"))
    for key in vault_keys:
        if key in exempt:
            # Said rather than left out. A row that quietly vanished would read
            # as a credential nobody thought to check, which is the shape of
            # every failure this report exists to refuse.
            rows.append(
                (
                    f"vault {key}",
                    "not compared — image/config/vault-exempt.txt says it is not a credential",
                )
            )
        else:
            look(f"vault {key}", "\n".join(sections["vault:" + key]))

    return rows, alarm, redactable, spots


# --- what the operator reads ---


def render(rows, alarm):
    """The table, and the sentence under it."""
    # The column widens for the longest name rather than names being cut to
    # fit: a truncated `vault cloudflare-a` names three different secrets, and
    # this report must never be ambiguous about which credential it just found.
    width = max([18] + [len(name) for name, _ in rows])
    for name, said in rows:
        print(f"    {name:<{width}}: {said}")
    print()

    if alarm and any(MISSING in said for _, said in rows):
        print("    -> A CHECK DID NOT RUN. Treat this as unreviewed: an answer that is")
        print("       missing is not an answer of no. Fix the comparison first.")
    elif alarm:
        print("    -> A REAL CREDENTIAL IS IN THIS FILE. Rotate it. Do not clear this")
        print("       transcript: clearing it would archive the credential.")
    else:
        print("    -> Shape only. No secret from the volume appears in this file, so a")
        print("       clearance here vouches for a fixture and not for a leak.")


def verdict(rows, alarm, redactable):
    """The same verdict the table states, in one line a shell can read.

    Written from the same rows the display reads, in the same order of
    precedence: a check that did not run outranks a credential found, which
    outranks shape alone. A second opinion computed elsewhere would drift, and
    it would drift into the record.

    The third field is whether the redactor has anything to name here. The
    shell adds what the shape rules matched, which it knows and this does not.
    """
    can = "redactable" if redactable else "nothing-to-redact"

    if any(MISSING in said for _, said in rows):
        return "not-compared\t\t" + can
    if alarm:
        found = ", ".join(name for name, said in rows if said.startswith("***"))
        return "alarm\t" + found + "\t" + can
    return "shape-only\t\t" + can


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: check.py <staged transcript> <spots file> <verdict file>")

    rows, alarm, redactable, spots = examine(
        read_transcript(sys.argv[1]), read_sections(sys.stdin.read())
    )
    render(rows, alarm)

    with open(sys.argv[2], "w") as handle:
        for line, column in sorted(set(spots)):
            handle.write(f"{line} {column}\n")
    with open(sys.argv[3], "w") as handle:
        handle.write(verdict(rows, alarm, redactable) + "\n")
