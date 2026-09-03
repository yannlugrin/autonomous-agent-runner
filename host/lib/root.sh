# shellcheck shell=bash
# One way to find the checkout, and the working directory every host script
# runs in.
#
# Sourced on the first line of every script under host/. It resolves its own
# location rather than the caller's, so a script may sit at any depth under
# host/ and still get the same answer, and it cds there: a script run by hand
# from somewhere else must not read a different tree than the one it belongs to.
#
# The checkout is not always the project root. The deployed checkout is a
# worktree at `deployed/` inside the project, with its own copy of this tree;
# RUNNER_ROOT — exported by the justfile — is the project above it, and is what
# AGENT_ARCHIVE and RUNNER_DEPLOYED are derived from. This is the other one:
# the files this script was shipped beside.
# see docs/sessions.md#the-checkout-is-not-always-the-project-root

RUNNER_CHECKOUT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

cd "$RUNNER_CHECKOUT" || exit 1
