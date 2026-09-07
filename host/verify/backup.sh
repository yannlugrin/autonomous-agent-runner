# shellcheck shell=bash
# Whether the agent's memory is still being backed up.
#
# Asked of `just mirror-status` rather than recomputed here: it already reads
# the workflow, the ref and the source, and two implementations of "is the
# backup running" is one that drifts. Its exit status is the answer.
#
# The one probe here that needs the network, deliberately. Every other section
# proves a mechanism against a container twin; this asks a forge whether a
# thing that runs elsewhere is still running, and there is no offline way to
# know. Unreachable is LOOK and never ok: not proven is not proven.
# see docs/verify.md#backup-running

echo "== the backup =="


# --- backup running ---
# FAIL rather than LOOK, and this is the one place in the suite that judges a
# thing outside the image: the mirror is what makes the agent's memory outlive
# a repository the agent may rewrite. It failed silently for three days in
# September 2026 with every other signal green, which is what this exists for.
# see docs/archive.md#the-key-goes-on-before-the-secret-goes-in

if ! command -v gh >/dev/null 2>&1; then
    verdict LOOK "backup running" "gh is not installed, so nothing here can ask whether the mirror ran"
else
    # Three answers and not two, which is why this reads the status rather than
    # branching on success: 0 ran, 1 stopped, 2 could not be read. The reasons
    # of the last two are written under the recipe's own verdict, one per line.
    #   see docs/archive.md#a-reading-that-failed-is-not-a-judgement
    out=$(host/archive/mirror.sh 2>&1); code=$?
    why=$(printf '%s' "$out" | sed -n '/^== verdict ==/,$p' | sed -n 's/^    - //p' | paste -sd'; ' -)
    if [ "$code" -eq 0 ]; then
        verdict ok "backup running" "$(printf '%s' "$out" | sed -n 's/^  *ok — //p')"
    elif [ "$code" -eq 2 ]; then
        # Unreachable is LOOK and never ok, and it is not a FAIL either: this
        # is the state where nothing was read, not one where something stopped.
        verdict LOOK "backup running" "$why"
    else
        # No reasons is not a judgement: the recipe ended before it reached one,
        # and a bare `[FAIL] backup running` is then a mechanism this probe
        # cannot tell from a stopped backup. The last line it printed is the
        # whole clue, and it names the line it died on.
        [ -n "$why" ] || why="'just mirror-status' ended without a verdict, so nothing here judged the backup: $(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
        verdict FAIL "backup running" "$why"
    fi
fi
