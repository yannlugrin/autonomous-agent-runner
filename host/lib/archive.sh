# shellcheck shell=bash
# Where the archive checkout is, and the sentence for "it is not there".
#
# Sourced by the recipes that only read the archive — `sessions`, `read` and
# `mirror` — so they agree on one spelling of the missing-clone message. The
# path itself is computed once in the justfile and exported.
#
# `collect` and `publish-status` write the archive and carry their own refusal:
# theirs is reached deep inside a run that has already extracted transcripts,
# and the sentence belongs where the work stops.
# see docs/archive.md#the-listing

ARCHIVE="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"


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
# Which ref holds the collected sessions, into ARCHIVE_REF. Local first: `just
# collect` runs on this host and commits to the local `sessions`, so that is the
# one ahead; origin/sessions is the fallback for a fresh clone.

archive_ref() {
    if git -C "$ARCHIVE" rev-parse --verify --quiet sessions >/dev/null; then
        ARCHIVE_REF=sessions
    elif git -C "$ARCHIVE" rev-parse --verify --quiet origin/sessions >/dev/null; then
        ARCHIVE_REF=origin/sessions
    else
        echo "No 'sessions' branch here or on origin. Nothing has been collected yet." >&2
        echo "It is created by 'just collect --push'." >&2
        exit 1
    fi
}


# --- archive_rows ---
# The sessions branch as one ordered table, newest first, and the two lists
# behind it: ARCHIVE_FILES, ARCHIVE_SUBS, ARCHIVE_ROWS — over the ref
# archive_ref picks.
#
# One implementation, because `sessions` prints this table and `read` counts
# into it: the number a listing shows and the number `read` takes are the same
# handle by construction rather than by two orderings agreeing.
#
# A row is the transcript's path, then session-meta.jq's fourteen fields. A
# session and whatever it spawned go through that pass together, and the reduce
# in there tells them apart by isSidechain.
# see docs/archive.md#newest-first-and-what-a-number-means

# shellcheck disable=SC2034  # ARCHIVE_FILES, ARCHIVE_SUBS and ARCHIVE_ROWS are
# this function's output, read by sessions.sh and read.sh after they call it
archive_rows() {
    need_archive
    archive_ref

    # A sub-agent writes a transcript of its own beside its session, as
    # <session-id>--agent-<agent-id>.jsonl, and is not a session: listed as one
    # it is a row with no title, and its output would be counted twice.
    # see docs/archive.md#a-subagent-is-not-a-session
    local all_files
    all_files=$(git -C "$ARCHIVE" ls-tree -r --name-only "$ARCHIVE_REF" -- transcripts | grep '\.jsonl$')
    ARCHIVE_FILES=$(printf '%s\n' "$all_files" | grep -v -- '--agent-')
    ARCHIVE_SUBS=$(printf '%s\n' "$all_files" | grep -- '--agent-')
    [ -n "$ARCHIVE_FILES" ] || {
        echo "No transcripts under transcripts/ on $ARCHIVE_REF." >&2; exit 1; }

    ARCHIVE_ROWS=$(for f in $ARCHIVE_FILES; do
        printf '%s\t' "$f"
        { git -C "$ARCHIVE" show "$ARCHIVE_REF:$f"
          for s in $(printf '%s\n' "$ARCHIVE_SUBS" | grep -F "${f%.jsonl}--agent-"); do
              git -C "$ARCHIVE" show "$ARCHIVE_REF:$s"
          done
        } | jq -rn -f host/archive/session-meta.jq
    done | sort -r -t"$(printf '\t')" -k2,2 -k3,3)
}
