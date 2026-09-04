"""One transcript, read out of the agent's volume from the host.

RUNS ON THE HOST, and imported by the scripts beside it — `session-stats.py`
for what a session cost, `session-recovery.py` for what a stopped one was
doing. It exists as a module because there are two of them and there will not
be a third spelling: the reader names a directory the agent never chose and
compares an mtime against a moment, and a second copy getting either wrong
does not fail — it answers "no sessions yet" and is believed.

The transcript is copied out through a throwaway container rather than read
from a bind mount, so nothing here depends on anything the agent can execute,
and nothing is added to a session to make it work.
see docs/sessions.md#which-transcripts-are-a-sessions
"""

import os
import re
import subprocess
import sys

# Required, not defaulted: a fallback naming some other agent's volume reads
# as "no sessions yet" rather than as a mistake. Checked where they are used
# rather than at import, so that a caller's --selftest, which touches no
# volume, can run without an environment around it.
VOLUME = os.environ.get("AGENT_VOLUME", "")
IMAGE = os.environ.get("RUNNER_EXTRACT_IMAGE", "alpine:3")

# Claude Code files a transcript under the working directory it was started in,
# encoded. `run` and `chat` both pass -w into the agent's repository, so a
# session lands here and nothing else does: a `claude` someone typed inside
# `just shell` files under `-home-agent`, and `just verify`'s probes run with a
# HOME of their own so their transcripts never reach the volume. Those are
# deliberately not sessions, and the archive filters on the same directory for
# the same reason.
# see docs/verify.md#a-probe-does-not-file-in-the-agents-directory
PROJECT = os.environ.get("AGENT_PROJECT_DIR", "")


def required():
    for name, value in (("AGENT_VOLUME", VOLUME), ("AGENT_PROJECT_DIR", PROJECT)):
        if not value:
            sys.exit(f"{name} not set — run this through 'just', which derives it")


class Transcript:
    """What was read, and which file it came out of.

    A pair rather than a bare string because the path is only knowable here.
    A recovery from a run that was killed has no session id to name the file
    with, and a caller working it out for itself would be a second `ls -t`
    that can disagree with the one that actually read.
    """

    def __init__(self, text, path):
        self.text = text
        # The reader sees the volume at /vol; the agent sees it as its own
        # home. Rewritten here rather than by the caller, because this is the
        # file that knows where the mount was put.
        self.path = re.sub(r"^/vol/", "~/", path or "")


class NoTranscript(Exception):
    """Nothing to read, and which nothing it was.

    `reason` is `absent` (no transcript under the project directory at all) or
    `stale` (one exists, and it is older than the moment asked about). The
    caller words it: "no sessions yet" and "this session wrote none" are the
    same fact to a reader of the volume and different news to a person.
    """

    def __init__(self, reason, detail=""):
        super().__init__(detail or reason)
        self.reason = reason


# The newest transcript, or one named outright, plus the sub-agent files that
# belong to it. The glob is one level deep on purpose: sub-agent transcripts
# sit a directory further down and would otherwise be candidates for "newest"
# themselves.
#
# SINCE is what stops a session that wrote no transcript at all from being read
# as the previous session's: a container that died during bootstrap leaves the
# transcript before it as the newest file in the volume. SESSION skips the
# question entirely when the result envelope named which session it was —
# still checked against SINCE, so a named file from an older run is refused the
# same way an unnamed one is.
READER = r"""
if [ -n "$SESSION" ]; then
    f="/vol/.claude/projects/$PROJECT/$SESSION.jsonl"
    [ -f "$f" ] || exit 3
else
    f=$(ls -t "/vol/.claude/projects/$PROJECT"/*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] || exit 3
fi
[ "$(stat -c %Y "$f")" -ge "$SINCE" ] || exit 4
# Which file this was, on stderr so it cannot be mistaken for a record. The
# caller that names a session id already knows; the one recovering from a run
# that was killed outright does not, and the path is the whole of what it can
# offer for anything deeper.
echo "PATH=$f" >&2
cat "$f"
if [ "$SUBAGENTS" = yes ]; then
    for s in "${f%.jsonl}"/subagents/*.jsonl; do
        [ -f "$s" ] && cat "$s"
    done
fi
exit 0
"""


def read(since, session="", subagents=True):
    """A Transcript. Raises NoTranscript, or exits on a broken read.

    A read that fails for any other reason is not a state to interpret: the
    volume is there or the docker daemon is, and neither is a question this
    can answer usefully.
    """
    required()
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
            "-e",
            f"SESSION={session}",
            "-e",
            f"SUBAGENTS={'yes' if subagents else 'no'}",
            IMAGE,
            "sh",
            "-c",
            READER,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 3:
        raise NoTranscript("absent")
    if proc.returncode == 4:
        raise NoTranscript("stale")
    if proc.returncode != 0:
        sys.exit(f"Could not read the transcript: {proc.stderr.strip()}")
    named = re.search(r"^PATH=(.+)$", proc.stderr, re.M)
    return Transcript(proc.stdout, named.group(1) if named else "")
