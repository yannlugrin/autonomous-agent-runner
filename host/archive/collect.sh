#!/usr/bin/env bash
# Archive the agent's session transcripts to the private archive repository.
#
# Runs on the host, not in the container: anything the agent can execute, the
# agent can influence. This reads the volume from outside and commits with the
# operator's own git credentials. Tamper-resistant, not tamper-proof — the
# agent can delete a transcript before this runs, and running it as the
# container exits shrinks that window to seconds.
#
# The transcripts live on `sessions`, an orphan branch of the archive, and the
# commit is made in a throwaway worktree checked out on it.
# see docs/archive.md#the-worktree-and-why-the-commit-is-never-made-in-the-archive-checkout
#
# The orchestrator: what every stage shares — the flags, the paths, the staging
# directory and its cleanup — with the stages themselves sourced at the bottom
# in the order they run. Sourced rather than run because they are one
# collection: a stage's output is the next one's input, and passing that
# between processes would mean serialising the volume's secrets.
# see docs/archive.md#the-stages-of-a-collection
#
# `--approve <hash> <why>` and `--redact <hash> <why>` are parsed here rather
# than declared as `just` options: they take two values each and repeat, which
# a declared option cannot express, so a note travels as "$@".
#
# Usage:  ./collect.sh [--push] [--held]
#         ./collect.sh [--approve <hash> <why>]... [--redact <hash> <why>]...

set -uo pipefail

# Run from the repository root whatever the caller's cwd.
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    forward_to_deployed collect "$@"
fi

# From here on a failed command stops the run: everything below writes to the
# archive or decides what reaches it, and carrying on past a failed step would
# commit what it had.
set -e


# --- what the run is working on ---

# Plain, because compose.yaml names the volume explicitly rather than letting
# the project name prefix it. If the two literals disagree the failure is a
# loud "no such volume".
VOLUME="${AGENT_VOLUME:?not set — run this through 'just', which derives it from the agent name}"
# Computed and exported by the justfile. Named here, decided there; `:?` and
# not a default, so a second copy of that decision cannot grow back.
ARCHIVE="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"
IMAGE="${RUNNER_EXTRACT_IMAGE:-alpine:3}"
BRANCH=sessions
PUSH=false
HELD=false


# --- the flags ---
# One line per ruling: <verb>\t<what was named>\t<why>. A list, so a review of
# several held transcripts is one run: each ruling names one transcript and
# carries its own note, and they land in one commit together.
# see docs/archive.md#several-rulings-in-one-run

RULINGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --push)  PUSH=true ;;
        --held) HELD=true ;;
        # --approve says "this is nothing, archive it as it stands";
        # --redact is for a transcript that carries a real credential and is
        # still worth keeping.  see docs/archive.md#the-third-ending
        --approve|--redact)
            [ -n "${2:-}" ] || { echo "$1 needs the hash this script printed, or its first eight characters." >&2; exit 2; }
            [ -n "${3:-}" ] || { echo "$1 needs a note saying why. It goes in the record." >&2; exit 2; }
            RULINGS="${RULINGS:+$RULINGS
}$(printf '%s\t%s\t%s' "${1#--}" "$2" "$3")"
            shift 2 ;;
        *) echo "Usage: collect.sh [--push] [--held] [--approve <what> <why>]... [--redact <what> <why>]..." >&2; exit 2 ;;
    esac
    shift
done

die() { printf '\n%s\n\n' "$*" >&2; exit 1; }


# --- the archive, the daemon and the volume ---
# rev-parse rather than a test on `.git`, which is a directory in a clone and
# a file in a linked worktree. Deliberately not a clone-if-missing: the URL
# would be written down a second time beside the one in the clone's origin and
# the pair would drift, and a missing archive costs nothing durable.

git -C "$ARCHIVE" rev-parse --git-dir >/dev/null 2>&1 || die \
    "No archive repository at $ARCHIVE. Clone it:

    git clone git@github.com:${AGENT_ARCHIVE_REPO:-<owner>/<archive>}.git $ARCHIVE

It is private, and separate from the agent's memory repository on purpose:
transcripts have a different risk profile and a different lifetime, and
keeping them apart is what lets the memory repository stay publishable."

# Before the volume probe, not after: a stopped daemon makes that probe fail,
# and its message says the volume does not exist — which reads as the agent's
# world having been lost rather than a service being off.
host/lib/docker-up.sh

docker volume inspect "$VOLUME" >/dev/null 2>&1 || die \
    "No docker volume named '$VOLUME'.
That name was derived from compose's own project name. If it is wrong,
list the volumes with \`docker volume ls\` and set AGENT_VOLUME."


# --- what the run leaves behind, and what removes it ---

staging="$(mktemp -d)"
wt=""
# Assigned further down, declared here so `cleanup` can name whatever path the
# run died on — `--held` returns before the worktree is even created.
layout=""

cleanup() {
    # A worktree left behind is not cosmetic: `worktree add` refuses the
    # branch on the next run, so every later collection fails.
    if [ -n "$wt" ]; then
        git -C "$ARCHIVE" worktree remove --force "$wt" 2>/dev/null || true
        git -C "$ARCHIVE" worktree prune 2>/dev/null || true
        rm -rf "${wt%/*}"
    fi
    rm -rf "$staging"
    [ -n "$layout" ] && rm -f "$layout"
    return 0
}
trap cleanup EXIT


# --- the stages, in order ---
# Each one is a file named for what it does, and each reads what the one above
# it left in this shell.

# shellcheck source=SCRIPTDIR/read-volume.sh
. host/archive/read-volume.sh    # the transcripts, the secrets, where each belongs
# shellcheck source=SCRIPTDIR/ledger.sh
. host/archive/ledger.sh         # what has already been ruled on
# shellcheck source=SCRIPTDIR/scan.sh
. host/archive/scan.sh           # the gate: shapes, verbatim, gitleaks, and the skip
# shellcheck source=SCRIPTDIR/rule.sh
. host/archive/rule.sh           # --held, --approve, --redact, and the proof
# shellcheck source=SCRIPTDIR/report.sh
. host/archive/report.sh         # what is held, and what the run read
# shellcheck source=SCRIPTDIR/archive.sh
. host/archive/archive.sh        # the worktree, the commit, the push
