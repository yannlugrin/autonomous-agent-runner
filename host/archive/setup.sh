#!/usr/bin/env bash
# One-time setup for the archive: the clone this host reads and writes.
# Idempotent — safe to re-run.
#
# Runs on the host, with the operator's own credentials. Nothing about it is the
# container's, and the agent is never told any of it.
#
# The mirror is not here. It has a repository of its own and `just setup-mirror`
# sets it up, because the machine that runs the agent writes transcripts to the
# archive and a record it could rewrite is not a record.
#   see docs/archive.md#the-archives-setup
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

ARCHIVE="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"
ARCHIVE_REPO="${AGENT_ARCHIVE_REPO:?not set — the archive repository, owner/name, from .env}"

die() { printf '\n%s\n\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }


# --- the clone ---
# Inside the project and gitignored, like `deployed/`: a demonstration that can
# be cloned and run must arrange nothing outside its own directory.
# AGENT_ARCHIVE stays overridable for a sibling layout, and an installation
# that already has one keeps it.

step "The archive clone at $ARCHIVE"

if git -C "$ARCHIVE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Already a git repository. Leaving it alone."
else
    [ -e "$ARCHIVE" ] && die "$ARCHIVE exists and is not a git repository. Move it, or point AGENT_ARCHIVE elsewhere."
    git clone "git@github.com:$ARCHIVE_REPO.git" "$ARCHIVE"
    echo "Cloned $ARCHIVE_REPO."
fi
