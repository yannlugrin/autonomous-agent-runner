#!/usr/bin/env bash
# What the archived sessions cost, priced from their sealed records.
#
# Runs on the host, over every session the records hold, where `just status`
# prices the one session that just ran. Both price through image/session-cost.py,
# which is where the price table is: a second copy of it drifts the day rates
# change, and both go on printing numbers that look equally right.
#
# The figure is not money that was spent. It is what the same traffic would have
# cost at published per-token API rates; this account is a subscription, not
# billed per token at all. Read it as weight, never as an invoice.
#
# The day is the archive's, which is UTC: a transcript is filed under the UTC
# day of its first timestamp and the pricing tool dates a session the same way,
# so a day directory holds exactly one day of sessions. `just stats --by-session`
# is where the local day lives.
# see docs/monitor.md#what-the-archive-cost
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/store.sh
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

need_store

opts=(--days "$days")
[ "$by_day" = yes ] && opts+=(--by-day)
python3 host/monitor/cost.py "${opts[@]}" -- "$@" | zebra
