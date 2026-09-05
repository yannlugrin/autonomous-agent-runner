#!/usr/bin/env bash
# The live view from another device: ttyd behind Tailscale, both in the
# foreground of this window, both gone when it closes.
#
# Runs on the host. What it serves is a plain `just listen --live` — the
# forwarding to the deployed checkout, the lock, the container, the render and
# the stop are that recipe's and are not touched here. This file is only the
# transport, and it holds nothing the session can read.
# see docs/sessions.md#the-live-view-from-another-device
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

port="${RUNNER_REMOTE_PORT:-7681}"

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

# EXIT does the killing and the other three are only how the script gets there:
# bash takes a fatal signal's default action without running an EXIT trap, so an
# untrapped HUP would leave the daemon behind — which is the one thing this
# recipe must not do.
trap 'exit 0' HUP INT TERM
trap 'kill "$daemon" 2>/dev/null' EXIT

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
# One client, so a second device cannot start a second follow and a
# second container with it. No --writable, so the page renders and nothing it
# sends can reach the session. --check-origin, so a page the viewing browser
# happens to be visiting cannot open this socket and read the transcript out of
# it.
# see docs/sessions.md#the-live-view-from-another-device

echo
echo "    http://$ip:$port"
echo
echo "This window is the server: Ctrl-C, or closing it, ends the stream and takes"
echo "this machine off the tailnet. One viewer at a time, read-only, and a device"
echo "that reconnects starts the render again from the top of the session."
echo

ttyd --interface 127.0.0.1 --port "$port" --max-clients 1 --check-origin \
     -t "titleFixed=$AGENT_NAME — live" \
     just listen --live
