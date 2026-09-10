#!/usr/bin/env bash
# What the agent has been doing, and whether that is changing — one screen.
#
# Runs on the host, over the sealed records and nothing else: no transcript is
# read, no jq filter runs, the volume is not touched. Every declared argument
# arrives as an environment variable: the values days and day, and the flags
# all, system and by_session.
#
# The arithmetic and the screen are host/monitor/stats.py. What is here is what
# has to be: the records and the journal brought up to date, and "no records" as
# a state with a command that fixes it rather than a failure.
# see docs/monitor.md#the-stats-screen
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
# shellcheck source=SCRIPTDIR/../lib/deploy-host.sh
. host/lib/deploy-host.sh

STORE="${RUNNER_RECORDS_DIR:?not set — run this through 'just', which derives it from the cache directory}"


# --- the records, from where they are sealed ---
# Every session end seals its record on the machine that runs the agent and
# publishes it to the archive's `cache` branch. When that is another machine the
# store here is never written, so the branch is fetched and read in its place.

if deploying_elsewhere; then
    . host/lib/archive.sh
    need_archive

    git -C "$ARCHIVE" fetch --quiet origin cache 2>/dev/null \
        || echo "note: could not fetch $ARCHIVE — reading origin/cache as last fetched." >&2

    STORE=$(mktemp -d) || exit 1
    trap 'rm -rf "$STORE"' EXIT

    git -C "$ARCHIVE" archive origin/cache records 2>/dev/null \
        | tar -x -C "$STORE" --strip-components=1 \
        || { echo "No records on origin/cache in $ARCHIVE — no session has been sealed yet." >&2; exit 1; }
    export RUNNER_RECORDS_DIR="$STORE"

# Said here rather than left to a traceback: a fresh clone has no records at
# all, and the command that makes them is not the one you just typed.
elif [ ! -d "$STORE" ]; then
    echo "No records yet — $STORE does not exist." >&2
    echo >&2
    echo "Every session end seals its own record. 'just records' seals what is" >&2
    echo "waiting, and 'just collect --push' is what puts a transcript where it" >&2
    echo "can be sealed from." >&2
    exit 1
fi


# --- the agent's journal, as it stands now ---
# stats.py checks its count against the newest heading in the agent's own
# repository, read from a bare clone fetched here. Not the archive's mirror: a
# workflow advances it on GitHub's best-effort schedule, and the check would
# report that lag as a wrong heading.  see docs/monitor.md#the-count-spelled-out

journal="${RUNNER_MONITOR:?not set — run this through 'just', which computes it}/memory"

if [ -n "${AGENT_REPO:-}" ]; then
    if [ ! -d "$journal" ]; then
        git init -q --bare "$journal" \
            && git -C "$journal" remote add origin "$AGENT_REPO" \
            && git -C "$journal" config remote.origin.fetch '+refs/heads/*:refs/remotes/source/*'
    fi

    git -C "$journal" fetch --quiet --prune origin 2>/dev/null \
        || echo "note: could not fetch $AGENT_REPO — its journal is read as last fetched." >&2
fi


opts=()
[ "$all" = yes ] && opts+=(--all)
[ "$system" = yes ] && opts+=(--system)
[ "$by_session" = yes ] && opts+=(--by-session)
[ -n "$day" ] && opts+=(--day "$day")

# A listing is paged on a terminal; a pipe or a file gets every line whole.
if [ -t 1 ] && { [ "$by_session" = yes ] || [ -n "$day" ]; }; then
    python3 host/monitor/stats.py --days "$days" ${opts[@]+"${opts[@]}"} | less -FRX
else
    python3 host/monitor/stats.py --days "$days" ${opts[@]+"${opts[@]}"}
fi
