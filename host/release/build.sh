#!/usr/bin/env bash
# Build the image as the candidate — nothing runs it until `just deploy`.
#
# Runs on the host. No arguments. Always the candidate: only `just deploy` moves
# the live tag, and only onto an image it built and proved.
# see docs/release.md#deploy-builds-and-does-not-retag
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

tag="$RUNNER_IMAGE_CANDIDATE"


# --- not on the machine that only runs ---
# The image is built where the code is edited and reaches this host by
# `docker save | ssh docker load`, so a build here would produce a second image
# nobody proved, on a machine sized to run one session and not to compile.
# see docs/release.md#the-runtime-host-originates-nothing

if [ "${RUNNER_RUNTIME_ONLY:-}" = true ]; then
    echo "This machine runs the agent; the image is built where the code is edited" >&2
    echo "and shipped here by 'just deploy' there." >&2
    exit 1
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
# The checkout being built and not the project root, since `deploy` builds in
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

# When that commit reached origin, from this checkout's remote-tracking reflog:
# git writes an entry there the instant a push succeeds, and only a push counts
# — a fetch entry would date this host's pull. Empty on a host that does not
# push, which is a state and not a gap: the image was built where nothing goes
# to origin, and a session on it ran code that may never have got there.
#
# No `exit` in the awk: a match closes the pipe under a `git` still writing, and
# `set -o pipefail` reads that SIGPIPE as the build failing. A reflog is small
# enough to read whole. see docs/release.md#the-first-match-cannot-close-the-pipe
# see docs/image.md#what-the-image-was-built-from
export RUNNER_PUSHED_AT
RUNNER_PUSHED_AT="$(TZ=UTC git -C "$RUNNER_CHECKOUT" reflog show \
    --date=format-local:%Y-%m-%dT%H:%M:%SZ --format='%H %gd %gs' \
    refs/remotes/origin/main 2>/dev/null \
    | awk -v s="$(git -C "$RUNNER_CHECKOUT" rev-parse HEAD 2>/dev/null)" \
        '$1 == s && /update by push$/ && !found { print $2; found = 1 }' \
    | sed -E 's/.*\{(.*)\}$/\1/')"


# --- the build ---
# Compose tags what it builds with its `image:`, and left to itself that is the
# deployed tag — see compose.yaml — so the tag is always named here.
#
# `--progress auto` is the one override of the quiet set in the justfile: which
# layers were cached is how you see whether a pin actually reinstalled, and a
# silent build that exits zero is the shape of failure this process is written
# against. see docs/release.md#what-the-image-was-built-from

RUNNER_IMAGE="$tag" docker compose --progress auto build

echo "Built $tag from $PWD. 'just verify' proves it."
