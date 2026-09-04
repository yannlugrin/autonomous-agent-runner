#!/usr/bin/env python3
"""What only this host knows about the agent, as one JSON object.

Runs on the host. Every fact here is one no reader on GitHub can reach:
whether a container is up, what the crontab holds, what the account has spent,
what the collection gate is holding back. The dashboard's other half — sessions,
issues, articles, the archive itself — is already on GitHub and is read there by
the workflow that renders the page. Nothing is gathered twice.

This is the only gatherer: `just status` renders what this prints and does not
go looking on its own, and the publisher sends the same bytes to the archive.
Every fact is asked of the one implementation of its rule — the lock library,
the budget gate, `just schedule --state`, `just deploy --state` — because a
second reader of a rule does not fail when it drifts, it answers wrongly.

Nothing missing is zero. Every section carries its own `error`, and a section
that could not be read says so rather than reporting an empty count: a page that
renders silence as good news is worse than a page that is down, because you
believe it.

see docs/archive.md#the-status-snapshot
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent


def run(cmd, timeout=120, cwd=ROOT):
    """Exit status, stdout and stderr — never an exception, never a raise.

    Every caller here treats failure as a fact to report. A collector that dies
    on the first thing that is not answering produces no JSON at all, which on
    the page is indistinguishable from a host that is switched off — and those
    two want opposite reactions from whoever is reading.
    """
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ds" % timeout
    except OSError as e:
        return 127, "", str(e)


def fields(text):
    """`key: value` lines into a dict — the shape three things here speak."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_-]*):\s?(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def from_lock_library():
    """The session facts, asked of session-lock.sh rather than of docker.

    One bash invocation and not five, because five would sample the world five
    times: a session that ends between the second and the third produces a
    report of a running session with no start time, a state that never existed.
    """
    script = r"""
        set -uo pipefail
        cd "$1" || exit 1
        . host/lib/session-lock.sh
        . host/lib/run-record.sh
        c=$(session_container)
        printf 'container: %s\n' "$(printf '%s' "$c" | tr '\t' ' ')"
        if [ -n "$c" ]; then
            printf 'kind: %s\n' "$(session_kind || echo unknown)"
            printf 'started: %s\n' "$(session_started || echo '')"
        fi
        printf 'idle_minutes: %s\n' "$(session_idle_minutes 2>/dev/null)"
        printf 'ended_at: %s\n' "$(session_ended_at || echo '')"
        printf 'other: %s\n' "$(service_container)"
        # How the last unattended run ended, in the same sample as the rest:
        # asked separately it could report a stop that a session started since
        # has already consumed.
        printf 'last_run: %s\n' "$(run_record_verdict "$([ -n "$c" ] && echo yes || echo no)")"
    """
    code, out, err = run(["bash", "-c", script, "--", ROOT])
    if code != 0 and not out:
        return None, err or "session-lock.sh could not be read"
    return fields(out), None


def budget():
    """The gate's own numbers, read on the host, whose login can always answer.

    The container's credential is a setup-token on a clean installation, and
    a setup-token cannot read usage, so a read made there says "cannot tell"
    for ever. The host holds the operator's own login, the one the guard reads
    with; the same file is run here, --env so stdout is NAME=value lines, and
    --advisory when the guard is off, where unset thresholds default to 5-100
    and the numbers exist whatever the guard says. Both halves are captured
    because the gate deliberately splits them — numbers to stdout, the one
    line it writes when it cannot tell to stderr — and on a page both are
    worth having.
    """
    armed = os.environ.get("ACCOUNT_BUDGET_GUARD", "") == "true"
    cmd = ["python3", str(ROOT / "image" / "claude-usage.py"), "--env"]
    if not armed:
        cmd.append("--advisory")
    code, out, err = run(cmd, timeout=180)
    if not out:
        return {
            "verdict": None,
            "windows": {},
            "error": err or "the gate did not answer — run 'just verify' to see why",
        }

    windows, verdict, unreadable = {}, None, []
    scoped, renewed = [], False
    for line in out.splitlines():
        if line.startswith("ACCOUNT_USAGE_SCOPED="):
            # The model-scoped weekly limits, deliberately not gated —
            # informative, and marked so nobody reads them as a budget. Prose,
            # carried whole; the key repeats, once per limit.  see docs/budget.md
            scoped.append(line[len("ACCOUNT_USAGE_SCOPED=") :])
        elif line == "RENEWED=1":
            # A renewal is not a fault, but a page that never shows one is a
            # page that cannot show the day they stop.
            renewed = True
        elif line.startswith("ACCOUNT_USAGE_"):
            name, _, value = line[len("ACCOUNT_USAGE_") :].partition("=")
            if value.strip() == "unknown":
                unreadable.append(name)
                continue
            w = {}
            for pair in value.split():
                k, _, v = pair.partition("=")
                w[k] = v
            # Numbers as numbers where they are numbers, so the renderer never
            # has to know which is which. `budget=20-60` and the instants stay
            # strings: splitting them here would be this file deciding how they
            # are shown, which is the renderer's business.
            for k in ("used", "allowed", "ratio"):
                try:
                    w[k] = float(w[k])
                except (KeyError, ValueError, TypeError):
                    pass
            windows[name] = w
        elif line.startswith("VERDICT="):
            verdict = line[len("VERDICT=") :]

    error = None
    if verdict is None:
        # The gate prints a verdict on every path it can reach, so its absence
        # means the output was truncated or is not the gate's.
        error = "the gate answered without a verdict — output was: %r" % out[:200]
    elif unreadable:
        error = "no reading for: %s" % ", ".join(unreadable)
    return {
        "guard": "on" if armed else "off",
        "verdict": verdict,
        "windows": windows,
        "scoped": scoped,
        "token_renewed": renewed,
        "error": error,
    }


def transcripts():
    """How many the collection gate is holding back.

    Asked of the collection script, which is the one implementation of that
    rule. It costs a couple of seconds because answering means extracting and
    scanning; it stops before staging anything, so it is safe beside a running
    session.
    """
    code, out, err = run(["host/archive/collect.sh", "--held"], timeout=300)
    n = fields(out).get("waiting-on-review")
    if n is None or not n.isdigit():
        return {
            "waiting_on_review": None,
            "error": (err or out or "no answer").splitlines()[0][:200]
            if (err or out)
            else "the review gate did not answer — run 'just collect' to see why",
        }
    return {"waiting_on_review": int(n), "error": None}


def deploy():
    """What cron runs, and how far behind `main` it is.

    Asked of `just deploy --state`, which is the one place the branch name, the
    tag names and the path of the deployed checkout are decided.
    """
    code, out, err = run(["just", "deploy", "--state"], timeout=60)
    f = fields(out)
    if not f.get("head"):
        return {
            "worktree": None,
            "deployed": None,
            "head": None,
            "ahead": None,
            "image_candidate": None,
            "image_deployed": None,
            "error": (err or out or "no answer")[:200],
        }

    def none(v):
        return None if v in ("", "-") else v

    ahead = none(f.get("ahead"))
    return {
        "worktree": f.get("worktree"),
        "deployed": none(f.get("deployed")),
        "head": none(f.get("head")),
        "ahead": int(ahead) if ahead and ahead.isdigit() else None,
        "image_candidate": none(f.get("image_candidate")),
        "image_deployed": none(f.get("image_deployed")),
        "error": None,
    }


def image():
    """What is baked in, read from the Dockerfile rather than from a build.

    The Dockerfile is what the next build will use, which is the honest answer
    to "what is the agent running": an image built before the last edit is a
    stale image, and that is worth seeing on the page rather than being told the
    digest of something that no longer exists.
    """
    out = {"base_digest": None, "claude_code_version": None, "error": None}
    try:
        with open(ROOT / "image" / "Dockerfile") as f:
            text = f.read()
    except OSError as e:
        out["error"] = str(e)
        return out
    m = re.search(r"^FROM\s+\S+@(sha256:[0-9a-f]{64})", text, re.M)
    out["base_digest"] = m.group(1) if m else None
    m = re.search(r"^ARG\s+CLAUDE_CODE_VERSION=(\S+)", text, re.M)
    out["claude_code_version"] = m.group(1) if m else None
    if out["base_digest"] is None:
        # An unpinned base is a fact about the boundary, not a parse failure.
        out["error"] = "the base image is not pinned to a digest"
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    # The one expensive thing in here, and the only one that leaves the machine:
    # the usage endpoint rate-limits an account that asks too often, so the
    # heartbeat asks without it and the publisher carries the previous reading
    # forward with its own timestamp.
    #   see docs/archive.md#the-heartbeat-does-not-read-the-budget
    ap.add_argument(
        "--no-budget",
        action="store_true",
        help="skip the gate; the caller carries the last reading forward",
    )
    # `opts` and not `args`: the session-stats invocation below already binds
    # `args` to its argument list, and the collision produces no JSON at all —
    # which the publisher reads as "nothing to publish".
    opts = ap.parse_args()

    errors = []

    # Docker first, and everything that needs it reads this. Without it three
    # sections would each spend their own timeout discovering the same silence,
    # and the collector would take minutes to say the one thing that was wrong.
    code, _, err = run(["host/lib/docker-up.sh"], timeout=30)
    docker = code == 0
    if not docker:
        errors.append("docker is not answering: %s" % (err or "no reason given"))

    lock, lock_error = from_lock_library()
    if lock_error:
        errors.append(lock_error)
        lock = {}

    running = bool(lock.get("container"))
    started = lock.get("started") or ""
    now = int(datetime.now(UTC).timestamp())

    session = {"running": running}
    if running:
        session["kind"] = lock.get("kind") or "unknown"
        session["container"] = lock.get("container")
        if started.isdigit():
            session["started_at"] = datetime.fromtimestamp(int(started), UTC).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            session["up_seconds"] = now - int(started)
        else:
            # Running but unreadable: docker answered `ps` and not `inspect`.
            # Say the half that is known rather than nothing.
            session["started_at"] = None
            session["up_seconds"] = None

    # --since, so a session that has not written its first line yet says so
    # rather than reporting the previous session's numbers under the heading
    # of this one.
    stats = {"lines": [], "error": None}
    if docker:
        args = ["host/session/session-stats.py"]
        if running:
            args += ["--since", started if started.isdigit() else "0"]
        code, out, err = run(args, timeout=180)
        if out:
            stats["lines"] = out.splitlines()
        else:
            stats["error"] = err or "session-stats.py said nothing"

    idle = lock.get("idle_minutes")
    last = {
        "ended_at": lock.get("ended_at") or None,
        # 999999 is the library's "no record since this machine last forgot",
        # and it is not a duration. Carried through as null with the flag
        # beside it, so the renderer never prints 16666 hours.
        "idle_minutes": int(idle) if (idle or "").isdigit() and int(idle) < 999999 else None,
        "forgotten": (idle or "").isdigit() and int(idle) >= 999999,
    }

    code, out, err = run(["just", "schedule", "--state"], timeout=60)
    sched = fields(out)
    schedule = {
        "state": sched.get("state") or "unknown",
        "daemon": sched.get("daemon"),
        "cron": sched.get("cron"),
        "cooldown": sched.get("cooldown"),
        "error": None if sched.get("state") else (err or out or "no answer")[:200],
    }
    if schedule["error"]:
        # A missing answer is not "nothing scheduled", for the same reason a
        # missing count is not zero.
        schedule["state"] = "unknown"

    snapshot = {
        "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "docker": docker,
        "session": session,
        "stats": stats,
        "last_session": last,
        "other_container": lock.get("other") or None,
        "schedule": schedule,
        "budget": budget()
        if (docker and not opts.no_budget)
        else {
            "verdict": None,
            "windows": {},
            "scoped": [],
            "token_renewed": False,
            "error": (
                "not read on this pass — the caller carries the last one forward"
                if opts.no_budget
                else "not read — docker is not answering"
            ),
        },
        "transcripts": transcripts()
        if docker
        else {
            "waiting_on_review": None,
            "error": "not read — docker is not answering",
        },
        "image": image(),
        "deploy": deploy(),
        "errors": errors,
    }

    json.dump(snapshot, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")

    # Zero even when sections failed, and deliberately: the failures are the
    # payload. A non-zero exit here would stop the publisher, and the page would
    # keep showing yesterday's snapshot with no sign that anything had gone
    # wrong — the one outcome worse than showing the trouble.
    return 0


if __name__ == "__main__":
    sys.exit(main())
