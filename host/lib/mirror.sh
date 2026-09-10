# shellcheck shell=bash
# Where the mirror's clone is, and the sentence for "it is not there".
#
# Sourced by `mirror`, which only reads it. The path is computed once in the
# justfile and exported, as the archive's is.
#
# The clone is a working folder, the one the operator edits the mirror in, and
# **blobless** — `--filter=blob:none` — because nothing here wants a file: the
# tip, its date, the commit count and the rewind marks are all commit metadata.
# Measured 2026-09-09: 1.4 MB against 267 MB for the whole memory, fetched in
# under two seconds, and a `git show origin/main:<path>` still reads the
# workflow by pulling that one blob on demand.
# see docs/monitor.md#the-mirror-is-not-in-the-archive

MIRROR="${AGENT_MIRROR:?not set — run this through 'just', which computes it}"


# --- mirror_url ---
# HTTPS and not ssh, so one credential covers both halves of what a host does
# with the mirror: `gh auth setup-git` installs a helper git uses for github.com,
# and the same token answers `gh api` for the workflow's state and its dispatch.
# Over ssh the fetch would want a deploy key of its own — a second secret on the
# machine that is meant to hold as little as possible, and the one machine that
# must not hold a key to the record auditing it.
# see docs/monitor.md#the-mirror-is-not-in-the-archive

# shellcheck disable=SC2329  # called by need_mirror below
mirror_url() {
    printf 'https://github.com/%s.git\n' "${AGENT_MIRROR_REPO:?not set — the mirror repository, owner/name, from .env}"
}


# --- need_mirror ---
# Makes the clone when it is absent rather than sending the caller to a recipe.
# It is a megabyte of commit metadata with no credential in it, and the machine
# that runs the agent must never run `setup-mirror`, which installs credentials
# — so a read that made the reader go there would be a read that cannot happen
# on the host where the status page is drawn.
# see docs/monitor.md#the-mirror-is-not-in-the-archive

need_mirror() {
    if git -C "$MIRROR" rev-parse --git-dir >/dev/null 2>&1; then
        # Checked every run and not only at creation: a clone made against
        # another URL goes on fetching it in silence, which is what the audit
        # clone did when the mirror changed repository.
        if [ "$(git -C "$MIRROR" remote get-url origin 2>/dev/null)" != "$(mirror_url)" ]; then
            git -C "$MIRROR" remote set-url origin "$(mirror_url)" || exit 1
            echo "The clone at $MIRROR pointed elsewhere; repointed at $(mirror_url)." >&2
        fi
        return 0
    fi

    repo="${AGENT_MIRROR_REPO:?not set — the mirror repository, owner/name, from .env}"
    [ -e "$MIRROR" ] && {
        echo "$MIRROR exists and is not a git repository. Move it, or point AGENT_MIRROR elsewhere." >&2
        exit 1; }

    # `clone --filter` keeps the filter as configuration, so every later fetch
    # honours it — including one typed by hand. Without it this is 9.6 MB where
    # it should be 1.4, measured, and nothing would say so.
    git clone -q --filter=blob:none "$(mirror_url)" "$MIRROR" || {
        echo "Could not make a clone of the mirror at $MIRROR." >&2; exit 1; }
    echo "Made a clone of $repo at $MIRROR." >&2
}
