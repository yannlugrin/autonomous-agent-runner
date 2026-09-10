#!/usr/bin/env bash
# Setup for the mirror: the credentials its workflow runs on. Idempotent, and
# that is not a nicety — it runs on any host, and on one whose token only reads
# the record it must leave everything it finds and say so rather than stop.
# Nothing here is done twice: an installed key is left alone, an installed token
# is left alone, settings it cannot read are left alone. FORCE_KEY=1 and
# FORCE_TOKEN=1 are how each is replaced on purpose.
#
# It touches the mirror's own repository and the two it copies:
#
#   1. the mirror's Actions token, which defaults to read-only and cannot
#      be raised by the workflow's own `permissions:` block;
#   2. a fresh read-only deploy key on the agent's own repository, and one on
#      the archive;
#   3. those keys' private halves, stored on the mirror as <PREFIX>_SOURCE_KEY
#      and <PREFIX>_ARCHIVE_KEY, and the push token as <PREFIX>_MIRROR_TOKEN.
#
# It does NOT make the clone `just mirror-status` reads. That one is made where
# it is read — host/lib/mirror.sh — because the machine that runs the agent
# needs it and must never run this recipe, and two things making one directory
# is one of them drifting. The archive's clone is not the same case: it is
# written, by `just collect`, and setting it up is a legitimate act on any host.
#
# Step 2 needs *admin* on each repository a key goes on. Without it the key is
# added by hand in a browser and this waits; either way step 3 happens only once
# the new key is proved to read, so a run that cannot finish changes nothing.
#   see docs/monitor.md#the-mirror-is-not-in-the-archive
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

MIRROR_REPO="${AGENT_MIRROR_REPO:?not set — the mirror repository, owner/name, from .env}"
ARCHIVE_REPO="${AGENT_ARCHIVE_REPO:?not set — the archive repository, owner/name, from .env}"

die() { printf '\n%s\n\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }


# --- what the mirror is for ---
# From here down is the workflow's credentials, and every step writes to
# GitHub. The source is the agent's own repository, read out of the clone URL
# rather than named a second time.

# No apostrophe in the message: inside ${var:?word} bash opens a single quote
# even within double quotes, and the script then fails to parse at its last
# line with an error naming neither this line nor the quote.
#   see docs/archive.md#a-quoting-trap-in-three-files
SOURCE=$(printf '%s' "${AGENT_REPO:?not set — the repository the agent commits to, from .env}" \
    | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^https?://[^/]+/##')
WORKFLOW="${AGENT_MIRROR_WORKFLOW:-mirror-$AGENT_USER.yml}"
TOKEN_SECRET="${AGENT_PREFIX}_MIRROR_TOKEN"
TITLE="$MIRROR_REPO mirror (read-only)"

command -v gh >/dev/null || die "gh is not installed."
command -v ssh-keygen >/dev/null || die "ssh-keygen is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"

who=$(gh api user --jq .login)
echo
echo "Authenticated as $who."


# --- Actions on the archive ---
# A workflow cannot request more than the repository grants: with the default
# left at "read", `permissions: contents: write` is ignored and the push fails
# with 403 at the very end of an otherwise successful run.

step "Actions on $MIRROR_REPO"

# Not being able to READ these is a state and not a failure: a host whose token
# is scoped to reading the record cannot ask about its settings, and they are
# very probably already right — set once, from a machine with admin. Saying so
# and going on is what lets this recipe run anywhere.
# The exit status, not the output: `gh api` prints the error BODY to stdout, so
# a substitution keeps `{"message":"Resource not accessible…"}` and every
# comparison against it falls through to the write. Measured 2026-09-09, that is
# how a read this was told to tolerate became a PUT that killed the run.
if enabled=$(gh api "repos/$MIRROR_REPO/actions/permissions" --jq .enabled 2>/dev/null); then
    if [ "$enabled" = "true" ]; then
        echo "Actions already enabled."
    elif gh api -X PUT "repos/$MIRROR_REPO/actions/permissions" -F enabled=true >/dev/null 2>&1; then
        echo "Actions enabled."
    else
        echo "Actions are off and this token cannot turn them on — do that from a host with admin."
    fi
else
    echo "This token cannot read the Actions settings; leaving them alone."
fi

if perm=$(gh api "repos/$MIRROR_REPO/actions/permissions/workflow" --jq .default_workflow_permissions 2>/dev/null); then
    if [ "$perm" = "write" ]; then
        echo "Workflow token already 'write'."
    elif gh api -X PUT "repos/$MIRROR_REPO/actions/permissions/workflow" \
            -f default_workflow_permissions=write \
            -F can_approve_pull_request_reviews=false >/dev/null 2>&1; then
        echo "Workflow token raised from '$perm' to 'write'."
    else
        echo "The workflow token is '$perm' and this token cannot raise it — do that from a host with admin."
    fi
else
    echo "This token cannot read the workflow permission; leaving it alone."
fi


# --- the read keys, on the agent's repository and on the archive ---
# THE ORDER IS THE POINT: the public half goes on the source repository and is
# proved to read it before the private half replaces the secret the mirror is
# running on. A run that cannot finish leaves the working mirror untouched.
#
# Nothing is deleted from here. Keys are immutable, so rotation used to be
# delete-then-add, which destroys the running credential first and cannot run
# at all without admin; superseded keys are named at the end for you to remove.
#   see docs/archive.md#the-key-goes-on-before-the-secret-goes-in

# A key already installed is left alone. It used to make a fresh one every run,
# which turned a re-run into a rotation of the agent's deploy key — and on a
# host that cannot add one, into a run that could never finish. FORCE_KEY=1
# rotates it deliberately, as FORCE_TOKEN=1 rotates the token.

# One directory for every key made here, so one trap removes them all.
keyroot=$(mktemp -d)
trap 'rm -rf "$keyroot"' EXIT

install_read_key() {
    local source="$1" secret="$2" make_key admin keydir pub secrets others n

    step "Read key for $source"

    # Not being able to LIST the secrets is not the same as their being absent, and
    # the difference is a key. A host whose token only reads the record gets 403
    # here, and a test that reads that as "not installed" makes a fresh deploy key
    # on the source repository every run. Unknown means leave it alone.
    # see docs/archive.md#gh-api-prints-its-errors-on-stdout
    if [ "${FORCE_KEY:-}" = 1 ]; then
        make_key=yes
    elif secrets=$(gh secret list --repo "$MIRROR_REPO" 2>/dev/null); then
        if printf '%s\n' "$secrets" | grep -q "^$secret"; then
            echo "$secret is already set. Leaving the key alone."
            echo "  (FORCE_KEY=1 makes a new one — that is what you do when it is compromised.)"
            make_key=no
        else
            make_key=yes
        fi
    else
        echo "This token cannot list the secrets, so whether $secret is installed"
        echo "cannot be known from here. Leaving it alone."
        make_key=no
    fi

    [ "$make_key" = yes ] || return 0

    # Asked before anything is generated, so the run says which path it is on
    # rather than discovering it halfway through.
    admin=$(gh api "repos/$source" --jq '.permissions.admin // false' 2>/dev/null) || admin=false

    keydir=$(mktemp -d "$keyroot/key.XXXXXX")
    ssh-keygen -q -t ed25519 -N '' -C "$TITLE" -f "$keydir/key"
    pub=$(cat "$keydir/key.pub")
    echo "Generated (it lives in a temp dir this script deletes on exit)."

    # The raw API rather than `gh repo deploy-key`: it takes read_only as an
    # explicit argument instead of a default, and its output does not shift between
    # gh versions.
    if [ "$admin" = true ]; then
        gh api "repos/$source/keys" -f title="$TITLE" -f key="$pub" -F read_only=true \
            --jq '"Added key \(.id), read_only=\(.read_only)."'
    else
        cat <<MSG

  $who has no admin on $source, so this half is yours to add. That is the
  normal path when the agent's account is reachable only by browser.

  https://github.com/$source/settings/keys/new

    Title               $TITLE
    Key                 the line below, whole
    Allow write access  LEAVE UNCHECKED — this key only reads

$pub

  Nothing has been changed yet. The mirror is still running on the key it
  has, and stays on it until the check below passes.

MSG
        read -rp "  press enter once the key is added (ctrl-c to abandon) : " _
    fi


    step "Verify the key can read $source"

    # ssh -T against github always exits 1 for a deploy key, so it proves nothing.
    # A ls-remote does: it is exactly what the workflow runs. On every path, and
    # before the secret moves — this check sat inside the API branch until
    # 2026-09-06, which is the one branch that did not need it.
    if GIT_SSH_COMMAND="ssh -i $keydir/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
       git ls-remote --heads "git@github.com:$source.git" main >/dev/null 2>&1; then
        echo "Read access confirmed."
    else
        die "The new key cannot read $source, so it was NOT stored.

Nothing changed: the mirror is still running on whatever key it had. Check the
key landed on $source itself, read-only, and run this again."
    fi


    step "Secret $secret on $MIRROR_REPO"
    gh secret set "$secret" -R "$MIRROR_REPO" < "$keydir/key"
    echo "Set. The mirror now reads $source with this key."

    if [ "$admin" = true ]; then
        others=$(gh api "repos/$source/keys" --jq \
            ".[] | select(.title == \"$TITLE\") | \"  \(.id)  added \(.created_at)\"" 2>/dev/null | head -20)
        n=$(printf '%s\n' "$others" | grep -c . || true)
        if [ "${n:-0}" -gt 1 ]; then
            echo
            echo "$n keys on $source carry this title. The newest is the live one;"
            echo "remove the others when the next mirror run has gone green:"
            printf '%s\n' "$others"
        fi
    else
        echo
        echo "Remove any older key with this title at"
        echo "https://github.com/$source/settings/keys once the next run is green."
    fi
}

install_read_key "$SOURCE" "${AGENT_PREFIX}_SOURCE_KEY"
install_read_key "$ARCHIVE_REPO" "${AGENT_PREFIX}_ARCHIVE_KEY"


# --- the token the mirror pushes with ---
# Not secrets.GITHUB_TOKEN, and it cannot be: an Actions token may never push a
# commit that creates or updates a file under .github/workflows/, and there is
# no permission that allows it — the restriction follows the file and not the
# ref, so moving the mirror out of refs/heads/* does not avoid it. Nor can one
# be minted from the API, fine-grained tokens being a UI-only flow, so this asks
# for one rather than creating it.
#   see docs/archive.md#the-workflow-token-cannot-be-the-actions-token

step "The token the mirror pushes with"

skip_token=false
# The same distinction as the key above: 403 is not "absent".
if secrets=$(gh secret list --repo "$MIRROR_REPO" 2>/dev/null); then
    if printf '%s\n' "$secrets" | grep -q "^$TOKEN_SECRET"; then
        echo "$TOKEN_SECRET is already set. Leaving it alone."
        echo "  (FORCE_TOKEN=1 replaces it — that is what you do when it expires.)"
        [ "${FORCE_TOKEN:-}" = 1 ] || skip_token=true
    fi
else
    echo "This token cannot list the secrets, so whether $TOKEN_SECRET is installed"
    echo "cannot be known from here. Leaving it alone."
    skip_token=true
fi

if [ "$skip_token" != true ]; then
    owner=$(printf '%s' "$MIRROR_REPO" | cut -d/ -f1)
    cat <<TEXT

  AS $owner, NOT AS THE AGENT'S ACCOUNT. Check the avatar before you start:
  the deploy key step above asks you to log in as the account that owns
  $SOURCE, and if you are still signed in as it, "$owner" will not be in the
  Resource owner list and $MIRROR_REPO will not be in the repository list.
  That reads as "the repository is missing" and is really "you are the wrong
  person".

  The two credentials this workflow holds point opposite ways and belong to
  opposite accounts. The deploy key READS the agent's repository and is the
  agent's, because a deploy key needs admin there. This token WRITES the
  archive and is the operator's, because the agent has no access here — and
  must not: a token that writes this repository is a token that writes the
  place every other secret is kept.

  https://github.com/settings/personal-access-tokens/new

    Token name          anything, e.g. $MIRROR_REPO mirror
    Resource owner      $owner
    Repository access   Only select repositories -> $MIRROR_REPO
    Permissions         Contents:  Read and write
                        Workflows: Read and write
                        (Metadata: Read-only is added for you)

  ONE repository, not "All repositories". This token can write the repository
  that holds every other secret here, so its reach is worth keeping to the one
  thing it has to touch.

  It EXPIRES, and the mirror stops dead when it does — check-credentials.yml
  reads the expiry off a response header for exactly that reason.

TEXT
    read -rsp "  paste the token : " TOKEN; echo
    [ -n "$TOKEN" ] || die "the token is required."

    if ! GH_TOKEN="$TOKEN" gh api "repos/$MIRROR_REPO" --jq .full_name >/dev/null 2>&1; then
        die "that token cannot read $MIRROR_REPO. Check the resource owner and the
repository selection."
    fi
    echo "  reads $MIRROR_REPO: ok"

    # -i, because the expiry is a response header and nothing else reports it.
    # -i and --jq do not combine: -i puts the headers into the body --jq is
    # handed. Two calls, each asking one thing.
    exp=$(GH_TOKEN="$TOKEN" gh api -i "repos/$MIRROR_REPO" 2>/dev/null \
          | sed -n 's/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *//p' | tr -d '\r')
    if [ -n "$exp" ]; then
        echo "  expires: $exp"
    else
        echo "  NO EXPIRY HEADER — this is a classic token, not the fine-grained"
        echo "  one asked for, and almost certainly far broader than one"
        echo "  repository. Storing it; replace it when you can."
    fi

    # Whether it may push a workflow file is the half no read can prove, and it
    # is the half this exists for: a token with Contents and without Workflows
    # passes everything above and fails only at the first run after the agent
    # touches a workflow file. The mirror run in "Left to do" settles it.
    #
    # Stdin, and no --body flag: `gh secret set` reads standard input when
    # --body is absent, and `--body -` would store the literal string "-".
    printf '%s' "$TOKEN" | gh secret set "$TOKEN_SECRET" --repo "$MIRROR_REPO"
    echo "  $TOKEN_SECRET set."
fi

cat <<MSG

== Left to do

  1. Seed the mirror's own default branch from examples/mirror/, or bring it
     up to date — the workflow and scripts/mirror-ref.sh: a workflow only
     exists once it is on that branch.
  2. Run it once by hand and read what it prints. This is also what proves the
     token carries Workflows and not only Contents:
     gh workflow run $WORKFLOW --repo $MIRROR_REPO
  3. Read the record — it is NOT a branch and is invisible on github.com:
     just mirror-status
  4. Give each host its own access to it, including this one:
     just setup-gh

MSG
