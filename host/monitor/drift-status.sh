#!/usr/bin/env bash
# What the audit currently stands on — the two anchors, the commit they are
# read against, and the last runs.
#
# Runs on the host. No arguments. It fetches before it reports, for the reason
# `just mirror-status` does: a status read off stale refs is worse than none.
# Nothing else here writes anything.
# see docs/monitor.md#the-two-anchors
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/monitor/clone.sh

sync_clone

head=$(git -C "$AUDIT_CLONE" rev-parse refs/remotes/mirror/source)


# --- one anchor ---
# Its sha, when the commit under it was made, and how far the mirror has moved
# since. Local time: a person reads this.

anchor() {
    local label="$1" file="$2" sha
    sha=$(cat "$file" 2>/dev/null)

    if [ -z "$sha" ]; then
        printf '  %-9s unset — the first run freezes it\n' "$label"
    elif ! git -C "$AUDIT_CLONE" rev-parse --verify -q "$sha^{commit}" >/dev/null; then
        printf '  %-9s %s — NOT IN THIS HISTORY; the mirror was rewritten under it\n' \
            "$label" "${sha:0:12}"
    else
        printf '  %-9s %s  %s  (%s commit(s) behind)\n' "$label" "${sha:0:12}" \
            "$(git -C "$AUDIT_CLONE" log -1 --format=%cd --date=iso-local "$sha")" \
            "$(git -C "$AUDIT_CLONE" rev-list --count "$sha..$head")"
    fi
}


# --- what it stands on ---

echo "== the audit clone =="
printf '  %-9s %s on %s\n' "mirror" "$MIRROR_REF" "$AGENT_ARCHIVE_REPO"
printf '  %-9s %s  %s\n' "head" "${head:0:12}" \
    "$(git -C "$AUDIT_CLONE" log -1 --format=%cd --date=iso-local "$head")"
anchor baseline "$AUDIT_STATE/baseline.sha"
anchor cursor "$AUDIT_STATE/cursor.sha"
echo


# --- what it has produced ---
# The log is the only record of what a run covered: the reports are files a
# person can move, and the baseline says nothing about the runs behind it.

echo "== the last runs =="
if [ -s "$AUDIT_LOG" ]; then
    tail -5 "$AUDIT_LOG" | while IFS=$'\t' read -r when what from to commits obs; do
        printf '  %s  %-14s %s..%s  %s commit(s), %s observation(s)\n' \
            "$when" "$what" "${from:0:12}" "${to:0:12}" "$commits" "$obs"
    done
else
    echo "  none — 'just drift-audit' is what makes one."
fi

reports=$(find "$AUDIT_REPORTS" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
echo
echo "$reports report(s) in $AUDIT_REPORTS"
