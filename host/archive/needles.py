#!/usr/bin/env python3
# A raw docstring: it names the two characters a JSON-escaped newline is made
# of, and `\ n` in an ordinary string is a SyntaxWarning on stderr every run.
r"""The strings whose presence in a transcript means a real credential is in it.

Runs on the host, inside `just collect`. Reads the volume stream — the
`=== <section>` blocks `read-volume.sh` extracts from the volume, plus the
`=== exempt` list appended to it — on stdin, and prints one needle per line
on stdout for `grep -F -f -`. `--selftest` prints one `just verify` verdict
line instead and reads nothing.

Imported by `check.py` and `redact.py`, which need the same sections, the
same needles and the same whole values: two spellings of one rule drift, and
the one that drifts is the one nobody is looking at.
see docs/archive.md#one-definition-of-a-credentials-outward-shape

A transcript is JSONL, so a newline inside a value arrives as the two
characters \ and n. An exact whole-value match therefore cannot find a
multi-line secret, ever. Every needle here is newline-free for that reason.

A PEM is reduced to its body: the armour is boilerplate, identical across
every key of its type. Only the second half of that body is windowed, because
every key of a format shares its opening bytes — every OpenSSH private key
begins with the base64 of `openssh-key-v1`, every PKCS#8 Ed25519 key with
`MC4CAQAwBQYDK2Vw`. Windowing the second half is what separates "the key is in
here" from "something key-shaped is".

WINDOW 24 at STRIDE 8, so any run of 31 contiguous characters from that half is
caught. A real leak carries the whole body and is caught many times over; a
fragment under 24 base64 characters is seventeen bytes of key and reconstructs
nothing. A needle at every offset would mean hundreds of them, and this list is
handed to one grep pass over every transcript in the volume.

DOCUMENT_MIN is the floor that keeps this layer free of false positives. A login
file is a document, most of which is not secret: beside its tokens it carries an
oauth scope and a rate-limit tier, and those are words that appear in ordinary
output. A gate that held every transcript mentioning one would be switched off
within a day. A credential in a document is a long unbroken run; a scope name is
a word. A file whose whole content is one secret has no such problem and keeps
the lower floor.

see docs/archive.md#the-verbatim-layer
"""

import base64
import json
import sys

MIN = 12  # a whole-file secret shorter than this is an identifier
DOCUMENT_MIN = 40  # a secret picked out of a document, where words live too
WINDOW = 24
STRIDE = 8
ARMOUR = "-----"


# --- the volume stream ---


def read_sections(text):
    """The `=== <name>` blocks of the volume stream, as {name: [line, ...]}."""
    sections, current = {}, None
    for line in text.split("\n"):
        if line.startswith("=== "):
            current = line[4:]
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    return sections


def read_transcript(path):
    """One transcript as text, whatever bytes are in it.

    `errors="replace"` rather than a decode that can raise: a transcript
    holds command output verbatim, so an undecodable byte is ordinary, and a
    reader that died on one would hold the file back for a reason nobody
    could act on.
    """
    with open(path, errors="replace") as handle:
        return handle.read()


def leaves(node):
    """Every string in a parsed JSON document, at any depth."""
    if isinstance(node, dict):
        for value in node.values():
            yield from leaves(value)
    elif isinstance(node, list):
        for value in node:
            yield from leaves(value)
    elif isinstance(node, str):
        yield node


def exempted(sections):
    """Vault entries ruled not to be credentials.

    Only the verbatim layer honours this. Every shape rule still reads the
    same text, so an entry rotated into something token-shaped is caught
    anyway — an exemption cannot make a real credential invisible, it can
    only stop an identifier being mistaken for one.
    """
    return {line.strip() for line in sections.get("exempt", ()) if line.strip()}


def compared(name, exempt):
    """Whether a section of the volume stream is one to compare against."""
    # `public` is excluded for redact.py rather than for the scan: winnow()
    # below already drops what is publishable from detection, but the redactor
    # replaces from values() and does not — a comparable `public` section would
    # rewrite every public key in every archived transcript into a marker.
    if name in ("vault-cache", "ssh-keys", "exempt", "public"):
        return False
    return not (name.startswith("vault:") and name[len("vault:") :] in exempt)


def publishable(sections):
    """What the volume hands out on purpose, as one blob of text."""
    return "\n".join(sections.get("public", ()))


# --- what a credential looks like from outside ---


def winnow(found, public):
    """Needles that prove nothing, dropped.

    A needle wholly inside a public key is evidence of nothing: it is in
    every place that key was ever printed, and printing it is what it is
    for. Only the windowed halves can land there — a whole key body is
    never a substring of its own public half — so this narrows the ssh
    comparison at its fringe and leaves the layer that finds a real leak
    exactly where it was.

    It must narrow and never blind. Everything it drops must be text the volume
    itself publishes, which is why `public` is read from the .pub files rather
    than reconstructed: an over-wide section here would empty this list and the
    ssh comparison would become nothing at all, silently. `--selftest` below
    proves both halves — the body still found, a bare public key no longer
    objected to.
    see docs/archive.md#public-halves-are-not-secrets
    """
    return [n for n in found if not (public and n in public)]


def needles(raw):
    """Every newline-free string whose presence proves this secret is there."""
    raw = raw.strip()
    if not raw:
        return []

    if ARMOUR in raw:
        body = "".join(line for line in raw.splitlines() if line and ARMOUR not in line)
        half = body[len(body) // 2 :]
        found = [body] + [half[i : i + WINDOW] for i in range(0, len(half) - WINDOW + 1, STRIDE)]
        return [n for n in found if len(n) >= WINDOW]

    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = None
    if parsed is not None:
        return [v for v in leaves(parsed) if len(v) >= DOCUMENT_MIN]

    if "\n" in raw:
        # Unparseable is not the same as absent: fall back to long words, so
        # a malformed login file cannot read as "nothing to compare against".
        return [w for w in raw.split() if len(w) >= DOCUMENT_MIN]
    return [raw] if len(raw) >= MIN else []


def values(raw):
    """The full forms of a credential — what a redaction replaces.

    `needles` answers "is it in here", and it windows a key body so that a
    fragment is still found. Replacing those windows would shred a body into
    a row of markers with the parts between them left in place, so redaction
    works from the whole forms instead: the body entire, and each line of it
    as the file happens to wrap them, since a transcript may carry either.

    Longest first, so the whole is gone before anything goes looking for its
    parts. Everything that is not a PEM is already whole, and reuses the
    needles rather than restating them.
    """
    raw = raw.strip()

    if ARMOUR in raw:
        wrapped = [line for line in raw.splitlines() if line and ARMOUR not in line]
        whole = "".join(wrapped)
        found = {v for v in [whole] + wrapped if len(v) >= MIN}
    else:
        found = set(needles(raw))

    return sorted(found, key=len, reverse=True)


# --- the needles of one volume stream ---


def picked(stream):
    """Every needle the whole stream yields, sorted, ready for `grep -F`.

    Empty needles are filtered out, because an empty pattern line makes grep
    match every line of every file — which would hold the entire archive back
    and read exactly like a catastrophic leak. Nothing at all is returned when
    there is nothing to compare: a pattern file of one empty line is not an
    empty one.
    """
    sections = read_sections(stream)
    exempt = exempted(sections)
    public = publishable(sections)

    found = set()
    for name, lines in sections.items():
        if compared(name, exempt):
            found.update(winnow(needles("\n".join(lines)), public))

    return sorted(n for n in found if n and "\n" not in n)


# --- the selftest ---


def selftest():
    """The public-half winnow, asked in both directions, as a verdict line.

    Printed in `just verify`'s `state|label|detail` protocol and read by
    host/verify/mechanical.sh, so the probe runs the real needler rather than
    a second copy of it.

    An OpenSSH private key file contains its own public key, so a window of the
    body lands inside an `ssh-ed25519 AAAA...` a session prints properly. A
    winnow one step too wide drops all of them and the ssh comparison compares
    nothing, with no symptom whatever — that is the direction this exists for. A
    winnow never reached puts the published key back among the needles, which is
    loud but spends a ruling on every session that prints it.
    see docs/verify.md#the-public-winnow
    """
    # 72 bytes -> 96 base64 characters, no padding and no repeated run, so
    # every window below is distinct and a match means what it says.
    body = base64.b64encode(bytes(range(72))).decode()
    half = body[len(body) // 2 :]
    windows = [half[i : i + WINDOW] for i in range(0, len(half) - WINDOW + 1, STRIDE)]
    published = "ssh-ed25519 " + windows[1] + " agent@probe"

    # The section names the volume really emits, since the keys are discovered
    # rather than listed: a probe spelling `=== ssh` would go on passing after
    # a rename that had stopped the real thing being compared at all.
    stream = (
        "=== ssh-keys\n=== ssh:id_probe\n"
        "-----BEGIN OPENSSH PRIVATE KEY-----\n" + body + "\n"
        "-----END OPENSSH PRIVATE KEY-----\n=== public\n" + published + "\n"
    )
    found = picked(stream)

    said = []
    if body not in found:
        said.append("THE KEY BODY IS NO LONGER A NEEDLE — the ssh comparison is blind")
    if windows[0] not in found:
        said.append("an unpublished window was dropped — the winnow is too wide")
    leaked = [n for n in found if n in published]
    if leaked:
        said.append(
            "%d needle(s) sit inside the published key — the winnow is not being reached"
            % len(leaked)
        )

    if said:
        print("FAIL|public winnow|" + "; ".join(said))
        return 1
    print(
        "ok|public winnow|the body is still found, its published window is not, "
        "and the public key is not itself a needle"
    )
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    found = picked(sys.stdin.read())
    if found:
        print("\n".join(found))
