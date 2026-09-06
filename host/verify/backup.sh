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
# see docs/verify.md#is-the-backup-running

echo "== the backup =="


# --- backup running ---
# FAIL rather than LOOK, and this is the one place in the suite that judges a
# thing outside the image: the mirror is what makes the agent's memory outlive
# a repository the agent may rewrite. It failed silently for three days in
# September 2026 with every other signal green, which is what this exists for.
# see docs/archive.md#the-key-goes-on-before-the-secret-goes-in

if ! command -v gh >/dev/null 2>&1; then
    verdict LOOK "backup running" "gh is not installed, so nothing here can ask whether the mirror ran"
elif out=$(host/archive/mirror.sh 2>&1); then
    verdict ok "backup running" "$(printf '%s' "$out" | sed -n 's/^  *ok — //p')"
else
    # Its own words, indented under the verdict: the reasons are what say
    # whether this is a broken credential, a disabled workflow or a dead
    # schedule, and they are already written there.
    verdict FAIL "backup running" \
        "$(printf '%s' "$out" | sed -n '/^== verdict ==/,$p' | sed -n 's/^    - //p' | paste -sd'; ' -)"
fi
