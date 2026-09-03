#!/usr/bin/env bash
# Create .venv, install the pinned lint tooling, and make this installation's
# own configuration files.
#
# Runs on the host. One declared flag arrives as an environment variable:
# restore.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
# shellcheck source=SCRIPTDIR/../lib/config-files.sh
. host/lib/config-files.sh


# --- the lint set ---
# Nothing is installed outside this project: the versions are pinned in
# requirements-dev.txt, and `just lint`, the pre-commit hook and CI all run
# those same ones, so a hook and a command cannot differ.
# see docs/release.md#setup-the-project-local-venv-and-the-lint-set

if [ ! -d .venv ]; then
    python3 -m venv .venv
fi

.venv/bin/pip install -q -r requirements-dev.txt
.venv/bin/pre-commit install

echo "setup: .venv ready (ruff, mypy, pre-commit), hook installed"


# --- this installation's own files ---
# Made from their committed examples, and only when absent: an edit is yours,
# and this recipe is run again after every pull. Silent when all three are
# there, because a line printed on every run is a line nobody reads on the day
# it says something.
# see docs/configuration.md#the-three-files-that-are-yours

missing=()
for name in "${CONFIG_FILES[@]}"; do
    [ -e "image/config/$name" ] || missing+=("$name")
done

if [ ${#missing[@]} -eq 0 ]; then
    exit 0
fi


# --- where they come from ---
# The examples, or --restore for the copies `just deploy` puts on the archive's
# `config` branch: the files are untracked, so a machine that lost them has no
# other copy, and the branch holds what was live at the last deploy.
#
# Local first, then origin — the same three cases, in the same order, that the
# archive's other branch writers handle. see docs/archive.md#the-config-branch

ref=""
if [ "$restore" = yes ]; then
    archive="${AGENT_ARCHIVE:?not set — run this through 'just', which computes it}"
    if [ ! -d "$archive/.git" ]; then
        echo "setup: --restore reads the archive at $archive, and there is no clone there. 'just setup-archive' makes one." >&2
        exit 1
    fi
    git -C "$archive" fetch --quiet origin config 2>/dev/null || true
    for candidate in refs/heads/config refs/remotes/origin/config; do
        if git -C "$archive" show-ref --quiet --verify "$candidate"; then ref="$candidate"; break; fi
    done
    if [ -z "$ref" ]; then
        echo "setup: no 'config' branch in $archive — nothing has been backed up there yet, so the examples are all there is." >&2
        exit 1
    fi
fi

for name in "${missing[@]}"; do
    if [ -n "$ref" ] && git -C "$archive" show "$ref:$name" > "image/config/$name.part" 2>/dev/null; then
        mv "image/config/$name.part" "image/config/$name"
        echo "setup: image/config/$name restored from the archive's config branch"
    else
        # A `git show` that failed left a truncated file behind; the example is
        # the answer either way, and saying which one it was is the point.
        rm -f "image/config/$name.part"
        cp "image/config/${name%.txt}.example.txt" "image/config/$name"
        echo "setup: image/config/$name created from image/config/${name%.txt}.example.txt — edit it before you build"
    fi
done
