# shellcheck shell=bash
# The clones the monitor keeps, where everything it writes lives, and how each
# is brought up to date. Two of them, reading two different things:
#
#   mirror/   the ARCHIVE's mirror of the agent's memory — a copy, refreshed by
#             a workflow on GitHub's schedule, and what the drift audit reads
#             because the audit is about what moved between two anchors
#   memory/   the agent's repository ITSELF, fetched by this host on demand, and
#             what `just records` reads because a record must be current at the
#             moment it is sealed rather than as current as an hourly workflow
#             managed to be
#
# Sourced by `drift-audit` and `drift-status`, the two that need the mirror to
# be current, by `just records`, which needs the second, and by `drift-accept`
# and `drift-diff`, which read the anchors and the clone as they stand and so
# take the paths and never fetch.
#
# Working state, not tracked content: everything below sits under
# RUNNER_MONITOR — `monitor/` inside the project, gitignored, exactly as
# `deployed/` and `archive/` are, so a clone of this repository arranges nothing
# outside its own directory. What the auditor is told, and what it may do, is
# tracked: host/monitor/drift-audit/.  see docs/monitor.md#where-the-audit-keeps-its-state

# shellcheck disable=SC2034  # the AUDIT_* below are this file's output, read by
# the scripts that source it
MONITOR="${RUNNER_MONITOR:?not set — run this through 'just', which computes it}"

AUDIT_CLONE="$MONITOR/mirror"
# The agent's repository as this host reads it. Bare: nothing is ever checked
# out of it and nothing is ever written to it — rule 2 is about writing, and
# this only fetches.
MEMORY_CLONE="$MONITOR/memory"
# The session's working directory: the run procedure, the anchors it is given,
# and the reports it writes. `../mirror` from in there is the clone, which is
# how the auditor's settings.json spells what it may read.
AUDIT_WORK="$MONITOR/drift-audit"
AUDIT_STATE="$AUDIT_WORK/state"
AUDIT_REPORTS="$AUDIT_WORK/reports"
AUDIT_LOG="$MONITOR/logs/drift-audit.tsv"

# What is mirrored, and from where, both derived: the archive's own mirror
# workflow writes the agent's memory to this ref, and `just mirror-status`
# reports on the same one.  see docs/monitor.md#why-the-mirror-is-a-hidden-ref
MIRROR_REF="refs/archive/${AGENT_USER:?not set — run this through 'just', which derives it}"
ARCHIVE_REMOTE="git@github.com:${AGENT_ARCHIVE_REPO:?not set — the archive repository, owner/name, from .env}.git"


# --- sync_clone ---
# Clone on first use, fetch afterwards, and return only when the mirror ref is
# really there. The archive keeps the mirrored content on a hidden ref rather
# than on a branch, so the refspecs are explicit: a plain clone fetches nothing.
#
# Nothing is written to the archive: a fetch is a read, this clone has no push
# refspec, and the audit never commits.

sync_clone() {
    # Asked of the remote first, before anything local exists. The content
    # refspec names one exact ref, and a fetch of a ref the archive does not
    # have fails outright — so without this an archive whose mirror has never
    # run reports itself as a network failure, and leaves an empty clone behind
    # for the next run to look current.
    git ls-remote --exit-code "$ARCHIVE_REMOTE" "$MIRROR_REF" >/dev/null 2>&1
    case $? in
        0) ;;
        2)  echo "No mirror of the agent's memory at $MIRROR_REF on $AGENT_ARCHIVE_REPO." >&2
            echo >&2
            echo "The audit reads that ref and nothing else, so there is nothing to read." >&2
            echo "'just mirror-status' says whether the workflow that writes it is enabled" >&2
            echo "and when it last ran; 'just setup-archive' is what installs it." >&2
            exit 1 ;;
        *)  echo "Could not reach $ARCHIVE_REMOTE. Nothing audited." >&2
            exit 1 ;;
    esac

    if [ ! -d "$AUDIT_CLONE/.git" ]; then
        mkdir -p "$MONITOR" || exit 1
        git init -q -b audit "$AUDIT_CLONE" || exit 1
        git -C "$AUDIT_CLONE" remote add origin "$ARCHIVE_REMOTE" || exit 1
        git -C "$AUDIT_CLONE" config remote.origin.fetch \
            "+$MIRROR_REF:refs/remotes/mirror/source" || exit 1
        # The marks the mirror writes before a force-push, each holding the tip
        # as it stood: the audit reports every one that is new.
        git -C "$AUDIT_CLONE" config --add remote.origin.fetch \
            '+refs/archive/rewound/*:refs/remotes/rewound/*' || exit 1
    fi

    if ! git -C "$AUDIT_CLONE" fetch --prune origin \
        || ! git -C "$AUDIT_CLONE" rev-parse --verify -q refs/remotes/mirror/source >/dev/null; then
        echo "Fetched $ARCHIVE_REMOTE and $MIRROR_REF did not land. Nothing audited." >&2
        exit 1
    fi
}


# --- sync_memory ---
# The agent's own repository, brought up to date here and now.
#
# NOT the mirror, and that is the whole point. The mirror is the archive's copy,
# advanced by a workflow on GitHub's best-effort schedule, so a record sealed
# against it would be as current as that workflow last managed to be — which was
# three days, once. This fetches the source at the moment the record is written,
# which is what makes "the commits this session made" a settled fact rather than
# a guess about whether a copy has caught up.
#
# It is read and never written: no push refspec, no checkout, no commit. The
# fetch stamps FETCH_HEAD, and that mtime is how a later run knows how recently
# the source was actually read.
#   see docs/monitor.md#the-commits-come-from-the-agents-repository

sync_memory() {
    # No apostrophe in the message: inside ${var:?word} bash opens a single
    # quote even within double quotes, and the file then fails to parse far
    # below, at an error naming neither this line nor the quote.
    #   see docs/archive.md#a-quoting-trap-in-three-files
    local remote="${AGENT_REPO:?not set — the repository the agent owns, from .env}"

    if [ ! -d "$MEMORY_CLONE" ]; then
        mkdir -p "$MONITOR" || exit 1
        git init -q --bare "$MEMORY_CLONE" || exit 1
        git -C "$MEMORY_CLONE" remote add origin "$remote" || exit 1
        git -C "$MEMORY_CLONE" config remote.origin.fetch \
            '+refs/heads/*:refs/remotes/source/*' || exit 1
    fi

    if ! git -C "$MEMORY_CLONE" fetch --prune --quiet origin; then
        echo "Could not reach $remote. The commits a session made cannot be read," >&2
        echo "so nothing is sealed against a source that may be behind." >&2
        return 1
    fi
}
