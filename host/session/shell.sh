#!/usr/bin/env bash
# A shell in the container, for bootstrap and for looking around.
#
# Runs on the host. No arguments.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh


# --- always the live runner ---
# The live runner is the deployed checkout: see host/lib/deployed.sh. A candidate
# is looked inside with `just test-container`.

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    forward_to_deployed shell
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
