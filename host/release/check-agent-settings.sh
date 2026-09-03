#!/usr/bin/env bash
# Report any `permissions` block in a settings file the agent can write:
# $HOME/.claude/settings*.json and <checkout>/.claude/settings*.json, both
# honoured. An allow rule is a capability grant and not a note — it exempts a
# spelling from the one layer that still judges what `defaultMode: auto` would
# otherwise run — and nothing else here would say a word about one. Any
# permissions block is drift, because nothing the agent writes needs one: hence
# an invariant, not a diff against an approved copy that would go stale here.
# see docs/boundary.md#check-agent-settings-and-why-an-invariant
#
# It stops nothing, and it must not: a session stood down on a settings edit
# would be an agent that can lock itself out of its own container. It is not a
# security boundary either — the agent can read this file, and one that wanted
# to hide would write its rule, act, and remove it between two runs. It catches
# the durable case, which is the one that matters: a grant left in place,
# working, unnoticed.
#
# --quiet prints nothing when the files are clean, for callers that only
# want the exit status. Exit 0 clean, 1 something found, 2 could not look.
set -uo pipefail

# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

quiet=false
case "${1:-}" in --quiet) quiet=true ;; "") ;; *) echo "Usage: check-agent-settings.sh [--quiet]" >&2; exit 2 ;; esac

# `just` computes AGENT_USER and exports it; compose requires it and cannot
# derive it, because it cannot lowercase a name. Said here rather than left to
# compose's eleven interpolation errors, which are the correct complaint and
# not a readable one.
if [ -z "${AGENT_USER:-}" ]; then
    echo "AGENT_USER is unset — run this through 'just', which computes and exports it." >&2
    exit 2
fi

# --entrypoint python3, the same idiom `just verify` uses to read the image's
# own settings: it skips bootstrap, which has side effects, and reads the
# volume, which is the live world this is about. No session, so no budget.
#
# The repo directory is derived the way everything else derives it — from the
# container's own user name — rather than passed in, so a renamed agent does
# not leave this reading a path that no longer exists.
out=$(docker compose run --rm -T --entrypoint python3 agent -c '
import getpass, json, os, sys

home = os.path.expanduser("~")
repo = os.environ.get(getpass.getuser().upper().replace("-", "_") + "_REPO_DIR")
paths = [os.path.join(home, ".claude", "settings.json"),
         os.path.join(home, ".claude", "settings.local.json")]
if repo:
    paths += [os.path.join(repo, ".claude", "settings.json"),
              os.path.join(repo, ".claude", "settings.local.json")]
else:
    print("UNREADABLE\t(repo dir unset)\t_REPO_DIR names no path in this container")

for p in paths:
    try:
        with open(p) as f:
            d = json.load(f)
    except FileNotFoundError:
        continue
    except Exception as e:
        # A file Claude Code cannot parse is a file whose rules do not apply,
        # which is a different fact from a clean one and must not read as it.
        print("UNREADABLE\t%s\t%s" % (p, e))
        continue
    perms = d.get("permissions")
    if not isinstance(perms, dict):
        continue
    for key in ("allow", "deny", "ask", "defaultMode", "additionalDirectories"):
        v = perms.get(key)
        if v in (None, [], {}):
            continue
        print("FOUND\t%s\t%s = %s" % (p, key, json.dumps(v)))
' 2>/dev/null)
rc=$?

if [ $rc -ne 0 ]; then
    echo "Agent settings: could not be read — the container did not answer." >&2
    exit 2
fi

# An UNREADABLE line is not a clean answer. Reported as loudly as a finding
# and exits the same way, because the failure this whole script is against is
# a silent one.
if [ -z "$out" ]; then
    $quiet || echo "Agent settings: no permissions block in any file the agent can write."
    exit 0
fi

echo "Agent settings: a permissions block is present where none belongs."
printf '%s\n' "$out" | while IFS=$'\t' read -r kind path detail; do
    printf '  %-10s %s\n             %s\n' "$kind" "$path" "$detail"
done
echo "  Every rule the agent needs is in image/managed-settings.json. An allow here"
echo "  exempts a command from the auto-mode classifier; it cannot loosen the deny list."
exit 1
