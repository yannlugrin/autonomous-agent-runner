#!/usr/bin/env bash
# Stop early, and say why, when the docker daemon is not answering.
#
# Runs on the host, called as a command by the recipes that need docker and by
# host/archive/collect.sh — not sourced, because there is no state to share.
#
# Its own step because the daemon here comes and goes, and without a check every
# recipe reports that absence as whatever its own first docker call happens to
# say: a stopped daemon reaching the collection reads as a lost volume rather
# than a stopped service, the worst possible wording for the one thing here that
# must never be assumed lost. It matters most from cron, where nobody reads the
# failure as it happens.
#
# `docker version` rather than `docker info`: both ask the server, and it is the
# cheaper one on a check that runs before every recipe.
# see docs/sessions.md#the-docker-daemon-and-a-missing-image

# --image NAME: also require that image to exist locally. Opt-in, because
# `build` runs before there is one and `collect` reads the volume through
# alpine. The recipes that start a container on compose's default pass the tag
# that would run, since a missing tag otherwise surfaces as compose being
# refused a Docker Hub pull — which reads as a credential problem, not as
# "nothing was deployed yet".
set -uo pipefail
image=""
case "${1:-}" in --image) image="${2:-}" ;; esac

if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    [ -z "$image" ] && exit 0
    docker image inspect "$image" >/dev/null 2>&1 && exit 0
    cat >&2 <<MSG

No image tagged $image on this machine, so nothing can run on it.

Nothing was started, and nothing was changed. 'just build' makes the
candidate; 'just deploy' tags the deployed one, and nothing else does.

This is exit 69, the same as a daemon that is not answering: in both cases
the host is not ready, and neither is a session's fault.
MSG
    exit 69
fi

# 69 is EX_UNAVAILABLE, chosen to sit beside the two this repository already
# uses: 75 for an hour skipped because a session held the lock, 78 for
# bootstrap regressed — three causes, three codes, told apart without parsing
# text.
cat >&2 <<'MSG'

Docker is installed, but its daemon is not answering.

Nothing was started, and nothing was changed.

  Docker Desktop — what provides the daemon on this machine: start it on
  Windows, and check that WSL integration is enabled for this distro.

  A native daemon instead:  sudo systemctl start docker

Then run the same command again. This is exit 69: distinct from 75, an hour
skipped because a session was already running, and from 78, bootstrap
regressed and nothing started.
MSG
exit 69
