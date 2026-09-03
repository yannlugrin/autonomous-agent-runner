#!/usr/bin/env bash
# Move the frozen baseline to the last audited commit.
#
# Runs on the host. No arguments. This is the ratchet, and the one thing here
# that loses something: the cumulative sections of every later report run
# against the new baseline, so what the old range held stops being reported.
# Read the reports that cover the range first — they stay where they are, but
# nothing regenerates them.
# see docs/monitor.md#the-two-anchors
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/monitor/clone.sh

old=$(cat "$AUDIT_STATE/baseline.sha" 2>/dev/null)
new=$(cat "$AUDIT_STATE/cursor.sha" 2>/dev/null)

[ -n "$old" ] || { echo "No baseline yet. 'just drift-audit' freezes one on its first run." >&2; exit 1; }
[ -n "$new" ] || { echo "No completed audit yet, so there is nothing to ratchet to." >&2; exit 1; }
[ "$old" != "$new" ] || { echo "Baseline is already at ${new:0:12}."; exit 0; }


# --- the question ---
# Asked, and refused where there is nobody to ask: this is not a step to take
# from a script that has not thought about it.

[ -t 0 ] || { echo "Nothing to answer on — run this from a terminal." >&2; exit 1; }

printf 'Move the baseline %s -> %s? Every later report stops covering the range between. [y/N] ' \
    "${old:0:12}" "${new:0:12}"
read -r reply
case "$reply" in [yY]*) ;; *) echo "Baseline left at ${old:0:12}."; exit 1 ;; esac

echo "$new" > "$AUDIT_STATE/baseline.sha" || exit 1
mkdir -p "$(dirname "$AUDIT_LOG")" || exit 1
printf '%s\tbaseline-moved\t%s\t%s\t0\t0\n' "$(date -Iseconds)" "$old" "$new" >> "$AUDIT_LOG"

echo "Baseline at ${new:0:12}."
