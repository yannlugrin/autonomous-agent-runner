#!/usr/bin/env bash
# The live view from another device: ttyd behind Tailscale, both in the
# foreground of this window.
#
# Runs on the host. The follow is this window's own `just listen --live`, tee'd
# to a file that ttyd serves with `tail -F`. So the window shows the transcript
# rather than a server's log, one container feeds any number of viewers, and a
# viewer that goes away costs a `tail` and not a session's worth of following.
# This file is only the transport, and it holds nothing the session can read.
# see docs/sessions.md#the-live-view-from-another-device
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

port="${RUNNER_REMOTE_PORT:-7681}"

# What the window prints and what the viewers tail, one file: `mktemp` because
# it is a buffer that dies with the run and not a record, and because two runs
# must not share one.
view=$(mktemp) || exit 1

# Tailscale's own state, outside the checkout and outside the agent's cache: it
# holds this node's key, and a node that re-registers every run is a new machine
# in the admin console every run. The directory is what persists — the daemon
# reading it does not.
state="${XDG_STATE_HOME:-$HOME/.local/state}/tailscaled"
sock="${XDG_RUNTIME_DIR:-/tmp}/tailscaled-$UID.sock"
log="$state/daemon.log"


# --- what has to be installed ---
# Named one at a time rather than as a set, because `tailscale` without
# `tailscaled` is what an apt install that has been removed leaves behind.

for binary in tailscaled tailscale ttyd; do
    command -v "$binary" >/dev/null && continue
    echo "$binary is not installed, and this is the only recipe that wants it." >&2
    echo >&2
    echo "  ttyd                     apt install ttyd" >&2
    echo "  tailscale, tailscaled    the static tarball from pkgs.tailscale.com," >&2
    echo "                           which ~/.dotfiles puts in ~/.local/bin" >&2
    exit 1
done


# --- what this window is holding ---
# EXIT does the taking down, and the three signals are only how the script gets
# there: bash takes a fatal signal's default action without running an EXIT
# trap, so an untrapped HUP would leave a daemon behind — the one thing this
# recipe must not do. Installed before anything is started, so there is nothing
# it can miss.

daemon=""
viewer=""

# shellcheck disable=SC2329  # invoked by the EXIT trap below
stop_all() {
    [ -n "$viewer" ] && kill "$viewer" 2>/dev/null
    [ -n "$daemon" ] && kill "$daemon" 2>/dev/null
    rm -f "$view"
    return 0
}
trap 'exit 0' HUP INT TERM
trap stop_all EXIT


# --- the tailnet, for as long as this window ---
# Userspace networking, which is what lets this run as an ordinary user with no
# tun device, no root and no system service — and it is what makes the port
# above reachable at all: in this mode tailscaled proxies an inbound connection
# to the same port on 127.0.0.1, which is the only address ttyd is bound to.
#
# The socket is this daemon's own. The CLI defaults to the system one, so every
# call below passes --socket or it would ask a daemon that is not there.

mkdir -p "$state" && chmod 700 "$state" || exit 1

tailscaled --tun=userspace-networking --statedir="$state" --socket="$sock" >"$log" 2>&1 &
daemon=$!

for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || {
    echo "tailscaled did not come up. Its last words, from $log:" >&2
    tail -n 5 "$log" >&2
    exit 1
}

# `up` every time and not only when logged out: it is idempotent on a node that
# already has its key, and it is the one command that prints the login URL on a
# node that does not. The hostname says which node this is, and keeps it apart
# from a Tailscale installed here for anything else.
tailscale --socket="$sock" up --hostname="$(hostname)-remote" || exit 1
ip=$(tailscale --socket="$sock" ip -4) || exit 1


# --- the viewer ---
# 127.0.0.1 spelled as an address, because `-i lo` binds the other address WSL
# keeps on that interface — which the tailnet proxy never hands anything to —
# and `-i localhost` binds nothing at all. Both silent, both measured.
#
# No --writable, so the page renders and nothing it sends reaches anything.
# --check-origin, so a page the viewing browser happens to be visiting cannot
# open this socket from the side and read the transcript out of it. `-d 3`
# drops libwebsockets' notices, which are what would otherwise fill this window
# instead of the transcript. A font that can be read at arm's length, which the
# device overrides for itself with `?fontSize=` on the URL.
#
# `tail -F` and not the recipe: every client gets its own child, and a child
# that is a tail costs nothing to start, nothing to stop, and does not follow a
# session of its own.
# see docs/sessions.md#the-live-view-from-another-device

ttyd --interface 127.0.0.1 --port "$port" --check-origin -d 3 \
     -t fontSize=18 -t "titleFixed=$AGENT_NAME — live" \
     tail -n +1 -F "$view" &
viewer=$!

echo
echo "    http://$ip:$port"
echo
echo "Read-only, for any device on the tailnet; add ?fontSize=24 to the URL to"
echo "size it for the one you are reading it on. Ctrl-C here ends the stream and"
echo "takes this machine off the tailnet. The transcript follows, below and there."
echo

just listen --live | tee "$view"
