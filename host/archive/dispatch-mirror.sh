#!/usr/bin/env bash
# Ask the archive's mirror workflow to run, now that a session has ended.
#
# Runs on the host, on the operator's `gh` credential — the container has no
# part in this and is not told about it. It dispatches a workflow in the
# operator's own archive repository; nothing here reads or writes the agent's.
#
# The mirror's schedule is its fidelity knob and its only one: a rewrite
# upstream can only be preserved back to the last run, and GitHub runs schedules
# on a best-effort basis. A session end is the moment the memory actually moved,
# so it is the moment worth asking on, and the only one this host knows about
# that GitHub does not.
#
# The cooldown counts every run and not only the ones dispatched from here,
# because the schedule still fires. An unset or empty cooldown dispatches every
# time, deliberately: this is a cost knob and not a guard, and the irreversible
# direction here is a mirror that did not run.
#   see docs/archive.md#asking-the-mirror-to-run
set -uo pipefail

REPO="${AGENT_ARCHIVE_REPO:?not set — the archive repository, owner/name, from .env}"
# No apostrophe in either message above: inside ${var:?word} bash opens a single
# quote even within double quotes, and the script then fails to parse at its last
# line with an error naming neither this line nor the quote.
#   see docs/archive.md#a-quoting-trap-in-three-files
WORKFLOW="${AGENT_ARCHIVE_WORKFLOW:-mirror-${AGENT_USER:?not set — run this through \`just\`, which derives it}.yml}"

# Minutes. Read from .env by `just`, and deliberately not passed into the
# container: this is host bookkeeping a session could do nothing with.
cooldown="${AGENT_ARCHIVE_MIRROR_COOLDOWN:-}"

case "$cooldown" in
    '') ;;
    *[!0-9]*)
        echo "AGENT_ARCHIVE_MIRROR_COOLDOWN is '$cooldown', which is not a number of minutes." >&2
        echo "Asking for the mirror anyway — see the header." >&2
        cooldown=''
        ;;
esac

errfile=$(mktemp); trap 'rm -f "$errfile"' EXIT


# --- is there a workflow to ask ---
# An archive seeded without one is the ordinary state of a fresh
# installation, said in one line and not as a failed dispatch.

if ! gh api "repos/$REPO/actions/workflows/$WORKFLOW" --jq .id >/dev/null 2>"$errfile"; then
    if grep -q 'HTTP 404' "$errfile"; then
        echo "The archive has no mirror workflow ($WORKFLOW): nothing to dispatch. examples/archive/ carries one; seed the archive's main from it, then run 'just setup-archive'."
        exit 0
    fi
    echo "Could not ask the archive about its workflows: $(grep -m1 . "$errfile" || echo 'gh gave no reason')" >&2
    exit 1
fi

if [ -n "$cooldown" ] && [ "$cooldown" -gt 0 ]; then
    # In-progress runs are listed too, which is what we want: a mirror that
    # started a minute ago and is still going has run. A dispatch takes a few
    # seconds to appear here, so a cooldown of a minute or two would sometimes
    # miss the run it just asked for; the value this is for is an hour.
    if ! last=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" \
                    --limit 1 --json createdAt --jq '.[0].createdAt' 2>"$errfile"); then
        echo "Could not read the mirror's recent runs: $(grep -m1 . "$errfile" || echo 'gh gave no reason')" >&2
        echo "Asking for the mirror anyway — see the header." >&2
        last=''
    fi

    if [ -n "$last" ]; then
        # A createdAt this host cannot parse is one more reading that failed,
        # and those fall towards running.
        if when=$(date -u -d "$last" +%s 2>/dev/null) && [ -n "$when" ]; then
            # Negative when GitHub's clock is ahead of this one, which reads
            # as "ran just now" and skips — the safe direction here, since a
            # skipped dispatch costs an hour the schedule still covers.
            age=$(( ( $(date +%s) - when ) / 60 ))
            [ "$age" -lt 0 ] && age=0
            if [ "$age" -lt "$cooldown" ]; then
                echo "The mirror ran ${age}m ago; AGENT_ARCHIVE_MIRROR_COOLDOWN=${cooldown} asks for ${cooldown}m. Not dispatched."
                exit 0
            fi
        fi
    fi
fi

# Its own stdout is held back: it says "Created workflow_dispatch event for
# $WORKFLOW at main", which is this line with more words.
if ! gh workflow run "$WORKFLOW" --repo "$REPO" >/dev/null; then
    echo "The mirror could not be dispatched." >&2
    exit 1
fi
echo "Asked $REPO to mirror the memory now."
