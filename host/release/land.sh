#!/usr/bin/env bash
# Put what was pushed and shipped into service, on the machine the agent runs on.
#
# Runs on that machine, and only ever because `just deploy` on the machine that
# builds ran it over ssh: RUNNER_SHIPPED_ID is set by that call and by nothing
# else, and its absence is what tells a hand on the wrong terminal from the far
# half of a deploy.
#
# It is `deploy`'s other half and not `deploy` itself because the two mean
# opposite things by the same names. There, HEAD is new and `deployed` is what
# is live; here, `deployed` is what has just arrived and the working tree is
# what is still live. One script holding both would be one script whose
# variables mean the reverse of themselves depending on which machine reads it.
# see docs/release.md#the-tag-flip-is-the-deploy
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

here="$RUNNER_CHECKOUT"
incoming="$RUNNER_IMAGE_INCOMING"
deployed="$RUNNER_IMAGE_DEPLOYED"

[ -n "${RUNNER_SHIPPED_ID:-}" ] || {
    echo "'just land' is the far half of a deploy and is run by the machine that builds." >&2
    echo "Nothing here starts a release: deploy from the machine the code is edited on." >&2
    exit 1; }


# --- what arrived, before anything is held ---
# Both checks are cheap and neither touches what is running, so they come before
# the schedule is paused: a refusal here costs nothing and leaves the machine
# exactly as it was.

arrived=$(docker images -q --no-trunc "$incoming" 2>/dev/null | head -1)
if [ "$arrived" != "$RUNNER_SHIPPED_ID" ]; then
    echo "The image here is not the one that was shipped:" >&2
    echo "  here:    ${arrived:-nothing tagged $incoming}" >&2
    echo "  shipped: $RUNNER_SHIPPED_ID" >&2
    exit 1
fi

want=$(git -C "$here" rev-parse --short refs/heads/deployed 2>/dev/null) || want=""
[ -n "$want" ] || { echo "No 'deployed' branch here: the push did not arrive." >&2; exit 1; }

# The image's own account of what it was built from, against the commit that is
# about to become the working tree. The id above says the image is the one that
# was proved; this says the code beside it will be the code it was built from.
# see docs/release.md#the-id-and-the-commit-answer-different-questions
built_from=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$incoming" 2>/dev/null \
    | sed -n 's/^AGENT_RUNNER_COMMIT=//p' | head -1)
if [ -z "$built_from" ] || [ "$built_from" != "$want" ]; then
    echo "The image and the branch that arrived name different commits:" >&2
    echo "  image built from: ${built_from:-the image does not say}" >&2
    echo "  branch deployed:  $want" >&2
    exit 1
fi

# Nothing writes here, so a dirty tree is somebody having edited the machine by
# hand. Refused rather than reset over: this is the one thing the reset below
# would destroy without trace.
dirty=$(git -C "$here" status --porcelain 2>/dev/null)
if [ -n "$dirty" ]; then
    echo "The working tree here has been edited, and landing would discard it:" >&2
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    exit 1
fi


# --- the schedule, held for the length of the change ---
# A session started between the tree moving and the tag flipping would run new
# code on the old image. Paused first, enabled again only when both have
# happened and agree; a failure in between leaves it paused and says so.
# see docs/release.md#the-schedule-is-held-for-the-duration

sched=$(just schedule --state 2>/dev/null | sed -n 's/^state: //p')
resume=no
if [ "$sched" = enabled ]; then
    just schedule --pause >/dev/null || { echo "Could not pause the schedule; nothing landed." >&2; exit 1; }
    resume=yes
fi

# shellcheck disable=SC2329  # invoked by the EXIT trap below
finish() {
    if [ $? -ne 0 ] && [ "$resume" = yes ]; then
        echo "SCHEDULE_LEFT_PAUSED — the schedule here was paused to land this and is left paused: the line above says what stopped. Fix it and deploy again, or 'just schedule --enable' to run what is there." >&2
    fi
}
trap finish EXIT

was=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo "nothing")

# `--detach`, so no branch is ever current here: that is what lets the next
# deploy push `deployed` into this repository at all. `clean -fdq` takes any
# untracked file that appeared and leaves what is ignored, which is where `.env`
# lives. see docs/release.md#reset-not-merge
# A && B || C is what is meant here: either failing is the same refusal.
# shellcheck disable=SC2015
git -C "$here" checkout --detach --quiet refs/heads/deployed \
    && git -C "$here" clean -fdq || {
    echo "Could not move the working tree to $want; nothing was flipped and the old image is still live." >&2
    exit 1; }

docker tag "$incoming" "$deployed" || {
    echo "The tree moved to $want and the image tag did not: the pair disagree, and the schedule is paused." >&2
    exit 1; }


# --- what actually went live ---
# Read back rather than assumed: the two commands above each report success, and
# neither proves the pair a session will start on.

live_image=$(docker images -q --no-trunc "$deployed" 2>/dev/null | head -1)
live_tree=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo "")
if [ "$live_image" != "$RUNNER_SHIPPED_ID" ] || [ "$live_tree" != "$want" ]; then
    echo "The pair that is live is not the one that was landed:" >&2
    echo "  image: ${live_image:-none} (wanted $RUNNER_SHIPPED_ID)" >&2
    echo "  tree:  ${live_tree:-unreadable} (wanted $want)" >&2
    exit 1
fi

echo "Landed: $was -> $want, image ${live_image#sha256:}."

just schedule --relocate || {
    echo "SCHEDULE_NOT_RELOCATED — the crontab still names another directory; 'just schedule' shows it." >&2
    exit 1; }

if [ "$resume" = yes ]; then
    just schedule --enable >/dev/null || { echo "Could not enable the schedule again." >&2; exit 1; }
    echo "The schedule is enabled again."
fi

# Here and nowhere else, because this is the moment a configuration change takes
# effect. Not fatal: it is live, and a backup that did not reach origin is worth
# a line rather than an exit code someone reads as a failed landing.
# see docs/archive.md#the-config-branch
host/release/config-backup.sh \
    || echo "CONFIG_NOT_BACKED_UP — this is live; the line above says what stopped the backup." >&2

exit 0
