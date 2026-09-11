# shellcheck shell=bash
# What the monitor reads the agent's memory from, where everything it writes
# lives, and how each is brought up to date. Two sources, reading two things:
#
#   mirror/      the ARCHIVE's mirror of the agent's memory — a copy, refreshed
#                by a workflow on GitHub's schedule, and what the drift audit
#                reads because the audit is about what moved between two anchors
#   memory.log   the commits in the agent's checkout ITSELF, read out of its
#                volume on demand, and what `just records` reads because a record
#                must be current at the moment it is sealed rather than as
#                current as an hourly workflow managed to be
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
# The agent's checkout as this host last read it: one `git log`, replaced whole
# on every read.
MEMORY_LOG="$MONITOR/memory.log"
# Whether the last push carried that checkout to origin, as `just listen` shows it.
MEMORY_STATE="$MONITOR/memory.state"
# The session's working directory: the run procedure, the anchors it is given,
# and the reports it writes. `../mirror` from in there is the clone, which is
# how the auditor's settings.json spells what it may read.
AUDIT_WORK="$MONITOR/drift-audit"
AUDIT_STATE="$AUDIT_WORK/state"
AUDIT_REPORTS="$AUDIT_WORK/reports"
AUDIT_LOG="$MONITOR/logs/drift-audit.tsv"

# What is mirrored, and from where. The mirror lives in a repository of its own
# — not in the archive, which the machine running the agent can write — and the
# ref no longer carries the agent's name: that repository holds nothing else.
# `just mirror-status` reports on the same ref.
# see docs/monitor.md#why-the-mirror-is-a-hidden-ref
MIRROR_REF="refs/memory/mirror"
MIRROR_REMOTE="git@github.com:${AGENT_MIRROR_REPO:?not set — the mirror repository, owner/name, from .env}.git"


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
    git ls-remote --exit-code "$MIRROR_REMOTE" "$MIRROR_REF" >/dev/null 2>&1
    case $? in
        0) ;;
        2)  echo "No mirror of the agent's memory at $MIRROR_REF on $AGENT_MIRROR_REPO." >&2
            echo >&2
            echo "The audit reads that ref and nothing else, so there is nothing to read." >&2
            echo "'just mirror-status' says whether the workflow that writes it is enabled" >&2
            echo "and when it last ran; 'just setup-mirror' is what installs it there." >&2
            exit 1 ;;
        *)  echo "Could not reach $ARCHIVE_REMOTE. Nothing audited." >&2
            exit 1 ;;
    esac

    if [ ! -d "$AUDIT_CLONE/.git" ]; then
        mkdir -p "$MONITOR" || exit 1
        git init -q -b audit "$AUDIT_CLONE" || exit 1
        git -C "$AUDIT_CLONE" remote add origin "$MIRROR_REMOTE" || exit 1
    fi

    # Reconciled on every run and not only at creation. The mirror moved
    # repository once — out of the archive, so the machine that runs the agent
    # could not rewrite the record that audits it — and a clone made before that
    # went on fetching the old place in silence, reporting a mirror that was
    # correct until the day those refs were deleted. The refspecs are rewritten
    # rather than added to, because `--add` is what left three generations of
    # them here. see docs/monitor.md#the-audit-clone-is-reconciled-not-assumed

    if [ "$(git -C "$AUDIT_CLONE" remote get-url origin 2>/dev/null)" != "$MIRROR_REMOTE" ]; then
        echo "The audit clone pointed elsewhere; repointing it at $AGENT_MIRROR_REPO." >&2
        git -C "$AUDIT_CLONE" remote set-url origin "$MIRROR_REMOTE" || exit 1
    fi

    want="+$MIRROR_REF:refs/remotes/mirror/source
+refs/memory/rewound/*:refs/remotes/rewound/*"
    if [ "$(git -C "$AUDIT_CLONE" config --get-all remote.origin.fetch 2>/dev/null)" != "$want" ]; then
        git -C "$AUDIT_CLONE" config --unset-all remote.origin.fetch 2>/dev/null
        # The marks the mirror writes before a force-push, each holding the tip
        # as it stood: the audit reports every one that is new.
        while IFS= read -r spec; do
            git -C "$AUDIT_CLONE" config --add remote.origin.fetch "$spec" || exit 1
        done <<< "$want"

        # `--prune` only reaches what a refspec names, so tracking refs left by
        # an older shape survive it and would read as current. Cleared here, and
        # the fetch below is what puts back everything that still exists.
        git -C "$AUDIT_CLONE" for-each-ref --format='%(refname)' refs/remotes \
            | while IFS= read -r r; do
                  git -C "$AUDIT_CLONE" update-ref -d "$r"
              done
    fi

    if ! git -C "$AUDIT_CLONE" fetch --prune origin \
        || ! git -C "$AUDIT_CLONE" rev-parse --verify -q refs/remotes/mirror/source >/dev/null; then
        echo "Fetched $MIRROR_REMOTE and $MIRROR_REF did not land. Nothing audited." >&2
        exit 1
    fi
}


# --- sync_memory ---
# The commits in the agent's own checkout, read out of its volume here and now.
#
# Not the mirror, a copy only as current as a workflow last managed to be, and
# not the repository on GitHub, which takes a credential the host running the
# agent does not hold and lacks any commit whose push did not go through. The
# checkout is where a session's commits are made.
#   see docs/monitor.md#the-commits-come-from-the-agents-checkout
#
# Read-only mount, no network, and the entrypoint replaced so nothing
# bootstraps. Written aside and moved into place, so the log's mtime is the
# moment of a read that completed — the instant a record waits on.

sync_memory() {
    # No apostrophe in the messages: inside ${var:?word} bash opens a single
    # quote even within double quotes, and the file then fails to parse far
    # below, at an error naming neither this line nor the quote.
    #   see docs/archive.md#a-quoting-trap-in-three-files
    local volume="${AGENT_VOLUME:?not set — run this through just}"
    local home="${AGENT_HOME:?not set — run this through just}"
    local checkout="${AGENT_REPO_DIR:?not set — run this through just}"
    local image="${RUNNER_IMAGE:-${RUNNER_IMAGE_DEPLOYED:?not set — run this through just}}"
    local tmp

    mkdir -p "$MONITOR" || return 1
    tmp=$(mktemp "$MEMORY_LOG.XXXXXX") || return 1

    # The checkout's git config is the agent's, so what would change these lines
    # is overridden here: signatures, colour, renames, and every global setting.
    if ! docker run --rm --network none --read-only \
            -v "$volume:$home:ro" \
            -e GIT_CONFIG_GLOBAL=/dev/null -e GIT_CONFIG_NOSYSTEM=1 \
            --entrypoint git "$image" \
            -C "$checkout" log --no-renames --no-show-signature --no-color \
            --format='C%H %ct' --numstat --branches --remotes=origin >"$tmp"; then
        rm -f "$tmp"
        echo "Could not read the commits out of the checkout in $volume. The commits a session" >&2
        echo "made cannot be read, so nothing is sealed against a source that may be behind." >&2
        return 1
    fi
    mv "$tmp" "$MEMORY_LOG"
}


# --- sync_push_state ---
# Whether the session's push reached origin, out of the same checkout the same
# way. Only a successful push moves the checkout's `refs/remotes/origin/*`, so a
# commit no origin ref holds is one the last push did not carry, and
# ERROR_ON_PUSH is the hook's own report of why. Neither needs the network, or
# the credential for origin this host does not hold.
#   see docs/backup.md#the-host-reads-the-flag-too
#
# The counts are printed before anything taken out of the flag: the agent can
# write that file, and the reader keeps the first value of a key. fsmonitor is
# off because it names a command, the checkout's config is the agent's, and
# `status` is the one call here that would run it.

sync_push_state() {
    local volume="${AGENT_VOLUME:?not set — run this through just}"
    local home="${AGENT_HOME:?not set — run this through just}"
    local checkout="${AGENT_REPO_DIR:?not set — run this through just}"
    local image="${RUNNER_IMAGE:-${RUNNER_IMAGE_DEPLOYED:?not set — run this through just}}"
    local reader tmp

    reader=$(cat <<'SH'
cd "$1" || exit 1
unpushed=$(git rev-list --count --branches --not --remotes=origin) || unpushed=-
if changes=$(git -c core.fsmonitor=false status --porcelain); then
    uncommitted=$(printf '%s\n' "$changes" | grep -v ' ERROR_ON_PUSH$' | grep -c .)
else
    uncommitted=-
fi
printf 'unpushed: %s\nuncommitted: %s\n' "$unpushed" "$uncommitted"
[ -f ERROR_ON_PUSH ] || exit 0
sed -n 's/^reason: /push_reason: /p; s/^consecutive: /push_consecutive: /p' ERROR_ON_PUSH
awk '/^detail:/ { on = 1; next }
     on && NF && !/^ *---/ { sub(/^ +/, ""); print "push_detail: " $0; exit }' ERROR_ON_PUSH
SH
)

    mkdir -p "$MONITOR" || return 1
    tmp=$(mktemp "$MEMORY_STATE.XXXXXX") || return 1
    if ! docker run --rm --network none --read-only \
            -v "$volume:$home:ro" \
            -e GIT_CONFIG_GLOBAL=/dev/null -e GIT_CONFIG_NOSYSTEM=1 -e GIT_OPTIONAL_LOCKS=0 \
            --entrypoint sh "$image" -c "$reader" sh "$checkout" >"$tmp"; then
        rm -f "$tmp"
        echo "Could not read whether the memory reached origin out of the checkout in $volume." >&2
        return 1
    fi
    mv "$tmp" "$MEMORY_STATE"
}
