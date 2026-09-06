#!/usr/bin/env python3
"""One durable record per archived session — written once, never rewritten.

    session-records.py --pending      how many transcripts have no record yet
    session-records.py --seal         write a record for every session that can
    session-records.py --recheck      re-derive every record and diff, writing nothing
    session-records.py --rewrite ID   replace one record, after its transcript changed
    session-records.py --selftest     prove the arithmetic and stop

Runs on the host, under `just records`, which is what fetches the two joined
sources before calling this and what publishes what it writes. Reading only:
the archive's `sessions` and `status` branches, and this host's own clone of
the agent's repository. It writes nothing outside RUNNER_RECORDS_DIR.

WHAT A RECORD IS. One archived transcript: when it ran, what it was, what it
spent, which commits it made, and which version of the runner it ran under —
assembled once, when every field in it is final.

ONE TRANSCRIPT IS NOT ALWAYS ONE RUN. `just chat --continue` appends to the
transcript it resumes, so a file can hold two runs with hours between them, and
`runs` is the list of them — one per Claude Code version, which is what proves
a seam, since a process cannot change its own binary. Everything joined on time
is joined per run and never over the file's span: attributing over the span
gives a conversation the commits of every unattended session that ran while
nobody was typing, and an occupancy that never happened.

**TWO DENOMINATORS LIVE IN ONE RECORD, AND MIXING THEM IS SILENT.** `runs` is
per run. `messages`, `requests`, `usage`, `tools`, `end_context`, `subagents`,
`day`, `local_day`, `title`, `kind` and `started_by` are per TRANSCRIPT. A
consumer that counts runs and then averages messages is dividing one by the
other and nothing warns it.
Count sessions by runs; take a per-transcript field only against the count of
transcripts. There is no duration field for exactly this reason: `end - start`
on a resumed transcript is 8.6 hours for 3.4 hours of work, and it is the number
a reader reaches for first because it looks like the answer. A duration is the
sum of `to - from` over the runs. It is not a statistics command and must not be
shaped by one: `just sessions`, `just read`, `just tools` and `just cost` each
want a different slice, and assembling many records into a table is the
reader's job, not the store's.

WHY IT EXISTS. Everything about a session is otherwise re-derived from its raw
transcript on every read — six seconds over the whole archive today, growing by
about forty transcripts a day. Two of the facts worth keeping are not in the
transcript at all and have to be joined in from elsewhere: which commits the
session made, and which runner built its container. One of those is joined
against a source the agent is free to rewrite, so a sealed record is the only
lasting witness to it.

SEALING is the whole of "written once". A record is written when every field in
it is final, and the three conditions are exact rather than a wait:

  the transcript is on `origin/sessions`   settled, past the credential gate,
                                           past any redact ruling
  the agent's repository was fetched        every commit that session made is
  LATER than the session's `end`            then present, whether or not the
                                            agent has committed since
  a `status` snapshot exists LATER than     the latest snapshot at or before
  the session's `start`                     that start can no longer change

All three hold the moment a session ends, which is why `run` and `chat` call
this there: `just collect --push` has put the transcript on origin, the
container's exit hook has pushed the memory and this fetches it, and
`publish-status --now` has just written a snapshot. A session with no record is
computed on demand by whoever wants it.

THE PRICES COME FROM image/session-cost.py AND NOWHERE ELSE. This file does not
restate a rate. The rates that produced a figure are stored beside it, because
`PRICES` carries no version marker of any kind: a stored price with nothing
beside it cannot be audited, re-derived, or told apart from one computed under
different rates. With them inline a record is self-contained — the arithmetic
checks from the record alone — and a reader who wants every session on one
ruler re-prices from the components against today's table without re-reading a
transcript.

Whatever shows money says what it is: API list rates for the same traffic, not
money spent, and it does not convert into the subscription's allowance.

see docs/monitor.md#one-record-per-session
"""

import argparse
import bisect
import importlib.util
import json
import os
import subprocess
import sys
import threading
import time
from datetime import UTC, datetime

SUFFIX = ".jsonl"
AGENT_MARK = "--agent-"
TRANSCRIPTS = "transcripts"

# The ref every field is settled against. Deliberately not the local `sessions`
# branch `just sessions` reads: local is what `just collect` has committed and
# may still be redacted or held, and a record sealed against it could need
# rewriting. Sealing waits for the push.
SESSIONS_REF = "refs/remotes/origin/sessions"
# Local first, as host/lib/archive.sh reads `sessions`: `publish-status` writes
# the local branch and then pushes, so the local one is the more current of the
# two and a record must be sealed against the most current answer there is.
STATUS_REFS = ("refs/heads/status", "refs/remotes/origin/status")
STATUS_FILE = "snapshot.json"

# The agent's own repository, as this host fetched it — not the archive's mirror
# of it. A record must be current at the moment it is sealed, and the mirror is
# a copy advanced by a workflow on GitHub's schedule: it was three days behind
# on 2026-09-06 and a third of the archive could not seal. The clone is made and
# fetched by sync_memory in host/monitor/clone.sh, and is never written.
# see docs/monitor.md#the-commits-come-from-the-agents-repository
MEMORY_REFS = "refs/remotes/source/*"

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# --------------------------------------------------------------------------
# The price table, loaded from the image
# --------------------------------------------------------------------------
# Imported by path because the file has a dash in its name and cannot be
# imported by module name. `host/monitor/cost.sh` reaches the same file by
# running it; this one needs its functions, and a second copy of the rates
# drifts the day they change while both go on printing numbers that look
# equally right.


def price_module():
    path = os.path.join(CHECKOUT, "image", "session-cost.py")
    spec = importlib.util.spec_from_file_location("session_cost", path)
    if spec is None or spec.loader is None:
        sys.exit("Could not load the price table at %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COST = price_module()


# --------------------------------------------------------------------------
# git, read-only
# --------------------------------------------------------------------------


def git(repo, *args, check=True):
    done = subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True, errors="replace"
    )
    if check and done.returncode != 0:
        sys.exit("git %s in %s failed:\n%s" % (" ".join(args), repo, done.stderr.strip()))
    return done.stdout


def git_lines(repo, *args, check=True):
    return [line for line in git(repo, *args, check=check).split("\n") if line]


def blobs(repo, ref, path):
    """{path: (blob id, size)} for every transcript under `path` on `ref`."""
    found = {}
    for line in git_lines(repo, "ls-tree", "-r", "-l", ref, "--", path):
        meta, _, name = line.partition("\t")
        _mode, kind, blob, size = meta.split(None, 3)
        if kind == "blob" and name.endswith(SUFFIX):
            found[name] = (blob, int(size))
    return found


def blob_lines(repo, blob):
    """One blob's lines, streamed — these run to hundreds of megabytes."""
    proc = subprocess.Popen(["git", "-C", repo, "cat-file", "blob", blob], stdout=subprocess.PIPE)
    assert proc.stdout is not None
    with proc.stdout as stream:
        for raw in stream:
            yield raw.decode("utf-8", "replace")
    if proc.wait() != 0:
        sys.exit("Could not read blob %s from %s" % (blob, repo))


def batch_blobs(repo, specs):
    """(spec, text) for each spec, through one `cat-file --batch`.

    1455 status snapshots is 1455 process starts otherwise, and the whole
    series is read on every run that has anything to seal.

    The requests go down a thread because they do not fit in a pipe: a thousand
    of them is past the 64KB buffer, and writing them all before reading the
    first answer deadlocks with git, which is blocked writing answers nobody is
    reading. It hangs in silence and looks like a slow archive.
    """
    proc = subprocess.Popen(
        ["git", "-C", repo, "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None

    def ask():
        try:
            proc.stdin.write(("\n".join(specs) + "\n").encode())
            proc.stdin.close()
        except BrokenPipeError:
            pass

    writer = threading.Thread(target=ask, daemon=True)
    writer.start()
    for spec in specs:
        header = proc.stdout.readline().decode().split()
        if len(header) < 3:
            continue  # missing or ambiguous — the snapshot simply is not there
        size = int(header[2])
        body = proc.stdout.read(size)
        proc.stdout.read(1)
        yield spec, body.decode("utf-8", "replace")
    writer.join()
    proc.wait()


# --------------------------------------------------------------------------
# Time
# --------------------------------------------------------------------------
# Epoch integers and nothing else. Two spellings of one instant is the drift
# that comment 5 warns about, and epoch is the spelling the arithmetic needs.


def epoch(stamp):
    """An ISO-8601 transcript timestamp as integer epoch seconds, UTC."""
    if not isinstance(stamp, str) or len(stamp) < 19:
        return None
    try:
        return int(
            datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=UTC).timestamp()
        )
    except ValueError:
        return None


def local_day(when):
    return time.strftime("%Y-%m-%d", time.localtime(when)) if when is not None else None


# --------------------------------------------------------------------------
# One transcript's own numbers
# --------------------------------------------------------------------------
# A session's main chain and each of its sub-agents go through this same pass,
# and what it produces stays on the one that ran it. Blended into the session's,
# delegation disappears and "the session ran 40 Reads" stops meaning anything.


class Chain:
    def __init__(self):
        self.start = None
        self.end = None
        self.messages = 0
        self.requests = {}
        self.end_context = 0
        self.end_at = ""
        self.tools = {}
        self.mcp = {}
        self.denials = {}
        self.agent_calls = {}
        self.title = None
        self.entrypoint = None
        self.turns = False
        self.generating_ms = 0
        self.cwd = None
        self.git_branch = None
        self.versions = []
        self.effort = None
        self.permission_mode = None
        self.agent_type = None
        self.opening = None

    def feed(self, record):
        stamp = record.get("timestamp")
        when = epoch(stamp)
        if when is not None:
            self.start = when if self.start is None else min(self.start, when)
            self.end = when if self.end is None else max(self.end, when)

        # The opening prompt, kept only until it can be classified: `run` and
        # `chat` each write a marker in front of what they seed, and it is the
        # one thing that says a transcript is a session at all.
        if self.opening is None and record.get("type") == "user" and not record.get("isSidechain"):
            body = (record.get("message") or {}).get("content")
            if isinstance(body, list):
                body = " ".join(b.get("text", "") for b in body if isinstance(b, dict))
            if isinstance(body, str) and body.strip():
                self.opening = body

        kind = record.get("type")
        if kind == "ai-title" and record.get("aiTitle"):
            self.title = record["aiTitle"]
        if record.get("entrypoint"):
            self.entrypoint = record["entrypoint"]
        if kind in ("assistant", "user"):
            self.messages += 1

        # Turns exist only where someone took them. An unattended run is
        # headless and has none, and there the elapsed time IS the working time.
        if record.get("subtype") == "turn_duration":
            self.turns = True
            self.generating_ms += record.get("durationMs") or 0

        # ONE FILE IS NOT ALWAYS ONE RUN. `just chat --continue` appends to the
        # transcript it resumes, and a process cannot change its own binary
        # mid-run — so a change of Claude Code version across a transcript is a
        # seam, and the only signal that PROVES one. Kept as consecutive runs
        # rather than grouped by value, so an interleave would show as three
        # entries and not two, and with each run's own window, so a reader can
        # see that the machine was not held for the whole span.
        #   see docs/monitor.md#one-file-is-not-always-one-run
        version = record.get("version")
        if version:
            if not self.versions or self.versions[-1][0] != version:
                self.versions.append([version, None, None])
            run = self.versions[-1]
            if when is not None:
                run[1] = when if run[1] is None else min(run[1], when)
                run[2] = when if run[2] is None else max(run[2], when)

        # The last non-null wins: these describe the state the session ended in,
        # and a session that changed branch mid-run ended on the second one.
        # Not the version above: there, a change is evidence and the last one
        # alone would destroy it.
        for field, name in (
            ("cwd", "cwd"),
            ("gitBranch", "git_branch"),
            ("effort", "effort"),
            ("permissionMode", "permission_mode"),
            ("attributionAgent", "agent_type"),
        ):
            if record.get(field) is not None:
                setattr(self, name, record[field])

        if record.get("toolDenialKind"):
            self.count(self.denials, record["toolDenialKind"])
        server = record.get("attributionMcpServer")
        if server:
            self.count(self.mcp.setdefault(server, {}), record.get("attributionMcpTool") or "?")

        if kind != "assistant":
            return

        # Streaming snapshots: several records carry one requestId with a usage
        # that grows across them, and the last is the complete one.
        request = record.get("requestId")
        if request:
            self.requests[request] = record

        usage = (record.get("message") or {}).get("usage") or {}
        if stamp and stamp >= self.end_at:
            self.end_at = stamp
            self.end_context = (
                (usage.get("input_tokens") or 0)
                + (usage.get("cache_creation_input_tokens") or 0)
                + (usage.get("cache_read_input_tokens") or 0)
            )

        # Every tool_use block, bucketed by the CALL's own UTC day rather than
        # the session's: `just tools` counts a call on the day it happened, and
        # a session running past midnight lands on both sides.
        day = stamp[:10] if isinstance(stamp, str) and len(stamp) >= 10 else None
        for block in (record.get("message") or {}).get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if day:
                self.count(self.tools.setdefault(day, {}), block.get("name") or "?")
            if block.get("name") == "Agent":
                self.count(self.agent_calls, (block.get("input") or {}).get("subagent_type"))

    @staticmethod
    def count(where, key):
        where[key] = where.get(key, 0) + 1

    @property
    def generating(self):
        return self.generating_ms // 1000 if self.turns else None

    def usage_rows(self):
        """One row per (model, speed, geo), priced at the rates stored beside it.

        Keyed by all three and not by model alone: `speed` selects a separate
        table — opus output is 25.00 standard and 50.00 fast — and a US-pinned
        `inference_geo` multiplies every category by 1.1. Both are per-request
        fields, so two requests on one model can price differently. Neither
        multiplier applies anywhere in the archive today, which is exactly why
        keying on model alone would look correct indefinitely and then be
        silently half-price the first time a session runs on fast mode.
        """
        rows = {}
        for record in self.requests.values():
            message = record.get("message") or {}
            usage = message.get("usage") or {}
            model = message.get("model")
            key = (model, usage.get("speed"), usage.get("inference_geo"))
            row = rows.setdefault(
                key,
                {
                    "model": model,
                    "speed": usage.get("speed"),
                    "geo": usage.get("inference_geo"),
                    "requests": 0,
                    "input": 0,
                    "output": 0,
                    "output_reported": 0,
                    "thinking": 0,
                    "cache_write_5m": 0,
                    "cache_write_1h": 0,
                    "cache_read": 0,
                    "searches": 0,
                },
            )
            counts = COST.tokens_of(usage)
            row["requests"] += 1
            row["input"] += counts["input"]
            row["output"] += counts["output"]
            # Two facts that do not reconcile, so both are kept. `output` is
            # what was consumed: a request that fell back carries an
            # `iterations` array whose first attempt was really billed and
            # which the top-level usage omits. `output_reported` is what the
            # top level states, which is the figure `just sessions` and
            # `just read` show. They differ on 2 of 579 sessions in the archive
            # on 2026-09-06, by 1452 and 672 tokens — the only two requests
            # that ever fell back.  see docs/monitor.md#the-two-output-figures
            row["output_reported"] += usage.get("output_tokens", 0) or 0
            row["cache_write_5m"] += counts["write5m"]
            row["cache_write_1h"] += counts["write1h"]
            row["cache_read"] += counts["read"]
            # Thinking is read from the top level and never from the iterations,
            # which do not carry it. It is a SUBSET of output, reported beside
            # it and never added to it.
            row["thinking"] += (usage.get("output_tokens_details") or {}).get(
                "thinking_tokens", 0
            ) or 0
            row["searches"] += (usage.get("server_tool_use") or {}).get(
                "web_search_requests", 0
            ) or 0

        priced = []
        for key in sorted(rows, key=lambda k: tuple(part or "" for part in k)):
            row = rows[key]
            # A model the table refuses keeps its requests and its components
            # and gets no rates and no price. Dropped instead, an unpriced
            # session would look exactly like a cheap one — which is the failure
            # session-cost.py refuses by design.
            try:
                rates = COST.rates(row["model"], row["speed"])
            except COST.Unpriceable:
                row["rates"] = None
                row["usd"] = None
            else:
                row["rates"] = list(rates)
                row["usd"] = round(sum(costs(row).values()), 6)
            priced.append(row)
        return priced


def costs(row):
    """The five priced categories of one usage row, in dollars.

    From the row's own components and the row's own rates, so the arithmetic is
    checkable from the record alone with no table and no tooling. A reader who
    wants every session on one ruler runs this against today's table instead.
    """
    rate = dict(zip(COST.CATEGORIES, [row["rates"][i] for i in (0, 2, 1, 3, 4)], strict=False))
    counted = {
        "input": row["input"],
        "write1h": row["cache_write_1h"],
        "write5m": row["cache_write_5m"],
        "read": row["cache_read"],
        "output": row["output"],
    }
    scale = COST.US_MULTIPLIER if row["geo"] == "us" else 1.0
    return {name: counted[name] / 1e6 * rate[name] * scale for name in COST.CATEGORIES}


def started_by(opening):
    """Who seeded this transcript: the runner, the operator, or nobody.

    `run` and `chat` each write a marker in front of the prompt they seed —
    RUNNER_SAYS and OPERATOR_SAYS, the line rule 1 rests on — and
    host/session/transcript.jq reads the same two to decide whose name to print
    over a message. A transcript with neither was not started by either, and in
    this archive every one of them is a `just verify` probe: 554 runner, 7
    operator, 20 neither on 2026-09-06, of which 19 say `probe-<n>` in their own
    opening line.

    THIS IS WHAT SEPARATES A SESSION FROM A PROBE, and nothing else does. The
    probes carry the same cwd, the same permission mode and the same effort as a
    real session; they are short, and shortness is not a rule. They are in the
    archive at all because `just verify` ran against the agent's own HOME until
    2026-09-04 — after which they land in a home of their own and stop arriving.

    Matched literally, as `chat --continue` matches it: changing OPERATOR_NAME
    stops the operator's marker matching transcripts written before the change.
    see docs/monitor.md#a-probe-is-not-a-session
    """
    if not opening:
        return None
    for marker, who in (
        (os.environ.get("RUNNER_SAYS"), "runner"),
        (os.environ.get("OPERATOR_SAYS"), "operator"),
    ):
        if marker and marker in opening:
            return who
    return None


def chain_of(repo, blob):
    chain = Chain()
    for line in blob_lines(repo, blob):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            chain.feed(record)
    return chain


# --------------------------------------------------------------------------
# What the archive holds
# --------------------------------------------------------------------------


def archive_index(archive):
    """{session id: (main path, [sub-agent paths])} over origin/sessions.

    A sub-agent writes a transcript of its own beside its session, as
    `<session-id>--agent-<agent-id>.jsonl`, and is not a session.
    """
    found = blobs(archive, SESSIONS_REF, TRANSCRIPTS)
    index = {}
    for path in sorted(found):
        name = os.path.basename(path)[: -len(SUFFIX)]
        session, _, _ = name.partition(AGENT_MARK)
        main, subs = index.setdefault(session, [None, []])
        if AGENT_MARK in name:
            subs.append(path)
        else:
            index[session][0] = path
    return {s: (m, subs) for s, (m, subs) in index.items() if m}, found


def record_path(transcript):
    """Where a session's record sits under the records directory: the path its
    transcript does.

    The archive's own layout, taken from the transcript's actual path rather
    than spelled a second time here — `transcripts/2026/09-06/<id>.jsonl`
    becomes `2026/09-06/<id>.json`, and `transcripts/undated/<id>.jsonl`
    becomes `undated/<id>.json`.
    see host/archive/archive-layout.py
    """
    rest = transcript[len(TRANSCRIPTS) + 1 :]
    return rest[: -len(SUFFIX)] + ".json"


# --------------------------------------------------------------------------
# The two joined sources
# --------------------------------------------------------------------------


class Memory:
    """The agent's repository, as this host last fetched it.

    A sealed record is the only lasting witness to these shas: this is a
    repository the agent may rewrite. The archive keeps rewound history under
    `refs/archive/rewound/<timestamp>`, so it is belt and braces rather than the
    only copy — and it is the reason the field is worth sealing rather than
    recomputing forever.

    `fetched_at` is FETCH_HEAD's mtime, which is when this host last actually
    read the source. That is what sealing turns on, and it is exact: a fetch
    that happened after a session ended has every commit that session made,
    whether or not the agent has committed since. The mirror could only ever
    answer the weaker question — has a copy of it moved past that instant.
    """

    def __init__(self, clone):
        self.head = None
        self.fetched_at = None
        self.commits = []
        self.stat = {}
        if not clone or not os.path.isdir(clone):
            return
        stamp = os.path.join(clone, "FETCH_HEAD")
        if os.path.exists(stamp):
            self.fetched_at = int(os.path.getmtime(stamp))
        refs = git_lines(clone, "rev-parse", "--glob=" + MEMORY_REFS, check=False)
        if not refs:
            self.fetched_at = None
            return
        self.head = refs[0]

        # --no-renames so the file count does not depend on git's rename
        # heuristics moving under a record that was sealed years earlier.
        sha = None
        for line in git_lines(
            clone,
            "log",
            "--no-renames",
            "--format=C%H %ct",
            "--numstat",
            "--glob=" + MEMORY_REFS,
        ):
            if line.startswith("C"):
                sha, _, when = line[1:].partition(" ")
                self.commits.append((int(when), sha))
                self.stat[sha] = {"files": set(), "insertions": 0, "deletions": 0}
                continue
            added, removed, path = (line.split("\t", 2) + ["", "", ""])[:3]
            if sha is None:
                continue
            entry = self.stat[sha]
            entry["files"].add(path)
            # A binary file reports `-` for both, and is a changed file with no
            # line count rather than a zero one.
            if added.isdigit():
                entry["insertions"] += int(added)
            if removed.isdigit():
                entry["deletions"] += int(removed)
        self.commits.sort()

    def within(self, start, end):
        """The commits made inside [start, end], and what they changed.

        A plain window test, needing no grace period, no fuzz and no
        nearest-neighbour rule: measured against the real archive and the real
        memory on 2026-09-06, every commit whose session is in the archive falls
        in exactly one window. A session whose window contains another's — a
        conversation left open while unattended runs come and go — lists that
        session's commits too, so a reader that wants a total takes the union of
        the shas rather than the sum of the lists.
        see docs/monitor.md#attributing-a-commit
        """
        shas = [sha for when, sha in self.commits if start <= when <= end]
        files, insertions, deletions = set(), 0, 0
        for sha in shas:
            entry = self.stat[sha]
            files |= entry["files"]
            insertions += entry["insertions"]
            deletions += entry["deletions"]
        return shas, {"files": len(files), "insertions": insertions, "deletions": deletions}


class Deploys:
    """Which runner was live when, from the archive's `status` branch.

    NOT in the transcript and not recoverable from it: the system prompt does
    tell every session which runner commit built its container, and the system
    prompt is not stored.

    `deploy.deployed` and never `deploy.head`: head is main's last commit and
    moves whether or not anything was deployed, while deployed is the branch
    `just deploy` resets and builds the image from. Of the 1022 snapshots
    carrying the field on 2026-09-06, 358 have the two differing, main running
    ahead of live by up to 16 commits.
    """

    def __init__(self, archive):
        self.head = None
        self.at = []
        self.rows = []
        ref = next(
            (
                r
                for r in STATUS_REFS
                if git_lines(archive, "rev-parse", "--verify", "-q", r, check=False)
            ),
            None,
        )
        if ref is None:
            return
        self.head = git(archive, "rev-parse", ref).strip()
        series = {}
        specs = ["%s:%s" % (sha, STATUS_FILE) for sha in git_lines(archive, "rev-list", ref)]
        for _spec, text in batch_blobs(archive, specs):
            try:
                snapshot = json.loads(text)
            except ValueError:
                continue
            when = epoch(snapshot.get("generated_at"))
            if when is None:
                continue
            deploy = snapshot.get("deploy") or {}
            series[when] = (deploy.get("deployed"), deploy.get("image_deployed"))
        for when in sorted(series):
            self.at.append(when)
            self.rows.append(series[when])

    @property
    def latest(self):
        return self.at[-1] if self.at else None

    def live_at(self, when):
        """The latest snapshot at or before `when`. The container keeps the
        image it started with, so this is asked of a session's start.

        Two limits, recorded rather than smoothed over: the field is absent
        before 2026-08-28 and those sessions get null, because nothing missing
        is zero; and the ten-minute publish floor means a deploy between two
        snapshots is seen up to ten minutes late.
        """
        if when is None or not self.at:
            return None, None
        index = bisect.bisect_right(self.at, when) - 1
        return self.rows[index] if index >= 0 else (None, None)


# --------------------------------------------------------------------------
# The record
# --------------------------------------------------------------------------


def build(archive, session, main, subs, sizes, memory, deploys):
    chain = chain_of(archive, sizes[main][0])
    blob, size = sizes[main]

    # The UTC day directory the archive filed it under, which is the archive's
    # own answer and the day `just cost` groups by; `local_day` is the day the
    # session started against the clock in the room, which is what a person
    # means by "yesterday" and what `just sessions` shows.
    where = main[len(TRANSCRIPTS) + 1 :].rsplit("/", 1)[0]
    day = where.replace("/", "-") if where != "undated" else None

    # The runs, which are what actually held the machine. A version change
    # across a transcript is a seam and the file's own span is not one window:
    # `7c00b68f` on 2026-08-26 is 8h34m of file and two runs of 2h38m and 46m,
    # with fifteen unattended sessions in the five hours between them. The outer
    # edges are the file's, because the first record of a transcript carries a
    # timestamp and no version; the seams are interior and stay open.
    #   see docs/monitor.md#one-file-is-not-always-one-run
    runs = [dict(zip(("version", "from", "to"), r, strict=False)) for r in chain.versions]
    if runs and chain.start is not None:
        runs[0]["from"] = min(runs[0]["from"], chain.start)
        runs[-1]["to"] = max(runs[-1]["to"], chain.end)

    record = {
        "id": session,
        "path": main,
        "blob": blob,
        "day": day,
        "local_day": local_day(chain.start),
        "start": chain.start,
        "end": chain.end,
        "generating": chain.generating,
        "kind": "auto" if chain.entrypoint == "sdk-cli" else "chat",
        "started_by": started_by(chain.opening),
        "title": chain.title,
        "messages": chain.messages,
        "requests": len(chain.requests),
        "cwd": chain.cwd,
        "git_branch": chain.git_branch,
        "runs": runs,
        "effort": chain.effort,
        "permission_mode": chain.permission_mode,
        "bytes": size,
        "end_context": chain.end_context,
        "usage": chain.usage_rows(),
        "tools": {day: dict(sorted(names.items())) for day, names in sorted(chain.tools.items())},
        "mcp": {name: dict(sorted(tools.items())) for name, tools in sorted(chain.mcp.items())},
        "denials": dict(sorted(chain.denials.items())),
        "agent_calls": [
            {"type": kind, "count": count}
            for kind, count in sorted(
                chain.agent_calls.items(), key=lambda kv: (-kv[1], kv[0] or "")
            )
        ],
        "subagents": [],
    }

    # In the order ls-tree gives them, which is the order `just read` lists them
    # and the order `--subagent K` indexes into.
    for path in subs:
        sub_blob, sub_size = sizes[path]
        sub = chain_of(archive, sub_blob)
        record["subagents"].append(
            {
                "id": os.path.basename(path)[: -len(SUFFIX)].split(AGENT_MARK, 1)[1],
                "type": sub.agent_type,
                "path": path,
                "blob": sub_blob,
                "bytes": sub_size,
                "start": sub.start,
                "end": sub.end,
                "messages": sub.messages,
                "requests": len(sub.requests),
                "end_context": sub.end_context,
                "effort": sub.effort,
                "tools": {d: dict(sorted(names.items())) for d, names in sorted(sub.tools.items())},
                "mcp": {n: dict(sorted(t.items())) for n, t in sorted(sub.mcp.items())},
                "denials": dict(sorted(sub.denials.items())),
                "usage": sub.usage_rows(),
            }
        )

    # Joined per RUN and never over the file's span. The commits a session made
    # are the ones inside the window it was running, and a resumed transcript's
    # span also contains every session that ran while nobody was typing —
    # sixteen commits belonging to fifteen other sessions, in the one case this
    # archive holds. The runner is asked of each run's start for the same
    # reason: two runs of one transcript can have started on two images.
    for run in runs:
        if run["from"] is None:
            run["commits"] = None
            run["commit_stat"] = None
            run["runner_commit"] = None
            run["runner_image"] = None
            continue
        run["commits"], run["commit_stat"] = memory.within(run["from"], run["to"])
        run["runner_commit"], run["runner_image"] = deploys.live_at(run["from"])
    return record


def sealed(record, memory, deploys):
    """What is still holding a record back, or None when nothing is.

    Not "has it been a while" — three exact conditions, each of which can only
    be answered yes. The reason is carried out rather than counted, because a
    store that quietly stopped sealing looks exactly like one with nothing to
    do — a source this host cannot reach holds back every session that ended
    after it was last read, and says nothing about it.
    """
    if record["start"] is None:
        return None
    if memory.fetched_at is None or memory.fetched_at <= record["end"]:
        return "memory"
    if deploys.latest is None or deploys.latest <= record["start"]:
        return "status"
    return None


def write(root, transcript, record):
    path = os.path.join(root, record_path(transcript))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(record, handle, indent=1)
        handle.write("\n")
    return path


# --------------------------------------------------------------------------
# The commands
# --------------------------------------------------------------------------


def without_a_record(archive, root):
    """Which sessions have no record, from the filenames alone.

    No transcript is parsed and nothing is fetched: this is what decides
    whether the run touches the network at all.
    """
    index, _sizes = archive_index(archive)
    return [
        session
        for session, (main, _subs) in sorted(index.items())
        if not os.path.exists(os.path.join(root, record_path(main)))
    ]


def orphans(archive, root):
    """Records whose transcript is no longer on the branch.

    A record is written once and never rewritten, so it outlives its subject:
    remove a transcript from `sessions` and the record stands as the only
    remaining account of that session. That is worth keeping and worth SAYING —
    the store and the branch have then parted company, and nothing else reports
    it. `--recheck` walks the archive, so without this it would visit only the
    transcripts that are still there and call the store clean.
    """
    index, _sizes = archive_index(archive)
    kept = {record_path(main) for main, _subs in index.values()}
    found = []
    for base, _dirs, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".json"):
                continue
            rel = os.path.relpath(os.path.join(base, name), root)
            if rel not in kept:
                found.append(rel)
    return found


def seal(archive, clone, root, state_path, only=None, dry_run=False):
    index, sizes = archive_index(archive)
    memory = Memory(clone)
    deploys = Deploys(archive)

    wanted = sorted(index) if only is None else [only]
    written, waiting, differs, same = [], [], [], 0

    for session in wanted:
        main, subs = index[session]
        target = os.path.join(root, record_path(main))
        stored_here = os.path.exists(target)
        if only is None and not dry_run and stored_here:
            continue
        if dry_run and not stored_here:
            waiting.append((session, "no record"))  # nothing to compare against
            continue
        record = build(archive, session, main, subs, sizes, memory, deploys)
        holding = sealed(record, memory, deploys)
        if holding and dry_run:
            # A record is stored and its own source no longer reaches past it,
            # which means that source moved backwards — a clone remade, or the
            # status branch rewound. Said, not counted as waiting: there is a
            # record here.
            differs.append((session, "sealed, but the %s no longer reaches it" % holding))
            continue
        if holding:
            waiting.append((session, holding))
            continue
        if dry_run:
            try:
                with open(target) as handle:
                    stored = json.load(handle)
            except (OSError, ValueError) as broken:
                differs.append((session, "unreadable: %s" % broken))
                continue
            if stored == record:
                same += 1
            else:
                differs.append((session, fields_that_differ(stored, record)))
            continue
        written.append(write(root, main, record))

    if not dry_run:
        save_state(state_path, archive, memory, deploys, root)
    return written, waiting, differs, same, (memory, deploys)


def why_waiting(waiting, memory, deploys):
    """One line naming what the sessions without a record are waiting for."""
    if not waiting:
        return "nothing waiting"
    counts = {}
    for _session, holding in waiting:
        counts[holding] = counts.get(holding, 0) + 1
    said = []
    for holding, n in sorted(counts.items()):
        latest = {"memory": memory.fetched_at, "status": deploys.latest}.get(holding)
        when = time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(latest)) if latest else "nothing there"
        said.append("%d waiting on the %s (last read %s)" % (n, holding, when))
    return ", ".join(said)


def fields_that_differ(stored, fresh):
    names = sorted(set(stored) | set(fresh))
    return ", ".join(n for n in names if stored.get(n) != fresh.get(n)) or "(equal but reordered)"


def save_state(path, archive, memory, deploys, root):
    """What the sealing was done against, so a record can be audited against its
    sources later and staleness is visible rather than silent.

    It stays on this host and is not published: the `cache` branch is written
    once per file and never rewritten, and this is the one file that changes on
    every run.
    """
    kept = sum(len(files) for _root, _dirs, files in os.walk(root))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(
            {
                "sealed_at": int(time.time()),
                "sessions": git(archive, "rev-parse", SESSIONS_REF).strip(),
                "status": deploys.head,
                "status_latest": deploys.latest,
                "memory": memory.head,
                "memory_fetched_at": memory.fetched_at,
                "records": kept,
            },
            handle,
            indent=1,
        )
        handle.write("\n")


# --------------------------------------------------------------------------
# --selftest: the parts that are wrong in ways nothing downstream would show
# --------------------------------------------------------------------------


def selftest():
    failures, ran = [], []

    def check(name, got, want):
        ran.append(name)
        if got != want:
            failures.append("%s: got %r, wanted %r" % (name, got, want))

    check("epoch parses a transcript stamp", epoch("2026-09-06T08:48:00.123Z"), 1788684480)
    check("epoch refuses a short stamp", epoch("2026-09-06"), None)
    check("epoch refuses a non-string", epoch(None), None)

    check(
        "a record sits where its transcript does",
        record_path("transcripts/2026/09-06/abc.jsonl"),
        "2026/09-06/abc.json",
    )
    check(
        "an undated transcript keeps its directory",
        record_path("transcripts/undated/abc.jsonl"),
        "undated/abc.json",
    )

    # The rate tuple is written `input, 5m write, 1h write, read, output` and
    # the categories are ordered `input, write1h, write5m, read, output`. The
    # two middle columns are swapped between them, which is the one mistake
    # here that prints a plausible number.
    row = {
        "model": "claude-opus-5",
        "speed": "standard",
        "geo": "not_available",
        "input": 1_000_000,
        "output": 0,
        "cache_write_5m": 0,
        "cache_write_1h": 0,
        "cache_read": 0,
        "rates": [5.00, 6.25, 10.00, 0.50, 25.00],
    }
    check("input at base", round(sum(costs(row).values()), 6), 5.00)
    row["input"], row["cache_write_5m"] = 0, 1_000_000
    check("5m write at 1.25x base", round(sum(costs(row).values()), 6), 6.25)
    row["cache_write_5m"], row["cache_write_1h"] = 0, 1_000_000
    check("1h write at twice base", round(sum(costs(row).values()), 6), 10.00)
    row["cache_write_1h"], row["cache_read"] = 0, 1_000_000
    check("cache read at a tenth", round(sum(costs(row).values()), 6), 0.50)
    row["cache_read"], row["output"] = 0, 1_000_000
    check("output at output rate", round(sum(costs(row).values()), 6), 25.00)
    row["geo"] = "us"
    check("us geo multiplies", round(sum(costs(row).values()), 6), 27.50)

    # One chain, fed the shapes that have each been read wrong here before.
    chain = Chain()
    chain.feed({"type": "user", "timestamp": "2026-09-05T23:59:00.000Z"})
    chain.feed(
        {
            "type": "assistant",
            "timestamp": "2026-09-05T23:59:30.000Z",
            "requestId": "r1",
            "message": {
                "model": "claude-opus-5",
                "usage": {
                    "input_tokens": 1,
                    "output_tokens": 10,
                    "speed": "standard",
                    "iterations": [
                        {"input_tokens": 1, "output_tokens": 4},
                        {"input_tokens": 1, "output_tokens": 6},
                    ],
                },
                "content": [{"type": "tool_use", "name": "Read"}],
            },
        }
    )
    # The same request, one snapshot later and one day later: last writer wins,
    # and the call lands on its own UTC day and not on the session's.
    chain.feed(
        {
            "type": "assistant",
            "timestamp": "2026-09-06T00:00:30.000Z",
            "requestId": "r1",
            "message": {
                "model": "claude-opus-5",
                # A request that fell back: the top level reports the second
                # attempt alone, and the first was really consumed.
                "usage": {
                    "input_tokens": 1,
                    "output_tokens": 8,
                    "speed": "standard",
                    "iterations": [
                        {"input_tokens": 1, "output_tokens": 4},
                        {"input_tokens": 1, "output_tokens": 8},
                    ],
                },
                "content": [{"type": "tool_use", "name": "Bash"}],
            },
        }
    )
    check("one request, not two snapshots", len(chain.requests), 1)
    rows = chain.usage_rows()
    check("one row per model, speed and geo", len(rows), 1)
    check("both attempts counted", rows[0]["output"], 12)
    check("the top level reports only the second", rows[0]["output_reported"], 8)
    check("the calls land on their own days", sorted(chain.tools), ["2026-09-05", "2026-09-06"])
    check("the day keeps its own call", chain.tools["2026-09-05"], {"Read": 1})
    # Records, not requests: two snapshots of one request are two messages, and
    # that is what session-meta.jq counts today.
    check("messages count records, not requests", chain.messages, 3)

    # One file, two runs: `chat --continue` appends to the transcript it
    # resumes, and the version change across the seam is what proves it. One
    # entry per consecutive run, each with its own window, so the span between
    # them is visibly not time the machine was held.
    resumed = Chain()
    for stamp, version in (
        ("2026-08-26T08:23:56.000Z", "2.1.241"),
        ("2026-08-26T11:02:04.000Z", "2.1.241"),
        ("2026-08-26T16:11:38.000Z", "2.1.246"),
        ("2026-08-26T16:58:11.000Z", "2.1.246"),
    ):
        resumed.feed({"type": "user", "timestamp": stamp, "version": version})
    check("a resume is two runs", [v[0] for v in resumed.versions], ["2.1.241", "2.1.246"])
    check("the first run ends at the seam", resumed.versions[0][2], epoch("2026-08-26T11:02:04Z"))
    check("the second starts after it", resumed.versions[1][1], epoch("2026-08-26T16:11:38Z"))
    # A record carrying no version belongs to neither and breaks no run.
    resumed.feed({"type": "user", "timestamp": "2026-08-26T16:59:00.000Z"})
    check("a versionless record starts nothing", len(resumed.versions), 2)
    check("no turns, no generating time", chain.generating, None)

    chain.feed({"subtype": "turn_duration", "durationMs": 2500})
    chain.feed({"subtype": "turn_duration", "durationMs": 1400})
    check("generating is whole seconds", chain.generating, 3)

    # A model the table refuses keeps its requests and gets no price.
    refused = Chain()
    refused.feed(
        {
            "type": "assistant",
            "timestamp": "2026-09-06T00:00:00.000Z",
            "requestId": "r9",
            "message": {"model": COST.SYNTHETIC, "usage": {"output_tokens": 5}},
        }
    )
    row = refused.usage_rows()[0]
    check("a refused model keeps its requests", row["requests"], 1)
    check("a refused model has no rates", row["rates"], None)
    check("a refused model has no price", row["usd"], None)

    if failures:
        print("session-records --selftest FAILED (%d of %d)" % (len(failures), len(ran)))
        for line in failures:
            print("  " + line)
        return 1
    print("session-records --selftest ok (%d cases)" % len(ran))
    return 0


# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pending", action="store_true", help="how many sessions have no record")
    parser.add_argument(
        "--seal", action="store_true", help="write a record for every session that can"
    )
    parser.add_argument(
        "--recheck", action="store_true", help="re-derive every record and diff it, writing nothing"
    )
    parser.add_argument("--rewrite", metavar="ID", help="replace one session's record")
    parser.add_argument("--selftest", action="store_true", help="prove the arithmetic and stop")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    archive = os.environ.get("AGENT_ARCHIVE") or ""
    clone = os.path.join(os.environ.get("RUNNER_MONITOR") or "", "memory")
    root = os.environ.get("RUNNER_RECORDS_DIR") or ""
    state = os.environ.get("RUNNER_RECORDS_STATE") or ""
    if not archive or not root or not state:
        sys.exit("Run this through 'just records', which computes where everything is.")

    if args.pending:
        print(len(without_a_record(archive, root)))
        return 0

    if args.recheck:
        _w, waiting, differs, same, _sources = seal(archive, clone, root, state, dry_run=True)
        for session, why in differs:
            print("DIFFERS  %s — %s" % (session[:8], why))
        gone = orphans(archive, root)
        for rel in gone:
            print("ORPHAN   %s — its transcript is no longer on %s" % (rel, SESSIONS_REF))
        print(
            "%d record(s) match, %d differ, %d orphaned, %d without a record yet"
            % (same, len(differs), len(gone), len(waiting))
        )
        # Orphans are a STATE and not a fault: a transcript the operator took
        # off the branch leaves a record behind on purpose, and an audit that
        # went permanently red on it is one nobody reads by the third week. A
        # record disagreeing with a transcript that is still there is the fault.
        return 1 if differs else 0

    if args.rewrite:
        index, _sizes = archive_index(archive)
        hits = [s for s in index if s.startswith(args.rewrite)]
        if len(hits) != 1:
            sys.exit("'%s' matches %d sessions on %s." % (args.rewrite, len(hits), SESSIONS_REF))
        written, waiting, _d, _s, _sources = seal(archive, clone, root, state, only=hits[0])
        if waiting:
            sys.exit("%s has not sealed yet — nothing rewritten." % hits[0][:8])
        print("rewrote %s" % written[0])
        return 0

    if args.seal:
        written, waiting, _d, _s, sources = seal(archive, clone, root, state)
        print("%d record(s) written, %d without one yet" % (len(written), len(waiting)))
        if waiting:
            print("  " + why_waiting(waiting, *sources))
        return 0

    # No default: every caller says which of the five it wants, so a typo in
    # `just records` cannot write records while looking like it audited them.
    parser.error("one of --pending, --seal, --recheck, --rewrite ID or --selftest")


if __name__ == "__main__":
    sys.exit(main())
