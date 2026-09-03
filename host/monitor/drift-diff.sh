#!/usr/bin/env bash
# The cumulative change the reports are drawn from, with no agent in the way.
#
# Runs on the host. Arguments limit the diff to those paths, as `git diff` takes
# them. It reads the clone as it stands and never fetches: this is the range the
# last audit actually read, and re-fetching would widen it under you.
# see docs/monitor.md#the-two-anchors
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/monitor/clone.sh

baseline=$(cat "$AUDIT_STATE/baseline.sha" 2>/dev/null)
cursor=$(cat "$AUDIT_STATE/cursor.sha" 2>/dev/null)

[ -n "$baseline" ] || { echo "No baseline yet. 'just drift-audit' freezes one on its first run." >&2; exit 1; }
[ -n "$cursor" ] || { echo "No completed audit yet, so the range is empty." >&2; exit 1; }

exec git -C "$AUDIT_CLONE" diff "$baseline..$cursor" -- "$@"
