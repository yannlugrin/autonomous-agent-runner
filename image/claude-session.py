#!/usr/bin/env python3
"""Start a Claude Code session on the runner's own system prompt.

    claude-session [--template PATH] [claude arguments...]  render, then exec claude
    claude-session [--template PATH] --render              print the prompt and stop

Claude Code's default system prompt describes an interactive coding assistant
helping a user at a terminal. The agent is neither, and `--system-prompt`
replaces exactly that block: the billing header and the one-line SDK identity
are still sent, and `tools` and `messages` are untouched, which is where
CLAUDE.md actually travels. So the replacement describes the situation a
session is in and points at CLAUDE.md and SELF.md for everything else. It never
says what to do now: that is the opening message's job, and it names its sender.

The template is a boundary in all but name: not enforcement, but the one thing
that speaks to the agent every session through a layer it cannot read in its
own repository, reply to, or send a pull request against. A change to it is
reviewed the way managed-settings.json is.

`--template` is how the drift audit on the host renders the auditor's — a
different session told a subset of the same facts. Only the placeholders the
given template contains are measured.

Placeholders carry values this script measures, never sentences it decides. A
placeholder that resolved to "focus on X today" would be direction arriving
outside the trusted channel, in the one layer nobody reviews. Everything below
is checkable against a command:

  {{NOW}}             date -u, ISO-8601.
  {{CWD}}             the working directory — the checkout under `run` and
                      `chat`, which pass -w; the home under a verify probe.
  {{IS_GIT_REPO}}     git rev-parse, true or false.
  {{PLATFORM}}        uname -s, lowercased, as the default prompt spelt it.
  {{OS_VERSION}}      uname -r.
  {{MODEL_SETTING}}   the `model` key of the settings in force — the managed
                      ones, or what `--settings` names. What was asked for;
                      what answers is decided later by the CLI, so the line
                      says "requested", never "you are", and the served model
                      is read from the transcript afterwards by
                      host/session/session-stats.py.
  {{TRANSCRIPT_RETENTION}}
                      `cleanupPeriodDays`, out of the same settings file.
  {{CLAUDE_VERSION_INTENDED}}
                      {{PREFIX}}_CLAUDE_VERSION, baked into the image from the
                      Dockerfile's ARG at build: what the image was built to
                      install, which is not the same claim as what runs.
  {{CLAUDE_VERSION_RUNNING}}
                      `claude --version`, resolved through PATH — the binary
                      this script then execs, not the pinned path. When the two
                      differ the running line says so; nothing refuses.
  {{RUNNER_COMMIT}}   {{PREFIX}}_RUNNER_COMMIT, and
  {{RUNNER_COMMITTED_AT}}
                      {{PREFIX}}_RUNNER_COMMITTED_AT — the commit of the runner
                      checkout this image was built from, and when it was made.
  {{CONCURRENCY}}     empty unless {{PREFIX}}_OTHER_SESSION_STARTED_AT is set,
                      which `run --force` and `chat --force` do when they start
                      a session beside a running one. Here rather than in the
                      opening message, where in `chat` it would land in front
                      of the sender line — the line rule 1 rests on being first.
  {{GIT_STATUS}}      branch, git user, porcelain status, last five commits;
                      empty outside a repository.
  {{AGENT_NAME}}      AGENT_NAME, and
  {{OPERATOR_NAME}}   OPERATOR_NAME — who the agent is and who the operator is,
                      as `just` exports them on the host.

A placeholder that survives is a refusal to start. From inside the session a
literal `{{NOW}}` is invisible — nothing checks the prompt but the model, and
the model does not know what it should have said — so the script exits before
exec'ing claude, with the name of what it could not fill.

--render prints what a session would be told and starts nothing; it needs no
credential, and `just verify` uses it to prove no placeholder survives.

see docs/sessions.md#what-a-session-is-told
see docs/sessions.md#one-renderer-two-templates
"""

import functools
import getpass
import json
import os
import platform
import subprocess
import sys
import tempfile
from datetime import UTC, datetime

# The image's own, and the one every container session renders. `--template`
# names another.
TEMPLATE = "/usr/local/share/agent/system-prompt-template.md"


def _prefix():
    """The agent's own namespace, e.g. BORGES.

    Built from the account rather than written out: the container's account IS
    the agent, so nothing has to be passed in to say who this is. A dash cannot
    appear in a shell name.
    """
    return getpass.getuser().upper().replace("-", "_")


# What governs a session in the container. `--settings` in the arguments names
# what governs one somewhere else.
SETTINGS = "/etc/claude-code/managed-settings.json"

CONCURRENCY = """\
Another session was running when this one started, at {other} (UTC). It is
a separate container with the same volume mounted, so {shared} is one
directory shared by both, not a copy each. The working tree can change
between two of your own commands, `git status` can be stale as you read
it, `.git/index.lock` can be held by the other session, and both sets of
commits land in one history. This was measured at launch and is not
updated."""


def git(*args):
    try:
        out = subprocess.run(["git", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.rstrip("\n") if out.returncode == 0 else None


@functools.cache
def git_status():
    if git("rev-parse", "--is-inside-work-tree") != "true":
        return False, ""
    branch = git("rev-parse", "--abbrev-ref", "HEAD") or "(unknown)"
    user = git("config", "user.name") or "(unset)"
    porcelain = git("status", "--porcelain") or ""
    status = porcelain if porcelain else "(clean)"
    log = git("log", "--oneline", "-5") or "(none)"
    return True, (
        f"Git branch: {branch}\nGit user: {user}\nStatus:\n{status}\nRecent commits:\n{log}"
    )


def model_setting(settings):
    try:
        with open(settings) as f:
            return json.load(f).get("model") or "none"
    except (OSError, ValueError):
        return "none"


def retention_days(settings):
    """`cleanupPeriodDays`, read back out of the settings file that carries it.

    Read, not passed in: a second copy in the environment would be a second
    thing to keep true, and the day the two parted this line would report a
    retention that is not the one in force, with no symptom. An unreadable or
    absent key says so in words — a blank would read as agreement.
    see docs/sessions.md#retention-is-read-from-the-file-that-decides-it
    """
    try:
        with open(settings) as f:
            days = json.load(f).get("cleanupPeriodDays")
    except (OSError, ValueError):
        return "(unreadable)"
    return str(days) if isinstance(days, int) else "(the settings do not say)"


@functools.cache
def claude_versions():
    """(intended, running): what the image was built to install, and what answers.

    `claude` through PATH, never /usr/local/bin/claude: the subject is the
    binary this script is about to execvp, and PATH puts ~/.npm-global/bin and
    ~/.local/bin, both in the volume, ahead of the pinned one. Asked by absolute
    path this would report the pin back to itself and agree with the ARG
    forever.

    Neither half refuses: a mismatch is reported and never fatal, since
    refusing would stand down the session that could have reported it. An
    unreadable value says so in words.
    see docs/sessions.md#three-lines-that-are-read-not-measured
    """
    intended = os.environ.get(f"{_prefix()}_CLAUDE_VERSION", "").strip()
    try:
        out = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=10)
        # "2.1.238 (Claude Code)" — the first field, and only if it looks like
        # a version: a CLI that started printing something else must not have
        # its first word silently adopted as one.
        first = out.stdout.split()[0] if out.returncode == 0 and out.stdout.split() else ""
        running = first if first[:1].isdigit() else ""
    except (OSError, subprocess.TimeoutExpired):
        running = ""
    if intended and running and intended != running:
        # A comparison of two measured strings, not a judgement about it: what
        # to do next is CLAUDE.md's to say, not this header's.
        running += " — DIFFERS from the intended version above"
    return (intended or "(the image does not say)", running or "(unreadable)")


@functools.cache
def runner_build():
    """(commit, committed_at): the runner checkout this image was built from.

    Read from the image, not measured here: the container holds no checkout of
    the runner and could not read this if it wanted to. An empty value says so
    in words — a blank would read as agreement — and nothing refuses.
    """
    prefix = _prefix()
    commit = os.environ.get(f"{prefix}_RUNNER_COMMIT", "").strip()
    at = os.environ.get(f"{prefix}_RUNNER_COMMITTED_AT", "").strip()
    unknown = "(the image does not say)"
    return commit or unknown, at or unknown


def concurrency():
    other = os.environ.get(f"{_prefix()}_OTHER_SESSION_STARTED_AT", "")
    if not other:
        return ""
    return CONCURRENCY.format(other=other, shared=os.getcwd())


def named(name):
    """A value `just` exports on the host, refused rather than left blank.

    A sentence rendered with a hole in it is as invisible from inside the
    session as an unfilled placeholder, so it stops the same way.
    """
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(
            f"claude-session: {name} is not set and the template asks for it — refusing to start"
        )
    return value


def placeholders(settings):
    """Every placeholder this renderer knows, each as the measurement behind it.

    Callables and not values, so that only what a template asks for is measured:
    the auditor's template on the host has no image to read a version out of and
    no managed settings to name a retention. The measurements answering two
    placeholders each are cached, so both halves still cost one read.
    """
    return {
        "NOW": lambda: datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "CWD": os.getcwd,
        "IS_GIT_REPO": lambda: "true" if git_status()[0] else "false",
        "PLATFORM": lambda: platform.system().lower(),
        "OS_VERSION": platform.release,
        "MODEL_SETTING": lambda: model_setting(settings),
        "TRANSCRIPT_RETENTION": lambda: retention_days(settings),
        "CLAUDE_VERSION_INTENDED": lambda: claude_versions()[0],
        "CLAUDE_VERSION_RUNNING": lambda: claude_versions()[1],
        "RUNNER_COMMIT": lambda: runner_build()[0],
        "RUNNER_COMMITTED_AT": lambda: runner_build()[1],
        "CONCURRENCY": concurrency,
        "GIT_STATUS": lambda: git_status()[1],
        "AGENT_NAME": lambda: named("AGENT_NAME"),
        "OPERATOR_NAME": lambda: named("OPERATOR_NAME"),
    }


def render(template=TEMPLATE, settings=SETTINGS):
    with open(template) as f:
        text = f.read()

    for name, measure in placeholders(settings).items():
        token = "{{" + name + "}}"
        if token in text:
            text = text.replace(token, measure())

    if "{{" in text:
        start = text.index("{{")
        sys.exit(
            f"claude-session: unfilled placeholder in {template}: "
            f"{text[start : start + 40].splitlines()[0]!r} — refusing to start"
        )

    # Two blank lines where an empty CONCURRENCY block left three.
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text


def settings_path(args):
    """The settings file that governs the session these arguments would start.

    Read out of the arguments and not consumed: `--settings` is claude's own
    flag and still has to reach it, and the model and retention lines have to
    name the file actually in force. Nothing in the container passes one, so a
    session there reads the managed settings.
    """
    for i, arg in enumerate(args):
        if arg == "--settings" and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith("--settings="):
            return arg.split("=", 1)[1]
    return SETTINGS


def main():
    args = sys.argv[1:]

    # First, and consumed: everything after it belongs to claude, which has no
    # --template of its own to confuse this with.
    template = TEMPLATE
    if args[:1] == ["--template"]:
        if len(args) < 2:
            sys.exit("claude-session: --template wants a path")
        template, args = args[1], args[2:]

    # --render anywhere among the arguments: the rest may still carry the
    # --settings the model line is read from.
    show = "--render" in args
    args = [a for a in args if a != "--render"]
    text = render(template, settings_path(args))
    if show:
        sys.stdout.write(text)
        return
    fd, path = tempfile.mkstemp(prefix="system-prompt.", suffix=".txt")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.execvp("claude", ["claude", "--system-prompt-file", path, *args])


if __name__ == "__main__":
    main()
