#!/usr/bin/env bash
# The test environment — an empty home every time, and never the agent's.
#
# Runs on the host. Same image, same environment, same hardening as a real
# session; the only difference is that this service has no volume, so
# /home/<agent> is the image's own and goes away with the container. That is
# what makes it honest: a rehearsal against a home that already holds a key and
# a login proves nothing about the morning the volume is gone.
#
# Nothing runs the agent in here. It is for the questions that come before a
# session — does the container start, can the login be restored without a
# browser, can the key be restored without adding a new one to the account. The
# entrypoint stops at exit 78 on an empty home, which is the correct answer and
# an unhelpful one when you want to look around: prefix `AGENT_SKIP_CLONE=1` and
# it reports what it found and hands over anyway.
#
# It parses its own --build rather than taking a declared flag: everything after
# it is the command to run in the container, with options of its own, and `just`
# would refuse `just test-container bash -l` as an unknown `-l`.
# see docs/sessions.md#the-test-twin
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"


# --- the candidate, always ---
# This is a rehearsal, and testing runs what is built and not what is live.
# --build builds it first.

build=false
case "${1:-}" in --build) build=true; shift ;; esac

if [ "$build" = true ]; then just build || exit $?; fi

export RUNNER_IMAGE="$RUNNER_IMAGE_CANDIDATE"
host/lib/docker-up.sh --image "$RUNNER_IMAGE" || exit $?


# --- the container ---
# No lock and no collection: this container spends no budget and touches no
# shared state, so a rehearsal must not stand a real session down, and its
# transcripts die with it. With no command, the image's own `bash -l`.

docker compose run --rm agent-test "$@"
