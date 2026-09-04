#!/usr/bin/env bash
# Pin the base image to its current digest, in the Dockerfile. Runs on the
# host, no arguments.
#
# Guarded because the agent wrote the script that edits the file defining its
# own confinement: the pin lands alone, it never commits, and what it produces
# is a diff for you to read rather than take.
# see docs/release.md#the-two-pins
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

if [ -n "$(git status --porcelain image/Dockerfile)" ]; then
    echo "Dockerfile has uncommitted changes. Resolve them first so the pin lands alone." >&2
    exit 1
fi

# The daemon is needed to resolve a digest, not to ask npm for a version.
case " $* " in *" --claude "*) ;; *) host/lib/docker-up.sh || exit $? ;; esac
host/release/pin.py "$@"

echo
git --no-pager diff -- image/Dockerfile
echo
echo "Nothing was committed. Read the diff, then commit it yourself."
