# shellcheck shell=bash
# The clone of the agent's own repository its journal is read from, and the fetch that keeps it
# current.
#
# Sourced by `stats`, which checks its count against the newest heading, and by `journal`, which
# shows the entries. Not the archive's mirror: a workflow advances it on GitHub's best-effort
# schedule, and both would show that lag as the journal.  see docs/monitor.md#the-count-spelled-out

JOURNAL_CLONE="${RUNNER_MONITOR:?not set — run this through 'just', which computes it}/memory"


# --- fetch_journal ---
# Makes the bare clone on first use and fetches it on every one. A failed fetch leaves it as last
# fetched and says so; with no AGENT_REPO there is nowhere to fetch from.

fetch_journal() {
    [ -n "${AGENT_REPO:-}" ] || return 0

    if [ ! -d "$JOURNAL_CLONE" ]; then
        git init -q --bare "$JOURNAL_CLONE" \
            && git -C "$JOURNAL_CLONE" remote add origin "$AGENT_REPO" \
            && git -C "$JOURNAL_CLONE" config remote.origin.fetch '+refs/heads/*:refs/remotes/source/*'
    fi

    git -C "$JOURNAL_CLONE" fetch --quiet --prune origin 2>/dev/null \
        || echo "note: could not fetch $AGENT_REPO — its journal is read as last fetched." >&2
}


# --- need_store_and_journal ---
# need_store, from store.sh, which the caller sources, and fetch_journal side by side: two
# independent round trips. need_store stays in this shell, because it exports the records' path
# and sets the trap that removes a fetched copy.

need_store_and_journal() {
    fetch_journal &
    local fetching=$!
    need_store
    wait "$fetching"
}
