#!/usr/bin/env bash
# What is in a checkout and not live yet, as one phrase — "2 commit(s) not
# deployed, and 3 uncommitted change(s)" — or nothing at all and exit 1 when
# there is neither, so each caller decides whether that silence deserves a
# sentence.
#
# Runs on the host. Two callers wrap it in sentences of their own: the forwarder
# in host/lib/deployed.sh and `just listen --live`. One spelling, because the
# one that drifts is the one nobody was looking at when it did.
# see docs/release.md#what-not-deployed-is-counted-against
set -uo pipefail

# The checkout to describe, which is not always the caller's own: `listen`
# runs in the deployed checkout and asks about the tree above it.
here="${1:-.}"
DEPLOYED="${RUNNER_DEPLOYED:?not set — run this through 'just', which computes it}"

# Counted against the deployed checkout's HEAD and not against the `deployed`
# branch: the branch is what `just deploy` moves, the checkout is what cron
# actually reads, and where the two differ the checkout is the honest answer.
ahead=$(git -C "$here" rev-list --count \
    "$(git -C "$DEPLOYED" rev-parse HEAD 2>/dev/null)..HEAD" 2>/dev/null || echo "")
dirty=$(git -C "$here" status --porcelain 2>/dev/null | wc -l)

what=""
[ "${ahead:-0}" -gt 0 ] && what="$ahead commit(s) not deployed"
[ "$dirty" -gt 0 ] && what="${what:+$what, and }$dirty uncommitted change(s)"
[ -n "$what" ] || exit 1
printf '%s\n' "$what"
