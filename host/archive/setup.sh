#!/usr/bin/env bash
# One-time setup for the archive: the clone this host reads and writes, and the
# credentials its mirror workflow runs on. Idempotent — safe to re-run.
#
# Runs on the host, with the operator's own credentials. Nothing about it is the
# container's, and the agent is never told any of it. It touches four things:
#
#   1. the archive clone at AGENT_ARCHIVE, cloned from AGENT_ARCHIVE_REPO when
#      it is not there;
#   2. that repository's Actions token, which defaults to read-only and cannot
#      be raised by the workflow's own `permissions:` block;
#   3. a fresh read-only deploy key on the agent's own repository;
#   4. that key's private half, stored on the archive as <PREFIX>_SOURCE_KEY.
#
# Step 3 needs *admin* on the agent's repository. Without it the key is added by
# hand in a browser and this waits; either way step 4 happens only once the new
# key is proved to read, so a run that cannot finish changes nothing.
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

# The two records live on refs the default refspec never fetches — one orphan
# branch and one ref outside refs/heads/*. Asked for by name here, once, so
# `just sessions` and `just mirror` have something to read.
git -C "$ARCHIVE" fetch --quiet origin '+refs/archive/*:refs/archive/*' 2>/dev/null \
    || echo "No refs/archive/* on origin yet — the mirror has not run."


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
WORKFLOW="${AGENT_ARCHIVE_WORKFLOW:-mirror-$AGENT_USER.yml}"
KEY_SECRET="${AGENT_PREFIX}_SOURCE_KEY"
TOKEN_SECRET="${AGENT_PREFIX}_ARCHIVE_TOKEN"
TITLE="$ARCHIVE_REPO mirror (read-only)"

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

step "Actions on $ARCHIVE_REPO"

enabled=$(gh api "repos/$ARCHIVE_REPO/actions/permissions" --jq .enabled)
if [ "$enabled" != "true" ]; then
    gh api -X PUT "repos/$ARCHIVE_REPO/actions/permissions" -F enabled=true
    echo "Actions enabled."
else
    echo "Actions already enabled."
fi

perm=$(gh api "repos/$ARCHIVE_REPO/actions/permissions/workflow" --jq .default_workflow_permissions)
if [ "$perm" != "write" ]; then
    gh api -X PUT "repos/$ARCHIVE_REPO/actions/permissions/workflow" \
        -f default_workflow_permissions=write \
        -F can_approve_pull_request_reviews=false >/dev/null
    echo "Workflow token raised from '$perm' to 'write'."
else
    echo "Workflow token already 'write'."
fi


# --- the read key on the agent's repository ---
# THE ORDER IS THE POINT: the public half goes on the agent's repository and is
# proved to read it before the private half replaces the secret the mirror is
# running on. A run that cannot finish leaves the working mirror untouched.
#
# Nothing is deleted from here. Keys are immutable, so rotation used to be
# delete-then-add, which destroys the running credential first and cannot run
# at all without admin; superseded keys are named at the end for you to remove.
#   see docs/archive.md#the-key-goes-on-before-the-secret-goes-in

step "Read key for $SOURCE"

# Asked before anything is generated, so the run says which path it is on
# rather than discovering it halfway through.
admin=$(gh api "repos/$SOURCE" --jq '.permissions.admin // false' 2>/dev/null || echo false)

keydir=$(mktemp -d)
trap 'rm -rf "$keydir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "$TITLE" -f "$keydir/key"
pub=$(cat "$keydir/key.pub")
echo "Generated (it lives in a temp dir this script deletes on exit)."

# The raw API rather than `gh repo deploy-key`: it takes read_only as an
# explicit argument instead of a default, and its output does not shift between
# gh versions.
if [ "$admin" = true ]; then
    gh api "repos/$SOURCE/keys" -f title="$TITLE" -f key="$pub" -F read_only=true \
        --jq '"Added key \(.id), read_only=\(.read_only)."'
else
    cat <<MSG

  $who has no admin on $SOURCE, so this half is yours to add. That is the
  normal path when the agent's account is reachable only by browser.

  https://github.com/$SOURCE/settings/keys/new

    Title               $TITLE
    Key                 the line below, whole
    Allow write access  LEAVE UNCHECKED — this key only reads

$pub

  Nothing has been changed yet. The mirror is still running on the key it
  has, and stays on it until the check below passes.

MSG
    read -rp "  press enter once the key is added (ctrl-c to abandon) : " _
fi


step "Verify the key can read $SOURCE"

# ssh -T against github always exits 1 for a deploy key, so it proves nothing.
# A ls-remote does: it is exactly what the workflow runs. On every path, and
# before the secret moves — this check sat inside the API branch until
# 2026-09-06, which is the one branch that did not need it.
if GIT_SSH_COMMAND="ssh -i $keydir/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
   git ls-remote --heads "git@github.com:$SOURCE.git" main >/dev/null 2>&1; then
    echo "Read access confirmed."
else
    die "The new key cannot read $SOURCE, so it was NOT stored.

Nothing changed: the mirror is still running on whatever key it had. Check the
key landed on $SOURCE itself, read-only, and run this again."
fi


step "Secret $KEY_SECRET on $ARCHIVE_REPO"
gh secret set "$KEY_SECRET" -R "$ARCHIVE_REPO" < "$keydir/key"
echo "Set. The mirror now reads $SOURCE with this key."

if [ "$admin" = true ]; then
    others=$(gh api "repos/$SOURCE/keys" --jq \
        ".[] | select(.title == \"$TITLE\") | \"  \(.id)  added \(.created_at)\"" 2>/dev/null | head -20)
    n=$(printf '%s\n' "$others" | grep -c . || true)
    if [ "${n:-0}" -gt 1 ]; then
        echo
        echo "$n keys on $SOURCE carry this title. The newest is the live one;"
        echo "remove the others when the next mirror run has gone green:"
        printf '%s\n' "$others"
    fi
else
    echo
    echo "Remove any older key with this title at"
    echo "https://github.com/$SOURCE/settings/keys once the next run is green."
fi


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
if gh secret list --repo "$ARCHIVE_REPO" 2>/dev/null | grep -q "^$TOKEN_SECRET"; then
    echo "$TOKEN_SECRET is already set. Leaving it alone."
    echo "  (FORCE_TOKEN=1 replaces it — that is what you do when it expires.)"
    [ "${FORCE_TOKEN:-}" = 1 ] || skip_token=true
fi

if [ "$skip_token" != true ]; then
    owner=$(printf '%s' "$ARCHIVE_REPO" | cut -d/ -f1)
    cat <<TEXT

  AS $owner, NOT AS THE AGENT'S ACCOUNT. Check the avatar before you start:
  the deploy key step above asks you to log in as the account that owns
  $SOURCE, and if you are still signed in as it, "$owner" will not be in the
  Resource owner list and $ARCHIVE_REPO will not be in the repository list.
  That reads as "the repository is missing" and is really "you are the wrong
  person".

  The two credentials this workflow holds point opposite ways and belong to
  opposite accounts. The deploy key READS the agent's repository and is the
  agent's, because a deploy key needs admin there. This token WRITES the
  archive and is the operator's, because the agent has no access here — and
  must not: a token that writes this repository is a token that writes the
  place every other secret is kept.

  https://github.com/settings/personal-access-tokens/new

    Token name          anything, e.g. $ARCHIVE_REPO mirror
    Resource owner      $owner
    Repository access   Only select repositories -> $ARCHIVE_REPO
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

    if ! GH_TOKEN="$TOKEN" gh api "repos/$ARCHIVE_REPO" --jq .full_name >/dev/null 2>&1; then
        die "that token cannot read $ARCHIVE_REPO. Check the resource owner and the
repository selection."
    fi
    echo "  reads $ARCHIVE_REPO: ok"

    # -i, because the expiry is a response header and nothing else reports it.
    # -i and --jq do not combine: -i puts the headers into the body --jq is
    # handed. Two calls, each asking one thing.
    exp=$(GH_TOKEN="$TOKEN" gh api -i "repos/$ARCHIVE_REPO" 2>/dev/null \
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
    printf '%s' "$TOKEN" | gh secret set "$TOKEN_SECRET" --repo "$ARCHIVE_REPO"
    echo "  $TOKEN_SECRET set."
fi

cat <<MSG

== Left to do

  1. Push the archive repository — a scheduled workflow only exists once it is
     on the default branch:  git -C $ARCHIVE push -u origin main
  2. Run it once by hand and read what it prints. This is also what proves the
     token carries Workflows and not only Contents:
     gh workflow run $WORKFLOW --repo $ARCHIVE_REPO
  3. Read the mirror — it is NOT a branch and is invisible on github.com:
     just mirror

MSG
