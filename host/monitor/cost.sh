#!/usr/bin/env bash
# What the archived sessions cost, priced from their own transcripts.
#
# Runs on the host, over the archive's `sessions` branch — the whole record,
# where `just status` prices the one session that just ran. Both call
# image/session-cost.py, which is where the price table is: a second copy of it
# drifts the day rates change, and both go on printing numbers that look equally
# right.
#
# The figure is not money that was spent. It is what the same traffic would have
# cost at published per-token API rates; this account is a subscription, not
# billed per token at all. Read it as weight, never as an invoice.
#
# The day is the archive's, which is UTC: a transcript is filed under the UTC
# day of its first timestamp and the pricing tool dates a session the same way,
# so a day directory holds exactly one day of sessions. `just sessions` is where
# the local day lives, and it says so when the two differ.
# see docs/monitor.md#what-the-archive-cost
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/archive.sh
. host/lib/tty.sh

by_day="${by_day:?not set — run this through 'just', which declares the flags}"
days="${days:?not set — run this through 'just', which declares the flags}"


# --- what was asked for ---
# `just` parses the flags and passes their values as arguments too, ahead of the
# session ids; the recipe shifts those two off, so what is left here is ids.
# A window and an id name two different sets, and quietly honouring one of them
# would price something nobody asked for.

if [ "$#" -gt 0 ] && [ "$days" != 0 ]; then
    echo "A session id and --days name two different sets. Drop one." >&2
    exit 2
fi

need_archive
archive_ref

all=$(git -C "$ARCHIVE" ls-tree -r --name-only "$ARCHIVE_REF" -- transcripts | grep '\.jsonl$')
[ -n "$all" ] || { echo "No transcripts under transcripts/ on $ARCHIVE_REF." >&2; exit 1; }


# --- the transcripts to price ---
# By id: wherever it sits in the archive, matched on the start of the id. A
# prefix can land on two sessions and pricing both under one heading reads as
# one expensive session, so an ambiguous prefix stops and names them. The
# sub-agent files beside a session are not a second match: they are that
# session's own cost and travel with it.

paths=()
if [ "$#" -gt 0 ]; then
    scope="session $*"
    for id in "$@"; do
        # Hex and dashes only: the id goes into a regex, and a session id has
        # never been anything else.
        [[ "$id" =~ ^[0-9a-fA-F-]+$ ]] || { echo "'$id' is not a session id." >&2; exit 2; }

        mapfile -t hit < <(printf '%s\n' "$all" | grep -E "/${id}[^/]*\.jsonl$")
        [ ${#hit[@]} -gt 0 ] || { echo "No session starting '$id' on $ARCHIVE_REF." >&2; exit 1; }

        mapfile -t mains < <(printf '%s\n' "${hit[@]}" | grep -v -- '--agent-')
        if [ ${#mains[@]} -gt 1 ]; then
            echo "'$id' matches ${#mains[@]} sessions:" >&2
            printf '%s\n' "${mains[@]}" | sed 's|.*/||; s|\.jsonl$||; s|^|  |' >&2
            exit 2
        fi
        paths+=("${hit[@]}")
    done
else
    # The default window is one day per session line and ten by day, because a
    # day is one row there and a screenful here.
    if [ "$days" = 0 ]; then
        if [ "$by_day" = yes ]; then days=10; else days=1; fi
    fi
    scope="the last $days day(s) the archive holds"

    mapfile -t dirs < <(printf '%s\n' "$all" | sed 's|^transcripts/||; s|/[^/]*$||' | sort -u | tail -n "$days")
    for d in "${dirs[@]}"; do
        mapfile -t -O "${#paths[@]}" paths < <(printf '%s\n' "$all" | grep "^transcripts/$d/")
    done
fi


# --- priced ---
# Staged as files rather than piped, because a sub-agent is priced into the
# session that asked for the work and the archive says which one that is in the
# filename — `<session>--agent-<id>.jsonl`. A stream of concatenated transcripts
# loses exactly that.

stage=$(mktemp -d) || exit 1
trap 'rm -rf "$stage"' EXIT

for p in "${paths[@]}"; do
    git -C "$ARCHIVE" show "$ARCHIVE_REF:$p" > "$stage/$(basename "$p")" || exit 1
done

printf '%s transcript(s) from %s — %s\n\n' "${#paths[@]}" "$ARCHIVE_REF" "$scope"

opts=()
[ "$by_day" = yes ] && opts+=(--by-day)
python3 image/session-cost.py ${opts[@]+"${opts[@]}"} "$stage" | zebra
