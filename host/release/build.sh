#!/usr/bin/env bash
# Build the image as the candidate — nothing runs it until `just deploy`.
#
# Runs on the host. One declared flag arrives as an environment variable: live.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"


# --- which tag ---
# `--deployed` tags the live image instead of the candidate, and `just deploy`
# is its only caller. Refused anywhere but the deployed checkout, because that
# checkout is the build context: run here it would build the tree under edit and
# tag it live. see docs/release.md#deploy-builds-and-does-not-retag

if [ "$deployed" = yes ]; then
    tag="$RUNNER_IMAGE_DEPLOYED"
else
    tag="$RUNNER_IMAGE_CANDIDATE"
fi

if [ "$deployed" = yes ] && [ "$RUNNER_IS_DEPLOYED" != yes ]; then
    echo "--deployed builds straight onto the live tag and belongs to the deployed checkout; 'just deploy' is what runs it." >&2
    exit 2
fi


# --- this installation's own files ---
# They are untracked, so a fresh clone has none of them and the COPY that wants
# them fails with docker's account of a build context rather than with the one
# sentence that fixes it.
# see docs/configuration.md#the-three-files-that-are-yours

# shellcheck source=SCRIPTDIR/../lib/config-files.sh
. host/lib/config-files.sh

missing=""
for name in "${CONFIG_FILES[@]}"; do
    [ -e "image/config/$name" ] || missing="$missing image/config/$name"
done

if [ -n "$missing" ]; then
    echo "This installation's own configuration is missing:$missing" >&2
    echo "'just setup' makes each from its committed .example.txt. Edit them, then build." >&2
    exit 1
fi


# --- the classifier rules ---
# The autoMode block is baked into the image inside managed-settings.json, so a
# document that disagrees with it ships rules nobody reviewed. It also rebuilds
# from auto-mode/ and compares, because a fix typed into either output is erased
# by the next build with no symptom.
# see docs/release.md#check-auto-mode-and-the-sibling-it-outlived

host/release/check-auto-mode.py

host/lib/docker-up.sh || exit $?


# --- what this image is built from ---
# Measured here because nothing inside the build can: the context is image/ and
# carries no .git. It travels as a build argument into the image's last layer
# and reaches a session in its environment header, so a session can name its own
# version without comparing anything.
#
# The checkout being built and not the project root, since `--deployed` runs in
# the deployed checkout. Empty on a tree that is not a repository, which reads
# downstream as "the image does not say".
# see docs/image.md#what-the-image-was-built-from

export RUNNER_COMMIT
RUNNER_COMMIT="$(git -C "$RUNNER_CHECKOUT" rev-parse --short HEAD 2>/dev/null || true)"

# UTC and the same shape as every other instant a session is told, rather than
# git's default local time with an offset.
export RUNNER_COMMITTED_AT
RUNNER_COMMITTED_AT="$(TZ=UTC git -C "$RUNNER_CHECKOUT" show -s \
    --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ HEAD 2>/dev/null || true)"


# --- the build ---
# Compose tags what it builds with its `image:`, and left to itself that is the
# deployed tag — see compose.yaml — so the tag is always named here.
#
# `--progress auto` is the one override of the quiet set in the justfile: which
# layers were cached is how you see whether a pin actually reinstalled, and a
# silent build that exits zero is the shape of failure this process is written
# against. see docs/release.md#what-the-image-was-built-from

RUNNER_IMAGE="$tag" docker compose --progress auto build

if [ "$deployed" = yes ]; then
    echo "Built $tag from $PWD."
else
    echo "Built $tag. 'just verify' proves it; 'just deploy' makes it live."
fi
