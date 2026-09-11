# shellcheck shell=bash
# Where the sealed records are read from, and the sentence for "there are none".
#
# Sourced by the recipes that read the records — `stats`, `tools` and `cost`. A session end seals
# its record on the machine that runs the agent and publishes it to the archive's `cache` branch;
# when that is another machine the store here is never written, so the branch is read instead.
# see docs/monitor.md#one-record-per-session

# shellcheck source=SCRIPTDIR/deploy-host.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/deploy-host.sh"


# --- need_store ---
# Returns with RUNNER_RECORDS_DIR exported and pointing at the records, and exits 1 with the command
# that makes them when there are none. A fetched copy is removed on EXIT.

records_copy=""

need_store() {
    if deploying_elsewhere; then
        # shellcheck source=SCRIPTDIR/archive.sh
        . "$(dirname -- "${BASH_SOURCE[0]}")/archive.sh"
        need_archive

        git -C "$ARCHIVE" fetch --quiet origin cache 2>/dev/null \
            || echo "note: could not fetch $ARCHIVE — reading origin/cache as last fetched." >&2

        records_copy=$(mktemp -d) || exit 1
        trap 'rm -rf "$records_copy"' EXIT

        git -C "$ARCHIVE" archive origin/cache records 2>/dev/null \
            | tar -x -C "$records_copy" --strip-components=1 \
            || { echo "No records on origin/cache in $ARCHIVE — no session has been sealed yet." >&2; exit 1; }
        export RUNNER_RECORDS_DIR="$records_copy"
        return 0
    fi

    local store="${RUNNER_RECORDS_DIR:?not set — run this through 'just', which derives it from the cache directory}"
    [ -d "$store" ] && return 0

    # A fresh clone has no records at all, and the command that makes them is not the one just typed.
    echo "No records yet — $store does not exist." >&2
    echo >&2
    echo "Every session end seals its own record. 'just records' seals what is" >&2
    echo "waiting, and 'just collect --push' is what puts a transcript where it" >&2
    echo "can be sealed from." >&2
    exit 1
}
