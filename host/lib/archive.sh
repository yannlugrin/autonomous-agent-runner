# shellcheck shell=bash
# Where the archive checkout is, and the sentence for "it is not there".
#
# Sourced by the recipes that read the archive and never write it — `read`, and
# `stats`, `tools` and `cost` through host/lib/store.sh — so they agree on one
# spelling of the missing-clone message. With the agent on another machine they
# fetch it first. The path itself is computed once in the justfile and exported.
#
# `collect` and `publish-status` write the archive and carry their own refusal:
# theirs is reached deep inside a run that has already extracted transcripts,
# and the sentence belongs where the work stops.
# see docs/archive.md#reading-the-archive

ARCHIVE="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"

# shellcheck source=SCRIPTDIR/deploy-host.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/deploy-host.sh"


# --- need_archive ---
# Returns when there is a clone to read, and exits 1 with the way to make one
# when there is not.

need_archive() {
    # rev-parse rather than a test on `.git`, which is a directory in a clone
    # and a file in a linked worktree.
    git -C "$ARCHIVE" rev-parse --git-dir >/dev/null 2>&1 && return 0

    echo "No archive repository at $ARCHIVE." >&2
    echo >&2
    echo "    just setup-archive      clones ${AGENT_ARCHIVE_REPO:-<owner>/<archive>} there" >&2
    echo >&2
    echo "Or set AGENT_ARCHIVE to where it already is." >&2
    exit 1
}


# --- archive_ref ---
# Which ref holds the collected sessions, into ARCHIVE_REF. Where `just collect`
# runs, it commits to the local `sessions`, so that is the one ahead and
# origin/sessions is the fallback for a fresh clone. Where the agent runs on
# another machine nothing here writes `sessions`, so origin is fetched and read.
# see docs/archive.md#reading-the-archive

# shellcheck disable=SC2034  # ARCHIVE_REF is this function's output, read by its callers
archive_ref() {
    if deploying_elsewhere; then
        git -C "$ARCHIVE" fetch --quiet origin sessions 2>/dev/null \
            || echo "note: could not fetch $ARCHIVE — reading origin/sessions as last fetched." >&2
    elif git -C "$ARCHIVE" rev-parse --verify --quiet sessions >/dev/null; then
        ARCHIVE_REF=sessions
        return 0
    fi

    if git -C "$ARCHIVE" rev-parse --verify --quiet origin/sessions >/dev/null; then
        ARCHIVE_REF=origin/sessions
    else
        echo "No 'sessions' branch here or on origin. Nothing has been collected yet." >&2
        echo "It is created by 'just collect --push'." >&2
        exit 1
    fi
}
