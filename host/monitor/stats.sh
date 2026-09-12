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
# shellcheck source=SCRIPTDIR/../lib/journal.sh
. host/lib/journal.sh

# stats.py checks its count against the newest heading in the agent's own journal.
need_store_and_journal


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
