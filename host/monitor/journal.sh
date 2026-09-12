#!/usr/bin/env bash
# The agent's journal one entry at a time, each with the session that wrote it.
#
# Runs on the host, over this host's clone of the agent's repository and the sealed records. The
# entries and their sessions are host/monitor/journal.py; what is here is the fetch, and the loop
# that gives every entry a `less` of its own so that it ends where the entry ends. The declared
# argument arrives as the environment variable at.
# see docs/monitor.md#the-journal-entry-by-entry
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

# Two independent round trips, side by side. need_store stays in this shell: it exports the
# records' path and sets the trap that removes a fetched copy.
fetch_journal &
journal_fetch=$!
need_store
wait "$journal_fetch"

if ! git -C "$JOURNAL_CLONE" rev-parse --verify --quiet source/main >/dev/null 2>&1; then
    echo "Nothing has been fetched into $JOURNAL_CLONE — AGENT_REPO in .env names the repository." >&2
    exit 1
fi


# --- piped ---
# A pipe or a file gets the text whole and plain: the one entry asked for, or every one.

if [ ! -t 1 ]; then
    exec python3 host/monitor/journal.py --clone "$JOURNAL_CLONE" --at "$at"
fi


# --- on a terminal: one less per entry ---
# journal.py writes one file per entry and prints how many and which to open first. LESS is
# emptied because a -F in it would close every entry shorter than the screen as it opened.
# see docs/monitor.md#one-less-per-entry

entries=$(mktemp -d) || exit 1
# A second trap replaces the first, and store.sh has a fetched copy of the records to remove.
trap 'rm -rf "$entries" ${records_copy:+"$records_copy"}' EXIT

placed=$(python3 host/monitor/journal.py --clone "$JOURNAL_CLONE" --at "$at" --out "$entries") || exit $?
read -r count i <<<"$placed"

while :; do
    LESS='' less -R --lesskey-src=host/monitor/journal.lesskey \
        -P "?e(END) .entry $i of $count · → older  ← newer  q quit" "$entries/$i"
    case $? in
        114) [ "$i" -lt "$count" ] && i=$((i + 1)) ;;
        108) [ "$i" -gt 1 ] && i=$((i - 1)) ;;
        *) break ;;
    esac
done
