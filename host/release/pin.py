#!/usr/bin/env python3
"""Pin what the Dockerfile takes from outside: the base image and Claude Code.

A tag is not a pin and neither is "latest": both move underneath you and the
rebuild says nothing. `--image` resolves the base image's tag to the digest it
points at today; `--claude` resolves Claude Code to the version npm publishes
as latest; neither flag does both.

This edits the file that defines the agent's confinement, and the agent wrote
it. Its contract is therefore narrow by rule: exactly one FROM line and exactly
one ARG CLAUDE_CODE_VERSION line, or it refuses; it changes only those lines
and their date stamps, and it never commits. What it prints is for a human to
read before the diff.
See docs/release.md#the-two-pins.
"""

import datetime
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

DOCKERFILE = pathlib.Path(__file__).resolve().parent.parent.parent / "image" / "Dockerfile"
REGISTRY = "https://registry.npmjs.org/@anthropic-ai/claude-code/latest"

DIGEST_STAMP = re.compile(r"^# Digest taken .*\n", re.M)
FROM_LINE = re.compile(r"^FROM\s+(\S+?)(?:@sha256:\S+)?[ \t]*$", re.M)
VERSION_STAMP = re.compile(r"^# Version taken .*\n", re.M)
ARG_LINE = re.compile(r"^ARG CLAUDE_CODE_VERSION=(\S+)[ \t]*$", re.M)


def main(argv: list[str]) -> int:
    flags = set(argv[1:])
    unknown = flags - {"--image", "--claude"}
    if unknown:
        print(
            fail(
                f"unknown argument {' '.join(sorted(unknown))}; takes --image, --claude, or neither for both"
            ),
            file=sys.stderr,
        )
        return 1
    do_image = "--image" in flags or not flags
    do_claude = "--claude" in flags or not flags

    text = DOCKERFILE.read_text()
    today = datetime.date.today().isoformat()
    try:
        if do_image:
            text = pin_image(text, today)
        if do_claude:
            text = pin_claude(text, today)
    except PinError as refused:
        print(refused, file=sys.stderr)
        return 1
    DOCKERFILE.write_text(text)
    return 0


def pin_image(text: str, today: str) -> str:
    froms = re.findall(r"^FROM\s", text, re.M)
    if len(froms) != 1:
        raise fail(f"expected exactly one FROM line, found {len(froms)}")
    match = FROM_LINE.search(text)
    if not match:
        raise fail("the FROM line is not in a shape this can pin")
    ref = match.group(1)
    print(f"Pulling {ref} ...")
    subprocess.run(["docker", "pull", ref], check=True)
    inspected = subprocess.run(
        ["docker", "image", "inspect", ref], capture_output=True, text=True, check=True
    )
    repo_digests = json.loads(inspected.stdout)[0].get("RepoDigests") or []
    if not repo_digests:
        raise fail(f"{ref} has no RepoDigest — built locally rather than pulled")
    digest = repo_digests[0].split("@", 1)[1]
    old = match.group(0)
    new = f"FROM {ref}@{digest}"
    text = text[: match.start()] + new + text[match.end() :]
    text = DIGEST_STAMP.sub("", text)
    stamp = f"# Digest taken {today}. Re-pin with `just pin --image`.\n"
    text = text.replace(new, stamp + new, 1)
    print("Image: unchanged, " if old == new else "Image: ", end="")
    print(f"{ref} at {digest[:19]}…")
    return text


def pin_claude(text: str, today: str) -> str:
    args = ARG_LINE.findall(text)
    if len(args) != 1:
        raise fail(f"expected exactly one ARG CLAUDE_CODE_VERSION line, found {len(args)}")
    current = args[0]
    with urllib.request.urlopen(REGISTRY, timeout=30) as response:
        latest = json.load(response)["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", latest):
        raise fail(f"the registry answered {latest!r}, which is not a version")
    match = ARG_LINE.search(text)
    assert match is not None
    new = f"ARG CLAUDE_CODE_VERSION={latest}"
    text = text[: match.start()] + new + text[match.end() :]
    text = VERSION_STAMP.sub("", text)
    stamp = f"# Version taken {today}. Re-pin with `just pin --claude`.\n"
    text = text.replace(new, stamp + new, 1)
    if current == latest:
        print(f"Claude Code: unchanged, {latest} is what npm publishes as latest")
    else:
        print(f"Claude Code: {current} -> {latest}")
    return text


class PinError(Exception):
    """Refused, with nothing changed."""


def fail(why: str) -> PinError:
    return PinError(f"pin: {why}; nothing was changed.")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
