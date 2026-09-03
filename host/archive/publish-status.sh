#!/usr/bin/env bash
# Put what only this host knows where the dashboard can read it.
#
# Runs on the host. `status-collect.py` gathers, this one carries: the snapshot
# goes to `status`, an orphan branch of the archive, committed in a throwaway
# worktree — the same way `collect.sh` writes `sessions`. Nothing here
# interprets what it is carrying, and `status` has one writer, as the archive's
# README claims of every branch it holds.
#
# Cheap to call: `just run` calls it every time cron wakes it, and all but one
# call in ten returns before doing any work. The stamp is checked ahead of the
# collection, because collecting costs a container start for the budget gate —
# a floor tested after the expensive part is not a floor. --now skips it, and
# that is what a session end uses.
#
# No workflow dispatch here, deliberately: the renderer's schedule is the
# freshness knob and lives in the workflow, and dispatching on every publish
# would outrun a private repository's free Actions allowance.
#   see docs/archive.md#the-status-snapshot

set -uo pipefail

# Computed and exported by the justfile, as in collect.sh.
ARCHIVE="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"
BRANCH=status
FILE=snapshot.json
STAMP="${RUNNER_SNAPSHOT_PUBLISHED_AT:?not set — run this through 'just', which derives it from the agent name}"
FLOOR_MINUTES="${RUNNER_SNAPSHOT_COOLDOWN:-10}"
LOCK="${RUNNER_SNAPSHOT_LOCK:?not set — run this through 'just', which derives it from the agent name}"

# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

now=false
case "${1:-}" in
    --now) now=true ;;
    '') ;;
    *) echo "Usage: publish-status.sh [--now]" >&2; exit 2 ;;
esac

# Loud on a terminal, silent from cron unless something is wrong: a log that is
# all heartbeats is one nobody reads on the day it holds something.
say() { [ -t 1 ] && printf '%s\n' "$*"; return 0; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# The stamp lives in a directory that may not exist yet, and a redirection does
# not create one. A stamp that silently fails to land reads as "never
# published", so the floor stops holding and every run publishes again.
stamp() {
    mkdir -p "$(dirname "$STAMP")" 2>/dev/null || return 0
    date +%s > "$STAMP" 2>/dev/null || true
}

if [ ! -d "$ARCHIVE/.git" ]; then
    die "No archive at $ARCHIVE. Set AGENT_ARCHIVE, or clone it there."
fi

# Never two at once. Cron can fire the next `just run` while this one is still
# collecting, and two publishers would race between reading the branch and
# pushing over it. Non-blocking: the second has nothing to add that the first
# is not already carrying.
exec 8>"$LOCK"
if ! flock -n 8; then
    say "Status page: another publish is running. Nothing to do."
    exit 0
fi

if [ "$now" = false ]; then
    last=$(cat "$STAMP" 2>/dev/null) || last=""
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    since=$(( ( $(date +%s) - last ) / 60 ))
    # A stamp from the future means the clock moved. Publishing once and moving
    # on does not wedge until real time catches up, which is the same reading
    # session-lock.sh takes of its own record.
    if [ "$since" -ge 0 ] && [ "$since" -lt "$FLOOR_MINUTES" ]; then
        say "Status page: published $since minute(s) ago, and it is republished at most every $FLOOR_MINUTES minutes. Nothing to do."
        exit 0
    fi
fi

snapshot=$(mktemp) || die "Could not make a temporary file."
trap 'rm -f "$snapshot"' EXIT

# The collector exits zero even when sections failed, on purpose: the failures
# are its payload. So what is tested here is whether there is JSON at all,
# which is the only failure that leaves nothing to publish.
#
# --no-budget unless this is a session ending. The usage endpoint rate-limits an
# account that asks too often, and a heartbeat asking every ten minutes is the
# traffic worth removing; the reading is taken where it is decided, at a
# session's start and again at its end.
#   see docs/archive.md#the-heartbeat-does-not-read-the-budget
collect=("$RUNNER_CHECKOUT/host/archive/status-collect.py")
[ "$now" = true ] || collect+=(--no-budget)

if ! "${collect[@]}" > "$snapshot" 2>/dev/null; then
    die "status-collect.py failed outright. Nothing published."
fi
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$snapshot" 2>/dev/null \
    || die "status-collect.py produced something that is not JSON. Nothing published."

# The last reading, carried forward with the age of the reading rather than of
# the carry — so a budget shown on the page is honest about when it was taken,
# however many heartbeats have passed it along since.
python3 - "$snapshot" "$(git -C "$ARCHIVE" show "$BRANCH:$FILE" 2>/dev/null \
                       || git -C "$ARCHIVE" show "origin/$BRANCH:$FILE" 2>/dev/null \
                       || echo '{}')" <<'MERGE'
import json, sys
new = json.load(open(sys.argv[1]))
b = new.get("budget") or {}
if str(b.get("error") or "").startswith("not read on this pass"):
    try:
        prev = json.loads(sys.argv[2])
    except ValueError:
        prev = {}
    old = (prev.get("budget") or {})
    if old.get("windows"):
        # as_of survives every carry: the first one stamps it, the rest leave
        # it alone. Re-stamping would make a reading from an hour ago look
        # ten minutes old, which is the lie the timestamp exists to prevent.
        old["as_of"] = old.get("as_of") or prev.get("generated_at")
        new["budget"] = old
json.dump(new, open(sys.argv[1], "w"), indent=2)
MERGE

headline=$(python3 - "$snapshot" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("session") or {}
if s.get("running"):
    # The kind is `auto` or `chat` and the words are chosen here rather than
    # spliced in: "a auto session" is what a %s does with it, and this is a
    # commit subject that stands in the log for good.
    what = {"auto": "an unattended session is running",
            "chat": "a conversation is running"}.get(
                s.get("kind"), "a %s session is running" % (s.get("kind") or "?"))
else:
    m = (d.get("last_session") or {}).get("idle_minutes")
    what = "idle" if m is None else "idle, last session ended %dm ago" % m
budget = d.get("budget") or {}
b = (budget.get("verdict") or "budget unknown").split(":")[0]
if budget.get("guard") == "off":
    # Nothing refuses while the guard is off, so "over budget" would be false:
    # the advisory read is a burn rate against an even pace, 100 being on pace.
    w = budget.get("windows") or {}
    pace = ", ".join(
        "%s at %d%% of an even pace" % (name.lower(), float(win["ratio"]))
        for name, win in w.items()
        if isinstance(win.get("ratio"), (int, float))
    )
    b = "guard off" + ("; " + pace if pace else "")
print("%s; %s" % (what, b))
PY
) || headline="collected"

# `status` is created here on first run: absent locally, or present only on
# origin because this clone has never checked it out, or an orphan branch that
# already exists. The same three cases archive.sh handles, in the same order.
wt="$(mktemp -d)/$BRANCH"   # must not exist yet: `worktree add` creates it
if git -C "$ARCHIVE" show-ref --quiet --verify "refs/heads/$BRANCH"; then
    add=(add --quiet "$wt" "$BRANCH")
elif git -C "$ARCHIVE" show-ref --quiet --verify "refs/remotes/origin/$BRANCH"; then
    add=(add --quiet -b "$BRANCH" "$wt" "origin/$BRANCH")
else
    add=(add --quiet --orphan -b "$BRANCH" "$wt")
fi

# A worktree left behind is not cosmetic: `worktree add` refuses the same
# path next time, and every publish after this one fails.
cleanup() {
    rm -f "$snapshot"
    git -C "$ARCHIVE" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$ARCHIVE" worktree prune 2>/dev/null || true
    rmdir "$(dirname "$wt")" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$ARCHIVE" worktree "${add[@]}" || die \
    "Could not check out '$BRANCH' — see the message above.
If it is checked out elsewhere, remove that worktree."

# Behind origin is normal and not a conflict: this is the only writer, so a
# fetch first makes the push a fast-forward rather than a rejection needing a
# human. Failure here is not fatal — offline is a fine state to publish from,
# the commit is made, and the next run pushes both.
git -C "$wt" fetch --quiet origin "$BRANCH" 2>/dev/null \
    && git -C "$wt" merge --quiet --ff-only "origin/$BRANCH" 2>/dev/null

cp "$snapshot" "$wt/$FILE"
git -C "$wt" add -- "$FILE"

if git -C "$wt" diff --cached --quiet; then
    # Byte-identical to what is already there, which happens when the machine
    # has been idle. The stamp still moves, so the floor is measured from
    # attempts rather than from commits.
    stamp
    say "Status page: unchanged since the last publish. Nothing committed."
    exit 0
fi

# Committed as the operator: this is their repository and their machine, and a
# snapshot of the container is not something the container wrote.
git -C "$wt" commit --quiet -m "status: $headline" || die "The commit failed — see above."

if git -C "$wt" push --quiet origin "$BRANCH" 2>/dev/null; then
    stamp
    say "Status page published: $headline"
else
    # The commit stands and the next publish carries it. Said on stderr so cron
    # mails it, because a status branch that stopped reaching origin is a
    # dashboard that goes quietly stale while the host is perfectly well.
    echo "PUBLISH_FAILED — committed to $BRANCH in $ARCHIVE but the push did not go through." >&2
    exit 1
fi
