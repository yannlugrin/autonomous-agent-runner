#!/usr/bin/env bash
# What `just verify` proves, in order. The running order and the choice of
# image, and nothing else: every probe lives in host/verify/<section>.sh, and
# the vocabulary they all speak — verdict, verdicts_from, sees, need, spare —
# in host/verify/lib.sh.
#
# The sections are sourced, never executed: the counters and the summary's two
# lists are shell variables, and a section in its own process would count its
# verdicts where nothing reads them.
#
# Runs on the host. Two declared flags arrive as environment variables: build,
# deployed. see docs/verify.md#the-running-order

# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail


# --- where this runs ---
# The checkout this justfile belongs to. Every path below is relative to it, as
# a recipe body's would be, and `git rev-parse` in image-commit.sh answers for
# this tree rather than for wherever `just` was typed.

# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

# `just` computes AGENT_USER and exports it, and compose requires it. Said here
# rather than left to compose's eleven interpolation errors, which are the
# correct complaint and not a readable one.

if [ -z "${AGENT_USER:-}" ]; then
    echo "AGENT_USER is unset — run this through 'just verify', which computes and exports it." >&2
    exit 2
fi


# --- which image ---
# Ahead of everything: verify run against a stale image proves the image you
# replaced, in the words it uses when everything is right.
#
# The candidate, not what is live — proving is what stands between a build and
# a deploy. --deployed asks the same of what cron runs; --build runs what it
# just built. Exported, so every `docker compose run` below — the twin
# included — is on the image chosen here.
#
# see docs/verify.md#the-candidate-and-the-stale-image-failure

if [ "$build" = yes ]; then
    just build || exit $?
    which="$RUNNER_IMAGE_CANDIDATE"
elif [ "$deployed" = yes ]; then
    which="$RUNNER_IMAGE_DEPLOYED"
else
    which="$RUNNER_IMAGE_CANDIDATE"
fi

if ! docker image inspect "$which" >/dev/null 2>&1; then
    echo "No image tagged $which. 'just build' makes the candidate; 'just verify --build' does both." >&2
    exit 1
fi

export RUNNER_IMAGE="$which"
echo "image: $which"


# --- what every section shares ---

. host/verify/lib.sh

# The model a session is asked to run on — <NAME>_MODEL in .env, `sonnet` unless
# set, which the build renders into managed settings. Read once because two
# sections compare against it: the served model in session.sh, and what the
# system prompt tells a session in prompt.sh.

want="${AGENT_MODEL:-sonnet}"


# --- the sections, in order ---

. host/verify/host-tools.sh

# After the table and not inside it: the table is worth reading whole even on
# a machine where the daemon is down, and everything below needs the daemon.

host/lib/docker-up.sh || exit $?
echo

. host/verify/mechanical.sh
. host/verify/image-commit.sh
. host/verify/claude-code.sh
. host/verify/budget.sh
. host/verify/session.sh
. host/verify/prompt.sh


# --- summary ---
# Everything above scrolls; this does not, and it repeats every line that is
# not ok so a failure cannot be the one thing that went past while the build
# output was still printing. Non-zero on a failure, so cron and a pre-deploy
# check read the same answer a human does.
# see docs/verify.md#the-verdict-vocabulary

echo
echo "== summary =="
printf '  %d checks: %d ok, %d to look at, %d failed\n' \
    "$((verdict_ok + verdict_look + verdict_fail))" "$verdict_ok" "$verdict_look" "$verdict_fail"

if [ -n "$look_lines" ]; then
    echo
    echo "  Needs your eyes — each is a state only you can rule on, not a defect:"
    while IFS= read -r line; do tinted "$line"; done <<< "${look_lines%$'\n'}"
fi

if [ -n "$fail_lines" ]; then
    echo
    echo "  FAILED — each of these is a mechanism not doing its job:"
    while IFS= read -r line; do tinted "$line"; done <<< "${fail_lines%$'\n'}"
    echo
    echo "  Do not deploy on this."
    exit 1
fi

echo
echo "  Nothing failed. 'just deploy' is what makes this image live."
