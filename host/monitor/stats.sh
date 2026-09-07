#!/usr/bin/env bash
# What the agent has been doing, and whether that is changing — one screen.
#
# Runs on the host, over the sealed records and nothing else: no transcript is
# read, no jq filter runs, the volume is not touched. Every declared argument
# arrives as an environment variable: the value days and the flag all.
#
# The arithmetic and the screen are host/monitor/stats.py. What is here is what
# has to be: the store is a thing that may not exist yet, and "no records" is a
# state with a command that fixes it rather than a failure.
# see docs/monitor.md#the-stats-screen
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

STORE="${RUNNER_RECORDS_DIR:?not set — run this through 'just', which derives it from the cache directory}"

# Said here rather than left to a traceback: a fresh clone has no records at
# all, and the command that makes them is not the one you just typed.
if [ ! -d "$STORE" ]; then
    echo "No records yet — $STORE does not exist." >&2
    echo >&2
    echo "Every session end seals its own record. 'just records' seals what is" >&2
    echo "waiting, and 'just collect --push' is what puts a transcript where it" >&2
    echo "can be sealed from." >&2
    exit 1
fi

opts=()
[ "$all" = yes ] && opts+=(--all)
exec python3 host/monitor/stats.py --days "$days" ${opts[@]+"${opts[@]}"}
