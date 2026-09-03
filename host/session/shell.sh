#!/usr/bin/env bash
# A shell in the container, for bootstrap and for looking around.
#
# Runs on the host. One declared flag arrives as an environment variable:
# build.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh


# --- which image, and which checkout ---
# Without --build this is the live runner, and the live runner is the deployed
# checkout: see host/lib/deployed.sh. With it, this is testing, which runs what
# it built — the candidate, for this invocation only.
# see docs/sessions.md#the-build-flag-left-run-and-chat

if [ "$RUNNER_IS_DEPLOYED" = no ] && [ "$build" = no ]; then
    forward_to_deployed shell
fi

if [ "$build" = yes ]; then
    just build || exit $?
    export RUNNER_IMAGE="$RUNNER_IMAGE_CANDIDATE"
fi

host/lib/docker-up.sh --image "${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}" || exit $?


# --- the same world a session sees ---
# The environment `run` and `chat` build, and for the reason they build it: a
# session started by hand from this shell is a session, and it should not see a
# different world than one started for it. Running `claude` in here goes around
# the budget guard exactly as --ignore-budget does.
#
# The verdict is ignored, as `chat` ignores it: a shell is the operator at a
# keyboard spending their own quota deliberately. It costs a usage read and a
# schedule read before the prompt appears. No collection afterwards: a shell
# produces no transcript.
# see docs/sessions.md#where-the-budget-verdict-is-read-and-where-it-is-not

source host/lib/session-env.sh

docker compose run --rm "${SESSION_ENV[@]}" agent bash -l
