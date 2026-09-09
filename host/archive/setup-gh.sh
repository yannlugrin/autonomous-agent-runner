#!/usr/bin/env bash
# One-time setup for this host's own GitHub access to the mirror. Idempotent —
# safe to re-run, and re-running is how you check it later.
#
# Runs on any host that runs the agent, including the one that only runs it.
# That is the difference from `setup-mirror`: that recipe installs what WRITES
# the audit record and refuses on a runtime host, this one installs what asks
# the record to refresh itself and belongs there.
#
# It touches two things, both local:
#
#   1. `gh`'s stored credential for github.com;
#   2. git's credential helper, so the mirror's clone fetches over HTTPS with
#      the same token rather than wanting a deploy key of its own.
#
# What it proves depends on which machine it is: everywhere, that the token
# reads the mirror and that git can fetch it. On a RUNTIME host — the one that
# runs the agent — also that the token CANNOT write a ref there, because the
# machine the record audits must not be able to arrange it.
#
# On the machine the code is edited at, writing is expected: that is where
# `setup-mirror` runs, and the operator's own credential is the one that
# installs the workflow's. Requiring a narrow token there would be requiring the
# operator to be less than themselves.
#   see docs/monitor.md#the-mirror-is-not-in-the-archive
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

REPO="${AGENT_MIRROR_REPO:?not set — the mirror repository, owner/name, from .env}"

die() { printf '\n%s\n\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

command -v gh >/dev/null || die "gh is not installed."


# --- what the token must be able to do, and must not ---
# Asked of the API rather than of `gh auth status`, which reports the account
# and not what the token may do. A fine-grained token's permissions are not
# readable: the only honest question is whether an act succeeds.

reads_mirror() { gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1; }

# A ref that means nothing, created and then removed. A 403 is the answer this
# wants: the token cannot write, which is the property being installed. The sha
# is the mirror's own tip, so nothing about this depends on what is in the
# repository. see docs/monitor.md#only-a-write-attempt-tells-the-tokens-apart
cannot_write() {
    local sha out
    sha=$(gh api "repos/$REPO/git/ref/memory/mirror" --jq .object.sha 2>/dev/null) || return 0
    [ -n "$sha" ] || return 0
    out=$(gh api -X POST "repos/$REPO/git/refs" \
        -f ref=refs/probe/permcheck -f "sha=$sha" 2>&1) && {
        gh api -X DELETE "repos/$REPO/git/refs/probe/permcheck" >/dev/null 2>&1
        return 1
    }
    printf '%s' "$out" | grep -q 'not accessible by personal access token'
}


# --- the credential ---

step "gh's credential for github.com"

# On this machine a token that can write is right; on the one that runs the
# agent it is the failure this recipe exists to catch.
runtime=no
[ "${RUNNER_RUNTIME_ONLY:-}" = true ] && runtime=yes

good() {
    gh auth status >/dev/null 2>&1 || return 1
    reads_mirror || return 1
    [ "$runtime" = no ] && return 0
    cannot_write
}

if good; then
    if [ "$runtime" = yes ]; then
        echo "Already logged in with a token that reads $REPO and cannot write it."
    else
        echo "Already logged in with a token that reads $REPO."
    fi
else
    if gh auth status >/dev/null 2>&1; then
        if ! reads_mirror; then
            echo "The token here cannot read $REPO."
        else
            echo "The token here CAN write $REPO — that is the one the mirror's"
            echo "workflow pushes with, and it does not belong on a machine the"
            echo "record audits."
        fi
        echo "Replacing it."
        gh auth logout --hostname github.com >/dev/null 2>&1
    fi

    cat <<MSG

Make a fine-grained personal access token, at
https://github.com/settings/personal-access-tokens/new

    Resource owner      ${REPO%%/*}
    Repository access   Only select repositories -> $REPO
    Permissions         Contents: Read-only
                        Actions:  Read and write

Contents lets this host fetch the record. Actions lets it ask for a refresh.
Neither writes a ref, which is the point: this machine may ask the record to
update itself and may never touch it.

MSG
    [ -t 0 ] || die "There is no terminal to paste a token on. Over ssh that means
opening a shell first — 'ssh -t <host>', then 'cd <checkout> && just setup-gh' —
rather than passing the recipe as a command."
    # `read`, so Enter ends it. `gh auth login --with-token` reads to end of file
    # and wants a Ctrl-D; this does not, and somebody who typed one yesterday
    # would hand it an empty line.
    printf '  paste the token, then Enter : '
    read -rs TOKEN; echo
    [ -n "$TOKEN" ] || die "Nothing was pasted. Enter ends the line here — Ctrl-D is for
'gh auth login --with-token', which this runs for you."

    printf '%s' "$TOKEN" | gh auth login --with-token || die "gh would not take that token."
    unset TOKEN

    reads_mirror || die "That token cannot read $REPO. Check the resource owner and the
repository list — a fine-grained token reaches only what it names."
    if [ "$runtime" = yes ]; then
        cannot_write || die "That token CAN write $REPO. It is the workflow's token, not this
host's. Make one with Contents: Read-only and try again."
        echo "  installed: reads $REPO, cannot write it."
    else
        echo "  installed: reads $REPO."
    fi
fi


# --- git, so the clone fetches with the same token ---
# Without this the mirror's clone is HTTPS with nothing to authenticate it, and
# `just mirror-status` reports a fetch failure that reads like a network fault.

step "git's credential helper"

gh auth setup-git || die "gh could not configure git."
echo "  git uses gh for github.com."


# --- proved, not assumed ---

step "What it can do"

if git ls-remote "https://github.com/$REPO.git" >/dev/null 2>&1; then
    echo "  fetch      : ok — the clone can read the record"
else
    die "git still cannot read https://github.com/$REPO.git, so the clone will not fetch."
fi

if [ "$runtime" = yes ]; then
    if cannot_write; then
        echo "  write      : refused, which is what this host must not be able to do"
    else
        die "This host runs the agent and can write the record it is audited against.
Fix the token: Contents must be Read-only."
    fi
else
    echo "  write      : not checked — this is where the record's own setup is run from"
fi

workflow="${AGENT_MIRROR_WORKFLOW:-mirror-$AGENT_USER.yml}"
if gh api "repos/$REPO/actions/workflows/$workflow" --jq .state >/dev/null 2>&1; then
    echo "  workflow   : readable — 'just mirror-status' can report on it"
else
    echo "  workflow   : NOT readable — check Actions: Read on the token" >&2
fi

# shellcheck disable=SC2016  # the backticks are prose, not substitution
# The concrete command, not the script that every session end runs: that one is
# invoked by `just`, which loads `.env` and derives AGENT_USER, and typed by
# hand it has neither.
printf '\nProve Actions: Write by asking for a run — this is the same request a\nsession end makes, through the same token:\n\n    gh workflow run %s --repo %s\n\nThen `just mirror-status`: the last run is that minute.\n' \
    "$workflow" "$REPO"
