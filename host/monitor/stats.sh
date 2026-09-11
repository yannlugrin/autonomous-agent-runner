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
# shellcheck source=SCRIPTDIR/../lib/store.sh
. host/lib/store.sh

need_store


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
