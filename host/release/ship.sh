#!/usr/bin/env bash
# Put a locally built image on the machine the agent runs on.
#
# Runs on the host you build at. One argument: the tag to send, which arrives
# there under the same name. Called by `just deploy`; there is no recipe for it,
# because shipping an image nothing then checks is not an act worth a name.
#
# `docker save | ssh docker load` and not a registry: the whole image crosses
# every time, about 1.2 GB, and nothing leaves the two machines. A registry
# would send only the changed layers, and is what to reach for if that time ever
# stops being worth the simplicity. see docs/release.md#the-image-crosses-whole
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
# shellcheck source=SCRIPTDIR/../lib/deploy-host.sh
. host/lib/deploy-host.sh

tag="${1:?ship.sh <tag>}"

deploying_elsewhere || {
    echo "RUNNER_DEPLOY_HOST is empty: the agent runs here, and there is nothing to ship to." >&2
    exit 2; }

# The id, in full. It is what makes the transfer provable: `docker load` is
# content-addressed, so the image that arrives carries the id it left with, and
# a comparison of the two is a comparison of every byte that went into it — the
# commit, the untracked config files and the build arguments together.
here=$(docker images -q --no-trunc "$tag" 2>/dev/null | head -1)
[ -n "$here" ] || { echo "No image tagged $tag here. 'just build' makes one." >&2; exit 1; }

bytes=$(docker image inspect -f '{{.Size}}' "$tag" 2>/dev/null)
echo "Shipping $tag to $RUNNER_DEPLOY_HOST — about $(awk -v b="${bytes:-0}" 'BEGIN{printf "%.1f GB", b/1073741824}')."

# Minutes of silence read as a hang, and the size is known in advance, so this
# says how far rather than merely that it is alive. `pv` is the standard tool
# and is not required: without it, elapsed time in place.
#
# NOT `dd status=progress`: measured 2026-09-09 on uutils coreutils 0.8.0 — the
# one Ubuntu 26.04 ships and the one on this machine — where the flag is
# ACCEPTED and prints nothing but the closing summary. A progress flag that
# silently does nothing is worse than none.
# see docs/release.md#the-image-crosses-whole

if command -v pv >/dev/null 2>&1; then
    sent=0
    docker save "$tag" | pv -s "${bytes:-0}" | host_ssh "docker load" || sent=1
else
    docker save "$tag" | host_ssh "docker load" &
    transfer=$!
    started=$(date +%s)
    while kill -0 "$transfer" 2>/dev/null; do
        printf '\r  %ss elapsed (install pv for a bar and an ETA)' "$(( $(date +%s) - started ))"
        sleep 5
    done
    printf '\r%*s\r' 60 ''
    wait "$transfer"; sent=$?
fi

if [ "$sent" -ne 0 ]; then
    echo "The image did not arrive; nothing on $RUNNER_DEPLOY_HOST was changed." >&2
    exit 1
fi

there=$(host_ssh "docker images -q --no-trunc '$tag'" 2>/dev/null | tr -d '\r' | head -1)

if [ "$here" != "$there" ]; then
    echo "The image that arrived is not the one that left:" >&2
    echo "  here:  ${here:-none}" >&2
    echo "  there: ${there:-none}" >&2
    exit 1
fi

echo "Shipped: $tag is ${here#sha256:} on both machines."
